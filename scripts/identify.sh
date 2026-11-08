#!/usr/bin/env bash

DEPENDENCIES=(adb)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<EOM

Volcat NOMÉS DE LECTURA del dispositiu a diagnostics/<data>/ (privat, ignorat per git).
Para si el dispositiu no és el documentat (ro.hardware = ${EXPECTED_HARDWARE}).

usage: ${SCRIPT_NAME} [options]

options:
    -h|--help    Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[@]}

examples:
    ${SCRIPT_NAME}

EOM
    exit 1
}

main() {
    while [ "$1" != "" ]; do
        case $1 in
        -h | --help)
            usage
            ;;
        *)
            print_error "Opció desconeguda '$1'"
            usage
            ;;
        esac
        shift
    done

    exit_on_missing_tools "${DEPENDENCIES[@]}"
    require_device
    check_identity

    local out
    out="${ROOT}/diagnostics/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$out" || {
        print_error "No es pot crear ${out}"
        exit 1
    }

    collect_dumps "$out"
    print_summary "$out"
}

collect_dumps() {
    local out="$1"
    save_command "$out" getprop getprop
    save_command "$out" id id
    save_command "$out" cmdline cat /proc/cmdline
    save_command "$out" partitions cat /proc/partitions
    save_command "$out" mounts cat /proc/mounts
    save_command "$out" df df
    save_command "$out" by-name 'ls -l /dev/block/by-name'
    save_command "$out" mmc-devs 'ls -l /dev/block/ | grep mmcblk0'
    save_command "$out" cpuinfo cat /proc/cpuinfo
    save_command "$out" meminfo 'head -5 /proc/meminfo'
    save_command "$out" packages 'pm list packages -f'
    save_command "$out" usb-state 'getprop sys.usb.state'
    save_command "$out" sizes 'for d in mmcblk0 mmcblk0boot0 mmcblk0boot1; do echo $d $(cat /sys/block/$d/size 2>/dev/null) sectors; done'
    save_command "$out" su-perms 'ls -l /system/xbin/su /system/bin/su 2>&1'
    save_command "$out" wlan 'ip addr show 2>&1 | grep -v link/ether'
}

# Un volcat que falla no atura la resta: es deixa constància a l'avís
save_command() {
    local out="$1" name="$2"
    shift 2
    echo ">> ${name}"
    if ! adb shell "$@" >"${out}/${name}.txt" 2>&1; then
        print_warning "L'ordre '${name}' ha acabat amb error (vegeu ${name}.txt)"
    fi
}

print_summary() {
    local out="$1"
    print_header "Resum"
    grep -E 'ro.hardware|ro.board.platform|ro.product.(model|brand)|ro.build.(fingerprint|version.release)|ro.secure|ro.debuggable' "${out}/getprop.txt"
    echo "Guardat a ${out} (conté dades privades: no commiteu)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
