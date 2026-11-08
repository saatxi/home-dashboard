#!/usr/bin/env bash
# Verifica un backup: re-llegeix cada fitxer comprimit i compara amb el hash guardat.
source "$(dirname "$0")/common.sh"
dir="${1:?ús: verify-backup.sh <carpeta-backup>}"; bad=0
for f in "$dir"/*.img.gz; do
  n=$(basename "$f" .img.gz); exp=$(head -1 "$dir/$n.sha256" | awk '{print $1}'); size=$(sed -n 2p "$dir/$n.sha256")
  got=$(zcat "$f" | tee >(wc -c >/tmp/sz.$$) | sha256sum | awk '{print $1}'); wait; gsz=$(cat /tmp/sz.$$); rm -f /tmp/sz.$$
  if [ "$got" = "$exp" ] && [ "$gsz" = "$size" ]; then echo "[OK]   $n"; else echo "[FALLA] $n"; bad=1; fi
  zcat "$f" | head -c 1048576 | grep -qaP '\xcc{65536}' && { echo "[AVÍS] $n conté filler 0xCC"; bad=1; }
done
exit $bad
