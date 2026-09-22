#!/usr/bin/env bash
# Somente árvores sintéticas: mount/findmnt/umount/df simulados, tar real pequeno.
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${TEST_DIR}/../build-image.sh"
test_root="$(mktemp -d /tmp/pmjs-dual-build-test.XXXXXX)"
trap '[[ "${test_root}" == /tmp/pmjs-dual-build-test.* && -d "${test_root}" && ! -L "${test_root}" ]] && find -P "${test_root}" -depth -delete' EXIT

# Preserve os geradores reais para conferir generalização e bundle completo.
eval "$(declare -f build_rootfs_artifact | sed '1s/build_rootfs_artifact/build_rootfs_artifact_actual/')"
eval "$(declare -f build_homefs_artifact | sed '1s/build_homefs_artifact/build_homefs_artifact_actual/')"
eval "$(declare -f build_metadata_artifacts | sed '1s/build_metadata_artifacts/build_metadata_artifacts_actual/')"
eval "$(declare -f finalize_build_workspace | sed '1s/finalize_build_workspace/finalize_build_workspace_actual/')"
build_rootfs_artifact() {
    printf 'rootfs\n' >> "${events}"
    [[ "${scenario}" != rootfs_failure ]] || return 31
    build_rootfs_artifact_actual "$@"
}
build_homefs_artifact() {
    printf 'homefs\n' >> "${events}"
    [[ "${scenario}" != homefs_failure ]] || return 32
    build_homefs_artifact_actual "$@" || return 1
    [[ "${scenario}" != explicit_nfs_changed ]] || nfs_id=999
    return 0
}
build_metadata_artifacts() {
    build_metadata_artifacts_actual "$@" || return 1
    if [[ "${scenario}" == bad_sha ]]; then
        printf 'invalid checksum\n' > "$4"
    fi
}
finalize_build_workspace() {
    if [[ "${scenario}" == before_nfs_commit ]]; then kill -TERM "${BASHPID}"; fi
    finalize_build_workspace_actual "$@" || return 1
    printf 'nfs_commit\n' >> "${events}"
}

check_root() { :; }
check_dependencies() { :; }
check_nfs_dependencies() { :; }
eval "$(declare -f select_interactive_build_destinations | sed '1s/select_interactive_build_destinations/select_interactive_build_destinations_actual/')"
select_interactive_build_destinations() {
    # As leituras reais do terminal têm cobertura em test_image_naming.py;
    # aqui conferir o restante do main com a identidade escolhida previamente.
    if [[ "${scenario}" == interactive_selected ]]; then
        validate_ventoy_sync_destination "${ventoy_dir}" || return 1
        BUILD_ALSO_VENTOY_DIR=${VENTOY_DESTINATION}
        BUILD_VENTOY_COPY_SELECTED_INTERACTIVELY=true
    else
        select_interactive_build_destinations_actual
    fi
}
select_build_image_version() {
    # Não alterar config real; somente as origens e destinos sintéticos deste caso.
    IMAGE_NAME=pmjs-linux
    IMAGE_VERSION=0.9.0-test
    IMAGE_VERSION_SOURCE="fixture interativa"
    LOG_DIR="${case_root}/logs"
    LOCAL_TEMP_DIR="${case_root}/local-staging"
    OUTPUT_DIR="${case_root}/local-output"
    SOURCE_ROOT="${case_root}/source"
    HOME_USER="$(id -un)"
    HOME_SOURCE="${case_root}/${HOME_USER}"
    NFS_MOUNTPOINT=${nfs_dir}
    NFS_ENABLED=1
    [[ "${scenario}" != local_only ]] || NFS_ENABLED=0
    NFS_IMAGES_DIR=""
    MIN_FREE_SPACE_GIB=0
    VENTOY_FREE_SPACE_MARGIN_MIB=0
}
mount() {
    printf 'mount\n' >> "${events}"
    [[ "${scenario}" != mount_failure ]] || return 32
    nfs_mounted=1
}
umount() { printf 'umount\n' >> "${events}"; nfs_mounted=0; }
findmnt() {
    if [[ "$*" == *"--mountpoint ${nfs_dir}"* ]]; then
        (( nfs_mounted == 1 )) || return 1
        printf '%s 192.168.0.19:/var/clone-pmjs nfs4 %s\n' "${nfs_id}" "${nfs_dir}"
        return 0
    fi
    if [[ "$*" == *"--target ${nfs_dir}"* ]]; then
        (( nfs_mounted == 1 )) || return 1
        case "$*" in
            *'--output ID,SOURCE,FSTYPE,TARGET'*)
                printf '%s 192.168.0.19:/var/clone-pmjs nfs4 %s\n' "${nfs_id}" "${nfs_dir}" ;;
            *'--output FSTYPE'*) printf 'nfs4\n' ;;
            *'--output TARGET'*) printf '%s\n' "${nfs_dir}" ;;
            *) return 1 ;;
        esac
        return 0
    fi
    [[ "$*" == *"--target ${ventoy_dir}"* ]] || return 1
    case "$*" in
        *'--output ID'*) printf '%s\n' "${ventoy_id}" ;;
        *'--output SOURCE'*) printf '/dev/sdz1\n' ;;
        *'--output FSTYPE'*) printf 'exfat\n' ;;
        *'--output TARGET'*)
            if [[ "${scenario}" == ventoy_unmounted ]]; then printf '/\n';
            else printf '%s/Ventoy\n' "${case_root}"; fi ;;
        *) return 1 ;;
    esac
}
df() {
    local path=${!#}
    if [[ "${path}" == "${ventoy_dir}" && "${scenario}" == no_space ]]; then
        printf 'Avail\n0\n'
    else
        printf 'Avail\n1073741824\n'
    fi
}
rsync() {
    # O homefs usa rsync também; distinguir somente a cópia offline com progresso.
    if [[ "$*" != *--info=progress2* ]]; then command rsync "$@"; return; fi
    printf 'offline_copy\n' >> "${events}"
    [[ -d "${nfs_final}" && ! -e "${ventoy_final}" ]] || return 90
    validate_image_directory "${nfs_final}" >/dev/null || return 91
    local staging=${!#}
    # Há somente um staging próprio; outro staging externo deve permanecer intacto.
    [[ -f "${ventoy_dir}/.unrelated.sync.KEEP/sentinel" ]] || return 92
    if [[ "${scenario}" == copy_failure ]]; then
        cp -- "${nfs_final}/rootfs.tar.zst" "${staging}/"
        return 23
    fi
    command rsync "$@" || return 1
    case "${scenario}" in
        interrupt_copy) kill -TERM "${BASHPID}" ;;
        corrupt_copy) printf 'corruption\n' >> "${staging}/rootfs.tar.zst" ;;
        nfs_changed) nfs_id=999 ;;
        ventoy_changed) ventoy_id=999; return 76 ;;
        destination_race)
            mkdir -- "${ventoy_final}"
            printf 'preserve\n' > "${ventoy_final}/sentinel" ;;
    esac
    return 0
}

new_case() {
    scenario=$1
    case_root="${test_root}/${scenario}"
    nfs_dir="${case_root}/nfs"
    ventoy_dir="${case_root}/Ventoy/pmjs-images"
    nfs_final="${nfs_dir}/pmjs-linux-0.9.0-test"
    ventoy_final="${ventoy_dir}/pmjs-linux-0.9.0-test"
    events="${case_root}/events"
    nfs_id=100
    ventoy_id=200
    [[ "${scenario}" != same_mount ]] || ventoy_id=100
    nfs_mounted=0
    mkdir -p -- "${nfs_dir}" "${ventoy_dir}/.unrelated.sync.KEEP" \
        "${case_root}/source/etc/ssh" "${case_root}/source/etc/ocsinventory" \
        "${case_root}/source/usr/sbin" "${case_root}/source/var/lib/dbus" \
        "${case_root}/$(id -un)/.config/dconf"
    printf 'keep\n' > "${ventoy_dir}/.unrelated.sync.KEEP/sentinel"
    : > "${events}"
    local relative
    for relative in etc/passwd etc/group etc/hostname etc/ssh/sshd_config \
        etc/ocsinventory/ocsinventory-agent.cfg etc/x11vnc.pass usr/sbin/sshd; do
        printf 'fixture\n' > "${case_root}/source/${relative}"
    done
    printf 'PRETTY_NAME="PMJS Dual Test"\n' > "${case_root}/source/etc/os-release"
    printf 'model-id\n' > "${case_root}/source/etc/machine-id"
    printf 'private-key\n' > "${case_root}/source/etc/ssh/ssh_host_rsa_key"
    ln -s /etc/machine-id "${case_root}/source/var/lib/dbus/machine-id"
    printf 'profile\n' > "${case_root}/$(id -un)/.config/dconf/user"
}
run_case() {
    (
        trap cleanup EXIT
        trap 'on_signal TERM' TERM
        local -a args=(--also-ventoy-dir "${ventoy_dir}")
        [[ "${scenario}" != interactive_selected ]] || args=()
        if [[ "${scenario}" == explicit_nfs || "${scenario}" == explicit_nfs_changed ]]; then
            nfs_mounted=1
            args=(--nfs-dir "${nfs_dir}" "${args[@]}")
        elif [[ "${scenario}" == preexisting_nfs ]]; then
            nfs_mounted=1
        fi
        main "${args[@]}"
    ) > "${case_root}/output" 2>&1
}
assert_no_own_offline_staging() {
    [[ -z "$(find "${ventoy_dir}" -maxdepth 1 -name '.pmjs-linux-0.9.0-test.sync.*' -print -quit)" ]]
    [[ "$(<"${ventoy_dir}/.unrelated.sync.KEEP/sentinel")" == keep ]]
}

for scenario_name in success interactive_selected preexisting_nfs explicit_nfs; do
    new_case "${scenario_name}"
    run_case
    validate_image_directory "${nfs_final}"
    validate_image_directory "${ventoy_final}"
    for filename in rootfs.tar.zst homefs.tar.zst SHA256SUMS manifest.json; do
        cmp -- "${nfs_final}/${filename}" "${ventoy_final}/${filename}"
    done
    [[ "$(grep -c '^rootfs$' "${events}")" == 1 && "$(grep -c '^homefs$' "${events}")" == 1 ]]
    [[ "$(grep -c '^offline_copy$' "${events}")" == 1 ]]
    assert_no_own_offline_staging
    if [[ "${scenario_name}" == success || "${scenario_name}" == interactive_selected ]]; then grep -qx umount "${events}";
    else ! grep -Eq '^(mount|umount)$' "${events}"; fi
    grep -Fq 'SHA256: OK nos dois destinos' "${case_root}/output"
done

for scenario_name in rootfs_failure homefs_failure bad_sha before_nfs_commit mount_failure \
    ventoy_unmounted same_mount local_only existing_ventoy existing_nfs explicit_nfs_changed; do
    new_case "${scenario_name}"
    if [[ "${scenario_name}" == existing_ventoy ]]; then
        mkdir -- "${ventoy_final}"
        printf 'preserve\n' > "${ventoy_final}/sentinel"
    elif [[ "${scenario_name}" == existing_nfs ]]; then
        mkdir -- "${nfs_final}"
        printf 'preserve\n' > "${nfs_final}/sentinel"
    fi
    if run_case; then printf 'Falha esperada: %s\n' "${scenario_name}" >&2; exit 1; fi
    ! grep -qx offline_copy "${events}"
    if [[ "${scenario_name}" == existing_nfs ]]; then
        [[ "$(<"${nfs_final}/sentinel")" == preserve ]]
    else [[ ! -e "${nfs_final}" ]]; fi
    if [[ "${scenario_name}" == existing_ventoy ]]; then
        [[ "$(<"${ventoy_final}/sentinel")" == preserve ]]
    else [[ ! -e "${ventoy_final}" ]]; fi
    assert_no_own_offline_staging
    if [[ "${scenario_name}" == explicit_nfs_changed ]]; then
        [[ -n "$(find "${nfs_dir}" -maxdepth 1 -name '.pmjs-linux-0.9.0-test.build.*' -print -quit)" ]]
        grep -Fq 'Staging NFS não removido' "${case_root}/output"
        ! grep -qx umount "${events}"
    fi
done

for scenario_name in no_space copy_failure interrupt_copy corrupt_copy nfs_changed ventoy_changed destination_race; do
    new_case "${scenario_name}"
    if run_case; then printf 'Falha esperada: %s\n' "${scenario_name}" >&2; exit 1; fi
    validate_image_directory "${nfs_final}"
    grep -Fq 'Imagem válida preservada no NFS:' "${case_root}/output"
    if [[ "${scenario_name}" == destination_race ]]; then
        [[ "$(<"${ventoy_final}/sentinel")" == preserve ]]
    else [[ ! -e "${ventoy_final}" ]]; fi
    if [[ "${scenario_name}" == ventoy_changed ]]; then
        [[ -n "$(find "${ventoy_dir}" -maxdepth 1 -name '.pmjs-linux-0.9.0-test.sync.*' -print -quit)" ]]
        grep -Fq 'Staging não removido' "${case_root}/output"
    else assert_no_own_offline_staging; fi
    if [[ "${scenario_name}" == nfs_changed ]]; then ! grep -qx umount "${events}";
    else grep -qx umount "${events}"; fi
done

# Compatibilidade/CLI: o build direto no Ventoy não recebe cópia secundária.
for invalid_args in missing empty repeated conflict; do
    if (
        case "${invalid_args}" in
            missing) parse_build_arguments --also-ventoy-dir ;;
            empty) parse_build_arguments --also-ventoy-dir '' ;;
            repeated) parse_build_arguments --also-ventoy-dir /a --also-ventoy-dir /b ;;
            conflict) parse_build_arguments --ventoy-dir /a --also-ventoy-dir /b ;;
        esac
    ) >/dev/null 2>&1; then exit 1; fi
done
[[ -z "${BUILD_ALSO_VENTOY_DIR}" ]]
printf 'OK: build NFS → Ventoy, imutabilidade, falhas e cleanup seguro (22 cenários + CLI)\n'
