#!/usr/bin/env bash
# Funcions compartides. Tot el que es fa al dispositiu és NOMÉS LECTURA.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_PLATFORM="sun50iw10p1"   # Allwinner A133 (Xoro CPF10PF / LOOFII C-3)

need() { command -v "$1" >/dev/null || { echo "Falta '$1'. Vegeu docs/wsl-setup.md" >&2; exit 1; }; }

# Executa una ordre al dispositiu com a root (adbd root o su)
dev_root() {
  if [ "$(adb shell id -u 2>/dev/null | tr -d '\r')" = "0" ]; then adb shell "$@"
  else adb shell "su -c '$*'"; fi
}
dev_root_out() {  # com dev_root però binari-segur (exec-out)
  if [ "$(adb shell id -u 2>/dev/null | tr -d '\r')" = "0" ]; then adb exec-out "$@"
  else adb exec-out "su -c '$*'"; fi
}

require_device() {
  need adb
  [ "$(adb get-state 2>/dev/null)" = "device" ] || { echo "Cap dispositiu ADB. Executeu scripts/wsl-usb-check.sh" >&2; exit 1; }
}

# Para al primer desajust d'identitat (regla del repo de referència)
check_identity() {
  local p m; p="$(adb shell getprop ro.hardware | tr -d '\r')"; m="$(adb shell getprop ro.product.model | tr -d '\r')"
  [ "$p" = "$EXPECTED_PLATFORM" ] || { echo "ATURA: ro.hardware='$p', s'esperava '$EXPECTED_PLATFORM'. No és el dispositiu documentat." >&2; exit 2; }
  echo "Identitat OK: model=$m ro.hardware=$p"
}
