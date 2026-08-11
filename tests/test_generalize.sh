#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${PROJECT_DIR}/lib/generalize.sh"

ui_error() { :; }

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT
source_root="${test_root}/source"
build_dir="${test_root}/build"
mkdir -p -- "${source_root}/etc" "${source_root}/var/lib/dbus" "${build_dir}"
touch -- "${source_root}/etc/machine-id"
ln -s -- /etc/machine-id "${source_root}/var/lib/dbus/machine-id"

validate_generalization_source "${source_root}"
staging=""
prepare_generalization_staging "${build_dir}" staging
dropin="${staging}/etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf"
grep -Fqx -- 'ExecStartPre=' "${dropin}"
grep -Fqx -- 'ExecStartPre=/usr/bin/ssh-keygen -A' "${dropin}"
grep -Fqx -- 'ExecStartPre=/usr/sbin/sshd -t' "${dropin}"
cleanup_generalization_staging "${staging}" "${build_dir}"
[[ ! -e "${staging}" ]]

ln -sfn -- /etc/hostname "${source_root}/var/lib/dbus/machine-id"
if validate_generalization_source "${source_root}"; then
    printf 'Symlink D-Bus inválido foi aceito\n' >&2
    exit 1
fi

printf 'OK: staging e contrato de generalização validados\n'
