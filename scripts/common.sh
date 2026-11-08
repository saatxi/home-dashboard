#!/usr/bin/env bash
# Llibreria compartida pels scripts (es carrega amb source, no s'executa).
# Tot el que es fa al dispositiu és NOMÉS LECTURA.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_HARDWARE="sun50iw10p1" # Allwinner A133 (Xoro CPF10PF / LOOFII C-3)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]]; then
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
fi

print_header() {
    echo -e "${BLUE}== $1${NC}"
}

print_success() {
    echo -e "${GREEN}[OK]${NC}     $1"
}

print_error() {
    echo -e "${RED}[FALLA]${NC}  $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[AVÍS]${NC}   $1"
}

exit_on_missing_tools() {
    for cmd in "$@"; do
        if command -v "$cmd" &>/dev/null; then
            continue
        fi
        print_error "Falta l'eina '${cmd}'. Vegeu docs/wsl-setup.md"
        exit 1
    done
}

require_device() {
    exit_on_missing_tools adb
    if [ "$(adb get-state 2>/dev/null)" != "device" ]; then
        print_error "Cap dispositiu ADB. Executeu scripts/wsl-usb-check.sh"
        exit 1
    fi
}

require_root() {
    if [ "$(adb shell id -u | tr -d '\r')" != "0" ]; then
        print_error "Cal adbd root (id=0)"
        exit 1
    fi
}

# Para al primer desajust d'identitat (regla del repo de referència)
check_identity() {
    local hardware model
    hardware="$(adb shell getprop ro.hardware | tr -d '\r')"
    model="$(adb shell getprop ro.product.model | tr -d '\r')"
    if [ "$hardware" != "$EXPECTED_HARDWARE" ]; then
        print_error "ATURA: ro.hardware='${hardware}', s'esperava '${EXPECTED_HARDWARE}'. No és el dispositiu documentat."
        exit 2
    fi
    print_success "Identitat: model=${model} ro.hardware=${hardware}"
}
