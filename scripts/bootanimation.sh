#!/usr/bin/env bash
set -Eeuo pipefail

DEPENDENCIES=(python3 zip unzip sha256sum)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Directori propi dins de kiosk/build/: build-kiosk.sh no el toca (i bootanimation.sh no toca la resta)
OUT_DIR="${BOOTANIMATION_OUT_DIR:-${ROOT}/kiosk/build/bootanimation}"
ZIP="${OUT_DIR}/bootanimation.zip"
DEVICE_ZIP="/data/local/bootanimation.zip"
SYSTEM_ZIP="/system/media/bootanimation.zip"
WIDTH=1920
HEIGHT=1200
FPS=30

usage_text() {
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

install, remove i status comproven primer que el dispositiu sigui el documentat
(ro.hardware = ${EXPECTED_HARDWARE}). install regenera sempre el zip abans de desar-lo.

options:
    -y|--yes     No demanis confirmació (només per a install i remove)
    -h|--help    Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[*]} adb

examples:
    ${SCRIPT_NAME} build
    ${SCRIPT_NAME} status
    ${SCRIPT_NAME} install
    ${SCRIPT_NAME} remove --yes

EOM
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

# Dispositiu present i verificat abans de qualsevol ordre que hi parli
connect_device() {
    require_device
    check_identity
}

show_status() {
    local selinux
    connect_device
    print_header "Animació d'arrencada al marc"
    if adb_sh "test -f ${DEVICE_ZIP}"; then
        print_success "Substituïda: ${DEVICE_ZIP}"
        adb_sh "ls -l ${DEVICE_ZIP}; sha256sum ${DEVICE_ZIP}" | sed 's/^/           /'
    else
        print_warning "No hi ha ${DEVICE_ZIP}: surt l'animació de fàbrica"
    fi
    # Pot no existir (la sortida de 'test' evita que pipefail aturi l'script)
    if adb_sh "test -f ${SYSTEM_ZIP}"; then
        adb_sh "ls -l ${SYSTEM_ZIP}; sha256sum ${SYSTEM_ZIP}" | sed 's/^/           /'
    else
        print_warning "No hi ha ${SYSTEM_ZIP} al sistema"
    fi
    selinux="$(adb_sh getenforce)" || selinux="desconegut"
    print_success "SELinux: ${selinux} (el kiosk tanca l'animació amb setprop; cal Permissive)"
}

install_zip() {
    connect_device
    # Sempre es regenera: és barat i evita desar un zip antic si canvia l'script
    build_zip
    if [ "${ASSUME_YES}" != true ] &&
        ! confirm "Desar l'animació negra a ${DEVICE_ZIP} (es desfà amb '${SCRIPT_NAME} remove')?"; then
        print_warning "Cancel·lat"
        return 1
    fi
    if ! adb push "${ZIP}" "${DEVICE_ZIP}" >/dev/null; then
        print_error "adb push ha fallat"
        return 1
    fi
    adb_sh "chmod 644 ${DEVICE_ZIP}" >/dev/null
    local local_sum remote_sum
    local_sum=$(sha256sum "${ZIP}" | cut -d' ' -f1)
    remote_sum=$(adb_sh "sha256sum ${DEVICE_ZIP}" | cut -d' ' -f1) || remote_sum=""
    if [ -z "${remote_sum}" ] || [ "${local_sum}" != "${remote_sum}" ]; then
        print_error "El hash del marc no coincideix"
        return 1
    fi
    print_success "Desat i verificat (${remote_sum:0:12}…). Es veurà al proper reinici"
    log_change "push black bootanimation.zip to ${DEVICE_ZIP}" "adb shell rm ${DEVICE_ZIP}" ||
        print_warning "Canvi fet però no registrat; per desfer-lo: adb shell rm ${DEVICE_ZIP}"
}

remove_zip() {
    connect_device
    if ! adb_sh "test -f ${DEVICE_ZIP}"; then
        print_warning "No hi ha ${DEVICE_ZIP}: res a esborrar"
        return 0
    fi
    if [ "${ASSUME_YES}" != true ] &&
        ! confirm "Esborrar ${DEVICE_ZIP} (torna l'animació d'Uhale)?"; then
        print_warning "Cancel·lat"
        return 1
    fi
    adb_sh "rm -f ${DEVICE_ZIP}" >/dev/null
    if adb_sh "test -f ${DEVICE_ZIP}"; then
        print_error "No s'ha pogut esborrar ${DEVICE_ZIP}"
        return 1
    fi
    print_success "Esborrat. Tornarà l'animació de fàbrica al proper reinici"
    log_change "rm ${DEVICE_ZIP} (restore factory boot animation)" "adb push ${ZIP} ${DEVICE_ZIP}" ||
        print_warning "Canvi fet però no registrat; per restaurar-lo: adb push ${ZIP} ${DEVICE_ZIP}"
}

main() {
    local command=""
    ASSUME_YES=false
    while [ $# -gt 0 ]; do
        case $1 in
        build | status | install | remove)
            if [ -n "${command}" ]; then
                print_error "Només es pot indicar una ordre ('${command}' i '$1')"
                usage
            fi
            command="$1"
            ;;
        -y | --yes)
            ASSUME_YES=true
            ;;
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
    if [ -z "${command}" ]; then
        print_error "Cal indicar una ordre"
        usage
    fi

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
