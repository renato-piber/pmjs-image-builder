#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"

# shellcheck source=../lib/rootfs.sh
source "${PROJECT_DIR}/lib/rootfs.sh"

log_write() { :; }
ui_error() { printf 'ERRO: %s\n' "$*" >&2; }

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT

source_root="${test_root}/source"
build_dir="${test_root}/output"
archive_file="${build_dir}/rootfs.tar.gz"
mkdir -p -- \
    "${source_root}/proc/self" \
    "${source_root}/sys/kernel" \
    "${source_root}/dev/pts" \
    "${source_root}/run/lock" \
    "${source_root}/etc" \
    "${build_dir}"
touch -- \
    "${source_root}/proc/self/status" \
    "${source_root}/sys/kernel/uevent_seqnum" \
    "${source_root}/dev/pts/0" \
    "${source_root}/run/lock/service.lock" \
    "${source_root}/etc/os-release"

generate_rootfs "${source_root}" "${build_dir}" "${archive_file}"
validate_rootfs "${archive_file}" "${source_root}" "${build_dir}"

mapfile -t archive_entries < <(tar --list --gzip --file "${archive_file}")
for entry in "${archive_entries[@]}"; do
    case "${entry}" in
        ./sys|./sys/*|./proc|./proc/*|./dev|./dev/*|./run|./run/*)
            printf 'Entrada de pseudo-filesystem encontrada: %s\n' "${entry}" >&2
            exit 1
            ;;
    esac
done

printf 'OK: pseudo-filesystems ausentes do rootfs\n'
