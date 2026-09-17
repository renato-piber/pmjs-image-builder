#!/usr/bin/env bash
# Sem dispositivos reais, udev real ou mount real. Somente fixtures /tmp.
set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${TEST_DIR}/../build-image.sh"
test_root="$(mktemp -d /tmp/pmjs-ventoy-automount-test.XXXXXX)"
trap '[[ "${test_root}" == /tmp/pmjs-ventoy-automount-test.* && -d "${test_root}" && ! -L "${test_root}" ]] && find -P "${test_root}" -depth -delete' EXIT
log_write() { :; }

ventoy_device_is_block() {
    case "$1" in
        /dev/sdz1|/dev/nvme0n1p1) return 0 ;;
        /dev/sdy1) [[ "${mode}" == ambiguous ]] ;;
        /dev/mapper/sdz1|/dev/mapper/nvme0n1p1) [[ "${mapper_present}" == 1 ]] ;;
        *) return 1 ;;
    esac
}
device_property_fixture() {
    local property=$1 device=$2
    case "${property}" in
        LABEL)
            if [[ "${mode}" == wrong_label ]]; then printf 'Other\n';
            elif [[ "${mode}" == wrong_mapper && "${device}" == /dev/mapper/* ]]; then printf 'Other\n';
            else printf 'Ventoy\n'; fi ;;
        FSTYPE) if [[ "${mode}" == unsupported_fs ]]; then printf 'ext4\n'; else printf 'exfat\n'; fi ;;
        TRAN)
            if [[ "${mode}" == not_usb ]]; then printf 'sata\n';
            elif [[ "${mode}" == parent_usb && "${device}" == "${fixture_partition}" ]]; then printf '\n';
            else printf 'usb\n'; fi ;;
        PKNAME) printf 'sdz\n' ;;
    esac
}
lsblk() {
    local property=$3 device=${!#}
    if [[ "${property}" == NAME,TYPE ]]; then
        [[ "${mode}" != enumeration_failure ]] || return 2
        [[ "${mode}" != absent ]] || return 0
        printf '%s part\n' "${fixture_partition}"
        [[ "${mode}" != ambiguous ]] || printf '/dev/sdy1 part\n'
        return 0
    fi
    if [[ "${mode}" == blkid_fallback && ( "${property}" == LABEL || "${property}" == FSTYPE ) ]]; then return 0; fi
    device_property_fixture "${property}" "${device}"
}
blkid() {
    printf 'blkid\n' >> "${events}"
    case "$2" in LABEL) printf 'Ventoy\n' ;; TYPE) printf 'exfat\n' ;; esac
}
findmnt() {
    local query_kind="" query_path="" output=""
    while (( $# > 0 )); do
        case "$1" in
            --target|--source|--mountpoint) query_kind=$1; query_path=$2; shift 2 ;;
            --output) output=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    if [[ "${query_path}" == /run/live/medium ]]; then
        if [[ "${live_boot}" == 1 ]]; then printf '/dev/mapper/ventoy\n'; else printf '/dev/sr0\n'; fi
        return 0
    fi
    [[ "${record_available}" == 1 ]] || return 1
    case "${query_kind}" in
        --source)
            [[ "${query_path}" == "${record_source}" ]] || return 1
            printf '%s\n' "${record_target// /\\x20}"
            return 0 ;;
        --mountpoint) [[ "${query_path}" == "${record_target}" ]] || return 1 ;;
        --target) [[ "${query_path}" == "${record_target}/"* ]] || return 1 ;;
        *) return 2 ;;
    esac
    case "${output}" in
        ID,SOURCE,FSTYPE,OPTIONS)
            printf '%s %s %s %s\n' "${record_id}" "${record_source}" "${record_fs}" "${record_options}" ;;
        ID) printf '%s\n' "${record_id}" ;;
        SOURCE) printf '%s\n' "${record_source}" ;;
        FSTYPE) printf '%s\n' "${record_fs}" ;;
        TARGET) printf '%s\n' "${record_target// /\\x20}" ;;
        *) return 2 ;;
    esac
}
mount() {
    printf 'mount %s\n' "$*" >> "${events}"
    [[ "$*" == *'-o rw,nosuid,nodev -- '* ]] || return 90
    [[ "${mode}" != mount_failure ]] || return 32
    record_available=1
    record_target=${VENTOY_MOUNTPOINT}
    record_source=$6
    [[ "${mode}" != no_confirmation ]] || record_available=0
    [[ "${mode}" != wrong_source ]] || record_source=/dev/sda1
    [[ "${mode}" != wrong_type ]] || record_fs=ext4
    [[ "${mode}" != forced_ro ]] || record_options=ro,nosuid,nodev
    if [[ "${mode}" == mount_signal ]]; then kill -TERM "${BASHPID}"; fi
    return 0
}
umount() {
    printf 'umount %s\n' "$*" >> "${events}"
    [[ "${mode}" != umount_failure ]] || return 16
    record_available=0
}
udevadm() {
    printf 'udev %s\n' "$*" >> "${events}"
    [[ "${mode}" != udev_failure ]] || return 1
    if [[ "$1" == settle && "${mode}" == udev_mapper ]]; then mapper_present=1; fi
}

new_case() {
    mode=$1
    case_root="${test_root}/${mode}"
    events="${case_root}/events"
    VENTOY_MOUNTPOINT="${case_root}/mountpoint"
    VENTOY_VOLUME_LABEL=Ventoy
    VENTOY_ALLOWED_FSTYPES=exfat
    fixture_partition=/dev/sdz1
    mapper_present=0
    live_boot=0
    record_available=0
    record_id=500
    record_source=${fixture_partition}
    record_target=${VENTOY_MOUNTPOINT}
    record_fs=exfat
    record_options=rw,nosuid,nodev
    mkdir -p -- "${case_root}"
    : > "${events}"
    case "${mode}" in
        existing_rw|existing_ro|existing_error|existing_without_images)
            record_available=1
            record_target="${case_root}/desktop/Ventoy com espaço"
            mkdir -p -- "${record_target}"
            [[ "${mode}" != existing_ro ]] || record_options=ro,nosuid,nodev ;;
        occupied)
            record_available=1
            record_source=/dev/sda1
            record_fs=ext4
            mkdir -- "${VENTOY_MOUNTPOINT}" ;;
        nonempty)
            mkdir -- "${VENTOY_MOUNTPOINT}"
            printf 'keep\n' > "${VENTOY_MOUNTPOINT}/local-file" ;;
        mapper|wrong_mapper) mapper_present=1 ;;
        nvme_mapper) mapper_present=1; fixture_partition=/dev/nvme0n1p1 ;;
        missing_mapper|udev_mapper|udev_failure) live_boot=1 ;;
    esac
}
run_case() {
    (
        trap cleanup EXIT
        trap 'on_signal TERM' TERM
        prepare_ventoy_automount || exit 1
        printf 'selected=%s\n' "${VENTOY_DESTINATION}" >> "${events}"
        [[ -d "${VENTOY_DESTINATION}" ]] || exit 91
        if [[ "${mode}" == changed_mount ]]; then
            BUILD_VENTOY_COPY_IMAGE=pmjs-linux-test
            prepare_ventoy_sync_staging "${VENTOY_DESTINATION}" "${BUILD_VENTOY_COPY_IMAGE}" BUILD_VENTOY_COPY_STAGING
            printf 'keep\n' > "${BUILD_VENTOY_COPY_STAGING}/partial"
            record_id=999
            exit 73
        fi
        case "${mode}" in build_error|existing_error|umount_failure) exit 73 ;; esac
    ) > "${case_root}/output" 2>&1
}

for scenario in normal parent_usb blkid_fallback existing_rw existing_without_images mapper nvme_mapper udev_mapper; do
    new_case "${scenario}"
    if ! run_case; then cat "${case_root}/output" >&2; exit 1; fi
    grep -q '^selected=' "${events}"
    if [[ "${scenario}" == existing_* ]]; then
        ! grep -Eq '^(mount|umount) ' "${events}"
        [[ -d "${record_target}/pmjs-images" ]]
    else
        grep -q '^mount ' "${events}"
        grep -q '^umount ' "${events}"
        [[ -d "${VENTOY_MOUNTPOINT}/pmjs-images" ]]
    fi
    case "${scenario}" in
        mapper|udev_mapper) grep -q ' -- /dev/mapper/sdz1 ' "${events}" ;;
        nvme_mapper) grep -q ' -- /dev/mapper/nvme0n1p1 ' "${events}" ;;
        blkid_fallback) grep -qx blkid "${events}" ;;
    esac
done

for scenario in absent ambiguous not_usb wrong_label unsupported_fs enumeration_failure existing_ro \
    occupied nonempty mount_failure no_confirmation wrong_source wrong_type forced_ro \
    missing_mapper wrong_mapper udev_failure mount_signal; do
    new_case "${scenario}"
    status=0
    run_case || status=$?
    (( status != 0 ))
    ! grep -q '^selected=' "${events}"
    [[ ! -e "${VENTOY_MOUNTPOINT}/pmjs-images" && ! -e "${record_target}/pmjs-images" ]]
    case "${scenario}" in
        forced_ro|mount_signal) grep -q '^umount ' "${events}" ;;
        *) ! grep -q '^umount ' "${events}" ;;
    esac
    case "${scenario}" in
        no_confirmation|wrong_source|wrong_type) grep -Fq 'Ventoy não desmontado' "${case_root}/output" ;;
        mount_signal) [[ ${status} -eq 143 ]] ;;
        nonempty) [[ "$(<"${VENTOY_MOUNTPOINT}/local-file")" == keep ]] ;;
    esac
done

for scenario in build_error existing_error umount_failure changed_mount; do
    new_case "${scenario}"
    status=0
    run_case || status=$?
    [[ ${status} -eq 73 ]]
    case "${scenario}" in
        build_error|umount_failure) grep -q '^umount ' "${events}" ;;
        existing_error) ! grep -Eq '^(mount|umount) ' "${events}" ;;
        changed_mount)
            ! grep -q '^umount ' "${events}"
            [[ -n "$(find "${VENTOY_MOUNTPOINT}/pmjs-images" -name partial -print -quit)" ]]
            grep -Fq 'Staging não removido' "${case_root}/output" ;;
    esac
done

for unsafe in '' / /mnt /var /tmp /var/tmp /var/lib /etc/ventoy /home/usuario/ventoy /mnt/../tmp relative; do
    if (VENTOY_MOUNTPOINT=${unsafe}; validate_ventoy_automount_config) >/dev/null 2>&1; then exit 1; fi
done
mkdir -- "${test_root}/real-target"
ln -s real-target "${test_root}/symlink-target"
if (VENTOY_MOUNTPOINT="${test_root}/symlink-target"; validate_ventoy_automount_config) >/dev/null 2>&1; then exit 1; fi
[[ "$(ventoy_decode_mount_path '/media/Ventoy\x20com\x20espa\xc3\xa7o')" == '/media/Ventoy com espaço' ]]
if ventoy_decode_mount_path '/media/unsafe\x0a' >/dev/null 2>&1; then exit 1; fi
printf 'OK: automount Ventoy, mapper, mounts rw/ro, validação e cleanup seguro (30 cenários + paths)\n'
