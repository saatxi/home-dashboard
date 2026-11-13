#!/usr/bin/env bash
set -Eeuo pipefail

# Eines del PATH: javac, zip (i keytool només si cal generar la clau).
# Eines de ${BUILD_TOOLS}: aapt2, d8, zipalign, apksigner (es comproven a check_sdk).
DEPENDENCIES=(javac zip)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ANDROID_HOME="${ANDROID_HOME:-/usr/lib/android-sdk}"
BUILD_TOOLS="${BUILD_TOOLS:-${ANDROID_HOME}/build-tools/34.0.0}"
PLATFORM_JAR="${ANDROID_JAR:-${ANDROID_HOME}/platforms/android-34/android.jar}"
KEYSTORE="${KIOSK_KEYSTORE:-${HOME}/.android/debug.keystore}"
# Les contrasenyes van a apksigner/keytool per variable d'entorn (mai per la línia d'ordres)
KIOSK_KS_PASS="${KIOSK_KS_PASS:-android}"
KIOSK_KEY_ALIAS="${KIOSK_KEY_ALIAS:-androiddebugkey}"
KIOSK_KEY_PASS="${KIOSK_KEY_PASS:-android}"
export KIOSK_KS_PASS KIOSK_KEY_PASS
GENERATE_KEY="${KIOSK_GENERATE_KEY:-}"
KIOSK_DIR="${ROOT}/kiosk"
BUILD_DIR="${KIOSK_DIR}/build"
# Els intermedis van a work/: no s'esborra mai la resta de kiosk/build (bootanimation.sh hi té el seu zip)
WORK_DIR="${BUILD_DIR}/work"
APK="${BUILD_DIR}/kiosk.apk"

usage_text() {
    cat <<EOM

Construeix kiosk/build/kiosk.apk (launcher mínim amb WebView) sense Gradle.
Només escriu dins de kiosk/build (work/ i kiosk.apk); no toca el dispositiu.
Verifica la signatura de l'APK amb apksigner al final.

usage: ${SCRIPT_NAME} [options]

options:
    --generate-key  Si la clau no existeix, la genera (vegeu l'avís de sota)
    -h|--help       Mostra aquesta ajuda

environment:
    ANDROID_HOME     SDK d'Android (per defecte /usr/lib/android-sdk)
    BUILD_TOOLS      Directori de build-tools (per defecte \$ANDROID_HOME/build-tools/34.0.0)
    ANDROID_JAR      android.jar de la plataforma (per defecte android-34)
    KIOSK_KEYSTORE   Clau de signatura (per defecte ~/.android/debug.keystore)
    KIOSK_KS_PASS    Contrasenya del keystore (per defecte la de depuració)
    KIOSK_KEY_ALIAS  Àlies de la clau (per defecte androiddebugkey)
    KIOSK_KEY_PASS   Contrasenya de la clau (per defecte la de depuració)
    KIOSK_GENERATE_KEY=1  Equival a --generate-key

AVÍS: si el keystore no existeix, no se'n crea un de nou sense --generate-key (o
KIOSK_GENERATE_KEY=1). Una clau nova fa que 'adb install -r' falli amb
INSTALL_FAILED_UPDATE_INCOMPATIBLE si al marc ja hi ha el kiosk signat amb una altra clau.

dependencies: ${DEPENDENCIES[*]} (+ keytool per generar la clau; aapt2, d8, zipalign i apksigner de BUILD_TOOLS)

examples:
    ${SCRIPT_NAME}

EOM
}

check_sdk() {
    local path
    for path in "${BUILD_TOOLS}/aapt2" "${BUILD_TOOLS}/d8" "${BUILD_TOOLS}/zipalign" "${BUILD_TOOLS}/apksigner" "${PLATFORM_JAR}"; do
        if [ ! -e "${path}" ]; then
            print_error "Falta ${path}"
            exit 1
        fi
    done
}

ensure_keystore() {
    if [ -f "${KEYSTORE}" ]; then
        return
    fi
    if [ -z "${GENERATE_KEY}" ]; then
        print_error "No existeix el keystore ${KEYSTORE}"
        print_warning "Una clau nova fa que 'adb install -r' falli amb INSTALL_FAILED_UPDATE_INCOMPATIBLE si el marc ja té el kiosk signat amb una altra clau."
        print_warning "Restaureu la clau original (KIOSK_KEYSTORE=...) o, si sou conscient del risc, genereu-ne una amb --generate-key."
        exit 1
    fi
    exit_on_missing_tools keytool
    print_warning "Creo la clau de signatura a ${KEYSTORE}"
    mkdir -p "$(dirname "${KEYSTORE}")"
    keytool -genkeypair -keystore "${KEYSTORE}" -storepass:env KIOSK_KS_PASS -keypass:env KIOSK_KEY_PASS \
        -alias "${KIOSK_KEY_ALIAS}" -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
}

build() {
    local -a classes=()
    cd "${KIOSK_DIR}"
    rm -rf "${WORK_DIR}"
    rm -f "${APK}"
    mkdir -p "${WORK_DIR}/gen" "${WORK_DIR}/classes"

    "${BUILD_TOOLS}/aapt2" compile --dir res -o "${WORK_DIR}/res.zip"
    # targetSdk 28: evita les restriccions de visibilitat de paquets i d'"exported" de l'Android 11+.
    "${BUILD_TOOLS}/aapt2" link -o "${WORK_DIR}/base.apk" -I "${PLATFORM_JAR}" \
        --manifest AndroidManifest.xml -A assets "${WORK_DIR}/res.zip" \
        --java "${WORK_DIR}/gen" --min-sdk-version 23 --target-sdk-version 28 \
        --version-code 3 --version-name 0.3

    # -Xlint:-options: sense l'avís de 'source 8 obsolet'. Si javac falla, set -e atura la construcció.
    javac -nowarn -Xlint:-options -source 8 -target 8 -classpath "${PLATFORM_JAR}" -d "${WORK_DIR}/classes" \
        src/local/homedashboard/kiosk/*.java \
        "${WORK_DIR}/gen/local/homedashboard/kiosk/R.java"

    mapfile -d '' -t classes < <(find "${WORK_DIR}/classes" -name '*.class' -print0)
    if [ "${#classes[@]}" -eq 0 ]; then
        print_error "javac no ha generat cap .class"
        exit 1
    fi
    "${BUILD_TOOLS}/d8" --min-api 23 --lib "${PLATFORM_JAR}" --output "${WORK_DIR}" "${classes[@]}"
    (cd "${WORK_DIR}" && zip -qj base.apk classes.dex)
    "${BUILD_TOOLS}/zipalign" -f 4 "${WORK_DIR}/base.apk" "${WORK_DIR}/aligned.apk"
    "${BUILD_TOOLS}/apksigner" sign --ks "${KEYSTORE}" --ks-key-alias "${KIOSK_KEY_ALIAS}" \
        --ks-pass env:KIOSK_KS_PASS --key-pass env:KIOSK_KEY_PASS --out "${APK}" "${WORK_DIR}/aligned.apk"
    "${BUILD_TOOLS}/apksigner" verify "${APK}"
}

main() {
    while [ $# -gt 0 ]; do
        case $1 in
        --generate-key)
            GENERATE_KEY=1
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
    check_sdk
    ensure_keystore
    print_header "Construeixo el kiosk"
    build
    print_success "APK signat i verificat: ${APK}"
    local badging
    badging="$("${BUILD_TOOLS}/aapt2" dump badging "${APK}")"
    # grep sense coincidències no és un error aquí
    grep -E "^package|uses-permission|sdkVersion|launchable" <<<"${badging}" || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
