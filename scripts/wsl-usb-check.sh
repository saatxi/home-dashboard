#!/usr/bin/env bash
set -Eeuo pipefail

DEPENDENCIES=(lsusb adb)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage_text() {
    cat <<EOM

Diagnòstic de la cadena USB -> usbipd-win -> WSL -> adb. No canvia res.

usage: ${SCRIPT_NAME} [options]

options:
    -h|--help    Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[*]}

examples:
    ${SCRIPT_NAME}


sortida: el nombre de comprovacions que han fallat (0 = tot correcte)
EOM
}

main() {
    while [ $# -gt 0 ]; do
        case $1 in
        -h | --help)
            usage 0
            ;;
        *)
            print_error "Opció desconeguda '$1'"
            usage
            ;;
        esac
        shift
    done

    # Després d'analitzar els arguments: --help ha de funcionar sense lsusb ni adb
    exit_on_missing_tools "${DEPENDENCIES[@]}"

    local failures=0
    check_wsl_kernel || failures=$((failures + 1))
    check_vhci_module || failures=$((failures + 1))
    check_usb_bus || failures=$((failures + 1))
    check_allwinner_device || failures=$((failures + 1))
    check_udev_rule || failures=$((failures + 1))
    check_adb || failures=$((failures + 1))

    return "$failures"
}

check_wsl_kernel() {
    if ! uname -r | grep -i microsoft >/dev/null; then
        print_error "No sembla WSL"
        return 1
    fi
    print_success "WSL: $(uname -r)"
    # grep sense -q: llegeix tot el flux i evita un SIGPIPE a zcat (pipefail) que donaria un fals error
    if ! zcat /proc/config.gz 2>/dev/null | grep '^CONFIG_USBIP_VHCI_HCD' >/dev/null; then
        print_error "Kernel sense USBIP VHCI"
        return 1
    fi
    print_success "Kernel amb USBIP VHCI"
}

check_vhci_module() {
    if ! lsmod | grep vhci_hcd >/dev/null; then
        print_error "vhci_hcd no carregat: sudo modprobe vhci_hcd"
        return 1
    fi
    print_success "vhci_hcd carregat"
}

check_usb_bus() {
    if [ ! -d /sys/bus/usb/devices ]; then
        print_error "/sys/bus/usb absent: cal 'usbipd attach --wsl' (Windows) i vhci_hcd"
        return 1
    fi
    print_success "/sys/bus/usb existeix"
}

check_allwinner_device() {
    local found
    found=$(lsusb 2>/dev/null | grep -i '1f3a') || found=""
    if [ -z "$found" ]; then
        print_error "Cap dispositiu 1f3a visible (usbipd list / bind / attach)"
        return 1
    fi
    print_success "Dispositiu Allwinner visible: ${found}"
}

check_udev_rule() {
    if [ ! -f /etc/udev/rules.d/51-android.rules ]; then
        print_error "Falta /etc/udev/rules.d/51-android.rules"
        return 1
    fi
    print_success "Regla udev present"
}

# adb start-server pot penjar-se des d'algunes shells: el límit evita bloquejar l'script
check_adb() {
    print_success "$(adb version | sed -n 1p)"
    local devices
    devices=$(timeout 15 adb devices -l 2>/dev/null | tail -n +2 | grep -v '^$') || devices=""
    if [ -z "$devices" ]; then
        print_error "adb no veu cap dispositiu (o el servidor no respon en 15 s)"
        return 1
    fi
    print_success "adb veu: ${devices}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
