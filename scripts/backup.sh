#!/usr/bin/env bash
set -Eeuo pipefail

DEPENDENCIES=(adb gzip awk python3)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

DISK=/dev/block/mmcblk0
DATA_PARTITIONS=(UDISK media_data)
LIVE_PARTITIONS=(UDISK)
BOOT_DEVICES=(mmcblk0boot0 mmcblk0boot1)
# Estat de la còpia en curs (el trap d'EXIT en depèn)
BACKUP_DIR=""
BACKUP_COMPLETE=false
MANIFEST_FILE=""

usage_text() {
    cat <<EOM

Backup NOMÉS DE LECTURA via adb exec-out + dd. No escriu res al dispositiu.
Per defecte desa, en una sola carpeta: boot0/boot1, la zona del disc abans de la
primera partició (taula de particions i bootloader), totes les particions excepte
${DATA_PARTITIONS[*]}, i la cua del disc (còpia de la GPT).
Cada peça és <nom>.img.gz + <nom>.sha256 (hash i mida), i el hash del flux es
compara amb el que calcula el propi dispositiu. La carpeta inclou un MANIFEST
(dispositiu, opcions, peces, mides i hashes) que acaba amb 'complete=yes' només si
totes les peces han anat bé; verify-backup.sh el fa servir.

${LIVE_PARTITIONS[*]} està muntada i en ús: es desa en una sola passada com a còpia
en calent, amb una nota (.NOTE.txt) i sense comparació amb el hash del dispositiu.

usage: ${SCRIPT_NAME} [options]

options:
    --with-data    Afegeix ${DATA_PARTITIONS[*]} a la còpia completa
    --only-data    Fa només ${DATA_PARTITIONS[*]}
    -h|--help      Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[*]} (pigz, opcional, per comprimir més ràpid)

examples:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} --with-data

EOM
}

main() {
    local include_data=false
    local only_data=false

    while [ $# -gt 0 ]; do
        case $1 in
        --with-data)
            include_data=true
            ;;
        --only-data)
            include_data=true
            only_data=true
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
    require_root

    BACKUP_DIR="${OUTPUT_ROOT}/backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR" || {
        print_error "No es pot crear ${BACKUP_DIR}"
        exit 1
    }
    # Ctrl-C o fallada: s'esborren els .partial i la carpeta queda sense 'complete=yes'
    trap finish_backup EXIT
    trap 'exit 130' INT TERM

    MANIFEST_FILE="${BACKUP_DIR}/MANIFEST"
    write_manifest_header "$include_data" "$only_data"

    if [ "$only_data" = false ]; then
        backup_system "$BACKUP_DIR" || exit 3
    fi
    if [ "$include_data" = true ]; then
        backup_partitions "$BACKUP_DIR" data || exit 3
    fi

    echo "complete=yes" >>"$MANIFEST_FILE"
    BACKUP_COMPLETE=true
    echo "Backup a ${BACKUP_DIR}. Seguiu amb scripts/verify-backup.sh ${BACKUP_DIR}"
}

finish_backup() {
    local status=$?
    trap - EXIT
    if [ -n "$BACKUP_DIR" ]; then
        rm -f "${BACKUP_DIR}"/*.partial
        if [ "$BACKUP_COMPLETE" != true ]; then
            print_error "Backup INCOMPLET a ${BACKUP_DIR} (MANIFEST sense 'complete=yes'): no el feu servir"
        fi
    fi
    exit "$status"
}

write_manifest_header() {
    local include_data="$1" only_data="$2"
    local fingerprint model hardware
    fingerprint="$(adb_sh getprop ro.build.fingerprint)" || fingerprint=""
    model="$(adb_sh getprop ro.product.model)" || model=""
    hardware="$(adb_sh getprop ro.hardware)" || hardware=""
    {
        echo "manifest_version=1"
        echo "serial=$(device_serial)"
        echo "fingerprint=${fingerprint}"
        echo "model=${model}"
        echo "hardware=${hardware}"
        echo "date=$(date -Iseconds)"
        echo "with_data=${include_data}"
        echo "only_data=${only_data}"
    } >"$MANIFEST_FILE"
}

# Una línia per peça: piece <nom> <mida> <sha256> <live|exact>
manifest_add_piece() {
    local name="$1" size="$2" hash="$3" live="$4" kind=exact
    if [ "$live" = true ]; then
        kind=live
    fi
    if [ -n "$MANIFEST_FILE" ]; then
        echo "piece ${name} ${size} ${hash} ${kind}" >>"$MANIFEST_FILE"
    fi
}

backup_system() {
    local dest="$1"
    local geometry total first_start last_end
    geometry="$(disk_geometry)" || return 1
    read -r total first_start last_end <<<"$geometry"
    if [ -z "$total" ] || [ -z "$first_start" ] || [ -z "$last_end" ]; then
        print_error "No es pot llegir la geometria del disc"
        return 1
    fi

    backup_boot_devices "$dest" || return 1
    backup_disk_range "$dest" disk-head 0 "$first_start" || return 1
    backup_partitions "$dest" system || return 1
    backup_disk_range "$dest" disk-tail "$last_end" "$((total - last_end))" || return 1
}

backup_boot_devices() {
    local dest="$1"
    local device
    for device in "${BOOT_DEVICES[@]}"; do
        if adb_sh "[ -e /dev/block/${device} ]" >/dev/null; then
            dump_partition "/dev/block/${device}" "$device" "$dest" false || return 1
        fi
    done
}

backup_partitions() {
    local dest="$1" group="$2"
    local listing partition live dumped=0
    local -a partitions=()
    if ! listing="$(adb_sh 'ls /dev/block/by-name')"; then
        print_error "No es pot llistar /dev/block/by-name"
        return 1
    fi
    mapfile -t partitions <<<"$listing"
    for partition in "${partitions[@]}"; do
        if [ -z "$partition" ] || ! belongs_to_group "$partition" "$group"; then
            continue
        fi
        live=false
        if is_in_list "$partition" "${LIVE_PARTITIONS[@]}"; then
            live=true
        fi
        dump_partition "/dev/block/by-name/${partition}" "part-${partition}" "$dest" "$live" || return 1
        dumped=$((dumped + 1))
    done
    if [ "$dumped" -eq 0 ]; then
        print_error "El llistat de particions no té cap partició del grup '${group}'"
        return 1
    fi
}

# mmcblk0* són el disc sencer, boot0/1 (ja fets) i RPMB: no són particions
belongs_to_group() {
    local partition="$1" group="$2"
    case "$partition" in
    mmcblk0*) return 1 ;;
    esac
    if is_in_list "$partition" "${DATA_PARTITIONS[@]}"; then
        [ "$group" = data ]
        return
    fi
    [ "$group" = system ]
}

is_in_list() {
    local item="$1" candidate
    shift
    for candidate in "$@"; do
        if [ "$item" = "$candidate" ]; then
            return 0
        fi
    done
    return 1
}

# Imprimeix: sectors totals, inici de la primera partició i final de l'última
disk_geometry() {
    local total listing start size
    local first="" last=0
    # shellcheck disable=SC2016 # s'expandeix al dispositiu, no aquí
    if ! total="$(adb_sh 'cat /sys/block/mmcblk0/size')" ||
        ! listing="$(adb_sh 'for p in /sys/block/mmcblk0/mmcblk0p*; do echo $(cat $p/start) $(cat $p/size); done')"; then
        print_error "No es pot llegir la geometria del disc"
        return 1
    fi
    if ! [[ "$total" =~ ^[0-9]+$ ]]; then
        print_error "Mida de disc invàlida '${total}'"
        return 1
    fi
    while read -r start size; do
        if [ -z "$start" ]; then
            continue
        fi
        if ! [[ "$start" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ ]]; then
            print_error "Geometria de partició invàlida '${start} ${size}'"
            return 1
        fi
        if [ -z "$first" ] || [ "$start" -lt "$first" ]; then
            first="$start"
        fi
        if [ "$((start + size))" -gt "$last" ]; then
            last=$((start + size))
        fi
    done <<<"$listing"
    echo "$total $first $last"
}

backup_disk_range() {
    local dest="$1" name="$2" skip="$3" count="$4"
    if [ "$count" -le 0 ]; then
        return 0
    fi
    dump_stream "$name" "$dest" "$((count * 512))" "dd if=${DISK} bs=512 skip=${skip} count=${count}" false "sectors ${skip}+${count} of mmcblk0"
}

dump_partition() {
    local device="$1" name="$2" dest="$3" live="$4"
    local size
    if ! size="$(adb_sh "blockdev --getsize64 ${device}")"; then
        print_error "${name}: no es pot llegir la mida de ${device}"
        return 1
    fi
    dump_stream "$name" "$dest" "$size" "dd if=${device} bs=4M" "$live" "$device"
}

# Desa una peça com a <nom>.img.gz només si tot quadra; si no, no deixa .img.gz ni .sha256.
#
# Detecció de fallades del dispositiu: 'adb exec-out' no propaga l'estat de sortida remot i el
# stderr de dd no pot anar al flux (acabaria dins la imatge), així que dd va amb 2>/dev/null i
# les fallades es detecten per resultat: un dd que falla o s'atura deixa el flux més curt que
# 'size', i es comprova (1) l'estat d'adb i del compressor, (2) que la mida descomprimida del
# .partial sigui exactament 'size', i (3) si no és còpia en calent, que el sha256 coincideixi
# amb el que calcula el dispositiu en una lectura independent.
# El compressor és una etapa directa del pipeline (no una process substitution): quan el
# pipeline acaba, ja ha buidat i tancat el fitxer. Hash i mida es calculen després llegint el
# .partial (no el flux), de manera que es valida el que realment queda al disc.
dump_stream() {
    local name="$1" dest="$2" size="$3" read_cmd="$4" live="$5" source_info="$6"
    local compressor=gzip remote_hash="" local_hash local_size result raw
    local partial="${dest}/${name}.img.gz.partial"
    local final="${dest}/${name}.img.gz"
    local -a status=()

    if command -v pigz &>/dev/null; then
        compressor=pigz
    fi
    echo "== ${name} (${source_info}) ${size} bytes"

    if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -le 0 ]; then
        print_error "${name}: mida invàlida o buida ('${size}')"
        return 1
    fi

    if [ "$live" = false ]; then
        if ! raw="$(adb_sh "${read_cmd} 2>/dev/null | sha256sum")"; then
            print_error "${name}: no s'ha pogut calcular el hash al dispositiu"
            return 1
        fi
        remote_hash="${raw%% *}"
        if ! [[ "$remote_hash" =~ ^[0-9a-f]{64}$ ]]; then
            print_error "${name}: hash remot invàlid '${remote_hash}'"
            return 1
        fi
    fi

    rm -f "$partial" "$final" "${dest}/${name}.sha256"
    if adb exec-out "${read_cmd} 2>/dev/null" | "$compressor" -1 >"$partial"; then
        status=("${PIPESTATUS[@]}")
    else
        status=("${PIPESTATUS[@]}")
    fi
    if [ "${status[0]}" -ne 0 ] || [ "${status[1]}" -ne 0 ]; then
        print_error "${name}: la transferència ha fallat (adb=${status[0]}, ${compressor}=${status[1]})"
        rm -f "$partial"
        return 1
    fi

    if ! result="$("$compressor" -dc "$partial" | stream_sha_size)"; then
        print_error "${name}: no es pot rellegir el fitxer comprimit"
        rm -f "$partial"
        return 1
    fi
    read -r local_hash local_size <<<"$result"
    if [ "$local_size" != "$size" ]; then
        print_error "${name}: s'han rebut ${local_size} bytes, s'esperaven ${size}"
        rm -f "$partial"
        return 1
    fi
    if [ "$live" = false ] && [ "$remote_hash" != "$local_hash" ]; then
        print_error "${name}: hash no coincideix (remot '${remote_hash}', local '${local_hash}')"
        rm -f "$partial"
        return 1
    fi

    if ! printf '%s  %s\n%s\n%s\n' "$local_hash" "${name}.img.gz(raw)" "$size" "$source_info" >"${dest}/${name}.sha256" ||
        ! mv "$partial" "$final"; then
        print_error "${name}: no es pot desar la peça"
        rm -f "$partial" "$final" "${dest}/${name}.sha256"
        return 1
    fi
    if [ "$live" = true ]; then
        write_live_note "${dest}/${name}.NOTE.txt" "$name"
        print_warning "${name}: còpia en calent (sense comparar amb el marc). Vegeu ${name}.NOTE.txt"
    fi
    manifest_add_piece "$name" "$size" "$local_hash" "$live"
    print_success "sha256=${local_hash}"
}

write_live_note() {
    cat >"$1" <<EOM
COPIA EN CALENT (live copy) de ${2}: particio muntada en rw i en us durant la lectura.
Una sola passada: el sha256 es del flux rebut i NO s'ha comparat amb el hash calculat al marc,
perque la particio canvia entre lectures.
Integritat del fitxer: verificable (mida exacta + sha256 del flux). Consistencia del sistema de fitxers: NO garantida.
No usar com a base d'una restauracio sense fsck.f2fs previ.
EOM
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
