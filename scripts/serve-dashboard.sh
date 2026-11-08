#!/usr/bin/env bash

DEPENDENCIES=(python3)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SITE_DIR="${ROOT}/dashboard"
PORT=8080
BIND="127.0.0.1"
REFRESH_SECONDS=600
GENERATOR="${ROOT}/server/generate.py"
VENV_PYTHON="${ROOT}/server/.venv/bin/python"
REFRESHER_PID=""

usage() {
    cat <<EOM

Serveix dashboard/ amb un servidor estàtic i, si hi ha server/config.json, regenera data.json
cada ${REFRESH_SECONDS} s (temps, calendari, tasques). No toca el dispositiu.
Per defecte només escolta a 127.0.0.1 (el marc hi arriba amb 'adb reverse').

usage: ${SCRIPT_NAME} [options]

options:
    -p|--port N  Port (per defecte ${PORT})
    --lan        Escolta a totes les interfícies (0.0.0.0): visible a la LAN
    --no-refresh No regeneris data.json (només serveix el que hi ha)
    -h|--help    Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[@]}

examples:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} --port 9000

EOM
    exit 1
}

start_refresher() {
    if [ ! -x "${VENV_PYTHON}" ] || [ ! -f "${ROOT}/server/config.json" ]; then
        print_warning "Sense server/.venv o server/config.json: no regenero data.json"
        return
    fi
    (
        while true; do
            "${VENV_PYTHON}" "${GENERATOR}" || print_warning "generate.py ha fallat"
            sleep "${REFRESH_SECONDS}"
        done
    ) &
    REFRESHER_PID=$!
    trap 'kill "${REFRESHER_PID}" 2>/dev/null || true' EXIT
}

main() {
    set -euo pipefail
    REFRESH=true
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
        --no-refresh)
            REFRESH=false
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
    if [ "${REFRESH}" = true ]; then
        start_refresher
    fi
    print_header "Serveixo ${SITE_DIR} a http://${BIND}:${PORT}/"
    python3 -I "${ROOT}/server/static_server.py" --port "${PORT}" --bind "${BIND}" --directory "${SITE_DIR}"
}

main "$@"
