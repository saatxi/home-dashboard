#!/usr/bin/env bash
set -Eeuo pipefail

DEPENDENCIES=(zcat python3)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage_text() {
    cat <<EOM

Verifica un backup: llegeix el MANIFEST (ha d'existir i acabar amb 'complete=yes'),
comprova que hi siguin totes les peces i cap de sobrera, i rellegeix cada .img.gz per
comprovar-ne el SHA-256, la mida exacta i que no contingui 64 KiB seguits de 0xCC.
Un backup anterior al MANIFEST només dóna un avís ('sense MANIFEST') i es verifica
el que hi ha; no es pot saber si hi falta alguna peça.

usage: ${SCRIPT_NAME} <carpeta-backup>

options:
    -h|--help    Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[*]}

examples:
    ${SCRIPT_NAME} backups/20261108-090535

EOM
}

# Globals omplerts per load_manifest: nom -> "mida hash"
declare -A MANIFEST_PIECES=()
MANIFEST_COMPLETE=false

main() {
    local backup_dir=""

    while [ $# -gt 0 ]; do
        case $1 in
        -h | --help)
            usage 0
            ;;
        -*)
            print_error "Opció desconeguda '$1'"
            usage
            ;;
        *)
            if [ -n "$backup_dir" ]; then
                print_error "Només es pot indicar una carpeta"
                usage
            fi
            backup_dir="$1"
            ;;
        esac
        shift
    done

    if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
        print_error "Cal indicar una carpeta de backup existent"
        usage
    fi

    exit_on_missing_tools "${DEPENDENCIES[@]}"

    local failures=0 has_manifest=false
    local image name
    local -a images=() partials=()

    if [ -f "${backup_dir}/MANIFEST" ]; then
        has_manifest=true
        load_manifest "${backup_dir}/MANIFEST"
        if [ "$MANIFEST_COMPLETE" != true ]; then
            print_error "MANIFEST sense 'complete=yes': el backup és incomplet"
            failures=$((failures + 1))
        fi
    else
        print_warning "${backup_dir}: sense MANIFEST (backup anterior): només es verifica el que hi ha, no es pot saber si falta cap peça"
    fi

    shopt -s nullglob
    images=("$backup_dir"/*.img.gz)
    partials=("$backup_dir"/*.partial)
    shopt -u nullglob

    if [ "${#partials[@]}" -gt 0 ]; then
        print_error "Hi ha fitxers .partial (còpia interrompuda): ${partials[*]##*/}"
        failures=$((failures + 1))
    fi
    if [ "${#images[@]}" -eq 0 ]; then
        print_error "No hi ha cap .img.gz a ${backup_dir}"
        failures=$((failures + 1))
    fi

    if [ "$has_manifest" = true ]; then
        for name in "${!MANIFEST_PIECES[@]}"; do
            if [ ! -f "${backup_dir}/${name}.img.gz" ]; then
                print_error "${name}: peça del MANIFEST que falta a la carpeta"
                failures=$((failures + 1))
            fi
        done
        for image in "${images[@]}"; do
            name="$(basename "$image" .img.gz)"
            if [ -z "${MANIFEST_PIECES[$name]:-}" ]; then
                print_error "${name}: .img.gz que no és al MANIFEST"
                failures=$((failures + 1))
            fi
        done
    fi

    for image in "${images[@]}"; do
        verify_image "$image" || failures=$((failures + 1))
    done

    if [ "$failures" -gt 0 ]; then
        print_error "${failures} problema(es) al backup"
        return 1
    fi
    print_success "Totes les imatges són correctes"
}

# MANIFEST: línies clau=valor, 'piece <nom> <mida> <sha256> <live|exact>' i 'complete=yes' al final
load_manifest() {
    local file="$1" line name size hash
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        piece\ *)
            read -r _ name size hash _ <<<"$line"
            MANIFEST_PIECES["$name"]="${size} ${hash}"
            ;;
        complete=yes)
            MANIFEST_COMPLETE=true
            ;;
        esac
    done <"$file"
}

verify_image() {
    local image="$1"
    local base="${image%.img.gz}"
    local name expected_hash expected_size actual manifest_entry
    name=$(basename "$image" .img.gz)

    if [ ! -f "${base}.sha256" ]; then
        print_error "${name}: falta ${name}.sha256"
        return 1
    fi
    expected_hash=$(head -1 "${base}.sha256" | awk '{print $1}')
    expected_size=$(sed -n 2p "${base}.sha256")

    actual=$(zcat "$image" | stream_sha_size) || actual="error de lectura del gzip"
    if [ "$actual" != "${expected_hash} ${expected_size}" ]; then
        print_error "${name}: hash o mida no coincideixen"
        return 1
    fi
    manifest_entry="${MANIFEST_PIECES[$name]:-}"
    if [ -n "$manifest_entry" ] && [ "$manifest_entry" != "${expected_size} ${expected_hash}" ]; then
        print_error "${name}: el .sha256 no coincideix amb el MANIFEST"
        return 1
    fi
    if ! has_no_filler "$image"; then
        print_error "${name}: conté filler 0xCC (>= 64 KiB)"
        return 1
    fi
    print_success "$name"
}

has_no_filler() {
    zcat "$1" | python3 -I -c '
import re, sys
run, tail = re.compile(rb"\xcc{65535}"), b""
while chunk := sys.stdin.buffer.read(1 << 20):
    if run.search(tail + chunk):
        sys.exit(1)
    tail = chunk[-65535:]'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
