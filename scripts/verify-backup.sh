#!/usr/bin/env bash
# Verifica un backup: re-llegeix cada fitxer comprimit i compara amb el hash guardat.
source "$(dirname "$0")/common.sh"
dir="${1:?ús: verify-backup.sh <carpeta-backup>}"; bad=0
for f in "$dir"/*.img.gz; do
  n=$(basename "$f" .img.gz); exp=$(head -1 "$dir/$n.sha256" | awk '{print $1}'); size=$(sed -n 2p "$dir/$n.sha256")
  got=$(zcat "$f" | tee >(wc -c >/tmp/sz.$$) | sha256sum | awk '{print $1}'); wait; gsz=$(cat /tmp/sz.$$); rm -f /tmp/sz.$$
  if [ "$got" = "$exp" ] && [ "$gsz" = "$size" ]; then echo "[OK]   $n"; else echo "[FALLA] $n"; bad=1; fi
  zcat "$f" | python3 -I -c 'import sys,re; r=re.compile(rb"\xcc{65535}"); t=b""
while (d:=sys.stdin.buffer.read(1<<20)):
    if r.search(t+d): sys.exit(1)
    t=d[-65535:]' || { echo "[AVÍS] $n conté filler 0xCC (>=64 KiB)"; bad=1; }
done
exit $bad
