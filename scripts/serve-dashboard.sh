#!/usr/bin/env bash

DEPENDENCIES=(python3)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SITE_DIR="${ROOT}/dashboard"
PORT=8080
BIND="127.0.0.1"

usage() {
    cat <<EOM

Serveix dashboard/ amb un servidor estàtic. No toca el dispositiu.
Per defecte només escolta a 127.0.0.1 (el marc hi arriba amb 'adb reverse').

usage: ${SCRIPT_NAME} [options]

options:
    -p|--port N  Port (per defecte ${PORT})
    --lan        Escolta a totes les interfícies (0.0.0.0): visible a la LAN
    -h|--help    Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[@]}

examples:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} --port 9000

EOM
    exit 1
}

main() {
    set -euo pipefail
    while [ "${1:-}" != "" ]; do
        case $1 in
        -p | --port)
            shift
            PORT="${1:-}"
            [[ "${PORT}" =~ ^[0-9]+$ ]] || { print_error "Port invàlid '${PORT}'"; usage; }
            ;;
        --lan)
            BIND="0.0.0.0"
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

    exit_on_missing_tools "${DEPENDENCIES[@]}"
    if [ ! -f "${SITE_DIR}/data/data.json" ]; then
        cp "${SITE_DIR}/data/data.example.json" "${SITE_DIR}/data/data.json"
        print_warning "Creo data/data.json a partir de l'exemple"
    fi
    print_header "Serveixo ${SITE_DIR} a http://${BIND}:${PORT}/"
    exec python3 -I -m http.server "${PORT}" --bind "${BIND}" --directory "${SITE_DIR}"
}

main "$@"
