#!/usr/bin/env bash
# shellcheck disable=SC2012,SC2015,SC2016  # idioma ok/ko deliberat; bash -c amb cometes simples
# Tests dels scripts amb un adb FALS (scripts/tests/bin/adb). No toca cap dispositiu real.
# Tot l'estat i la sortida van a un directori temporal que s'esborra en acabar.
# Ús: scripts/tests/run-tests.sh [grup...]   (sense arguments, tots els grups)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
S="${REPO}/scripts"
export PATH="${HERE}/bin:${PATH}"
export NO_COLOR=1 PERSIST_ATTEMPTS=2 PERSIST_INTERVAL=0 ADB_TIMEOUT=3

if [ "$(command -v adb)" != "${HERE}/bin/adb" ]; then
    echo "ABORT: adb no és el fals ($(command -v adb))"
    exit 99
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# El fals desa l'estat per defecte a $PWD/.fake: ho mantenim dins del temporal
cd "$WORK" || exit 99
unset ANDROID_SERIAL

pass=0 fail=0 skip=0
LAST_OUT=""
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '      %s\n' "${2//$'\n'/$'\n      '}"; }
skip() { skip=$((skip + 1)); printf 'SKIP  %s\n' "$1"; }

# expect <nom> <codi-esperat|nonzero> -- ordre...
expect() {
    local name="$1" want="$2" out rc=0
    shift 3
    out="$("$@" 2>&1)" || rc=$?
    LAST_OUT="$out"
    if { [ "$want" = nonzero ] && [ "$rc" -ne 0 ]; } || [ "$rc" = "$want" ]; then
        ok "$name (rc=$rc)"
    else
        ko "$name (rc=$rc, esperat $want)" "ordre: $*"$'\n'"$(printf '%s' "$out" | tail -15)"
    fi
}
# has <nom> <text>: la darrera sortida conté el text
has() {
    if grep -qF -- "$2" <<<"$LAST_OUT"; then ok "$1"; else ko "$1 (falta '$2')" "$(printf '%s' "$LAST_OUT" | tail -15)"; fi
}
# check <nom> <ordre...>: l'ordre ha de sortir amb 0
check() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else ko "$name" "ordre: $*"; fi
}
# fresh <nom>: estat net per a un test
fresh() {
    export FAKE_STATE="${WORK}/state-$1" OUTPUT_ROOT="${WORK}/out-$1"
    rm -rf "$FAKE_STATE" "$OUTPUT_ROOT"
    mkdir -p "$OUTPUT_ROOT"
    unset ANDROID_SERIAL FAKE_DEVICES FAKE_HARDWARE FAKE_STREAM_MODE FAKE_STREAM_ONLY FAKE_REMOTE_HASH_BAD \
        FAKE_PM_FAIL FAKE_NO_PERSIST FAKE_HOMES FAKE_INSTALLED FAKE_PARTS FAKE_ADB_HANG FAKE_PUSH_FAIL
}
first_backup_dir() { local d; d="$(ls -d "$OUTPUT_ROOT"/backups/*/ | head -1)"; echo "${d%/}"; }
no_partial() { [ -z "$(ls "$1"/*.partial 2>/dev/null)" ]; }
not_complete() { ! grep -qx 'complete=yes' "$1/MANIFEST"; }

group_help() {
    echo "== sintaxi i ajuda"
    local f b
    for f in "$S"/*.sh; do
        b="$(basename "$f")"
        [ "$b" = common.sh ] && continue # llibreria, no s'executa
        fresh help
        expect "$b --help" 0 -- "$f" --help
        expect "$b --bogus" nonzero -- "$f" --bogus
    done
    expect "verify-backup sense arguments" nonzero -- "$S/verify-backup.sh"
    expect "harden sense ordre" nonzero -- "$S/harden.sh"
    expect "bootanimation sense ordre" nonzero -- "$S/bootanimation.sh"
    expect "harden apply status (doble ordre)" nonzero -- "$S/harden.sh" apply status
    has "harden doble ordre: missatge" "Només es pot indicar una ordre"
    expect "wsl-usb-check --help amb PATH mínim" 0 -- env PATH=/usr/bin:/bin "$S/wsl-usb-check.sh" --help
}

check_dev() { bash -c 'set -Eeuo pipefail; source "$1/common.sh"; require_device; echo DEVICE-OK' _ "$S"; }

group_require_device() {
    echo "== require_device"
    fresh d1; export FAKE_DEVICES=""
    expect "zero dispositius" 1 -- check_dev; has "missatge zero" "Cap dispositiu ADB"
    fresh d2; export FAKE_DEVICES=$'A1\tdevice;B2\tdevice'
    expect "dos dispositius" 1 -- check_dev; has "missatge dos" "ANDROID_SERIAL"
    ANDROID_SERIAL=B2 expect "dos dispositius amb ANDROID_SERIAL" 0 -- check_dev
    fresh d3; export FAKE_DEVICES=$'A1\tunauthorized'
    expect "unauthorized" 1 -- check_dev; has "missatge unauthorized" "no autoritzat"
    fresh d4; export FAKE_DEVICES=$'A1\toffline'
    expect "offline" 1 -- check_dev; has "missatge offline" "offline"
    fresh d5; export FAKE_ADB_HANG=1
    expect "adb penjat (timeout)" 1 -- check_dev; has "missatge timeout" "no respon"
    fresh d6
    expect "un dispositiu bo" 0 -- check_dev
}

group_common() {
    echo "== adb_sh, print_* i log_change"
    fresh a1
    expect "adb_sh propaga l'estat d'adb" 3 -- bash -c 'source "$1/common.sh"; adb(){ echo "x"; return 3; }; adb_sh foo; exit $?' _ "$S"
    expect "adb_sh treu \\r" 0 -- bash -c 'source "$1/common.sh"; adb(){ printf "ab\r\n"; }; [ "$(adb_sh foo)" = ab ]' _ "$S"
    expect "print_* no interpreta escapades" 0 -- bash -c 'source "$1/common.sh"; [ "$(print_warning "a\\nb")" = "[AVÍS]   a\\nb" ]' _ "$S"
    cat >"${WORK}/lc-check.py" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read())
assert d["persisted"] is False and d["action"] == 'a "q" \\ b' and d["serial"] == "FAKE123" and "T" in d["date"], d
PY
    expect "log_change JSON vàlid amb cometes i barres" 0 -- bash -c 'source "$1/common.sh"; CHANGES_LOG="$2"; adb(){ echo S1; }; log_change "a \"q\" \\ b" "adb shell x" "\"persisted\":false" >/dev/null; python3 "$3" "$2"' _ "$S" "${WORK}/lc.jsonl" "${WORK}/lc-check.py"
}

# Manipula una còpia d'un backup bo amb Python (peça substituïda per farciment 0xCC)
make_filler_backup() {
    python3 - "$1" <<'PY'
import gzip, hashlib, sys
d = sys.argv[1]; data = b"\xcc" * 70000
gzip.open(f"{d}/part-env.img.gz", "wb").write(data)
open(f"{d}/part-env.sha256", "w").write(f"{hashlib.sha256(data).hexdigest()}  x\n{len(data)}\nx\n")
m = open(f"{d}/MANIFEST").read().splitlines()
m = [f"piece part-env {len(data)} {hashlib.sha256(data).hexdigest()} exact" if l.startswith("piece part-env ") else l for l in m]
open(f"{d}/MANIFEST", "w").write("\n".join(m) + "\n")
PY
}

group_backup_verify() {
    echo "== backup bo + verify-backup"
    fresh b1
    expect "backup bo" 0 -- "$S/backup.sh" --with-data
    local B1
    B1="$(first_backup_dir)"
    [ -f "$B1/MANIFEST" ] && tail -1 "$B1/MANIFEST" | grep -qx 'complete=yes' && ok "MANIFEST complet" || ko "MANIFEST complet" "$(cat "$B1/MANIFEST" 2>&1)"
    check "MANIFEST té UDISK (--with-data)" grep -q '^piece part-UDISK ' "$B1/MANIFEST"
    check "cap .partial" no_partial "$B1"
    [ "$(sed -n 2p "$B1/part-system.sha256")" = "$((4096 * 512))" ] && ok ".sha256: mida a la línia 2" || ko ".sha256: mida" "$(cat "$B1/part-system.sha256")"
    [ "$(wc -l <"$B1/part-system.sha256")" = 3 ] && ok ".sha256 té 3 línies" || ko ".sha256 línies"
    check "NOTE d'UDISK" test -f "$B1/part-UDISK.NOTE.txt"
    expect "verify-backup bo" 0 -- "$S/verify-backup.sh" "$B1"

    cp -r "$B1" "$WORK/b1-nopiece"; rm "$WORK/b1-nopiece/part-env.img.gz"
    expect "verify: peça eliminada" nonzero -- "$S/verify-backup.sh" "$WORK/b1-nopiece"; has "verify: diu quina falta" "part-env"
    cp -r "$B1" "$WORK/b1-stray"; cp "$B1/part-env.img.gz" "$WORK/b1-stray/stray.img.gz"; cp "$B1/part-env.sha256" "$WORK/b1-stray/stray.sha256"
    expect "verify: .img.gz sobrer" nonzero -- "$S/verify-backup.sh" "$WORK/b1-stray"; has "verify: sobrer al MANIFEST" "no és al MANIFEST"
    cp -r "$B1" "$WORK/b1-incomplete"; sed -i '/^complete=yes/d' "$WORK/b1-incomplete/MANIFEST"
    expect "verify: MANIFEST sense complete" nonzero -- "$S/verify-backup.sh" "$WORK/b1-incomplete"
    cp -r "$B1" "$WORK/b1-old"; rm "$WORK/b1-old/MANIFEST"
    expect "verify: backup antic sense MANIFEST (avís, ok)" 0 -- "$S/verify-backup.sh" "$WORK/b1-old"; has "verify: avís sense MANIFEST" "sense MANIFEST"
    mkdir "$WORK/empty-dir"
    expect "verify: carpeta buida" nonzero -- "$S/verify-backup.sh" "$WORK/empty-dir"
    cp -r "$B1" "$WORK/b1-corrupt"; printf 'x' >>"$WORK/b1-corrupt/part-env.img.gz"
    expect "verify: gz amb brossa final/corrupte" nonzero -- "$S/verify-backup.sh" "$WORK/b1-corrupt"
    cp -r "$B1" "$WORK/b1-badhash"; sed -i '1s/^./0/' "$WORK/b1-badhash/part-env.sha256"
    expect "verify: sha256 alterat" nonzero -- "$S/verify-backup.sh" "$WORK/b1-badhash"
    cp -r "$B1" "$WORK/b1-filler"; make_filler_backup "$WORK/b1-filler"
    expect "verify: filler 0xCC detectat" nonzero -- "$S/verify-backup.sh" "$WORK/b1-filler"; has "verify: missatge filler" "0xCC"
}

# bad_backup <nom> <mode> [només]: backup amb un flux defectuós
bad_backup() {
    fresh "$1"; export FAKE_STREAM_MODE="$2"
    [ -z "${3:-}" ] || export FAKE_STREAM_ONLY="$3"
    expect "backup $1 falla" 3 -- "$S/backup.sh"
    local out="$LAST_OUT" d
    d="$(first_backup_dir)"
    check "$1: sense .partial" no_partial "$d"
    check "$1: MANIFEST no complet" not_complete "$d"
    LAST_OUT="$out"; has "$1: avís incomplet" "INCOMPLET"
    BAD_DIR="$d"
}
no_piece() { [ ! -e "$BAD_DIR/part-system.img.gz" ] && [ ! -e "$BAD_DIR/part-system.sha256" ]; }

group_backup_fail() {
    echo "== backup amb fallades"
    bad_backup empty empty system; check "empty: res de part-system" no_piece
    bad_backup short short system; check "short: res de part-system" no_piece
    bad_backup fail fail system; check "fail: res de part-system" no_piece
    bad_backup garbage garbage system; check "garbage: res de part-system" no_piece
    bad_backup emptyall empty
    fresh hashbad; export FAKE_REMOTE_HASH_BAD=1
    expect "backup amb hash remot diferent" 3 -- "$S/backup.sh"; has "hash remot diferent: missatge" "hash no coincideix"
    fresh noparts; export FAKE_PARTS="mmcblk0"
    expect "backup amb llistat sense particions" 3 -- "$S/backup.sh"; has "llistat buit: missatge" "cap partició"
    fresh wronghw; export FAKE_HARDWARE=other
    expect "backup amb altre hardware" 2 -- "$S/backup.sh"
}

group_backup_interrupt() {
    echo "== backup interromput (SIGTERM)"
    fresh sig; export FAKE_STREAM_MODE=slow FAKE_STREAM_ONLY=system
    setsid "$S/backup.sh" >"${WORK}/sig.out" 2>&1 &
    local sigpid=$! rc d _
    for _ in $(seq 1 100); do
        ls "$OUTPUT_ROOT"/backups/*/part-system.img.gz.partial >/dev/null 2>&1 && break
        sleep 0.1
    done
    # SIGTERM: els jobs en segon pla d'un shell no interactiu ignoren SIGINT; el trap cobreix INT i TERM
    kill -TERM -- "-${sigpid}" 2>/dev/null || kill -TERM "$sigpid"
    wait "$sigpid"; rc=$?
    LAST_OUT="$(cat "${WORK}/sig.out")"
    [ "$rc" = 130 ] && ok "SIGTERM: rc=130" || ko "SIGTERM: rc=$rc (esperat 130)" "$LAST_OUT"
    d="$(first_backup_dir)"
    check "SIGTERM: .partial esborrat" no_partial "$d"
    check "SIGTERM: MANIFEST no complet" not_complete "$d"
    has "SIGTERM: avís incomplet" "INCOMPLET"
}

group_harden() {
    echo "== harden"
    fresh h1; export CHANGES_LOG="${WORK}/h1-changes.jsonl"
    expect "harden status" 0 -- "$S/harden.sh" status; has "status mostra example" "example  com.example  activat"
    expect "harden apply example -y" 0 -- "$S/harden.sh" apply example -y; has "apply: desactivat" "desactivat"
    expect "harden status després" 0 -- "$S/harden.sh" status; has "status desactivat" "example  com.example  desactivat"
    expect "harden revert example" 0 -- "$S/harden.sh" revert example
    expect "harden status final" 0 -- "$S/harden.sh" status; has "status activat" "example  com.example  activat"
    [ "$(wc -l <"$CHANGES_LOG")" = 2 ] && ok "log: 2 línies" || ko "log: línies" "$(cat "$CHANGES_LOG")"
    python3 - "$CHANGES_LOG" <<'PY' && ok "log: JSONL vàlid amb els camps" || ko "log: JSONL" "$(cat "$CHANGES_LOG")"
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    assert d["undo"].startswith("adb shell "), d
    assert d["writes_to_device"] is True and d["serial"] == "FAKE123" and "T" in d["date"], d
PY
    expect "harden apply example (sense -y, stdin buit)" 0 -- "$S/harden.sh" apply example </dev/null; has "cancel·lat" "Cancel"

    fresh h2; export CHANGES_LOG="${WORK}/h2-changes.jsonl" FAKE_PM_FAIL=1
    expect "pm falla" 1 -- "$S/harden.sh" apply example -y
    [ ! -e "$CHANGES_LOG" ] && ok "pm falla: res al log" || ko "pm falla: s'ha registrat" "$(cat "$CHANGES_LOG")"

    fresh h3; export CHANGES_LOG="${WORK}/h3-changes.jsonl" FAKE_NO_PERSIST=1
    expect "persistència no confirmada" 1 -- "$S/harden.sh" apply example -y
    [ "$(wc -l <"$CHANGES_LOG")" = 2 ] && grep -q '"persisted":false' "$CHANGES_LOG" && ok "log amb persisted:false" || ko "log persisted" "$(cat "$CHANGES_LOG")"
    check "persisted: log JSON vàlid" python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' "$CHANGES_LOG"

    fresh h4; export CHANGES_LOG="${WORK}/h4-changes.jsonl" FAKE_INSTALLED="com.example com.zeasn.frame"
    expect "apply uhale sense kiosk instal·lat" 1 -- "$S/harden.sh" apply uhale -y; has "uhale: kiosk no instal·lat" "no està instal·lat"
    [ ! -e "$CHANGES_LOG" ] && ok "uhale refusat: res al log" || ko "uhale refusat: log"
    fresh h5; export CHANGES_LOG="${WORK}/h5-changes.jsonl" FAKE_INSTALLED="com.example com.zeasn.frame local.homedashboard.kiosk" \
        FAKE_HOMES=$'1 activity:\n  com.zeasn.frame/.Home\n  com.android.settings/.FallbackHome'
    expect "apply uhale amb només FallbackHome com a altre HOME" 1 -- "$S/harden.sh" apply uhale -y; has "uhale: únic HOME" "únic HOME"
    fresh h6; export CHANGES_LOG="${WORK}/h6-changes.jsonl" FAKE_INSTALLED="com.example com.zeasn.frame local.homedashboard.kiosk"
    expect "apply uhale amb kiosk i HOME" 0 -- "$S/harden.sh" apply uhale -y
    expect "harden snapshot" 0 -- "$S/harden.sh" snapshot
    check "snapshot a OUTPUT_ROOT" ls "$OUTPUT_ROOT"/diagnostics/*-pre-hardening/getprop.txt
    expect "harden status amb pas sobrer" nonzero -- "$S/harden.sh" status example
    unset CHANGES_LOG
}

group_bootanimation() {
    echo "== bootanimation"
    if ! command -v zip >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        skip "bootanimation: falta zip/unzip al sistema (el script ho exigeix); grup omès"
        return
    fi
    fresh ba1; export CHANGES_LOG="${WORK}/ba1-changes.jsonl" BOOTANIMATION_OUT_DIR="${WORK}/ba1-out" FAKE_HARDWARE=other
    expect "install amb altre hardware" 2 -- "$S/bootanimation.sh" install -y; has "refusa per identitat" "ATURA"
    ! grep -q '^push' "$FAKE_STATE/calls.log" 2>/dev/null && ok "cap push fet" || ko "s'ha fet push!" "$(cat "$FAKE_STATE/calls.log")"
    expect "remove amb altre hardware" 2 -- "$S/bootanimation.sh" remove -y
    expect "status amb altre hardware" 2 -- "$S/bootanimation.sh" status
    fresh ba2; export CHANGES_LOG="${WORK}/ba2-changes.jsonl" BOOTANIMATION_OUT_DIR="${WORK}/ba2-out"
    expect "status (sense zip al sistema)" 0 -- "$S/bootanimation.sh" status; has "status avisa" "No hi ha /system"
    expect "install -y" 0 -- "$S/bootanimation.sh" install -y
    expect "status instal·lat" 0 -- "$S/bootanimation.sh" status; has "status: substituïda" "Substituïda"
    expect "remove -y" 0 -- "$S/bootanimation.sh" remove -y
    check "log JSONL (2 línies amb undo)" python3 -c 'import json,sys; ls=[json.loads(l) for l in open(sys.argv[1])]; assert len(ls)==2 and all(d["undo"].startswith("adb ") for d in ls), ls' "$CHANGES_LOG"
    unset BOOTANIMATION_OUT_DIR CHANGES_LOG
}

group_args() {
    echo "== serve-dashboard (només validació d'arguments)"
    expect "--port sense valor" nonzero -- "$S/serve-dashboard.sh" --port; has "--port: missatge" "Falta el valor"
    expect "--port 99999" nonzero -- "$S/serve-dashboard.sh" --port 99999; has "--port 99999: missatge" "Port invàlid"
    expect "--port 0" nonzero -- "$S/serve-dashboard.sh" --port 0
    expect "--port abc" nonzero -- "$S/serve-dashboard.sh" --port abc
}

group_identify() {
    echo "== identify"
    fresh i1
    expect "identify" 0 -- "$S/identify.sh"
    expect "identify amb altre hardware" 2 -- env FAKE_HARDWARE=other "$S/identify.sh"
}

ALL_GROUPS=(help require_device common backup_verify backup_fail backup_interrupt harden bootanimation args identify)
if [ "$#" -gt 0 ]; then groups=("$@"); else groups=("${ALL_GROUPS[@]}"); fi
for g in "${groups[@]}"; do
    if declare -F "group_${g}" >/dev/null; then "group_${g}"; else echo "Grup desconegut: $g (grups: ${ALL_GROUPS[*]})"; exit 2; fi
done

echo
echo "RESULTAT: ${pass} PASS, ${fail} FAIL, ${skip} SKIP"
[ "$fail" -eq 0 ]
