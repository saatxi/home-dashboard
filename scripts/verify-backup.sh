#!/usr/bin/env bash

DEPENDENCIES=(zcat sha256sum python3)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<EOM

Verifica un backup: rellegeix cada .img.gz i en comprova el SHA-256, la mida
exacta i que no contingui 64 KiB seguits de 0xCC.

usage: ${SCRIPT_NAME} <carpeta-backup>

options:
    -h|--help    Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[@]}

examples:
    ${SCRIPT_NAME} backups/20261108-090535

EOM
    exit 1
}

main() {
    local backup_dir=""

    while [ "$1" != "" ]; do
        case $1 in
        -h | --help)
            usage
            ;;
        -*)
            print_error "Opció desconeguda '$1'"
            usage
            ;;
        *)
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

    local failures=0
    local image
    for image in "$backup_dir"/*.img.gz; do
        verify_image "$image" || failures=$((failures + 1))
    done

    if [ "$failures" -gt 0 ]; then
        print_error "${failures} imatge(s) amb errors"
        return 1
    fi
    print_success "Totes les imatges són correctes"
}

verify_image() {
    local image="$1"
    local name expected_hash expected_size actual
    name=$(basename "$image" .img.gz)
    expected_hash=$(head -1 "${image%.img.gz}.sha256" | awk '{print $1}')
    expected_size=$(sed -n 2p "${image%.img.gz}.sha256")

    actual=$(zcat "$image" | python3 -I -c '
import hashlib, sys
h, n = hashlib.sha256(), 0
while chunk := sys.stdin.buffer.read(1 << 20):
    h.update(chunk)
    n += len(chunk)
print(h.hexdigest(), n)')

    if [ "$actual" != "${expected_hash} ${expected_size}" ]; then
        print_error "${name}: hash o mida no coincideixen"
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
    exit $?
fi
