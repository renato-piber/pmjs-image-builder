#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_PROJECT_DIR}/build-image.sh"

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && find -P "${test_root}" -depth -delete' EXIT

ventoy_mount_id=200
ventoy_mount_target="${test_root}/Ventoy"
ventoy_dir="${ventoy_mount_target}/pmjs-images"
local_temp="${test_root}/local-staging"
source_root="${test_root}/source"
home_user="$(id -un)"
home_uid="$(id -u)"
home_gid="$(id -g)"
home_source="${test_root}/${home_user}"
mkdir -p -- "${ventoy_dir}" "${local_temp}" "${test_root}/logs" \
    "${source_root}/etc/ssh" "${source_root}/etc/ocsinventory" \
    "${source_root}/etc/systemd/system" "${source_root}/usr/sbin" \
    "${source_root}/var/lib/dbus" "${home_source}/.config/dconf" \
    "${home_source}/Desktop"
touch -- "${source_root}/etc/passwd" "${source_root}/etc/group" \
    "${source_root}/etc/ssh/sshd_config" \
    "${source_root}/etc/ocsinventory/ocsinventory-agent.cfg" \
    "${source_root}/etc/x11vnc.pass" "${source_root}/usr/sbin/sshd"
printf '%s\n' pmjs-ventoy-test > "${source_root}/etc/hostname"
printf '%s\n' 'PRETTY_NAME="PMJS Ventoy Test"' > "${source_root}/etc/os-release"
printf '%s\n' machine-model-id > "${source_root}/etc/machine-id"
printf '%s\n' private-model-key > "${source_root}/etc/ssh/ssh_host_rsa_key"
ln -s -- /etc/machine-id "${source_root}/var/lib/dbus/machine-id"
ln -s -- hostname "${source_root}/etc/hostname.link"
chmod 0640 -- "${source_root}/etc/hostname"
extended_acl=0
if setfacl -m u:65534:r-- -- "${source_root}/etc/hostname" 2>/dev/null; then
    extended_acl=1
else
    setfacl -m u::rw-,g::r--,o::--- -- "${source_root}/etc/hostname"
fi
setfattr -n user.pmjs -v ventoy-stream -- "${source_root}/etc/hostname"
printf '%s\n' profile > "${home_source}/.config/dconf/user"

findmnt() {
    [[ "$*" == *"--target ${ventoy_dir}"* ]] || return 1
    case "$*" in
        *'--output ID'*) printf '%s\n' "${ventoy_mount_id}" ;;
        *'--output SOURCE'*) printf '%s\n' /dev/sdz1 ;;
        *'--output FSTYPE'*) printf '%s\n' exfat ;;
        *'--output TARGET'*) printf '%s\n' "${ventoy_mount_target}" ;;
        *) return 1 ;;
    esac
}

log_write() { :; }
init_log "${test_root}/logs"

# O modo é explícito, mutuamente exclusivo com NFS e não consulta o servidor.
BUILD_NFS_DIR=""
BUILD_VENTOY_DIR=""
parse_build_arguments --ventoy-dir "${ventoy_dir}"
[[ "${BUILD_VENTOY_DIR}" == "${ventoy_dir}" ]]
BUILD_NFS_DIR=""
BUILD_VENTOY_DIR=""
if parse_build_arguments --nfs-dir /mnt/nfs --ventoy-dir "${ventoy_dir}" >/dev/null 2>&1; then
    printf '%s\n' 'Destinos NFS e Ventoy foram aceitos juntos' >&2
    exit 1
fi
BUILD_NFS_DIR=""
BUILD_VENTOY_DIR="${ventoy_dir}"
nfs_selected=0
select_build_nfs_destination() { nfs_selected=1; return 99; }
select_build_destination
[[ ${nfs_selected} -eq 0 && "${BUILD_VENTOY_DIR}" == "${ventoy_dir}" ]]

# Um diretório local no filesystem raiz nunca é confundido com mídia montada.
saved_target=${ventoy_mount_target}
ventoy_mount_target=/
if validate_ventoy_destination "${ventoy_dir}" >/dev/null 2>&1; then
    printf '%s\n' 'Filesystem raiz aceito como Ventoy' >&2
    exit 1
fi
ventoy_mount_target=${saved_target}
validate_ventoy_destination "${ventoy_dir}"
check_local_staging_filesystem "${local_temp}"

if validate_ventoy_destination relative/pmjs-images >/dev/null 2>&1; then
    printf '%s\n' 'Path relativo aceito como Ventoy' >&2
    exit 1
fi
mkdir -- "${ventoy_mount_target}/wrong-name"
if validate_ventoy_destination "${ventoy_mount_target}/wrong-name" >/dev/null 2>&1; then
    printf '%s\n' 'Destino Ventoy sem nome pmjs-images foi aceito' >&2
    exit 1
fi

BUILD_DESTINATION_KIND=ventoy
IMAGE_COMPRESSION=zstd
OUTPUT_DIR=${ventoy_dir}
workspace=""
final_dir=""
prepare_build_workspace "${ventoy_dir}" pmjs-linux-0.2.0 workspace final_dir
rootfs_file="${workspace}/rootfs.tar.zst"
homefs_file="${workspace}/homefs.tar.zst"

# Os archives são gravados no Ventoy simulado; os dois stagings que precisam de
# semântica Unix ficam no diretório Linux local informado.
build_rootfs_artifact "${source_root}" "${ventoy_dir}" "${rootfs_file}" zstd 3 \
    "${local_temp}"
[[ -s "${rootfs_file}" ]]
[[ -z "$(find "${ventoy_dir}" -maxdepth 2 -name '.rootfs-generalize.*' -print -quit)" ]]
build_homefs_artifact "${home_source}" "${home_user}" "${home_uid}" "${home_gid}" \
    16 "${workspace}" "${homefs_file}" zstd 3 "${local_temp}"
[[ -s "${homefs_file}" ]]
[[ -z "$(find "${ventoy_dir}" -maxdepth 2 -name 'pmjs-homefs-staging.*' -print -quit)" ]]
build_metadata_artifacts "${workspace}" "${rootfs_file}" "${homefs_file}" \
    "${workspace}/SHA256SUMS" "${workspace}/manifest.json" \
    pmjs-linux 0.2.0 0.2.0 zstd "${source_root}"
validate_image_directory "${workspace}"
[[ ! -e "${final_dir}" ]]
check_active_build_destination "antes do teste de commit"
finalize_build_workspace "${workspace}" "${final_dir}"
workspace=""
check_active_build_destination "após o teste de commit"
validate_image_directory "${final_dir}"

# A generalização continua idêntica: identidade e host keys não entram, mas o
# mecanismo ssh-keygen -A entra no rootfs. Symlink e xattr continuam no tar.
listing="$(tar --list --zstd --file "${final_dir}/rootfs.tar.zst")"
grep -Fqx -- './etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf' <<< "${listing}"
! grep -Fqx -- './etc/machine-id' <<< "${listing}"
! grep -Fqx -- './etc/ssh/ssh_host_rsa_key' <<< "${listing}"
extract_dir="${test_root}/extracted"
mkdir -- "${extract_dir}"
tar --extract --zstd --numeric-owner --acls --xattrs \
    --file "${final_dir}/rootfs.tar.zst" --directory "${extract_dir}"
[[ -L "${extract_dir}/etc/hostname.link" ]]
[[ "$(readlink -- "${extract_dir}/etc/hostname.link")" == hostname ]]
[[ "$(getfattr --only-values -n user.pmjs -- "${extract_dir}/etc/hostname" 2>/dev/null)" == ventoy-stream ]]
if (( extended_acl == 1 )); then
    getfacl --absolute-names --numeric --omit-header -- "${extract_dir}/etc/hostname" |
        grep -Fqx -- 'user:65534:r--'
else
    [[ "$(getfacl --absolute-names --numeric --omit-header -- "${extract_dir}/etc/hostname")" == \
       "$(getfacl --absolute-names --numeric --omit-header -- "${source_root}/etc/hostname")" ]]
fi
[[ "$(stat -c '%u:%g:%a' -- "${extract_dir}/etc/hostname")" == \
   "$(stat -c '%u:%g:%a' -- "${source_root}/etc/hostname")" ]]
grep -Fqx -- 'ExecStartPre=/usr/bin/ssh-keygen -A' \
    "${extract_dir}/etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf"

# Versões continuam imutáveis.
if prepare_build_workspace "${ventoy_dir}" pmjs-linux-0.2.0 workspace ignored_final >/dev/null 2>&1; then
    printf '%s\n' 'Versão existente no Ventoy foi aceita' >&2
    exit 1
fi

# Corrupção antes da validação nunca cria o nome final.
invalid_workspace=""
invalid_final=""
prepare_build_workspace "${ventoy_dir}" pmjs-linux-invalid invalid_workspace invalid_final
cp -- "${final_dir}/rootfs.tar.zst" "${invalid_workspace}/rootfs.tar.zst"
cp -- "${final_dir}/homefs.tar.zst" "${invalid_workspace}/homefs.tar.zst"
build_metadata_artifacts "${invalid_workspace}" \
    "${invalid_workspace}/rootfs.tar.zst" "${invalid_workspace}/homefs.tar.zst" \
    "${invalid_workspace}/SHA256SUMS" "${invalid_workspace}/manifest.json" \
    pmjs-linux invalid 0.2.0 zstd "${source_root}"
printf '%s\n' corrupt >> "${invalid_workspace}/rootfs.tar.zst"
if validate_image_directory "${invalid_workspace}" >/dev/null 2>&1; then
    printf '%s\n' 'Bundle corrompido no Ventoy foi aceito' >&2
    exit 1
fi
[[ ! -e "${invalid_final}" ]]
cleanup_build_workspace "${invalid_workspace}" "${ventoy_dir}"

# Erro/interrupção com o mesmo mount remove apenas o workspace oculto.
cleanup_workspace=""
cleanup_final=""
prepare_build_workspace "${ventoy_dir}" pmjs-linux-cleanup cleanup_workspace cleanup_final
printf '%s\n' partial > "${cleanup_workspace}/rootfs.tar.zst.partial"
status=0
(
    BUILD_WORKSPACE=${cleanup_workspace}
    BUILD_DESTINATION_KIND=ventoy
    OUTPUT_DIR=${ventoy_dir}
    BUILD_SUCCEEDED=false
    NFS_MOUNTED_BY_BUILDER=0
    trap cleanup EXIT
    exit 71
) >/dev/null 2>&1 || status=$?
[[ ${status} -eq 71 && ! -e "${cleanup_workspace}" && ! -e "${cleanup_final}" ]]

# Se a mídia mudar, o cleanup não toca no path agora pertencente a outro mount.
changed_workspace=""
changed_final=""
prepare_build_workspace "${ventoy_dir}" pmjs-linux-mount-change \
    changed_workspace changed_final
printf '%s\n' preserve > "${changed_workspace}/sentinel"
status=0
(
    BUILD_WORKSPACE=${changed_workspace}
    BUILD_DESTINATION_KIND=ventoy
    OUTPUT_DIR=${ventoy_dir}
    BUILD_SUCCEEDED=false
    NFS_MOUNTED_BY_BUILDER=0
    ventoy_mount_id=999
    trap cleanup EXIT
    exit 72
) >/dev/null 2>&1 || status=$?
[[ ${status} -eq 72 && -f "${changed_workspace}/sentinel" && ! -e "${changed_final}" ]]
cleanup_build_workspace "${changed_workspace}" "${ventoy_dir}"

printf 'OK: build direto no Ventoy, generalização, mount e commit atômico validados\n'
