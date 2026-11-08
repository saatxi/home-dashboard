#!/usr/bin/env bash
# Volcat NOMÉS DE LECTURA del dispositiu a diagnostics/<data>/ (privat, ignorat per git).
source "$(dirname "$0")/common.sh"
require_device; check_identity
out="$ROOT/diagnostics/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$out"
run(){ local n="$1"; shift; echo ">> $n"; adb shell "$@" >"$out/$n.txt" 2>&1 || true; }
run getprop getprop
run id id
run cmdline cat /proc/cmdline
run partitions cat /proc/partitions
run mounts cat /proc/mounts
run df df
run by-name 'ls -l /dev/block/by-name'
run mmc-devs 'ls -l /dev/block/ | grep mmcblk0'
run cpuinfo cat /proc/cpuinfo
run meminfo 'head -5 /proc/meminfo'
run packages 'pm list packages -f'
run usb-state 'getprop sys.usb.state'
run sizes 'for d in mmcblk0 mmcblk0boot0 mmcblk0boot1; do echo $d $(cat /sys/block/$d/size 2>/dev/null) sectors; done'
run su-perms 'ls -l /system/xbin/su /system/bin/su 2>&1'
run wlan 'ip addr show 2>&1 | grep -v link/ether'
echo "Resum:"; grep -E 'ro.product.(model|brand)|ro.build.(fingerprint|version.release)|ro.hardware|ro.board.platform|ro.secure|ro.debuggable' "$out/getprop.txt"
echo "Guardat a $out (conté dades privades: no commiteu)"
