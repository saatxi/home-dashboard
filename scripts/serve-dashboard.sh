#!/usr/bin/env bash
set -Eeuo pipefail

DEPENDENCIES=(python3)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SITE_DIR="${ROOT}/dashboard"
PORT=8080
BIND="127.0.0.1"
REFRESH_SECONDS=600
GENERATOR="${ROOT}/server/generate.py"
VENV_PYTHON="${ROOT}/server/.venv/bin/python"
REFRESHER_PID=""
SERVER_PID=""
REFRESH=true

usage_text() {
    cat <<EOM

Serveix dashboard/ amb un servidor estàtic i, si hi ha server/config.json, regenera data.json
cada ${REFRESH_SECONDS} s (temps, calendari, tasques). No toca el dispositiu.
Per defecte només escolta a 127.0.0.1 (el marc hi arriba amb 'adb reverse').

usage: ${SCRIPT_NAME} [options]

options:
    -p|--port N  Port, 1-65535 (per defecte ${PORT})
    --lan        Escolta a totes les interfícies (0.0.0.0): visible a la LAN
    --no-refresh No regeneris data.json (només serveix el que hi ha)
    -h|--help    Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[*]}

examples:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} --port 9000

EOM
}

start_refresher() {
    if [ ! -x "${VENV_PYTHON}" ] || [ ! -f "${ROOT}/server/config.json" ]; then
        print_warning "Sense server/.venv o server/config.json: no regenero data.json"
        return
    fi
    (
        # El generador i el sleep van en segon pla amb 'wait': així el TERM del pare s'atén
        # a l'instant i el fill en curs es mata amb el bucle (no queda cap procés orfe).
        child=""
        trap '[ -z "${child}" ] || kill "${child}" 2>/dev/null; exit 0' TERM INT
        while true; do
            "${VENV_PYTHON}" "${GENERATOR}" &
            child=$!
            wait "${child}" || print_warning "generate.py ha fallat"
            sleep "${REFRESH_SECONDS}" &
            child=$!
            wait "${child}" || true
        done
    ) &
    REFRESHER_PID=$!
}

# Atura el servidor i el refrescador (amb els seus fills)
stop_children() {
    local pid
    for pid in "${SERVER_PID}" "${REFRESHER_PID}"; do
        if [ -n "${pid}" ]; then
            kill "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
        fi
    done
    SERVER_PID=""
    REFRESHER_PID=""
}

validate_port() {
    local port="$1"
    if ! [[ "${port}" =~ ^[0-9]{1,5}$ ]] || [ "$((10#${port}))" -lt 1 ] || [ "$((10#${port}))" -gt 65535 ]; then
        print_error "Port invàlid '${port}' (cal un nombre entre 1 i 65535)"
        usage
    fi
}

main() {
    while [ $# -gt 0 ]; do
        case $1 in
        -p | --port)
            if [ $# -lt 2 ]; then
                print_error "Falta el valor de '$1'"
                usage
            fi
            shift
            validate_port "$1"
            PORT="$((10#$1))"
            ;;
        --lan)
            BIND="0.0.0.0"
            ;;
        --no-refresh)
            REFRESH=false
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

    exit_on_missing_tools "${DEPENDENCIES[@]}"
    if [ ! -f "${SITE_DIR}/data/data.json" ]; then
        cp "${SITE_DIR}/data/data.example.json" "${SITE_DIR}/data/data.json"
        print_warning "Creo data/data.json a partir de l'exemple"
    fi
    trap stop_children EXIT
    trap 'exit 130' INT TERM
    if [ "${REFRESH}" = true ]; then
        start_refresher
    fi
    print_header "Serveixo ${SITE_DIR} a http://${BIND}:${PORT}/"
    # En segon pla + wait: així un TERM/INT al script s'atén a l'instant i el servidor no queda orfe
    python3 -I "${ROOT}/server/static_server.py" --port "${PORT}" --bind "${BIND}" --directory "${SITE_DIR}" &
    SERVER_PID=$!
    wait "${SERVER_PID}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
