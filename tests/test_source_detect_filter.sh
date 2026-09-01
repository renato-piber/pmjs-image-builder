#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${PROJECT_DIR}/lib/source_detect.sh"

lsblk() {
    local args=" $* " device=${*: -1}
    if [[ "${args}" == *' --output NAME,TYPE '* ]]; then
        printf '%s\n' \
            '/dev/sda3 part' \
            '/dev/nvme0n1p3 part' \
            '/dev/sdb1 part' \
            '/dev/sdc3 part' \
            '/dev/sdz9 part'
    elif [[ "${device}" == /dev/sdz9 ]]; then
        return 32
    elif [[ "${args}" == *' --output RM '* ]]; then
        [[ "${device}" == /dev/sdb1 ]] && printf '1\n' || printf '0\n'
    elif [[ "${args}" == *' --output TRAN '* ]]; then
        [[ "${device}" == /dev/sdb1 ]] && printf 'usb\n' || printf 'sata\n'
    elif [[ "${args}" == *' --output MOUNTPOINT '* ]]; then
        [[ "${device}" == /dev/sdc3 ]] && printf '/mnt/existente\n' || true
    fi
}

log_write() { :; }

blkid() {
    case "${*: -1}" in
        /dev/sda3) printf 'btrfs\n' ;;
        /dev/nvme0n1p3) printf 'ext4\n' ;;
        /dev/sdb1) printf 'btrfs\n' ;;
        /dev/sdc3) printf 'xfs\n' ;;
    esac
}

mapfile -t candidates < <(source_detect_list_candidates)
[[ ${#candidates[@]} -eq 2 ]]
[[ "${candidates[0]}" == '/dev/sda3|btrfs' ]]
[[ "${candidates[1]}" == '/dev/nvme0n1p3|ext4' ]]

printf 'OK: mídia USB/removível e filesystem já montado foram ignorados\n'
