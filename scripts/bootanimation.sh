#!/usr/bin/env bash

DEPENDENCIES=(python3 zip unzip sha256sum)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CHANGES_LOG="${ROOT}/frames/xoro/changes.jsonl"
OUT_DIR="${ROOT}/kiosk/build/bootanimation"
ZIP="${OUT_DIR}/bootanimation.zip"
DEVICE_ZIP="/data/local/bootanimation.zip"
SYSTEM_ZIP="/system/media/bootanimation.zip"
WIDTH=1920
HEIGHT=1200
FPS=30

usage() {
    cat <<EOM

Substitueix l'animació d'arrencada d'Uhale per una de negra, sense tocar /system.
Android 10 (build eng) llegeix ${DEVICE_ZIP} abans que ${SYSTEM_ZIP}.
Vegeu docs/hardening.md.

usage: ${SCRIPT_NAME} <command> [options]

commands:
    build        Genera ${ZIP} (només escriu a kiosk/build/)
    status       Mostra què hi ha al marc (només lectura)
    install      Desa el zip negre a ${DEVICE_ZIP} (escriu al marc)
    remove       Esborra ${DEVICE_ZIP}: torna l'animació d'Uhale (escriu al marc)

options:
    -y|--yes     No demanis confirmació (només per a install i remove)
    -h|--help    Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[@]} adb

examples:
    ${SCRIPT_NAME} build
    ${SCRIPT_NAME} status
    ${SCRIPT_NAME} install
    ${SCRIPT_NAME} remove --yes

EOM
    exit 1
}

# PNG negre sense dependències (sense PIL): filtre 0 + píxels RGB a zero, comprimit amb zlib.
write_black_png() {
    python3 -I - "$1" "${WIDTH}" "${HEIGHT}" <<'PY'
import struct, sys, zlib

path, width, height = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
raw = (b"\x00" + b"\x00\x00\x00" * width) * height


def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 9))
    + chunk(b"IEND", b"")
)
with open(path, "wb") as f:
    f.write(png)
PY
}

build_zip() {
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}/part0"
    write_black_png "${OUT_DIR}/part0/001.png"
    # 'p 0 0': es repeteix fins que el sistema tanca l'animació (el kiosk ho fa al arrencar)
    printf '%s %s %s\np 0 0 part0\n' "${WIDTH}" "${HEIGHT}" "${FPS}" >"${OUT_DIR}/desc.txt"
    # Sense compressió (-0): bootanim llegeix les entrades del zip directament.
    (cd "${OUT_DIR}" && zip -q -0 -r bootanimation.zip desc.txt part0)
    print_success "Generat ${ZIP} ($(stat -c %s "${ZIP}") bytes)"
    unzip -p "${ZIP}" desc.txt | sed 's/^/           /'
}

show_status() {
    require_device
    print_header "Animació d'arrencada al marc"
    if adb shell "test -f ${DEVICE_ZIP}"; then
        print_success "Substituïda: ${DEVICE_ZIP}"
        adb shell "ls -l ${DEVICE_ZIP}; sha256sum ${DEVICE_ZIP}" | tr -d '\r' | sed 's/^/           /'
    else
        print_warning "No hi ha ${DEVICE_ZIP}: surt l'animació de fàbrica"
    fi
    adb shell "ls -l ${SYSTEM_ZIP}; sha256sum ${SYSTEM_ZIP}" | tr -d '\r' | sed 's/^/           /'
    print_success "SELinux: $(adb shell getenforce | tr -d '\r') (el kiosk tanca l'animació amb setprop; cal Permissive)"
}

confirm() {
    local reply
    read -r -p "$1 (s/n): " -n 1 reply
    echo
    [[ "$reply" =~ ^[SsYy]$ ]]
}

log_change() {
    local action="$1"
    local undo="$2"
    mkdir -p "$(dirname "${CHANGES_LOG}")" || return 1
    printf '{"date":"%s","action":"%s","writes_to_device":true,"undo":"%s"}\n' \
        "$(date +%Y-%m-%d)" "${action}" "${undo}" >>"${CHANGES_LOG}"
    print_success "Registrat a ${CHANGES_LOG}"
}

install_zip() {
    require_device
    [ -f "${ZIP}" ] || build_zip
    if [ "${ASSUME_YES}" != true ] &&
        ! confirm "Desar l'animació negra a ${DEVICE_ZIP} (es desfà amb '${SCRIPT_NAME} remove')?"; then
        print_warning "Cancel·lat"
        return 1
    fi
    adb push "${ZIP}" "${DEVICE_ZIP}" >/dev/null
    adb shell "chmod 644 ${DEVICE_ZIP}"
    local local_sum remote_sum
    local_sum=$(sha256sum "${ZIP}" | cut -d' ' -f1)
    remote_sum=$(adb shell "sha256sum ${DEVICE_ZIP}" | tr -d '\r' | cut -d' ' -f1)
    if [ "${local_sum}" != "${remote_sum}" ]; then
        print_error "El hash del marc no coincideix"
        return 1
    fi
    print_success "Desat i verificat (${remote_sum:0:12}…). Es veurà al proper reinici"
    log_change "push black bootanimation.zip to ${DEVICE_ZIP}" "adb shell rm ${DEVICE_ZIP}"
}

remove_zip() {
    require_device
    if ! adb shell "test -f ${DEVICE_ZIP}"; then
        print_warning "No hi ha ${DEVICE_ZIP}: res a esborrar"
        return 0
    fi
    if [ "${ASSUME_YES}" != true ] &&
        ! confirm "Esborrar ${DEVICE_ZIP} (torna l'animació d'Uhale)?"; then
        print_warning "Cancel·lat"
        return 1
    fi
    adb shell "rm -f ${DEVICE_ZIP}"
    if adb shell "test -f ${DEVICE_ZIP}"; then
        print_error "No s'ha pogut esborrar ${DEVICE_ZIP}"
        return 1
    fi
    print_success "Esborrat. Tornarà l'animació de fàbrica al proper reinici"
    log_change "rm ${DEVICE_ZIP} (restore factory boot animation)" "adb push bootanimation.zip ${DEVICE_ZIP}"
}

main() {
    set -euo pipefail
    local command=""
    ASSUME_YES=false
    while [ "${1:-}" != "" ]; do
        case $1 in
        build | status | install | remove)
            command="$1"
            ;;
        -y | --yes)
            ASSUME_YES=true
            ;;
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
    [ -n "${command}" ] || usage

    exit_on_missing_tools "${DEPENDENCIES[@]}"
    case "${command}" in
    build) build_zip ;;
    status) show_status ;;
    install) install_zip ;;
    remove) remove_zip ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
