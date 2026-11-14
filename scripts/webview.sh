#!/usr/bin/env bash
# Gestiona l'actualització del WebView del marc.
#
# El WebView de fàbrica (Chromium 74) va signat amb la testkey pública d'AOSP.
# Això permet instal·lar una versió més nova signada amb la mateixa clau sense
# escriure a /system (adb install -r actua com una actualització d'usuari).
# El revert és net: adb uninstall treu l'actualització i es torna a la 74 de /product.
#
# Requisits del fitxer APK (es comproven abans d'instal·lar):
#   - package=com.android.webview
#   - minSdkVersion ≤ 29 (Android 10 = SDK 29)
#   - versionCode > 373018605 (la versió instal·lada al marc)
#   - native-code conté armeabi-v7a (el marc és de 32 bits)
#
# BACKUP OBLIGATORI: no s'executa 'install' sense un backup verificat.
#   scripts/backup.sh && scripts/verify-backup.sh backups/<carpeta>
#
# Signatura: es torna a signar l'APK amb testkey.pk8 / testkey.x509.pem
#   d'AOSP (build/make/target/product/security). Es comprova el hash del certificat
#   contra el valor de fàbrica (SHA-256: a40da80a…bf5dc) abans d'instal·lar.

set -Eeuo pipefail

DEPENDENCIES=(adb)
INSTALL_DEPS=(apksigner aapt2 openssl curl)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

WEBVIEW_PKG="com.android.webview"
# SHA-256 del certificat de la testkey d'AOSP que signava el WebView de fàbrica.
EXPECTED_CERT_SHA256="a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc"
# versionCode de la 74.0.3729.186 que ve de fàbrica.
FACTORY_VERSION_CODE=373018605
# minSdkVersion màxim acceptat (Android 10).
MAX_MIN_SDK=29

# URLs dels fitxers de clau pública d'AOSP. S'usen per verificar que els PEM descarregats
# coincideixen amb l'empremta coneguda (EXPECTED_CERT_SHA256) abans de signar.
AOSP_TESTKEY_PK8_URL="https://raw.githubusercontent.com/aosp-mirror/platform_build/master/target/product/security/testkey.pk8"
AOSP_TESTKEY_PEM_URL="https://raw.githubusercontent.com/aosp-mirror/platform_build/master/target/product/security/testkey.x509.pem"

usage_text() {
    cat <<EOM

Gestiona l'actualització del WebView del marc (com.android.webview).

usage: ${SCRIPT_NAME} <command> [options]

commands:
    install <apk>   Comprova, re-signa i instal·la un APK de WebView més nou.
                    Requereix un backup verificat a backups/.
    revert          Desinstal·la l'actualització i torna a la 74 de /product.
    status          Mostra la versió del WebView instal·lada al marc.

options:
    -y|--yes        No demanis confirmació (només per a 'install' i 'revert')
    -h|--help       Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[*]} (+ ${INSTALL_DEPS[*]} per a 'install')

Claus AOSP (es descarreguen a ${ROOT}/server/.venv/../.. si no hi ha connexió, proporcioneu-les manualment):
    testkey.pk8      clau privada RSA en format DER
    testkey.x509.pem certificat públic X.509

Passos per actualitzar:
  1. scripts/backup.sh && scripts/verify-backup.sh backups/<carpeta>
  2. Baixar un APK com.android.webview arm 32-bit (p. ex. de LineageOS prebuilts)
  3. ${SCRIPT_NAME} install <apk>
  4. Verificar: ${SCRIPT_NAME} status  (ha de mostrar una versió > 74.0.3729.186)
  5. Per desfer: ${SCRIPT_NAME} revert

EOM
}

# Comprova que hi ha un backup verificat a OUTPUT_ROOT/backups/ amb complete=yes.
require_verified_backup() {
    local backups_dir="${OUTPUT_ROOT}/backups"
    if [ ! -d "$backups_dir" ]; then
        print_error "No hi ha cap backup a ${backups_dir}. Feu scripts/backup.sh primer."
        exit 1
    fi
    local manifest found_complete=false
    for manifest in "${backups_dir}"/*/MANIFEST; do
        if grep -q "^complete=yes$" "$manifest" 2>/dev/null; then
            found_complete=true
            break
        fi
    done
    if [ "$found_complete" != true ]; then
        print_error "No hi ha cap backup verificat (cap MANIFEST amb 'complete=yes') a ${backups_dir}."
        print_error "Feu: scripts/backup.sh && scripts/verify-backup.sh backups/<carpeta>"
        exit 1
    fi
    print_success "Backup verificat trobat"
}

# Comprova que l'APK té els metadades correctes (paquet, SDK, versió, ABI).
check_apk_metadata() {
    local apk="$1"
    local badging
    badging="$(aapt2 dump badging "$apk" 2>&1)" || {
        print_error "aapt2 no pot llegir '${apk}': no és un APK vàlid?"
        exit 1
    }

    # Paquet
    local pkg
    pkg="$(printf '%s\n' "$badging" | grep -oP "^package: name='\K[^']+")" || pkg=""
    if [ "$pkg" != "$WEBVIEW_PKG" ]; then
        print_error "Paquet '${pkg}', s'esperava '${WEBVIEW_PKG}'"
        exit 1
    fi

    # versionCode
    local vc
    vc="$(printf '%s\n' "$badging" | grep -oP "^package:.*versionCode='\K[0-9]+")" || vc=0
    if [ "$((vc))" -le "$FACTORY_VERSION_CODE" ]; then
        print_error "versionCode ${vc} no és més gran que la versió de fàbrica (${FACTORY_VERSION_CODE})"
        exit 1
    fi

    # minSdkVersion
    local min_sdk
    min_sdk="$(printf '%s\n' "$badging" | grep -oP "^sdkVersion:'\K[0-9]+")" || min_sdk=999
    if [ "$((min_sdk))" -gt "$MAX_MIN_SDK" ]; then
        print_error "minSdkVersion ${min_sdk} > ${MAX_MIN_SDK} (Android 10): no funcionarà al marc"
        exit 1
    fi

    # ABI 32-bit
    if ! printf '%s\n' "$badging" | grep -q "native-code:.*'armeabi-v7a'"; then
        print_error "L'APK no té native-code armeabi-v7a (el marc és de 32 bits)"
        exit 1
    fi

    print_success "APK vàlid: pkg=${pkg} versionCode=${vc} minSdk=${min_sdk} abi=armeabi-v7a"
}

# Baixa les claus testkey d'AOSP a un directori temporal i verifica que el
# certificat coincideix amb l'empremta esperada.
fetch_testkeys() {
    local out_dir="$1"
    local pk8="${out_dir}/testkey.pk8"
    local pem="${out_dir}/testkey.x509.pem"

    print_header "Descarregant testkey AOSP…"
    curl --fail --silent --show-error --location --max-time 30 \
        -o "$pk8" "$AOSP_TESTKEY_PK8_URL"
    curl --fail --silent --show-error --location --max-time 30 \
        -o "$pem" "$AOSP_TESTKEY_PEM_URL"

    # Comparem la suma sha256 del DER del certificat contra el valor de fàbrica.
    local cert_der_hash
    cert_der_hash="$(openssl x509 -in "$pem" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
    if [ "$cert_der_hash" != "$EXPECTED_CERT_SHA256" ]; then
        print_error "El certificat descarregat no coincideix amb l'empremta esperada."
        print_error "  Esperat:  ${EXPECTED_CERT_SHA256}"
        print_error "  Obtingut: ${cert_der_hash}"
        print_error "No s'instal·larà l'APK."
        exit 1
    fi
    print_success "Testkey verificada (SHA-256 coincideix)"
}

# Torna a signar l'APK amb la testkey d'AOSP. Desa l'APK signat a <apk>-signed.apk.
resign_apk() {
    local apk="$1" pk8="$2" pem="$3"
    local signed="${apk}-signed.apk"

    print_header "Tornant a signar l'APK…"
    # Eliminar la firma existent i re-signar.
    # apksigner sign --ks no funciona amb PK8+PEM; cal --key i --cert.
    apksigner sign --key "$pk8" --cert "$pem" --out "$signed" "$apk" 2>&1
    apksigner verify "$signed" 2>&1 && print_success "Signatura verificada"
    printf '%s' "$signed"
}

cmd_status() {
    require_device
    adb shell dumpsys webviewupdate 2>/dev/null | grep -E "Current WebView package|version"
}

cmd_install() {
    local apk="$1" assume_yes="${2:-false}"
    if [ ! -f "$apk" ]; then
        print_error "No es troba el fitxer '${apk}'"
        exit 1
    fi

    require_device
    check_identity
    require_verified_backup
    exit_on_missing_tools "${INSTALL_DEPS[@]}"
    check_apk_metadata "$apk"

    local tmpdir
    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" EXIT

    fetch_testkeys "$tmpdir"
    local signed_apk
    signed_apk="$(resign_apk "$apk" "${tmpdir}/testkey.pk8" "${tmpdir}/testkey.x509.pem")"

    if [ "$assume_yes" != true ] && ! confirm "Instal·lar el WebView nou al marc (es pot desfer amb '${SCRIPT_NAME} revert')?"; then
        print_warning "Cancel·lat"
        exit 0
    fi

    print_header "Instal·lant WebView…"
    if ! adb install -r "$signed_apk"; then
        print_error "adb install ha fallat"
        log_change "webview install FAILED" "${SCRIPT_NAME} revert" || true
        exit 1
    fi

    log_change "webview install $(aapt2 dump badging "$apk" | grep -oP "versionCode='\K[0-9]+")" \
        "adb uninstall ${WEBVIEW_PKG}" \
        || print_warning "Canvi fet però no registrat"

    print_success "WebView instal·lat. Comproveu amb '${SCRIPT_NAME} status'"
}

cmd_revert() {
    local assume_yes="${1:-false}"

    require_device
    check_identity

    # Comprova que hi ha una actualització instal·lada (no es pot desinstal·lar la del /product).
    local installed_path
    installed_path="$(adb shell pm path "${WEBVIEW_PKG}" 2>/dev/null | tr -d '\r' | cut -d: -f2)" || installed_path=""
    if printf '%s' "$installed_path" | grep -q "^/product/"; then
        print_warning "El WebView ja és el de fàbrica (a /product). No cal fer revert."
        exit 0
    fi

    if [ "$assume_yes" != true ] && ! confirm "Desinstal·lar l'actualització del WebView i tornar a la 74 de /product?"; then
        print_warning "Cancel·lat"
        exit 0
    fi

    print_header "Desinstal·lant actualització de WebView…"
    if ! adb uninstall "${WEBVIEW_PKG}"; then
        print_error "adb uninstall ha fallat"
        exit 1
    fi

    log_change "webview revert (torna a 74 de /product)" "# manual: adb install -r <apk-signat>" \
        || print_warning "Canvi fet però no registrat"

    print_success "Revert fet. Comproveu amb '${SCRIPT_NAME} status'"
}

main() {
    local command="" apk="" assume_yes=false

    while [ $# -gt 0 ]; do
        case $1 in
        install | revert | status)
            if [ -n "$command" ]; then
                print_error "Només es pot indicar una ordre ('${command}' i '$1')"
                usage
            fi
            command="$1"
            if [ "$1" = "install" ]; then
                if [ $# -lt 2 ]; then
                    print_error "Falta el fitxer APK per a 'install'"
                    usage
                fi
                shift
                apk="$1"
            fi
            ;;
        -y | --yes)
            assume_yes=true
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

    if [ -z "$command" ]; then
        print_error "Cal indicar una ordre"
        usage
    fi

    exit_on_missing_tools "${DEPENDENCIES[@]}"

    case "$command" in
    install) cmd_install "$apk" "$assume_yes" ;;
    revert)  cmd_revert "$assume_yes" ;;
    status)  cmd_status ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
