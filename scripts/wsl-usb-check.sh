#!/usr/bin/env bash
# Diagnòstic de la cadena USB -> usbipd-win -> WSL -> adb. No canvia res.
ok(){ echo "[OK]   $*"; }; ko(){ echo "[FALLA] $*"; }
uname -r | grep -qi microsoft && ok "WSL: $(uname -r)" || ko "No sembla WSL"
zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_USBIP_VHCI_HCD' && ok "Kernel amb USBIP VHCI" || ko "Kernel sense USBIP VHCI"
lsmod | grep -q vhci_hcd && ok "vhci_hcd carregat" || ko "vhci_hcd no carregat: sudo modprobe vhci_hcd"
command -v lsusb >/dev/null && ok "lsusb present" || ko "sudo apt install usbutils"
if [ -d /sys/bus/usb/devices ]; then ok "/sys/bus/usb existeix"; else ko "/sys/bus/usb absent: cal 'usbipd attach --wsl' (Windows) i vhci_hcd"; fi
lsusb 2>/dev/null | grep -i '1f3a' && ok "Dispositiu Allwinner (1f3a) visible" || ko "Cap dispositiu 1f3a visible (usbipd list / bind / attach)"
command -v adb >/dev/null && ok "$(adb version | head -1)" || ko "adb no instal·lat"
adb devices 2>/dev/null
[ -f /etc/udev/rules.d/51-android.rules ] && ok "regla udev present" || ko "Falta /etc/udev/rules.d/51-android.rules"
