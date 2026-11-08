#!/usr/bin/env bash

DEPENDENCIES=(adb sha256sum gzip awk)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DISK=/dev/block/mmcblk0
DATA_PARTITIONS=(UDISK media_data)
LIVE_PARTITIONS=(UDISK)
BOOT_DEVICES=(mmcblk0boot0 mmcblk0boot1)

usage() {
    cat <<EOM

Backup NOMÉS DE LECTURA via adb exec-out + dd. No escriu res al dispositiu.
Per defecte desa, en una sola carpeta: boot0/boot1, la zona del disc abans de la
primera partició (taula de particions i bootloader), totes les particions excepte
${DATA_PARTITIONS[*]}, i la cua del disc (còpia de la GPT).
Cada peça és <nom>.img.gz + <nom>.sha256 (hash i mida), i el hash del flux es
compara amb el que calcula el propi dispositiu.

${LIVE_PARTITIONS[*]} està muntada i en ús: es desa en una sola passada com a còpia
en calent, amb una nota (.NOTE.txt) i sense comparació amb el hash del dispositiu.

usage: ${SCRIPT_NAME} [options]

options:
    --with-data    Afegeix ${DATA_PARTITIONS[*]} a la còpia completa
    --only-data    Fa només ${DATA_PARTITIONS[*]}
    -h|--help      Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[@]} (pigz, opcional, per comprimir més ràpid)

examples:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} --with-data

EOM
    exit 1
}

main() {
    local include_data=false
    local only_data=false

    while [ "$1" != "" ]; do
        case $1 in
        --with-data)
            include_data=true
            ;;
        --only-data)
            include_data=true
            only_data=true
            ;;
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

    exit_on_missing_tools "${DEPENDENCIES[@]}"
    require_device
    check_identity
    require_root

    local dest
    dest="${ROOT}/backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dest" || {
        print_error "No es pot crear ${dest}"
        exit 1
    }

    if [ "$only_data" = false ]; then
        backup_system "$dest" || exit 3
    fi
    if [ "$include_data" = true ]; then
        backup_partitions "$dest" data || exit 3
    fi

    echo "Backup a ${dest}. Seguiu amb scripts/verify-backup.sh ${dest}"
}

backup_system() {
    local dest="$1"
    local total first_start last_end
    read -r total first_start last_end < <(disk_geometry)
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
        if adb shell "[ -e /dev/block/${device} ]"; then
            dump_partition "/dev/block/${device}" "$device" "$dest" false || return 1
        fi
    done
}

backup_partitions() {
    local dest="$1" group="$2"
    local partition live
    for partition in $(adb shell 'ls /dev/block/by-name' | tr -d '\r'); do
        if ! belongs_to_group "$partition" "$group"; then
            continue
        fi
        live=false
        is_in_list "$partition" "${LIVE_PARTITIONS[@]}" && live=true
        dump_partition "/dev/block/by-name/${partition}" "part-${partition}" "$dest" "$live" || return 1
    done
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
        [ "$item" = "$candidate" ] && return 0
    done
    return 1
}

# Imprimeix: sectors totals, inici de la primera partició i final de l'última
disk_geometry() {
    local total start size
    local first="" last=0
    total=$(adb shell 'cat /sys/block/mmcblk0/size' | tr -d '\r')
    while read -r start size; do
        [ -z "$start" ] && continue
        if [ -z "$first" ] || [ "$start" -lt "$first" ]; then
            first="$start"
        fi
        if [ "$((start + size))" -gt "$last" ]; then
            last=$((start + size))
        fi
    done < <(adb shell 'for p in /sys/block/mmcblk0/mmcblk0p*; do echo $(cat $p/start) $(cat $p/size); done' | tr -d '\r')
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
    size=$(adb shell "blockdev --getsize64 ${device}" | tr -d '\r')
    dump_stream "$name" "$dest" "$size" "dd if=${device} bs=4M" "$live" "$device"
}

dump_stream() {
    local name="$1" dest="$2" size="$3" read_cmd="$4" live="$5" source_info="$6"
    local compressor=gzip remote_hash="" local_hash

    command -v pigz &>/dev/null && compressor=pigz
    echo "== ${name} (${source_info}) ${size} bytes"

    if [ "$live" = false ]; then
        remote_hash=$(adb shell "${read_cmd} 2>/dev/null | sha256sum" | awk '{print $1}')
    fi
    # tee amb process substitution: el flux es comprimeix i es calcula el hash a la vegada
    local_hash=$(adb exec-out "${read_cmd} 2>/dev/null" | tee >($compressor -1 >"${dest}/${name}.img.gz") | sha256sum | awk '{print $1}')
    wait

    if [ "$live" = false ] && { [ -z "$remote_hash" ] || [ "$remote_hash" != "$local_hash" ]; }; then
        print_error "${name}: hash no coincideix (remot '${remote_hash}', local '${local_hash}')"
        return 1
    fi
    printf '%s  %s\n%s\n%s\n' "$local_hash" "${name}.img.gz(raw)" "$size" "$source_info" >"${dest}/${name}.sha256"
    if [ "$live" = true ]; then
        write_live_note "${dest}/${name}.NOTE.txt" "$name"
        print_warning "${name}: còpia en calent (sense comparar amb el marc). Vegeu ${name}.NOTE.txt"
    fi
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
    exit 0
fi
