#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"

# shellcheck source=../lib/archive.sh
source "${PROJECT_DIR}/lib/archive.sh"
# shellcheck source=../lib/rootfs.sh
source "${PROJECT_DIR}/lib/rootfs.sh"

log_write() { :; }
ui_error() { printf 'ERRO: %s\n' "$*" >&2; }

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT

source_root="${test_root}/source"
build_dir="${test_root}/output"
archive_file="${build_dir}/rootfs.tar.gz"
generalization_staging=""
mkdir -p -- \
    "${source_root}/proc/self" \
    "${source_root}/sys/kernel" \
    "${source_root}/dev/pts" \
    "${source_root}/run/lock" \
    "${source_root}/etc/ssh" \
    "${source_root}/etc/ocsinventory" \
    "${source_root}/usr/sbin" \
    "${source_root}/var/lib/dbus" \
    "${source_root}/var/lib/ocsinventory-agent/server" \
    "${source_root}/var/cache/ocsinventory-agent" \
    "${source_root}/var/log/ocsinventory-client" \
    "${build_dir}"
touch -- \
    "${source_root}/proc/self/status" \
    "${source_root}/sys/kernel/uevent_seqnum" \
    "${source_root}/dev/pts/0" \
    "${source_root}/run/lock/service.lock" \
    "${source_root}/etc/passwd" \
    "${source_root}/etc/group" \
    "${source_root}/etc/hostname" \
    "${source_root}/etc/machine-id" \
    "${source_root}/etc/ssh/sshd_config" \
    "${source_root}/etc/ssh/ssh_host_rsa_key" \
    "${source_root}/etc/ssh/ssh_host_rsa_key.pub" \
    "${source_root}/etc/ocsinventory/ocsinventory-agent.cfg" \
    "${source_root}/etc/x11vnc.pass" \
    "${source_root}/usr/sbin/sshd" \
    "${source_root}/var/lib/ocsinventory-agent/server/ocsinv.conf" \
    "${source_root}/var/cache/ocsinventory-agent/cache" \
    "${source_root}/var/log/ocsinventory-client/agent.log"
printf '%s\n' 'machine-model-id' > "${source_root}/etc/machine-id"
printf '%s\n' '<DEVICEID>model-device</DEVICEID>' > \
    "${source_root}/var/lib/ocsinventory-agent/server/ocsinv.conf"
printf '%s\n' 'dbus-machine-model-id' > "${source_root}/var/lib/dbus/machine-id"

source "${PROJECT_DIR}/lib/generalize.sh"
validate_generalization_source "${source_root}"
prepare_generalization_staging "${build_dir}" generalization_staging

generate_rootfs "${source_root}" "${build_dir}" "${archive_file}" \
    "${generalization_staging}"
validate_rootfs "${archive_file}" "${source_root}" "${build_dir}"
cleanup_generalization_staging "${generalization_staging}" "${build_dir}"

mapfile -t archive_entries < <(tar --list --gzip --file "${archive_file}")
for entry in "${archive_entries[@]}"; do
    case "${entry}" in
        ./sys|./sys/*|./proc|./proc/*|./dev|./dev/*|./run|./run/*|\
        ./etc/machine-id|./var/lib/dbus/machine-id|./etc/ssh/ssh_host_*|\
        ./var/lib/ocsinventory-agent|./var/lib/ocsinventory-agent/*|\
        ./var/cache/ocsinventory-agent|./var/cache/ocsinventory-agent/*|\
        ./var/log/ocsinventory-client|./var/log/ocsinventory-client/*)
            printf 'Entrada proibida encontrada: %s\n' "${entry}" >&2
            exit 1
            ;;
    esac
done

rm -- "${source_root}/var/lib/dbus/machine-id"
validate_generalization_source "${source_root}"
generalization_staging=""
prepare_generalization_staging "${build_dir}" generalization_staging
absent_archive_file="${build_dir}/rootfs-dbus-absent.tar.gz"
generate_rootfs "${source_root}" "${build_dir}" "${absent_archive_file}" \
    "${generalization_staging}"
validate_rootfs "${absent_archive_file}" "${source_root}" "${build_dir}"
if tar --list --gzip --file "${absent_archive_file}" | \
   grep -Eq '^\./(etc/machine-id|var/lib/dbus/machine-id)/?$'; then
    printf 'Identidade persistente encontrada com machine-id D-Bus ausente\n' >&2
    exit 1
fi
cleanup_generalization_staging "${generalization_staging}" "${build_dir}"

if tar --extract --to-stdout --gzip --file "${archive_file}" 2>/dev/null | \
   grep -Fq -- 'model-device'; then
    printf 'DEVICEID antigo encontrado no rootfs\n' >&2
    exit 1
fi

for preserved_entry in \
    ./etc/hostname \
    ./etc/ssh/sshd_config \
    ./etc/ocsinventory/ocsinventory-agent.cfg \
    ./etc/x11vnc.pass \
    ./usr/sbin/sshd; do
    printf '%s\n' "${archive_entries[@]}" | grep -Fqx -- "${preserved_entry}"
done

printf 'OK: rootfs generalizado e pseudo-filesystems ausentes\n'
