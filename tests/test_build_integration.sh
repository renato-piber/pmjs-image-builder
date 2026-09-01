#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"

# Carrega exatamente os módulos e o fluxo usados pelo executável.
# shellcheck source=../build-image.sh
source "${TEST_PROJECT_DIR}/build-image.sh"

integration_root="$(mktemp -d)"
trap '[[ -n "${integration_root:-}" && "${integration_root}" == /tmp/* ]] && rm -rf -- "${integration_root}"' EXIT

source_root="${integration_root}/source"
build_dir="${integration_root}/build"
archive_file="${build_dir}/rootfs.tar.gz"
mkdir -p -- \
    "${source_root}/etc/ssh" \
    "${source_root}/etc/ocsinventory" \
    "${source_root}/usr/sbin" \
    "${source_root}/var/lib/dbus" \
    "${source_root}/var/lib/ocsinventory-agent/server" \
    "${source_root}/var/cache/ocsinventory-agent" \
    "${source_root}/var/log/ocsinventory-client" \
    "${build_dir}" \
    "${integration_root}/logs"
touch -- \
    "${source_root}/etc/passwd" \
    "${source_root}/etc/group" \
    "${source_root}/etc/hostname" \
    "${source_root}/etc/ssh/sshd_config" \
    "${source_root}/etc/ocsinventory/ocsinventory-agent.cfg" \
    "${source_root}/etc/x11vnc.pass" \
    "${source_root}/usr/sbin/sshd"
printf '%s\n' 'machine-model-id' > "${source_root}/etc/machine-id"
printf '%s\n' 'model-host-private-key' > "${source_root}/etc/ssh/ssh_host_rsa_key"
printf '%s\n' '<DEVICEID>model-device</DEVICEID>' > \
    "${source_root}/var/lib/ocsinventory-agent/server/ocsinv.conf"
touch -- \
    "${source_root}/var/cache/ocsinventory-agent/cache" \
    "${source_root}/var/log/ocsinventory-client/client.log"
ln -s -- /etc/machine-id "${source_root}/var/lib/dbus/machine-id"

init_log "${integration_root}/logs"
build_rootfs_artifact "${source_root}" "${build_dir}" "${archive_file}"
mapfile -t archive_entries < <(tar --list --gzip --file "${archive_file}")
printf '%s\n' "${archive_entries[@]}"

for forbidden_entry in \
    ./etc/machine-id \
    ./var/lib/dbus/machine-id \
    ./etc/ssh/ssh_host_rsa_key \
    ./var/lib/ocsinventory-agent/server/ocsinv.conf \
    ./var/cache/ocsinventory-agent/cache \
    ./var/log/ocsinventory-client/client.log; do
    if printf '%s\n' "${archive_entries[@]}" | grep -Fqx -- "${forbidden_entry}"; then
        printf 'Entrada proibida presente: %s\n' "${forbidden_entry}" >&2
        exit 1
    fi
done

for required_entry in \
    ./etc/ocsinventory/ocsinventory-agent.cfg \
    ./etc/x11vnc.pass \
    ./etc/ssh/sshd_config \
    ./etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf; do
    printf '%s\n' "${archive_entries[@]}" | grep -Fqx -- "${required_entry}"
done

for expected_option in \
    "--exclude=./etc/machine-id" \
    "--exclude=./var/lib/dbus/machine-id" \
    "--exclude=./etc/ssh/ssh_host_\\*" \
    "--exclude=./var/lib/ocsinventory-agent" \
    "--exclude=./var/lib/ocsinventory-agent/\\*" \
    "--exclude=./var/cache/ocsinventory-agent" \
    "--exclude=./var/cache/ocsinventory-agent/\\*" \
    "--exclude=./var/log/ocsinventory-client" \
    "--exclude=./var/log/ocsinventory-client/\\*"; do
    grep -Fq -- "${expected_option}" "${LOG_FILE}"
done
grep -Fq -- 'Staging de generalização:' "${LOG_FILE}"

printf 'OK: fluxo integrado do build produziu rootfs generalizado\n'
