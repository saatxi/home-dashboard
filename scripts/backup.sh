#!/usr/bin/env bash
# Backup NOMÉS DE LECTURA via adb exec-out + dd. No escriu res al dispositiu.
# Ús: scripts/backup.sh [--with-data]   (per defecte: sense UDISK/data)
source "$(dirname "$0")/common.sh"
need sha256sum; require_device; check_identity
[ "$(adb shell id -u | tr -d '\r')" = "0" ] || { echo "Cal adbd root (id=0)." >&2; exit 1; }
WITH_DATA=0; [ "${1:-}" = "--with-data" ] && WITH_DATA=1
GZ=gzip; command -v pigz >/dev/null && GZ=pigz
dest="$ROOT/backups/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dest"
dump(){  # dump <dispositiu-remot> <nom>
  local dev="$1" name="$2" size rhash lhash
  size=$(adb shell "blockdev --getsize64 $dev 2>/dev/null || echo \$((\$(cat /sys/class/block/\$(basename \$(readlink -f $dev))/size)*512))" | tr -d '\r')
  echo "== $name ($dev) $size bytes"
  rhash=$(adb shell "sha256sum $dev 2>/dev/null || toybox sha256sum $dev" | awk '{print $1}')
  lhash=$(adb exec-out "dd if=$dev bs=4M 2>/dev/null" | tee >($GZ -1 >"$dest/$name.img.gz") | sha256sum | awk '{print $1}')
  wait
  [ "$rhash" = "$lhash" ] || { echo "HASH NO COINCIDEIX a $name (remot $rhash, local $lhash)" >&2; exit 3; }
  printf '%s  %s\n%s\n' "$lhash" "$name.img.gz(raw)" "$size" >"$dest/$name.sha256"
  echo "   OK sha256=$lhash"
}
for d in mmcblk0boot0 mmcblk0boot1; do adb shell "[ -e /dev/block/$d ]" && dump "/dev/block/$d" "$d"; done
for p in $(adb shell 'ls /dev/block/by-name' | tr -d '\r'); do
  case "$p" in mmcblk0*) continue;; esac   # disc sencer, boot0/1 (ja fets) i RPMB: no són particions
  if { [ "$p" = "UDISK" ] || [ "$p" = "media_data" ]; } && [ $WITH_DATA = 0 ]; then echo "-- salto $p (usa --with-data)"; continue; fi
  dump "/dev/block/by-name/$p" "part-$p"
done
echo "Backup a $dest. Seguiu amb scripts/verify-backup.sh $dest"
