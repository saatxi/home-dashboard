#!/usr/bin/env bash
# Llibreria compartida pels scripts (es carrega amb source, no s'executa).
# Escriuen al dispositiu només harden.sh (pm disable/enable) i bootanimation.sh (install/remove);
# la resta (backup, identify, verify-backup, wsl-usb-check...) és de només lectura.
# Cada script activa 'set -Eeuo pipefail' abans de carregar aquest fitxer.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Base on s'escriuen backups/, diagnostics/ i frames/ (sobreescrivible, p. ex. per als tests)
OUTPUT_ROOT="${OUTPUT_ROOT:-${ROOT}}"
CHANGES_LOG="${CHANGES_LOG:-${OUTPUT_ROOT}/frames/xoro/changes.jsonl}"
EXPECTED_HARDWARE="sun50iw10p1" # Allwinner A133 (Xoro CPF10PF / LOOFII C-3)
EX_USAGE=64

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]]; then
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
fi

# printf amb format fix: el text (sovint del dispositiu) no s'interpreta mai com a escapades
print_header() {
    printf '%b== %s%b\n' "$BLUE" "$1" "$NC"
}

print_success() {
    printf '%b[OK]%b     %s\n' "$GREEN" "$NC" "$1"
}

print_error() {
    printf '%b[FALLA]%b  %s\n' "$RED" "$NC" "$1" >&2
}

print_warning() {
    printf '%b[AVÍS]%b   %s\n' "$YELLOW" "$NC" "$1"
}

# Cada script defineix usage_text (imprimeix l'ajuda). usage [codi]: 0 = ajuda demanada (stdout),
# altrament error d'ús (stderr, codi 64 per defecte).
usage() {
    local code="${1:-$EX_USAGE}"
    if [ "$code" -eq 0 ]; then
        usage_text
    else
        usage_text >&2
    fi
    exit "$code"
}

exit_on_missing_tools() {
    local cmd
    for cmd in "$@"; do
        if command -v "$cmd" &>/dev/null; then
            continue
        fi
        print_error "Falta l'eina '${cmd}'. Vegeu docs/wsl-setup.md"
        exit 1
    done
}

# adb shell sense \r i amb l'estat de sortida d'adb (no el de tr)
adb_sh() {
    local rc
    if adb shell "$@" | tr -d '\r'; then
        rc="${PIPESTATUS[0]}"
    else
        rc="${PIPESTATUS[0]}"
    fi
    return "$rc"
}

# Distingeix: cap dispositiu, més d'un, no autoritzat, offline. El primer adb va amb timeout.
require_device() {
    exit_on_missing_tools adb
    local listing rc=0 line serial state
    local -a found=()
    listing="$(timeout "${ADB_TIMEOUT:-15}" adb devices 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 124 ]; then
        print_error "adb no respon (timeout). Proveu 'adb kill-server' o scripts/wsl-usb-check.sh"
        exit 1
    elif [ "$rc" -ne 0 ]; then
        print_error "adb ha fallat (codi ${rc}). Executeu scripts/wsl-usb-check.sh"
        exit 1
    fi
    while IFS=$'\t' read -r serial state; do
        case "$serial" in
        '' | 'List of devices'* | '*'*) continue ;;
        esac
        if [ -n "${ANDROID_SERIAL:-}" ] && [ "$serial" != "$ANDROID_SERIAL" ]; then
            continue
        fi
        found+=("${serial}"$'\t'"${state}")
    done <<<"$listing"

    if [ "${#found[@]}" -eq 0 ]; then
        if [ -n "${ANDROID_SERIAL:-}" ]; then
            print_error "Cap dispositiu ADB amb ANDROID_SERIAL=${ANDROID_SERIAL}. Executeu scripts/wsl-usb-check.sh"
        else
            print_error "Cap dispositiu ADB. Executeu scripts/wsl-usb-check.sh"
        fi
        exit 1
    fi
    if [ "${#found[@]}" -gt 1 ]; then
        print_error "Hi ha ${#found[@]} dispositius ADB: indiqueu quin amb ANDROID_SERIAL=<serial> (adb devices)"
        exit 1
    fi
    line="${found[0]}"
    serial="${line%%$'\t'*}"
    state="${line#*$'\t'}"
    case "$state" in
    device) ;;
    unauthorized)
        print_error "Dispositiu ${serial} no autoritzat: accepteu la clau RSA a la pantalla del marc"
        exit 1
        ;;
    offline)
        print_error "Dispositiu ${serial} offline: reconnecteu el cable o feu 'adb kill-server'"
        exit 1
        ;;
    *)
        print_error "Dispositiu ${serial} en estat '${state}' (s'esperava 'device')"
        exit 1
        ;;
    esac
}

require_root() {
    local uid=""
    uid="$(adb_sh id -u)" || uid=""
    if [ "$uid" != "0" ]; then
        print_error "Cal adbd root (id=0)"
        exit 1
    fi
}

# Para al primer desajust d'identitat (regla del repo de referència)
check_identity() {
    local hardware="" model=""
    hardware="$(adb_sh getprop ro.hardware)" || hardware=""
    model="$(adb_sh getprop ro.product.model)" || model=""
    if [ "$hardware" != "$EXPECTED_HARDWARE" ]; then
        print_error "ATURA: ro.hardware='${hardware}', s'esperava '${EXPECTED_HARDWARE}'. No és el dispositiu documentat."
        exit 2
    fi
    print_success "Identitat: model=${model} ro.hardware=${hardware}"
}

device_serial() {
    local serial=""
    serial="$(timeout 10 adb get-serialno 2>/dev/null | tr -d '\r')" || serial=""
    printf '%s' "${serial:-unknown}"
}

# Sha-256 i mida (bytes) de stdin: imprimeix "<hash> <mida>"
stream_sha_size() {
    python3 -I -c '
import hashlib, sys
h, n = hashlib.sha256(), 0
while chunk := sys.stdin.buffer.read(1 << 20):
    h.update(chunk)
    n += len(chunk)
print(h.hexdigest(), n)'
}

confirm() {
    local reply=""
    read -r -p "$1 (s/n): " -n 1 reply || reply=""
    echo
    [[ "$reply" =~ ^[SsYy]$ ]]
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Una línia JSONL a CHANGES_LOG per cada canvi fet al dispositiu.
# log_change <acció> <ordre-per-desfer-completa, amb 'adb shell '/'adb '> [camps-extra]
# Els camps extra són membres JSON ja formats, p. ex. '"persisted":false'.
log_change() {
    local action="$1" undo="$2" extra="${3:-}"
    local serial
    serial="$(device_serial)"
    if ! mkdir -p "$(dirname "$CHANGES_LOG")"; then
        print_error "No es pot crear el directori de ${CHANGES_LOG}"
        return 1
    fi
    if ! printf '{"date":"%s","serial":"%s","action":"%s","writes_to_device":true,"undo":"%s"%s}\n' \
        "$(date -Iseconds)" "$(json_escape "$serial")" "$(json_escape "$action")" \
        "$(json_escape "$undo")" "${extra:+,${extra}}" >>"$CHANGES_LOG"; then
        print_error "No es pot escriure a ${CHANGES_LOG}"
        return 1
    fi
    print_success "Registrat a ${CHANGES_LOG}"
}
