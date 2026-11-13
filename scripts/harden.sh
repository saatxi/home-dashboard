#!/usr/bin/env bash
set -Eeuo pipefail

DEPENDENCIES=(adb)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

KIOSK_PACKAGE="local.homedashboard.kiosk" # package de kiosk/AndroidManifest.xml
PERSIST_ATTEMPTS="${PERSIST_ATTEMPTS:-6}"
PERSIST_INTERVAL="${PERSIST_INTERVAL:-5}"
STEP_PACKAGES=(
    "example:com.example"
    "uhale:com.zeasn.frame"
)

usage_text() {
    cat <<EOM

Hardening REVERSIBLE del marc: només desactiva apps amb 'pm disable-user' (no toca particions).
Cada 'apply' demana confirmació, registra el canvi a frames/xoro/changes.jsonl i es desfà amb 'revert'.

usage: ${SCRIPT_NAME} <command> [step]

commands:
    snapshot            Desa l'estat actual (només lectura) a diagnostics/<data>-pre-hardening/
    apply <step>        Desactiva l'app del pas
    revert <step>       Torna a activar l'app del pas
    status              Mostra l'estat enabled/disabled dels paquets dels passos

steps:
    example             com.example (app de test de fàbrica TS8ProdutionTest)
    uhale               com.zeasn.frame (Uhale); exigeix el kiosk (${KIOSK_PACKAGE}) instal·lat
                        i un altre HOME disponible

options:
    -y|--yes            No demanis confirmació (només per a 'apply')
    -h|--help           Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[*]}

examples:
    ${SCRIPT_NAME} snapshot
    ${SCRIPT_NAME} apply example
    ${SCRIPT_NAME} revert example

EOM
}

main() {
    local command=""
    local step=""
    local assume_yes=false

    while [ $# -gt 0 ]; do
        case $1 in
        -y | --yes)
            assume_yes=true
            ;;
        -h | --help)
            usage 0
            ;;
        snapshot | status | apply | revert)
            if [ -n "$command" ]; then
                print_error "Només es pot indicar una ordre ('${command}' i '$1')"
                usage
            fi
            command="$1"
            ;;
        *)
            if [ -n "$command" ] && [ -z "$step" ]; then
                step="$1"
            else
                print_error "Opció desconeguda '$1'"
                usage
            fi
            ;;
        esac
        shift
    done

    if [ -z "$command" ]; then
        print_error "Cal indicar una ordre"
        usage
    fi
    if [ -n "$step" ] && [ "$command" != apply ] && [ "$command" != revert ]; then
        print_error "'${command}' no admet cap pas ('${step}')"
        usage
    fi

    exit_on_missing_tools "${DEPENDENCIES[@]}"
    require_device
    require_root
    check_identity

    case "$command" in
    snapshot)
        take_snapshot
        ;;
    status)
        show_status
        ;;
    apply | revert)
        run_step "$command" "$step" "$assume_yes"
        ;;
    esac
}

take_snapshot() {
    local out
    out="${OUTPUT_ROOT}/diagnostics/$(date +%Y%m%d-%H%M%S)-pre-hardening"
    mkdir -p "$out" || {
        print_error "No es pot crear ${out}"
        exit 1
    }

    print_header "Instantània a ${out}"
    save_command "$out" packages-enabled pm list packages -e
    save_command "$out" packages-disabled pm list packages -d
    save_command "$out" dumpsys-uhale dumpsys package com.zeasn.frame
    save_command "$out" dumpsys-example dumpsys package com.example
    save_command "$out" home-activities cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME
    save_command "$out" getprop getprop
    save_command "$out" settings-global settings list global
    save_command "$out" settings-secure settings list secure
    save_command "$out" settings-system settings list system
    save_command "$out" su-perms ls -l /system/xbin/su
    save_command "$out" mounts cat /proc/mounts
    print_success "Instantània desada (només lectura)"
}

save_command() {
    local out="$1"
    local name="$2"
    shift 2
    if adb shell "$@" >"${out}/${name}.txt" 2>&1; then
        print_success "$name"
    else
        print_warning "$name ha fallat (vegeu ${out}/${name}.txt)"
    fi
}

show_status() {
    local entry package state
    for entry in "${STEP_PACKAGES[@]}"; do
        package="${entry#*:}"
        state="$(package_state "$package")" || exit 1
        echo "${entry%%:*}  ${package}  ${state}"
    done
}

package_state() {
    local package="$1"
    local all disabled
    # Es captura la sortida (sense pipe cap a grep -q): amb pipefail un SIGPIPE donaria falsos errors
    if ! all="$(adb_sh pm list packages "$package")" || ! disabled="$(adb_sh pm list packages -d "$package")"; then
        print_error "No es pot consultar 'pm list packages' (${package})"
        return 1
    fi
    if ! grep -qx "package:${package}" <<<"$all"; then
        echo "no-instal·lat"
    elif grep -qx "package:${package}" <<<"$disabled"; then
        echo "desactivat"
    else
        echo "activat"
    fi
}

step_package() {
    local step="$1"
    local entry
    for entry in "${STEP_PACKAGES[@]}"; do
        if [ "${entry%%:*}" = "$step" ]; then
            echo "${entry#*:}"
            return 0
        fi
    done
    return 1
}

run_step() {
    local command="$1"
    local step="$2"
    local assume_yes="$3"
    local package state

    if [ -z "$step" ]; then
        print_error "Cal indicar un pas"
        usage
    fi
    package="$(step_package "$step")" || {
        print_error "Pas desconegut '${step}'"
        usage
    }

    state="$(package_state "$package")" || exit 1
    if [ "$state" = "no-instal·lat" ]; then
        print_error "${package} no està instal·lat"
        exit 1
    fi

    if [ "$command" = "apply" ]; then
        apply_step "$step" "$package" "$state" "$assume_yes"
    else
        revert_step "$step" "$package" "$state"
    fi
}

apply_step() {
    local step="$1"
    local package="$2"
    local state="$3"
    local assume_yes="$4"

    if [ "$state" = "desactivat" ]; then
        print_warning "${package} ja està desactivat"
        return 0
    fi
    if [ "$step" = "uhale" ]; then
        require_kiosk_ready
        if ! has_other_home "$package"; then
            print_error "${package} és l'únic HOME: desactivar-la deixaria el marc sense pantalla d'inici. No es fa res."
            exit 1
        fi
    fi
    if [ "$assume_yes" != true ] && ! confirm "Desactivar ${package} (es desfà amb '${SCRIPT_NAME} revert ${step}')?"; then
        echo "Cancel·lat"
        return 0
    fi

    if ! adb_sh pm disable-user --user 0 "$package"; then
        print_error "pm disable-user ha fallat"
        exit 1
    fi
    verify_state "$package" "desactivat"
    log_change "disable ${package}" "adb shell pm enable ${package}" ||
        print_warning "Canvi fet però no registrat; per desfer-lo: adb shell pm enable ${package}"
    if ! wait_persisted "$package" "desactivat"; then
        log_change "disable ${package}: persistència no confirmada" "adb shell pm enable ${package}" '"persisted":false' || true
        exit 1
    fi
}

revert_step() {
    local step="$1"
    local package="$2"
    local state="$3"

    if [ "$state" = "activat" ]; then
        print_warning "${package} ja està activat"
        return 0
    fi
    if ! adb_sh pm enable "$package"; then
        print_error "pm enable ha fallat"
        exit 1
    fi
    verify_state "$package" "activat"
    log_change "enable ${package} (revert ${step})" "adb shell pm disable-user --user 0 ${package}" ||
        print_warning "Canvi fet però no registrat; per desfer-lo: adb shell pm disable-user --user 0 ${package}"
    if ! wait_persisted "$package" "activat"; then
        log_change "enable ${package} (revert ${step}): persistència no confirmada" "adb shell pm disable-user --user 0 ${package}" '"persisted":false' || true
        exit 1
    fi
}

verify_state() {
    local package="$1"
    local expected="$2"
    local state
    state="$(package_state "$package")" || exit 1
    if [ "$state" != "$expected" ]; then
        print_error "${package}: estat '${state}', s'esperava '${expected}'"
        exit 1
    fi
    print_success "${package}: ${state}"
}

# Android escriu package-restrictions.xml amb retard: un reinici abans no desa el canvi
wait_persisted() {
    local package="$1"
    local expected="$2"
    local file="/data/system/users/0/package-restrictions.xml"
    local attempt line
    for ((attempt = 1; attempt <= PERSIST_ATTEMPTS; attempt++)); do
        # grep sense coincidència (sortida 1) vol dir que encara no hi és: no és un error
        line="$(adb_sh "grep 'name=\"${package}\"' ${file}")" || line=""
        if [ "$expected" = "desactivat" ] && [[ "$line" == *'enabled="3"'* ]]; then
            print_success "Canvi desat a ${file}"
            return 0
        fi
        if [ "$expected" = "activat" ] && [[ "$line" != *'enabled="3"'* ]]; then
            print_success "Canvi desat a ${file}"
            return 0
        fi
        if [ "$attempt" -lt "$PERSIST_ATTEMPTS" ]; then
            sleep "$PERSIST_INTERVAL"
        fi
    done
    print_warning "No s'ha vist el canvi a ${file}; no reinicieu el marc encara"
    return 1
}

# El kiosk ha d'estar instal·lat (i actiu) abans de desactivar Uhale: ha de poder fer de HOME
require_kiosk_ready() {
    local kiosk_state
    kiosk_state="$(package_state "$KIOSK_PACKAGE")" || exit 1
    case "$kiosk_state" in
    activat) ;;
    desactivat)
        print_error "El kiosk (${KIOSK_PACKAGE}) està desactivat: no es pot desactivar Uhale sense un HOME alternatiu. No es fa res."
        exit 1
        ;;
    *)
        print_error "El kiosk (${KIOSK_PACKAGE}) no està instal·lat: desactivar Uhale deixaria el marc sense HOME. No es fa res."
        exit 1
        ;;
    esac
}

# Hi ha d'haver almenys una activitat HOME que no sigui del paquet que desactivem
# (ni el FallbackHome d'Android, que no és una pantalla d'inici útil)
has_other_home() {
    local package="$1"
    local homes line
    if ! homes="$(adb_sh cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME)"; then
        print_error "No es poden consultar les activitats HOME"
        exit 1
    fi
    while IFS= read -r line; do
        if ! [[ "$line" =~ ^[[:space:]]*[A-Za-z0-9_.]+/ ]]; then
            continue
        fi
        if [[ "$line" == *"${package}/"* ]] || [[ "$line" == *com.android.settings/*FallbackHome* ]]; then
            continue
        fi
        return 0
    done <<<"$homes"
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
