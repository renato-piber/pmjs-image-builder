#!/usr/bin/env bash
set -Eeuo pipefail

TEST_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${TEST_PROJECT_DIR}/build-image.sh"
test_root="$(mktemp -d)"
trap 'find "${test_root}" -depth -delete' EXIT
log_write() { :; }

reset_case() {
    NFS_ENABLED=1
    NFS_SERVER=192.168.0.19
    NFS_EXPORT=/var/clone-pmjs
    NFS_MOUNTPOINT="${test_root}/mountpoint"
    NFS_IMAGES_DIR=""
    BUILD_NFS_DIR=""
    NFS_MOUNTED_BY_BUILDER=0
    NFS_ACTIVE_MOUNTPOINT=""
    NFS_ACTIVE_SOURCE=""
    NFS_ACTIVE_ID=""
    NFS_MOUNT_IN_PROGRESS=0
    NFS_PENDING_SIGNAL=""
    BUILD_WORKSPACE=""
    mount_mode=success
    umount_mode=success
    : > "${test_root}/state"
    : > "${test_root}/events"
}

# Nenhum comando de mount real pode ser alcançado, mesmo se o teste falhar.
mount.nfs() { :; }
mount() {
    [[ "$*" == "-t nfs -- ${NFS_SERVER}:${NFS_EXPORT} ${NFS_MOUNTPOINT}" ]]
    printf 'mount\n' >> "${test_root}/events"
    case "${mount_mode}" in
        fail) return 32 ;;
        unconfirmed) return 0 ;;
        wrong) printf '42 wrong:/export nfs4 %s\n' "${NFS_MOUNTPOINT}" > "${test_root}/state" ;;
        *) printf '42 %s:%s nfs4 %s\n' "${NFS_SERVER}" "${NFS_EXPORT}" "${NFS_MOUNTPOINT}" > "${test_root}/state" ;;
    esac
    if [[ "${mount_mode}" == signal ]]; then
        kill -TERM "${BASHPID}"
    fi
}
umount() {
    [[ "$*" == "-- ${NFS_MOUNTPOINT}" ]]
    printf 'umount\n' >> "${test_root}/events"
    [[ "${umount_mode}" == success ]] || return 16
    : > "${test_root}/state"
}
findmnt() {
    [[ "$*" == "--noheadings --raw --mountpoint ${NFS_MOUNTPOINT} --output ID,SOURCE,FSTYPE,TARGET" ]] || return 2
    [[ -s "${test_root}/state" ]] || return 1
    command cat "${test_root}/state"
}
assert_no_event() { ! grep -qx "$1" "${test_root}/events"; }
expect_failure() {
    if "$@"; then
        printf 'Falha esperada não ocorreu: %s\n' "$*" >&2
        exit 1
    fi
}

reset_case
[[ ! -e "${NFS_MOUNTPOINT}" ]]
select_build_nfs_destination
[[ -d "${NFS_MOUNTPOINT}" && "${BUILD_NFS_DIR}" == "${NFS_MOUNTPOINT}" ]]
[[ "${NFS_MOUNTED_BY_BUILDER}" == 1 && "${NFS_ACTIVE_ID}" == 42 ]]
cleanup_nfs_mount
grep -qx umount "${test_root}/events"
[[ "${NFS_MOUNTED_BY_BUILDER}" == 0 ]]

reset_case
printf '20 192.168.0.19:/var/clone-pmjs nfs4 %s\n' "${NFS_MOUNTPOINT}" > "${test_root}/state"
select_build_nfs_destination
[[ "${NFS_MOUNTED_BY_BUILDER}" == 0 ]]
cleanup_nfs_mount
assert_no_event mount
assert_no_event umount

for occupied in '/dev/sda1 ext4' 'other:/export nfs' '192.168.0.19:/wrong nfs4'; do
    reset_case
    printf '21 %s %s\n' "${occupied}" "${NFS_MOUNTPOINT}" > "${test_root}/state"
    expect_failure select_build_nfs_destination
    [[ -z "${BUILD_NFS_DIR}" ]]
    cleanup_nfs_mount
    assert_no_event mount
    assert_no_event umount
done

for mount_mode_value in fail unconfirmed wrong; do
    reset_case
    mount_mode=${mount_mode_value}
    expect_failure select_build_nfs_destination
    [[ -z "${BUILD_NFS_DIR}" && -z "${BUILD_WORKSPACE}" ]]
    cleanup_nfs_mount
    assert_no_event umount
done

for dangerous in '' / /mnt /var /tmp /home /var/tmp /var/lib /usr/local /etc/nfs /proc/nfs /home/usuario/nfs /mnt/../tmp /mnt/nfs/ 'relative' '/mnt/a b'; do
    reset_case
    NFS_MOUNTPOINT=${dangerous}
    expect_failure select_build_nfs_destination
    assert_no_event mount
done
reset_case
ln -s -- "${NFS_MOUNTPOINT}" "${test_root}/alias"
NFS_MOUNTPOINT="${test_root}/alias"
expect_failure select_build_nfs_destination
assert_no_event mount

# --nfs-dir vence o automount, sem exigir export oficial ou mount.nfs.
reset_case
NFS_ENABLED=invalid
NFS_MOUNTPOINT=/
unset -f mount.nfs
parse_build_arguments --nfs-dir "${test_root}/explicit"
select_build_nfs_destination
[[ "${BUILD_NFS_DIR}" == "${test_root}/explicit" ]]
cleanup_nfs_mount
assert_no_event mount
assert_no_event umount
expect_failure parse_build_arguments --nfs-dir ''

reset_case
NFS_ENABLED=0
NFS_IMAGES_DIR="${test_root}/legacy"
select_build_nfs_destination
[[ "${BUILD_NFS_DIR}" == "${NFS_IMAGES_DIR}" ]]
assert_no_event mount
reset_case
unset NFS_ENABLED
select_build_nfs_destination
[[ -z "${BUILD_NFS_DIR}" ]]
assert_no_event mount
mount.nfs() { :; }

# A ausência de dependências deve falhar antes de mkdir/mount.
for missing in mount umount findmnt mount.nfs; do
    (
        reset_case
        command() {
            if [[ "$1" == -v && "$2" == "${missing}" ]]; then return 1; fi
            builtin command "$@"
        }
        expect_failure select_build_nfs_destination
        assert_no_event mount
    )
done

# Exercita o cleanup real do executável (EXIT, erro e SIGTERM), preservando
# o código principal mesmo se umount falhar. Apenas pequenos sentinelas locais.
for outcome in success error signal umount_error preexisting replaced replaced_same_source; do
    reset_case
    status=0
    (
        trap cleanup EXIT
        trap 'on_signal TERM' TERM
        if [[ "${outcome}" == preexisting ]]; then
            printf '20 192.168.0.19:/var/clone-pmjs nfs4 %s\n' "${NFS_MOUNTPOINT}" > "${test_root}/state"
        fi
        select_build_nfs_destination
        OUTPUT_DIR=${NFS_MOUNTPOINT}
        prepare_build_workspace "${OUTPUT_DIR}" pmjs-test BUILD_WORKSPACE LOCAL_IMAGE_DIR
        printf 'partial\n' > "${BUILD_WORKSPACE}/rootfs.tar.zst.partial"
        # Um path isolado fora do workspace jamais deve ser removido.
        ROOTFS_TEMP_FILE="${test_root}/outside"
        printf 'keep\n' > "${ROOTFS_TEMP_FILE}"
        case "${outcome}" in
            success) BUILD_SUCCEEDED=true; exit 0 ;;
            error) exit 71 ;;
            signal) kill -TERM "${BASHPID}" ;;
            umount_error) umount_mode=fail; exit 72 ;;
            preexisting) exit 75 ;;
            replaced)
                printf '99 other:/export nfs4 %s\n' "${NFS_MOUNTPOINT}" > "${test_root}/state"
                exit 73 ;;
            replaced_same_source)
                printf '99 192.168.0.19:/var/clone-pmjs nfs4 %s\n' "${NFS_MOUNTPOINT}" > "${test_root}/state"
                exit 74 ;;
        esac
    ) || status=$?
    [[ -f "${test_root}/outside" ]]
    case "${outcome}" in
        success) [[ ${status} -eq 0 ]] ;;
        error) [[ ${status} -eq 71 ]] ;;
        signal) [[ ${status} -eq 143 ]] ;;
        umount_error) [[ ${status} -eq 72 ]] ;;
        preexisting) [[ ${status} -eq 75 ]] ;;
        replaced) [[ ${status} -eq 73 ]] ;;
        replaced_same_source) [[ ${status} -eq 74 ]] ;;
    esac
    if [[ "${outcome}" == replaced* ]]; then
        assert_no_event umount
        [[ -n "$(find "${NFS_MOUNTPOINT}" -name '*.partial' -print -quit)" ]]
        # Remove somente os sentinelas do teste após as asserções.
        find "${NFS_MOUNTPOINT}" -mindepth 1 -depth -delete
    elif [[ "${outcome}" == preexisting ]]; then
        assert_no_event mount
        assert_no_event umount
        [[ -z "$(find "${NFS_MOUNTPOINT}" -name '*.partial' -print -quit)" ]]
    else
        grep -qx umount "${test_root}/events"
        [[ -z "$(find "${NFS_MOUNTPOINT}" -name '*.partial' -print -quit)" ]]
    fi
done

# Interrupção durante mount: o handler espera registrar o mount e então limpa.
reset_case
mount_mode=signal
status=0
(
    trap cleanup EXIT
    trap 'on_signal TERM' TERM
    select_build_nfs_destination
    exit 99
) || status=$?
[[ ${status} -eq 143 ]]
grep -qx umount "${test_root}/events"

# O main real deve abortar antes de detectar/capturar a origem. Os únicos
# preflights substituídos permitem executar sem root e mantêm logs em /tmp.
for main_failure in fail unconfirmed wrong; do
    reset_case
    mount_mode=${main_failure}
    status=0
    (
        trap cleanup EXIT
        check_root() { :; }
        check_dependencies() { :; }
        resolve_project_path() { printf '%s\n' "${test_root}/main-local"; }
        check_nfs_dependencies() {
            NFS_MOUNTPOINT="${test_root}/main-mount"
        }
        detect_capture_sources() {
            printf 'capture\n' >> "${test_root}/events"
            exit 90
        }
        main
    ) > "${test_root}/main-output" 2>&1 || status=$?
    [[ ${status} -eq 1 ]]
    grep -Fq '[ERRO] Build não iniciado.' "${test_root}/main-output"
    assert_no_event capture
    [[ -z "$(find "${test_root}/main-mount" -name '*.build.*' -print -quit)" ]]
done

printf 'OK: automount NFS, precedência, dependências, falhas e cleanup seguro\n'
