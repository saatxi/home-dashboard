#!/usr/bin/env bash

DEPENDENCIES=(javac keytool zipalign apksigner)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ANDROID_HOME="${ANDROID_HOME:-/usr/lib/android-sdk}"
BUILD_TOOLS="${BUILD_TOOLS:-${ANDROID_HOME}/build-tools/34.0.0}"
PLATFORM_JAR="${ANDROID_JAR:-${ANDROID_HOME}/platforms/android-34/android.jar}"
KEYSTORE="${KIOSK_KEYSTORE:-${HOME}/.android/debug.keystore}"
KIOSK_DIR="${ROOT}/kiosk"
BUILD_DIR="${KIOSK_DIR}/build"
APK="${BUILD_DIR}/kiosk.apk"

usage() {
    cat <<EOM

Construeix kiosk/build/kiosk.apk (launcher mínim amb WebView) sense Gradle.
Només escriu dins de kiosk/build; no toca el dispositiu.

usage: ${SCRIPT_NAME} [options]

options:
    -h|--help    Mostra aquesta ajuda

environment:
    ANDROID_HOME   SDK d'Android (per defecte /usr/lib/android-sdk)
    BUILD_TOOLS    Directori de build-tools (per defecte \$ANDROID_HOME/build-tools/34.0.0)
    ANDROID_JAR    android.jar de la plataforma (per defecte android-34)
    KIOSK_KEYSTORE Clau de signatura (per defecte ~/.android/debug.keystore, es crea si falta)

dependencies: ${DEPENDENCIES[@]}

examples:
    ${SCRIPT_NAME}

EOM
    exit 1
}

check_sdk() {
    local path
    for path in "${BUILD_TOOLS}/aapt2" "${BUILD_TOOLS}/d8" "${PLATFORM_JAR}"; do
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
    print_warning "Creo la clau de signatura de depuració a ${KEYSTORE}"
    mkdir -p "$(dirname "${KEYSTORE}")"
    keytool -genkeypair -keystore "${KEYSTORE}" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
}

build() {
    cd "${KIOSK_DIR}"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}/gen" "${BUILD_DIR}/classes"

    "${BUILD_TOOLS}/aapt2" compile --dir res -o "${BUILD_DIR}/res.zip"
    # targetSdk 28: evita les restriccions de visibilitat de paquets i d'"exported" de l'Android 11+.
    "${BUILD_TOOLS}/aapt2" link -o "${BUILD_DIR}/base.apk" -I "${PLATFORM_JAR}" \
        --manifest AndroidManifest.xml -A assets "${BUILD_DIR}/res.zip" \
        --java "${BUILD_DIR}/gen" --min-sdk-version 23 --target-sdk-version 28 \
        --version-code 2 --version-name 0.2

    javac -nowarn -source 8 -target 8 -classpath "${PLATFORM_JAR}" -d "${BUILD_DIR}/classes" \
        src/local/homedashboard/kiosk/*.java \
        "${BUILD_DIR}/gen/local/homedashboard/kiosk/R.java" 2>&1 | grep -v "^Note:\|warning:" || true

    "${BUILD_TOOLS}/d8" --min-api 23 --lib "${PLATFORM_JAR}" --output "${BUILD_DIR}" \
        $(find "${BUILD_DIR}/classes" -name '*.class')
    (cd "${BUILD_DIR}" && zip -qj base.apk classes.dex)
    "${BUILD_TOOLS}/zipalign" -f 4 "${BUILD_DIR}/base.apk" "${BUILD_DIR}/aligned.apk"
    "${BUILD_TOOLS}/apksigner" sign --ks "${KEYSTORE}" --ks-pass pass:android \
        --key-pass pass:android --out "${APK}" "${BUILD_DIR}/aligned.apk"
}

main() {
    set -euo pipefail
    while [ "${1:-}" != "" ]; do
        case $1 in
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

    exit_on_missing_tools "${DEPENDENCIES[@]}" zip
    check_sdk
    ensure_keystore
    print_header "Construeixo el kiosk"
    build
    print_success "APK: ${APK}"
    "${BUILD_TOOLS}/aapt2" dump badging "${APK}" | grep -E "^package|uses-permission|sdkVersion|launchable" || true
}

main "$@"
