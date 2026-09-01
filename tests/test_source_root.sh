#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${PROJECT_DIR}/lib/checks.sh"

ui_error() { printf 'ERRO: %s\n' "$*" >&2; }

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT

direct_root="${test_root}/direct"
mkdir -p -- "${direct_root}/etc" "${direct_root}/usr" "${direct_root}/var"
resolved=""
resolve_source_root "${direct_root}" resolved
[[ "${resolved}" == "$(realpath -e -- "${direct_root}")" ]]
check_source_root "${resolved}"

btrfs_mount="${test_root}/btrfs"
mkdir -p -- \
    "${btrfs_mount}/@rootfs/etc" \
    "${btrfs_mount}/@rootfs/usr" \
    "${btrfs_mount}/@rootfs/var" \
    "${btrfs_mount}/home"
resolved=""
resolve_source_root "${btrfs_mount}" resolved
[[ "${resolved}" == "$(realpath -e -- "${btrfs_mount}/@rootfs")" ]]
check_source_root "${resolved}"

resolved=""
resolve_source_root "${btrfs_mount}/@rootfs" resolved
[[ "${resolved}" == "$(realpath -e -- "${btrfs_mount}/@rootfs")" ]]

invalid_root="${test_root}/invalid"
mkdir -p -- "${invalid_root}/@rootfs/etc" "${invalid_root}/@rootfs/usr"
if resolve_source_root "${invalid_root}" resolved; then
    printf 'Layout Linux incompleto foi aceito\n' >&2
    exit 1
fi

printf 'OK: raiz direta e subvolume @rootfs foram resolvidos corretamente\n'
