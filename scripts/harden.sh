#!/usr/bin/env bash

DEPENDENCIES=(adb)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CHANGES_LOG="${ROOT}/frames/xoro/changes.jsonl"
STEP_PACKAGES=(
    "example:com.example"
    "uhale:com.zeasn.frame"
)

usage() {
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
    uhale               com.zeasn.frame (Uhale); exigeix un altre HOME disponible

options:
    -y|--yes            No demanis confirmació (només per a 'apply')
    -h|--help           Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[@]}

examples:
    ${SCRIPT_NAME} snapshot
    ${SCRIPT_NAME} apply example
    ${SCRIPT_NAME} revert example

EOM
    exit 1
}

main() {
    local command=""
    local step=""
    local assume_yes=false

    while [ "$1" != "" ]; do
        case $1 in
        -y | --yes)
            assume_yes=true
            ;;
        -h | --help)
            usage
            ;;
        snapshot | status | apply | revert)
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
    out="${ROOT}/diagnostics/$(date +%Y%m%d-%H%M%S)-pre-hardening"
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
        state="$(package_state "$package")"
        echo "${entry%%:*}  ${package}  ${state}"
    done
}

package_state() {
    local package="$1"
    if ! adb shell pm list packages "$package" | tr -d '\r' | grep -qx "package:${package}"; then
        echo "no-instal·lat"
    elif adb shell pm list packages -d "$package" | tr -d '\r' | grep -qx "package:${package}"; then
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

    state="$(package_state "$package")"
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
    if [ "$step" = "uhale" ] && ! has_other_home "$package"; then
        print_error "${package} és l'únic HOME: desactivar-la deixaria el marc sense pantalla d'inici. No es fa res."
        exit 1
    fi
    if [ "$assume_yes" != true ] && ! confirm "Desactivar ${package} (es desfà amb '${SCRIPT_NAME} revert ${step}')?"; then
        echo "Cancel·lat"
        return 0
    fi

    if ! adb shell pm disable-user --user 0 "$package" | tr -d '\r'; then
        print_error "pm disable-user ha fallat"
        exit 1
    fi
    verify_state "$package" "desactivat"
    wait_persisted "$package" "desactivat" || exit 1
    log_change "disable ${package}" "pm enable ${package}"
}

revert_step() {
    local step="$1"
    local package="$2"
    local state="$3"

    if [ "$state" = "activat" ]; then
        print_warning "${package} ja està activat"
        return 0
    fi
    if ! adb shell pm enable "$package" | tr -d '\r'; then
        print_error "pm enable ha fallat"
        exit 1
    fi
    verify_state "$package" "activat"
    wait_persisted "$package" "activat" || exit 1
    log_change "enable ${package} (revert ${step})" "pm disable-user --user 0 ${package}"
}

verify_state() {
    local package="$1"
    local expected="$2"
    local state
    state="$(package_state "$package")"
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
    for attempt in 1 2 3 4 5 6; do
        line="$(adb shell "grep 'name=\"${package}\"' ${file}" | tr -d '\r')"
        if [ "$expected" = "desactivat" ] && [[ "$line" == *'enabled="3"'* ]]; then
            print_success "Canvi desat a ${file}"
            return 0
        fi
        if [ "$expected" = "activat" ] && [[ "$line" != *'enabled="3"'* ]]; then
            print_success "Canvi desat a ${file}"
            return 0
        fi
        sleep 5
    done
    print_warning "No s'ha vist el canvi a ${file}; no reinicieu el marc encara"
    return 1
}

# Hi ha d'haver almenys una activitat HOME que no sigui del paquet que desactivem
has_other_home() {
    local package="$1"
    adb shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME |
        tr -d '\r' | grep -E '^[[:space:]]*[A-Za-z0-9_.]+/' | grep -qv "${package}/"
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
    mkdir -p "$(dirname "$CHANGES_LOG")" || return 1
    printf '{"date":"%s","action":"%s","writes_to_device":true,"undo":"adb shell %s"}\n' \
        "$(date +%Y-%m-%d)" "$action" "$undo" >>"$CHANGES_LOG"
    print_success "Registrat a ${CHANGES_LOG}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
