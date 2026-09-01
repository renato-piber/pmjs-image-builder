#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${PROJECT_DIR}/lib/checks.sh"
source "${PROJECT_DIR}/lib/source_detect.sh"

test_root="$(mktemp -d)"
trap '[[ -n "${SOURCE_DETECT_DIR:-}" ]] && cleanup_detected_capture_source; [[ -n "${test_root:-}" && "${test_root}" == /tmp/* && ! -L "${test_root}" && -d "${test_root}" ]] && find -P "${test_root}" -depth -delete' EXIT
messages="${test_root}/messages.log"
scenario=same_sata

ui_error() { printf 'ERROR %s\n' "$*" >> "${messages}"; }
log_write() { printf '%s %s\n' "$1" "$2" >> "${messages}"; }

source_detect_list_candidates() {
    case "${scenario}" in
        same_sata) printf '%s\n' '/dev/sda3|btrfs' ;;
        separate_sata|separate_direct|no_home) printf '%s\n' '/dev/sda3|btrfs' '/dev/sda4|btrfs' ;;
        separate_nvme) printf '%s\n' '/dev/nvme0n1p3|btrfs' '/dev/nvme0n1p4|btrfs' ;;
        traditional_separate) printf '%s\n' '/dev/sda3|ext4' '/dev/sda4|btrfs' ;;
    esac
}

source_detect_mount() {
    local device=$1 filesystem=$2 target=$3
    case "${scenario}:${device}" in
        same_sata:/dev/sda3)
            create_mock_root "${target}" btrfs
            mkdir -p -- "${target}/home/usuario"
            ;;
        separate_sata:/dev/sda3|separate_direct:/dev/sda3|no_home:/dev/sda3|separate_nvme:/dev/nvme0n1p3)
            create_mock_root "${target}" btrfs
            ;;
        separate_sata:/dev/sda4|separate_nvme:/dev/nvme0n1p4|traditional_separate:/dev/sda4)
            mkdir -p -- "${target}/home/usuario"
            ;;
        traditional_separate:/dev/sda3)
            create_mock_root "${target}" traditional
            ;;
        separate_direct:/dev/sda4) mkdir -p -- "${target}/usuario" ;;
        no_home:/dev/sda4) mkdir -p -- "${target}/home/outro" ;;
    esac
}

create_mock_root() {
    local target=$1 layout=$2 root=${target}
    [[ "${layout}" == btrfs ]] && root="${target}/@rootfs"
    mkdir -p -- "${root}/etc/ocsinventory" "${root}/usr" "${root}/var"
    touch -- "${root}/etc/os-release" \
        "${root}/etc/ocsinventory/ocsinventory-agent.cfg"
}

source_detect_mount_home() {
    local device=$1 subvolume=$2 target=$3
    [[ "${subvolume}" == home ]]
    mkdir -p -- "${target}/usuario"
}

source_detect_unmount() {
    printf 'UNMOUNT %s\n' "$1" >> "${messages}"
    find -P "$1" -mindepth 1 -depth -delete
}

run_success_case() {
    local expected_root_suffix=$1 expected_home_suffix=$2 expected_root_device=$3 expected_home_device=$4
    local source_root=auto home_source=auto capture_dir
    detect_capture_sources usuario source_root home_source
    capture_dir=${SOURCE_DETECT_DIR}
    [[ "${source_root}" == "${capture_dir}/${expected_root_suffix}" ]]
    [[ "${home_source}" == "${capture_dir}/${expected_home_suffix}" ]]
    validate_detected_capture_source "${source_root}"
    grep -Fq -- "Root encontrado: ${expected_root_device}" "${messages}"
    grep -Fq -- "Home encontrado: ${expected_home_device}" "${messages}"
    cleanup_detected_capture_source
    [[ ! -e "${capture_dir}" ]]
}

run_success_case 'root/@rootfs' 'root/home/usuario' /dev/sda3 /dev/sda3

scenario=separate_sata
run_success_case 'root/@rootfs' 'home/usuario' /dev/sda3 /dev/sda4

scenario=separate_nvme
run_success_case 'root/@rootfs' 'home/usuario' /dev/nvme0n1p3 /dev/nvme0n1p4

scenario=separate_direct
run_success_case 'root/@rootfs' 'home/usuario' /dev/sda3 /dev/sda4

scenario=traditional_separate
run_success_case 'root' 'home/usuario' /dev/sda3 /dev/sda4

scenario=no_home
source_root=auto
home_source=auto
if detect_capture_sources usuario source_root home_source; then
    printf 'Ausência da home foi aceita\n' >&2
    exit 1
fi
grep -Fq -- 'Partições BTRFS examinadas: /dev/sda3 /dev/sda4' "${messages}"
cleanup_detected_capture_source

printf 'OK: home conjunta/separada, SATA, NVMe, root tradicional e ausência validados\n'
