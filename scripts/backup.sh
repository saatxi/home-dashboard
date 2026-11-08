#!/usr/bin/env bash

DEPENDENCIES=(adb sha256sum gzip awk)
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DATA_PARTITIONS=(UDISK media_data)
BOOT_DEVICES=(mmcblk0boot0 mmcblk0boot1)

usage() {
    cat <<EOM

Backup NOMÉS DE LECTURA via adb exec-out + dd. No escriu res al dispositiu.
Cada partició es desa com a <nom>.img.gz + <nom>.sha256 (hash i mida en bytes),
i el hash del flux es compara amb el que calcula el propi dispositiu.

usage: ${SCRIPT_NAME} [options]

options:
    --with-data    Inclou també ${DATA_PARTITIONS[*]} (per defecte s'ometen)
    --only-data    Fa només ${DATA_PARTITIONS[*]}
    -h|--help      Mostra aquesta ajuda

dependencies: ${DEPENDENCIES[@]} (pigz, opcional, per comprimir més ràpid)

examples:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} --only-data

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
        backup_boot_devices "$dest" || exit 3
    fi
    backup_partitions "$dest" "$include_data" "$only_data" || exit 3

    echo "Backup a ${dest}. Seguiu amb scripts/verify-backup.sh ${dest}"
}

backup_boot_devices() {
    local dest="$1"
    local device
    for device in "${BOOT_DEVICES[@]}"; do
        if adb shell "[ -e /dev/block/${device} ]"; then
            dump_device "/dev/block/${device}" "$device" "$dest" || return 1
        fi
    done
}

backup_partitions() {
    local dest="$1" include_data="$2" only_data="$3"
    local partition
    for partition in $(adb shell 'ls /dev/block/by-name' | tr -d '\r'); do
        if ! should_backup_partition "$partition" "$include_data" "$only_data"; then
            continue
        fi
        dump_device "/dev/block/by-name/${partition}" "part-${partition}" "$dest" || return 1
    done
}

# mmcblk0* són el disc sencer, boot0/1 (ja fets) i RPMB: no són particions
should_backup_partition() {
    local partition="$1" include_data="$2" only_data="$3"
    case "$partition" in
    mmcblk0*) return 1 ;;
    esac
    if is_data_partition "$partition"; then
        [ "$include_data" = true ]
        return
    fi
    [ "$only_data" = false ]
}

is_data_partition() {
    local candidate
    for candidate in "${DATA_PARTITIONS[@]}"; do
        [ "$1" = "$candidate" ] && return 0
    done
    return 1
}

dump_device() {
    local device="$1" name="$2" dest="$3"
    local size remote_hash local_hash compressor=gzip

    command -v pigz &>/dev/null && compressor=pigz

    size=$(device_size "$device")
    echo "== ${name} (${device}) ${size} bytes"

    remote_hash=$(adb shell "sha256sum ${device}" | awk '{print $1}')
    # tee amb process substitution: el flux es comprimeix i es calcula el hash a la vegada
    local_hash=$(adb exec-out "dd if=${device} bs=4M 2>/dev/null" | tee >($compressor -1 >"${dest}/${name}.img.gz") | sha256sum | awk '{print $1}')
    wait

    if [ -z "$remote_hash" ] || [ "$remote_hash" != "$local_hash" ]; then
        print_error "${name}: hash no coincideix (remot '${remote_hash}', local '${local_hash}')"
        return 1
    fi
    printf '%s  %s\n%s\n' "$local_hash" "${name}.img.gz(raw)" "$size" >"${dest}/${name}.sha256"
    print_success "sha256=${local_hash}"
}

device_size() {
    adb shell "blockdev --getsize64 $1" | tr -d '\r'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
