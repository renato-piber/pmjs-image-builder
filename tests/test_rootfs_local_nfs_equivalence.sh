#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"

# Exercita o mesmo fluxo usado pelo executável para os dois destinos.
# shellcheck source=../build-image.sh
source "${TEST_PROJECT_DIR}/build-image.sh"

ui_error() { printf 'ERRO: %s\n' "$*" >&2; }
log_write() { :; }

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT

source_root="${test_root}/source"
local_output="${test_root}/local-output"
nfs_output="${test_root}/nfs-output"
local_temp="${test_root}/local-temp"
source_dropin="${source_root}/etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf"

mkdir -p -- \
    "$(dirname -- "${source_dropin}")" \
    "${source_root}/etc/ssh" \
    "${source_root}/etc/ocsinventory" \
    "${source_root}/usr/sbin" \
    "${source_root}/var/lib/dbus" \
    "${source_root}/var/lib/ocsinventory-agent/server" \
    "${local_output}" "${nfs_output}" "${local_temp}"
touch -- \
    "${source_root}/etc/passwd" \
    "${source_root}/etc/group" \
    "${source_root}/etc/ssh/sshd_config" \
    "${source_root}/etc/ocsinventory/ocsinventory-agent.cfg" \
    "${source_root}/etc/x11vnc.pass" \
    "${source_root}/usr/sbin/sshd"
printf '%s\n' 'pmjs-test-host' > "${source_root}/etc/hostname"
printf '%s\n' 'PRETTY_NAME="PMJS Test"' > "${source_root}/etc/os-release"
printf '%s\n' 'machine-model-id' > "${source_root}/etc/machine-id"
ln -s -- /etc/machine-id "${source_root}/var/lib/dbus/machine-id"
printf '%s\n' 'model-private-key' > "${source_root}/etc/ssh/ssh_host_ed25519_key"
printf '%s\n' '<DEVICEID>model-device</DEVICEID>' > \
    "${source_root}/var/lib/ocsinventory-agent/server/ocsinv.conf"

# Simula uma versão antiga/conflitante existente na máquina-modelo. O overlay
# gerado pelo builder deve ser a única versão do drop-in dentro do archive.
printf '%s\n' \
    '[Service]' \
    'ExecStartPre=/bin/false' \
    > "${source_dropin}"

chmod 0640 -- "${source_root}/etc/hostname"
setfattr -n user.pmjs -v generalized -- "${source_root}/etc/hostname"
if setfacl -m u:65534:r-- -- "${source_root}/etc/hostname" 2>/dev/null; then
    :
else
    setfacl -m u::rw-,g::r--,o::--- -- "${source_root}/etc/hostname"
fi
ln -s -- hostname "${source_root}/etc/hostname.link"

local_archive="${local_output}/rootfs.tar.zst"
nfs_archive="${nfs_output}/rootfs.tar.zst"
build_rootfs_artifact "${source_root}" "${local_output}" "${local_archive}" \
    zstd 3 "${local_temp}"
build_rootfs_artifact "${source_root}" "${nfs_output}" "${nfs_archive}" \
    zstd 3 "${local_temp}"

assert_generalized_archive() {
    local archive=$1 listing dropin_content

    validate_rootfs "${archive}" "${source_root}" "$(dirname -- "${archive}")" zstd
    listing="$(tar --list --zstd --file "${archive}")"
    [[ "$(grep -Fxc -- './etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf' \
        <<< "${listing}")" -eq 1 ]]
    for forbidden in \
        ./etc/machine-id \
        ./var/lib/dbus/machine-id \
        ./etc/ssh/ssh_host_ed25519_key \
        ./var/lib/ocsinventory-agent/server/ocsinv.conf; do
        ! grep -Fqx -- "${forbidden}" <<< "${listing}"
    done

    dropin_content="$(tar --extract --to-stdout --zstd --file "${archive}" \
        ./etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf)"
    [[ "${dropin_content}" == "$(printf '%s\n' \
        '[Service]' \
        'ExecStartPre=' \
        'ExecStartPre=/usr/bin/ssh-keygen -A' \
        'ExecStartPre=/usr/sbin/sshd -t')" ]]
    [[ "${dropin_content}" != *'/bin/false'* ]]
}

assert_generalized_archive "${local_archive}"
assert_generalized_archive "${nfs_archive}"

# Datas de criação do pequeno overlay podem diferir; nomes, conteúdo e
# metadados Unix relevantes devem ser semanticamente iguais.
local_extract="${test_root}/local-extract"
nfs_extract="${test_root}/nfs-extract"
mkdir -- "${local_extract}" "${nfs_extract}"
tar --extract --zstd --numeric-owner --acls --xattrs \
    --file "${local_archive}" --directory "${local_extract}"
tar --extract --zstd --numeric-owner --acls --xattrs \
    --file "${nfs_archive}" --directory "${nfs_extract}"
diff --recursive --no-dereference -- "${local_extract}" "${nfs_extract}"

local_listing="${test_root}/local.list"
nfs_listing="${test_root}/nfs.list"
tar --list --zstd --file "${local_archive}" | LC_ALL=C sort > "${local_listing}"
tar --list --zstd --file "${nfs_archive}" | LC_ALL=C sort > "${nfs_listing}"
cmp --silent -- "${local_listing}" "${nfs_listing}"

[[ "$(stat -c '%u:%g:%a' -- "${local_extract}/etc/hostname")" == \
   "$(stat -c '%u:%g:%a' -- "${nfs_extract}/etc/hostname")" ]]
[[ "$(stat -c '%u:%g:%a' -- "${nfs_extract}/etc/hostname")" == \
   "$(stat -c '%u:%g:%a' -- "${source_root}/etc/hostname")" ]]
[[ "$(getfacl --absolute-names --numeric --omit-header -- "${local_extract}/etc/hostname")" == \
   "$(getfacl --absolute-names --numeric --omit-header -- "${nfs_extract}/etc/hostname")" ]]
[[ "$(getfacl --absolute-names --numeric --omit-header -- "${nfs_extract}/etc/hostname")" == \
   "$(getfacl --absolute-names --numeric --omit-header -- "${source_root}/etc/hostname")" ]]
[[ "$(getfattr --only-values -n user.pmjs -- "${local_extract}/etc/hostname" 2>/dev/null)" == \
   "$(getfattr --only-values -n user.pmjs -- "${nfs_extract}/etc/hostname" 2>/dev/null)" ]]
[[ "$(getfattr --only-values -n user.pmjs -- "${nfs_extract}/etc/hostname" 2>/dev/null)" == \
   "$(getfattr --only-values -n user.pmjs -- "${source_root}/etc/hostname" 2>/dev/null)" ]]
[[ -L "${local_extract}/etc/hostname.link" && -L "${nfs_extract}/etc/hostname.link" ]]
[[ "$(readlink -- "${local_extract}/etc/hostname.link")" == \
   "$(readlink -- "${nfs_extract}/etc/hostname.link")" ]]

printf 'OK: rootfs local e NFS são semanticamente equivalentes e generalizados\n'
