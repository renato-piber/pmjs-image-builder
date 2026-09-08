#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly BUILDER_PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"

# shellcheck source=../build-image.sh
source "${BUILDER_PROJECT_DIR}/build-image.sh"

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT

ui_error() { printf 'ERRO ESP %s\n' "$*" >> "${test_root}/errors.log"; }
log_write() { :; }

nfs_dir="${test_root}/nfs-images"
local_temp="${test_root}/local-temp"
source_root="${test_root}/source"
home_user="$(id -un)"
home_uid="$(id -u)"
home_gid="$(id -g)"
home_source="${test_root}/${home_user}"
mkdir -p -- "${nfs_dir}" "${local_temp}" \
    "${source_root}/etc/ssh" "${source_root}/etc/ocsinventory" \
    "${source_root}/usr/sbin" "${source_root}/var/lib/dbus" \
    "${source_root}/var/cache" "${source_root}/var/log" \
    "${home_source}/.config/dconf" "${home_source}/Desktop"
touch -- "${source_root}/etc/passwd" "${source_root}/etc/group" \
    "${source_root}/etc/ssh/sshd_config" \
    "${source_root}/etc/ocsinventory/ocsinventory-agent.cfg" \
    "${source_root}/etc/x11vnc.pass" "${source_root}/usr/sbin/sshd"
printf '%s\n' 'pmjs-live-nfs-test' > "${source_root}/etc/hostname"
printf '%s\n' 'PRETTY_NAME="PMJS Test"' > "${source_root}/etc/os-release"
printf '%s\n' 'machine-model-id' > "${source_root}/etc/machine-id"
ln -s -- /etc/machine-id "${source_root}/var/lib/dbus/machine-id"
ln -s -- hostname "${source_root}/etc/hostname.link"
chmod 0640 -- "${source_root}/etc/hostname"
extended_acl=0
if setfacl -m u:65534:r-- -- "${source_root}/etc/hostname" 2>/dev/null; then
    extended_acl=1
else
    setfacl -m u::rw-,g::r--,o::--- -- "${source_root}/etc/hostname"
fi
setfattr -n user.pmjs -v nfs-stream -- "${source_root}/etc/hostname"
printf '%s\n' 'perfil' > "${home_source}/.config/dconf/user"
home_estimate_mib=0
estimate_homefs_staging_size_mib "${home_source}" home_estimate_mib
(( home_estimate_mib >= 1 ))

findmnt() {
    case "$*" in
        *FSTYPE*) printf '%s\n' nfs4 ;;
        *TARGET*) printf '%s\n' /mnt/pmjs-images ;;
    esac
}

check_nfs_staging_filesystem "${nfs_dir}"
BUILD_NFS_DIR=""
parse_build_arguments --nfs-dir "${nfs_dir}"
[[ "${BUILD_NFS_DIR}" == "${nfs_dir}" ]]

workspace=""
final_dir=""
prepare_build_workspace "${nfs_dir}" pmjs-linux-0.1.0 workspace final_dir
rootfs_file="${workspace}/rootfs.tar.zst"
homefs_file="${workspace}/homefs.tar.zst"
build_rootfs_artifact "${source_root}" "${nfs_dir}" "${rootfs_file}" zstd 3 \
    "${local_temp}"
IMAGE_COMPRESSION=zstd
build_homefs_artifact "${home_source}" "${home_user}" "${home_uid}" "${home_gid}" \
    16 "${workspace}" "${homefs_file}" zstd 3 "${local_temp}"
build_metadata_artifacts "${workspace}" "${rootfs_file}" "${homefs_file}" \
    "${workspace}/SHA256SUMS" "${workspace}/manifest.json" \
    pmjs-linux 0.1.0 0.1.0 zstd "${source_root}"
validate_image_directory "${workspace}"

[[ -s "${workspace}/rootfs.tar.zst" && -s "${workspace}/homefs.tar.zst" ]]
[[ ! -e "${final_dir}" ]]
[[ -z "$(find "${local_temp}" -maxdepth 1 -type f -name '*.tar.zst*' -print -quit)" ]]

finalize_build_workspace "${workspace}" "${final_dir}"
workspace=""
[[ -d "${final_dir}" ]]
validate_image_directory "${final_dir}"

extract_dir="${test_root}/extracted"
mkdir -- "${extract_dir}"
tar --extract --zstd --numeric-owner --acls --xattrs \
    --file "${final_dir}/rootfs.tar.zst" --directory "${extract_dir}"
[[ "$(stat -c '%u:%g:%a' -- "${extract_dir}/etc/hostname")" == \
    "$(stat -c '%u:%g:%a' -- "${source_root}/etc/hostname")" ]]
[[ -L "${extract_dir}/etc/hostname.link" ]]
[[ "$(readlink -- "${extract_dir}/etc/hostname.link")" == hostname ]]
if (( extended_acl == 1 )); then
    getfacl --absolute-names --numeric --omit-header -- "${extract_dir}/etc/hostname" |
        grep -Fqx -- 'user:65534:r--'
else
    [[ "$(getfacl --absolute-names --numeric --omit-header -- "${extract_dir}/etc/hostname")" == \
        "$(getfacl --absolute-names --numeric --omit-header -- "${source_root}/etc/hostname")" ]]
fi
[[ "$(getfattr --only-values -n user.pmjs -- "${extract_dir}/etc/hostname" 2>/dev/null)" == nfs-stream ]]

# Falha durante rootfs: somente workspace oculto, nunca diretório final.
failure_workspace=""
failure_final=""
prepare_build_workspace "${nfs_dir}" pmjs-linux-root-failure \
    failure_workspace failure_final
if (
    generate_rootfs() { return 71; }
    build_rootfs_artifact "${source_root}" "${nfs_dir}" \
        "${failure_workspace}/rootfs.tar.zst" zstd 3 "${local_temp}"
); then
    printf 'Falha injetada no rootfs foi aceita\n' >&2
    exit 1
fi
[[ ! -e "${failure_final}" ]]
cleanup_build_workspace "${failure_workspace}" "${nfs_dir}"

# Falha durante homefs: rootfs pode existir no staging, mas o final não aparece.
failure_workspace=""
failure_final=""
prepare_build_workspace "${nfs_dir}" pmjs-linux-home-failure \
    failure_workspace failure_final
if (
    generate_homefs() { return 72; }
    build_homefs_artifact "${home_source}" "${home_user}" "${home_uid}" \
        "${home_gid}" 16 "${failure_workspace}" \
        "${failure_workspace}/homefs.tar.zst" zstd 3 "${local_temp}"
); then
    printf 'Falha injetada no homefs foi aceita\n' >&2
    exit 1
fi
[[ ! -e "${failure_final}" ]]
cleanup_build_workspace "${failure_workspace}" "${nfs_dir}"

# Falha SHA256 após os archives: metadados não concluem e não há commit.
failure_workspace=""
failure_final=""
prepare_build_workspace "${nfs_dir}" pmjs-linux-sha-failure \
    failure_workspace failure_final
cp -- "${final_dir}/rootfs.tar.zst" "${failure_workspace}/rootfs.tar.zst"
cp -- "${final_dir}/homefs.tar.zst" "${failure_workspace}/homefs.tar.zst"
if (
    sha256sum() {
        if [[ " $* " == *' --check '* ]]; then
            return 73
        fi
        command sha256sum "$@"
    }
    build_metadata_artifacts "${failure_workspace}" \
        "${failure_workspace}/rootfs.tar.zst" \
        "${failure_workspace}/homefs.tar.zst" \
        "${failure_workspace}/SHA256SUMS" "${failure_workspace}/manifest.json" \
        pmjs-linux sha-failure 0.1.0 zstd "${source_root}"
); then
    printf 'Falha injetada no SHA256 foi aceita\n' >&2
    exit 1
fi
[[ ! -e "${failure_final}" ]]
cleanup_build_workspace "${failure_workspace}" "${nfs_dir}"

# Versão existente é imutável.
existing_workspace=""
existing_final=""
if prepare_build_workspace "${nfs_dir}" pmjs-linux-0.1.0 \
    existing_workspace existing_final; then
    printf 'Destino final existente foi aceito\n' >&2
    exit 1
fi

# Espaço NFS insuficiente falha antes do workspace.
(
    df() { printf 'Avail\n1024\n'; }
    if check_free_space "${nfs_dir}" 8; then
        printf 'NFS sem espaço foi aceito\n' >&2
        exit 1
    fi
)

# Interrupção antes do commit: staging validado é removível e final não existe.
interrupt_workspace=""
interrupt_final=""
prepare_build_workspace "${nfs_dir}" pmjs-linux-interrupted \
    interrupt_workspace interrupt_final
cp -- "${final_dir}/rootfs.tar.zst" "${interrupt_workspace}/rootfs.tar.zst"
cp -- "${final_dir}/homefs.tar.zst" "${interrupt_workspace}/homefs.tar.zst"
build_metadata_artifacts "${interrupt_workspace}" \
    "${interrupt_workspace}/rootfs.tar.zst" \
    "${interrupt_workspace}/homefs.tar.zst" \
    "${interrupt_workspace}/SHA256SUMS" "${interrupt_workspace}/manifest.json" \
    pmjs-linux interrupted 0.1.0 zstd "${source_root}"
validate_image_directory "${interrupt_workspace}"
[[ ! -e "${interrupt_final}" ]]
cleanup_build_workspace "${interrupt_workspace}" "${nfs_dir}"
[[ ! -e "${interrupt_workspace}" && ! -e "${interrupt_final}" ]]

printf 'OK: build direto em NFS, falhas, metadados e commit atômico validados\n'
