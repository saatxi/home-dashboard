#!/usr/bin/env bash
# Prova d'estabilitat i rendiment del marc (NOMÉS LECTURA al dispositiu).
#
# Recull memòria, kills del LMK, recàrregues del kiosk i captures de pantalla
# periòdiques. En acabar escriu un SUMMARY.txt amb els valors mínims i el
# nombre d'incidents.
#
# Criteris d'acceptació (vegeu docs/homescreens.md):
#   - 0 morts del renderitzador (onRenderProcessGone) i 0 kills del LMK durant la nit
#   - MemAvailable mínim ≥ 100 MB i sense tendència creixent del PSS del renderer
#   - Les captures mostren la pàgina sencera (no en blanc)
#   - Primer pintat ≤ 10 s (pageStarted → pageFinished)
#
# Ús:
#   scripts/soak.sh                              # 2 h, etiqueta automàtica
#   scripts/soak.sh --minutes 30 --label baseline
#   scripts/soak.sh --minutes 480 --label homescreens-night  # 8 h

set -Eeuo pipefail

DEPENDENCIES=(adb)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

DEFAULT_MINUTES=120
POLL_SECONDS="${SOAK_POLL_SECONDS:-60}"
SCREENSHOT_EVERY=15  # minuts

usage_text() {
    cat <<EOM

Prova d'estabilitat del marc (NOMÉS LECTURA). Recull dades cada ${POLL_SECONDS} s
i les desa a diagnostics/soak-<data>-<etiqueta>/ (privat, ignorat per git).

usage: ${SCRIPT_NAME} [options]

options:
    -m|--minutes N    Durada en minuts (per defecte ${DEFAULT_MINUTES})
    -l|--label TEXT   Etiqueta per al directori de sortida (per defecte: data+hora)
    -h|--help         Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[*]}

examples:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} --minutes 30 --label baseline
    ${SCRIPT_NAME} --minutes 480 --label homescreens-night

EOM
}

# Extreu un enter d'una línia de text: mem_field "MemAvailable: 123456 kB" → 123456
mem_field() { printf '%s\n' "$1" | grep -oP '\d+'; }

# Captura de pantalla al dispositiu i la baixa a $1.
take_screenshot() {
    local out_file="$1"
    local tmp_remote="/sdcard/soak_cap.png"
    if adb shell screencap -p "$tmp_remote" 2>/dev/null; then
        if adb pull "$tmp_remote" "$out_file" >/dev/null 2>&1; then
            adb shell rm -f "$tmp_remote" 2>/dev/null || true
        fi
    fi
}

main() {
    local minutes="$DEFAULT_MINUTES" label=""

    while [ $# -gt 0 ]; do
        case $1 in
        -m | --minutes)
            if [ $# -lt 2 ]; then print_error "Falta el valor de '$1'"; usage; fi
            shift
            if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ]; then
                print_error "Minuts invàlid: '$1' (cal un enter positiu)"; exit 1
            fi
            minutes="$1"
            ;;
        -l | --label)
            if [ $# -lt 2 ]; then print_error "Falta el valor de '$1'"; usage; fi
            shift
            label="$1"
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
    require_device
    check_identity

    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local dir_label="${label:-${timestamp}}"
    local out_dir="${OUTPUT_ROOT}/diagnostics/soak-${timestamp}-${dir_label}"
    mkdir -p "$out_dir"

    print_header "Soak ${minutes} min → ${out_dir}"
    printf '{"start":"%s","minutes":%d,"label":"%s","device":"%s"}\n' \
        "$(date -Iseconds)" "$minutes" "$dir_label" "$(device_serial)" \
        >"${out_dir}/meta.json"

    # Recull un logcat continu en segon pla, només des d'ara: sense -T, logcat bolca
    # primer tot el buffer antic i els comptadors inclourien incidents d'abans de la prova.
    # L'hora ha de ser la del marc (el seu rellotge no coincideix amb el del PC).
    local logcat_file="${out_dir}/logcat.txt" since=""
    since="$(adb shell date "'+%m-%d %H:%M:%S.000'" 2>/dev/null | tr -d '\r')" || since=""
    local logcat_args=(-s HomeDashboard)
    if [[ "$since" =~ ^[0-9]{2}-[0-9]{2}\ [0-9:.]+$ ]]; then
        logcat_args=(-T "$since" "${logcat_args[@]}")
    else
        print_warning "No s'ha pogut llegir l'hora del marc: el logcat inclourà línies antigues"
    fi
    adb logcat "${logcat_args[@]}" 2>/dev/null >"$logcat_file" &
    local logcat_pid=$!
    # shellcheck disable=SC2064
    trap "kill ${logcat_pid} 2>/dev/null || true" EXIT

    # Variables per al resum.
    local iter=0 total_iter=$(( (minutes * 60) / POLL_SECONDS ))
    local mem_min=999999 pss_max=0
    local screenshot_counter=0

    while [ "$iter" -lt "$total_iter" ]; do
        local t
        t="$(date +%Y%m%d-%H%M%S)"
        local sample_dir="${out_dir}/samples/${t}"
        mkdir -p "$sample_dir"

        # Memòria del sistema.
        local meminfo
        meminfo="$(adb shell cat /proc/meminfo 2>/dev/null | tr -d '\r')"
        printf '%s\n' "$meminfo" >"${sample_dir}/meminfo.txt"
        local mem_avail_kb=0
        mem_avail_kb="$(printf '%s\n' "$meminfo" | grep -m1 '^MemAvailable:' | grep -oP '\d+' || echo 0)"
        if [ "$mem_avail_kb" -lt "$mem_min" ]; then mem_min="$mem_avail_kb"; fi

        # PSS del kiosk i del renderer.
        local meminfo_kiosk=""
        meminfo_kiosk="$(adb shell dumpsys meminfo local.homedashboard.kiosk 2>/dev/null | tr -d '\r' | head -30 || true)"
        printf '%s\n' "$meminfo_kiosk" >"${sample_dir}/meminfo_kiosk.txt"
        local pss_kb=0
        # Android 10: "        TOTAL   172173 ..."; versions noves: "TOTAL PSS:   172173 ...".
        pss_kb="$(printf '%s\n' "$meminfo_kiosk" | grep -oP '^\s*TOTAL(\s+PSS:)?\s+\K\d+' | head -1)" || pss_kb=0
        pss_kb="${pss_kb:-0}"
        if [ "$pss_kb" -gt "$pss_max" ]; then pss_max="$pss_kb"; fi

        # LMK.
        adb shell dumpsys activity lmk 2>/dev/null >"${sample_dir}/lmk.txt" || true

        # Càrrega.
        adb shell cat /proc/loadavg 2>/dev/null | tr -d '\r' >"${sample_dir}/loadavg.txt" || true

        # Captura cada SCREENSHOT_EVERY minuts.
        local elapsed_min=$(( (iter * POLL_SECONDS) / 60 ))
        if [ "$(( elapsed_min % SCREENSHOT_EVERY ))" -eq 0 ] && [ "$iter" -gt 0 ] || [ "$iter" -eq 0 ]; then
            take_screenshot "${sample_dir}/screen.png"
            screenshot_counter=$(( screenshot_counter + 1 ))
        fi

        iter=$(( iter + 1 ))
        local remaining_min=$(( ((total_iter - iter) * POLL_SECONDS) / 60 ))
        printf '\r  %d/%d (%d min restants, MemAvail %d MB)   ' \
            "$iter" "$total_iter" "$remaining_min" \
            "$(( mem_avail_kb / 1024 ))"

        if [ "$iter" -lt "$total_iter" ]; then sleep "$POLL_SECONDS"; fi
    done
    printf '\n'

    # El procés de logcat pot haver mort ja (adb fals als tests); en ambdós casos silenciem l'error.
    kill "$logcat_pid" 2>/dev/null || true
    wait "$logcat_pid" 2>/dev/null || true

    # Compta incidents del logcat.
    local n_process_gone n_reload n_error
    n_process_gone=$(grep -c 'onRenderProcessGone\|renderProcessGone' "$logcat_file" 2>/dev/null) || n_process_gone=0
    n_reload=$(grep -c 'reload ' "$logcat_file" 2>/dev/null) || n_reload=0
    n_error=$(grep -c 'Error carregant\|Error loading' "$logcat_file" 2>/dev/null) || n_error=0

    # Escriu el resum.
    local summary="${out_dir}/SUMMARY.txt"
    {
        printf 'soak: %s min  label: %s\n' "$minutes" "$dir_label"
        printf 'start: %s\n' "$(head -1 "${out_dir}/meta.json" | grep -oP '"start":"\K[^"]+')"
        printf 'end:   %s\n\n' "$(date -Iseconds)"
        printf 'MemAvailable min:    %d MB\n' "$(( mem_min / 1024 ))"
        printf 'PSS kiosk max:       %d MB\n' "$(( pss_max / 1024 ))"
        printf 'onRenderProcessGone: %d\n' "$n_process_gone"
        printf 'reload events:       %d\n' "$n_reload"
        printf 'load errors:         %d\n' "$n_error"
        printf 'screenshots:         %d\n' "$screenshot_counter"
        printf '\nCriteris d acceptacio:\n'
        local ok=true
        if [ "$n_process_gone" -gt 0 ]; then
            printf '  FAIL  renderProcessGone > 0 (%d)\n' "$n_process_gone"; ok=false
        else
            printf '  OK    renderProcessGone = 0\n'
        fi
        if [ "$mem_min" -lt 102400 ]; then  # 100 MB en kB
            printf '  FAIL  MemAvailable min %d MB < 100 MB\n' "$(( mem_min / 1024 ))"; ok=false
        else
            printf '  OK    MemAvailable min %d MB >= 100 MB\n' "$(( mem_min / 1024 ))"
        fi
        if [ "$ok" = true ]; then
            printf '\nRESULTAT: OK\n'
        else
            printf '\nRESULTAT: FAIL - considereu scripts/webview.sh revert\n'
        fi
    } >"$summary"

    cat "$summary"
    print_success "Dades a ${out_dir}"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
