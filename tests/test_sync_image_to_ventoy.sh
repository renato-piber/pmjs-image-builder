#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_PROJECT_DIR}/sync-image-to-ventoy.sh"

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT
template_parent="${test_root}/template"
template_image="${template_parent}/pmjs-linux-0.2.0"
root_content="${test_root}/root-content"
home_content="${test_root}/home-content"
source_root="${test_root}/source"
mkdir -p -- "${template_image}" "${root_content}/etc" \
    "${home_content}/usuario" "${source_root}/etc"
printf '%s\n' root > "${root_content}/etc/issue"
printf '%s\n' home > "${home_content}/usuario/profile"
printf '%s\n' 'PRETTY_NAME="PMJS Sync Test"' > "${source_root}/etc/os-release"
tar --create --zstd --file "${template_image}/rootfs.tar.zst" \
    --directory="${root_content}" .
tar --create --zstd --file "${template_image}/homefs.tar.zst" \
    --directory="${home_content}" usuario
generate_checksums "${template_image}" "${template_image}/rootfs.tar.zst" \
    "${template_image}/homefs.tar.zst" "${template_image}/SHA256SUMS"
generate_manifest "${template_image}/manifest.json" pmjs-linux 0.2.0 0.2.0 zstd \
    "${template_image}/rootfs.tar.zst" "${template_image}/homefs.tar.zst" \
    "${source_root}"
validate_image_directory "${template_image}"

case_root=""
nfs_dir=""
ventoy_dir=""
events_file=""
nfs_mounted=0
mount_should_fail=0
ventoy_mount_id=200
ventoy_mount_target=""
mock_available_bytes=1073741824
copy_mode=normal

new_case() {
    local name=$1
    case_root="${test_root}/${name}"
    nfs_dir="${case_root}/nfs"
    ventoy_dir="${case_root}/ventoy/pmjs-images"
    events_file="${case_root}/events"
    mkdir -p -- "${nfs_dir}" "${ventoy_dir}" "${case_root}/logs"
    cp -a -- "${template_image}" "${nfs_dir}/pmjs-linux-0.2.0"
    : > "${events_file}"
    nfs_mounted=0
    mount_should_fail=0
    ventoy_mount_id=200
    ventoy_mount_target="${case_root}/ventoy"
    mock_available_bytes=1073741824
    copy_mode=normal
}

reset_sync_state() {
    SYNC_IMAGE_NAME=""
    SYNC_VENTOY_DIR=""
    SYNC_SOURCE_DIR=""
    SYNC_STAGING=""
    SYNC_FINAL_DIR=""
    SYNC_SUCCEEDED=false
    NFS_MOUNTED_BY_BUILDER=0
    NFS_ACTIVE_MOUNTPOINT=""
    NFS_ACTIVE_SOURCE=""
    NFS_ACTIVE_ID=""
    NFS_MOUNT_IN_PROGRESS=0
    NFS_PENDING_SIGNAL=""
    VENTOY_DESTINATION=""
    VENTOY_MOUNT_ID=""
    VENTOY_MOUNT_SOURCE=""
    VENTOY_MOUNT_FSTYPE=""
    VENTOY_MOUNT_TARGET=""
}

check_sync_root() { :; }
check_sync_dependencies() { :; }
check_nfs_dependencies() { :; }
load_sync_config() {
    IMAGE_NAME=pmjs-linux
    NFS_SERVER=192.168.0.19
    NFS_EXPORT=/var/clone-pmjs
    NFS_MOUNTPOINT=${nfs_dir}
    LOG_DIR="${case_root}/logs"
    VENTOY_FREE_SPACE_MARGIN_MIB=1
}
mount() {
    printf '%s\n' mount >> "${events_file}"
    (( mount_should_fail == 0 )) || return 32
    nfs_mounted=1
}
mount.nfs() { :; }
umount() {
    printf '%s\n' umount >> "${events_file}"
    nfs_mounted=0
}
findmnt() {
    if [[ "$*" == *"--mountpoint ${nfs_dir}"* ]]; then
        (( nfs_mounted == 1 )) || return 1
        printf '100 192.168.0.19:/var/clone-pmjs nfs4 %s\n' "${nfs_dir}"
        return 0
    fi
    [[ "$*" == *"--target ${ventoy_dir}"* ]] || return 1
    case "$*" in
        *'--output ID'*) printf '%s\n' "${ventoy_mount_id}" ;;
        *'--output SOURCE'*) printf '%s\n' /dev/sdz1 ;;
        *'--output FSTYPE'*) printf '%s\n' exfat ;;
        *'--output TARGET'*) printf '%s\n' "${ventoy_mount_target}" ;;
        *) return 1 ;;
    esac
}
df() {
    printf 'Avail\n%s\n' "${mock_available_bytes}"
}
rsync() {
    local staging_dir=${!#}
    [[ ! -e "${ventoy_dir}/pmjs-linux-0.2.0" ]]
    case "${copy_mode}" in
        interrupt) kill -TERM "${BASHPID}"; return 143 ;;
        *) command rsync "$@" ;;
    esac
    staging_dir=${staging_dir%/}
    case "${copy_mode}" in
        corrupt) printf 'corrupção\n' >> "${staging_dir}/rootfs.tar.zst" ;;
        changed_mount) ventoy_mount_id=999; return 76 ;;
    esac
}

run_sync() {
    local status=0
    (
        reset_sync_state
        main --image pmjs-linux-0.2.0 --ventoy-dir "${ventoy_dir}"
    ) > "${case_root}/output" 2>&1 || status=$?
    return "${status}"
}

assert_no_final_or_staging() {
    [[ ! -e "${ventoy_dir}/pmjs-linux-0.2.0" ]]
    [[ -z "$(find "${ventoy_dir}" -mindepth 1 -maxdepth 1 -name '.*.sync.*' -print -quit)" ]]
}

# Imagem válida, automount, validação posterior e publicação final.
new_case valid
run_sync
[[ -d "${ventoy_dir}/pmjs-linux-0.2.0" ]]
validate_image_directory "${ventoy_dir}/pmjs-linux-0.2.0"
grep -qx mount "${events_file}"
grep -qx umount "${events_file}"
grep -Fq '[OK] Imagem copiada para o Ventoy' "${case_root}/output"
grep -Fq 'SHA256: OK' "${case_root}/output"
[[ -z "$(find "${ventoy_dir}" -mindepth 1 -maxdepth 1 -name '.*.sync.*' -print -quit)" ]]

# NFS pré-existente é reutilizado e permanece montado.
new_case preexisting
nfs_mounted=1
run_sync
! grep -qx mount "${events_file}"
! grep -qx umount "${events_file}"
[[ -d "${ventoy_dir}/pmjs-linux-0.2.0" ]]

# Bundle incompleto no servidor.
new_case invalid_server
rm -- "${nfs_dir}/pmjs-linux-0.2.0/manifest.json"
if run_sync; then exit 1; fi
assert_no_final_or_staging
grep -qx umount "${events_file}"

# SHA256SUMS incorreto no servidor.
new_case bad_server_sha
sed -i '1s/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' \
    "${nfs_dir}/pmjs-linux-0.2.0/SHA256SUMS"
if run_sync; then exit 1; fi
assert_no_final_or_staging

# Espaço insuficiente falha antes de criar staging.
new_case no_space
mock_available_bytes=1
if run_sync; then exit 1; fi
assert_no_final_or_staging
grep -Fq 'Espaço insuficiente no Ventoy' "${case_root}/output"

# Versão final existente permanece intacta.
new_case immutable
mkdir -- "${ventoy_dir}/pmjs-linux-0.2.0"
printf '%s\n' preserve > "${ventoy_dir}/pmjs-linux-0.2.0/sentinel"
if run_sync; then exit 1; fi
[[ "$(<"${ventoy_dir}/pmjs-linux-0.2.0/sentinel")" == preserve ]]
[[ -z "$(find "${ventoy_dir}" -mindepth 1 -maxdepth 1 -name '.*.sync.*' -print -quit)" ]]

# Interrupção durante a cópia remove somente o staging da execução.
new_case interrupted
copy_mode=interrupt
if run_sync; then exit 1; fi
assert_no_final_or_staging
grep -qx umount "${events_file}"

# Corrupção durante a cópia é encontrada na releitura do Ventoy.
new_case corrupt_copy
copy_mode=corrupt
if run_sync; then exit 1; fi
assert_no_final_or_staging
grep -Fq 'falhou na validação completa' "${case_root}/output"

# Falha do mount encerra antes de acessar o servidor ou criar staging.
new_case mount_failure
mount_should_fail=1
if run_sync; then exit 1; fi
assert_no_final_or_staging
! grep -qx umount "${events_file}"

# Diretório local com o nome correto não é confundido com Ventoy montado.
new_case ventoy_unmounted
ventoy_mount_target=/
if run_sync; then exit 1; fi
assert_no_final_or_staging
grep -Fq 'Ventoy não parece estar montado' "${case_root}/output"

# Se o mount mudar, o cleanup recusa remover conteúdo no novo filesystem.
new_case safe_cleanup
copy_mode=changed_mount
if run_sync; then exit 1; fi
[[ ! -e "${ventoy_dir}/pmjs-linux-0.2.0" ]]
[[ -n "$(find "${ventoy_dir}" -mindepth 1 -maxdepth 1 -name '.*.sync.*' -print -quit)" ]]
grep -Fq 'Staging não removido' "${case_root}/output"

# Nome perigoso ou de staging nunca vira path sob o NFS.
for unsafe in ../pmjs-linux-0.2.0 /pmjs-linux-0.2.0 .pmjs-linux-0.2.0.sync.ABC pmjs-linux-0.2.0.build.X other-0.2.0; do
    if validate_sync_image_name "${unsafe}" pmjs-linux >/dev/null 2>&1; then
        printf 'Nome inseguro aceito: %s\n' "${unsafe}" >&2
        exit 1
    fi
done

printf 'OK: sincronização NFS -> Ventoy validada com mounts simulados\n'
