#!/usr/bin/env bash

check_config_file() {
    local config_file=$1
    [[ -r "${config_file}" ]] || { ui_error "Configuração não encontrada ou ilegível: ${config_file}"; return 1; }
}

validate_config() {
    local variable
    local required=(IMAGE_NAME IMAGE_VERSION OUTPUT_DIR LOG_DIR ROOTFS_FILENAME HOMEFS_FILENAME SOURCE_ROOT HOME_SOURCE HOME_USER IMAGE_COMPRESSION ZSTD_LEVEL MIN_FREE_SPACE_GIB HOMEFS_MAX_SIZE_MIB)
    for variable in "${required[@]}"; do
        [[ -n "${!variable:-}" ]] || { ui_error "Configuração obrigatória ausente: ${variable}"; return 1; }
    done
    [[ "${IMAGE_COMPRESSION}" == gzip || "${IMAGE_COMPRESSION}" == zstd ]] || { ui_error "IMAGE_COMPRESSION deve ser 'gzip' ou 'zstd'."; return 1; }
    [[ "${ZSTD_LEVEL}" =~ ^[1-9][0-9]*$ && ${ZSTD_LEVEL} -le 19 ]] || { ui_error "ZSTD_LEVEL deve estar entre 1 e 19."; return 1; }
    [[ "${ROOTFS_FILENAME}" == auto ]] || { ui_error "ROOTFS_FILENAME deve ser 'auto'."; return 1; }
    [[ "${HOMEFS_FILENAME}" == auto ]] || { ui_error "HOMEFS_FILENAME deve ser 'auto'."; return 1; }
    [[ "${MIN_FREE_SPACE_GIB}" =~ ^[0-9]+$ ]] || { ui_error "MIN_FREE_SPACE_GIB deve ser um inteiro não negativo."; return 1; }
    [[ "${HOMEFS_MAX_SIZE_MIB}" =~ ^[1-9][0-9]*$ ]] || { ui_error "HOMEFS_MAX_SIZE_MIB deve ser um inteiro positivo."; return 1; }
    [[ "${HOME_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { ui_error "HOME_USER contém caracteres inválidos."; return 1; }
    if [[ "${SOURCE_ROOT}" == auto || "${HOME_SOURCE}" == auto ]]; then
        [[ "${SOURCE_ROOT}" == auto && "${HOME_SOURCE}" == auto ]] || { ui_error "SOURCE_ROOT e HOME_SOURCE devem usar 'auto' juntos."; return 1; }
    fi
    [[ "${IMAGE_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { ui_error "IMAGE_NAME contém caracteres inválidos."; return 1; }
    [[ "${IMAGE_VERSION}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { ui_error "IMAGE_VERSION contém caracteres inválidos."; return 1; }
}

validate_version_file() {
    local version_file=$1 configured_version=$2 file_version
    [[ -r "${version_file}" ]] || { ui_error "Arquivo VERSION não encontrado: ${version_file}"; return 1; }
    file_version="$(tr -d '[:space:]' < "${version_file}")"
    [[ "${file_version}" == "${configured_version}" ]] || { ui_error "Versões divergentes: VERSION=${file_version}, image.conf=${configured_version}"; return 1; }
}

resolve_project_path() {
    local project_dir=$1 configured_path=$2
    if [[ "${configured_path}" == /* ]]; then realpath -m -- "${configured_path}"; else realpath -m -- "${project_dir}/${configured_path}"; fi
}

check_root() {
    (( EUID == 0 )) || { ui_error "Execute o build como root."; return 1; }
}

check_dependencies() {
    local command tar_version
    local dependencies=(tar gzip rsync stat du df realpath readlink getent id date mkdir mktemp install chmod find dirname basename mv rm tr tail awk grep lsblk blkid mount umount sha256sum python3 wc uname)
    for command in "${dependencies[@]}"; do
        command -v "${command}" >/dev/null 2>&1 || { ui_error "Dependência ausente: ${command}"; return 1; }
    done
    tar_version="$(tar --version)"
    [[ "${tar_version}" == *"GNU tar"* ]] || { ui_error "GNU tar é obrigatório para ACLs e atributos estendidos."; return 1; }
}

check_compression_dependency() {
    local compression=$1
    if [[ "${compression}" == zstd ]]; then
        command -v zstd >/dev/null 2>&1 || {
            ui_error "Compressão zstd selecionada, mas o binário 'zstd' não está instalado."
            return 1
        }
    fi
}

source_root_has_linux_layout() {
    local candidate=$1
    [[ -d "${candidate}/etc" && -d "${candidate}/usr" && -d "${candidate}/var" ]]
}

resolve_source_root() {
    local configured_root=$1
    local -n resolved_ref=$2
    local candidate rootfs_subvolume

    [[ "${configured_root}" == /* ]] || {
        ui_error "SOURCE_ROOT deve ser um caminho absoluto: ${configured_root}"
        return 1
    }
    candidate="$(realpath -e -- "${configured_root}")" || {
        ui_error "SOURCE_ROOT inexistente: ${configured_root}"
        return 1
    }
    [[ -d "${candidate}" && -r "${candidate}" ]] || {
        ui_error "Raiz de origem inválida: ${candidate}"
        return 1
    }

    if source_root_has_linux_layout "${candidate}"; then
        resolved_ref="${candidate}"
        return 0
    fi

    rootfs_subvolume="${candidate}/@rootfs"
    if [[ -d "${rootfs_subvolume}" && ! -L "${rootfs_subvolume}" ]] &&
       source_root_has_linux_layout "${rootfs_subvolume}"; then
        resolved_ref="$(realpath -e -- "${rootfs_subvolume}")"
        return 0
    fi

    ui_error "Nenhuma raiz Linux válida encontrada em ${candidate} ou ${rootfs_subvolume}"
    return 1
}

check_source_root() {
    local source_root=$1
    [[ -d "${source_root}" && -r "${source_root}" ]] || {
        ui_error "Raiz de origem inválida: ${source_root}"
        return 1
    }
    source_root_has_linux_layout "${source_root}" || {
        ui_error "Layout Linux incompleto em SOURCE_ROOT: ${source_root}"
        return 1
    }
}

prepare_directories() {
    local output_dir=$1 log_dir=$2
    mkdir -p -- "${output_dir}" "${log_dir}"
    [[ -d "${output_dir}" && -w "${output_dir}" ]] || { ui_error "Diretório de saída não gravável: ${output_dir}"; return 1; }
    [[ -d "${log_dir}" && -w "${log_dir}" ]] || { ui_error "Diretório de logs não gravável: ${log_dir}"; return 1; }
}

prepare_build_directory() {
    local build_dir=$1
    mkdir -p -- "${build_dir}"
    [[ -d "${build_dir}" && -w "${build_dir}" ]] || { ui_error "Diretório do build não gravável: ${build_dir}"; return 1; }
}

check_destination_filesystem() {
    local source_root=$1 destination=$2 source_device destination_device
    source_device="$(stat -c '%d' -- "${source_root}")"
    destination_device="$(stat -c '%d' -- "${destination}")"
    [[ "${source_device}" != "${destination_device}" ]] || { ui_error "O destino (${destination}) está no mesmo filesystem da raiz (${source_root}). Monte OUTPUT_DIR em outro filesystem."; return 1; }
    log_write INFO "Filesystem validado: raiz=${source_device}, destino=${destination_device}"
}

check_free_space() {
    local destination=$1 minimum_gib=$2 available_bytes minimum_bytes
    available_bytes="$(df --output=avail -B1 -- "${destination}" | tail -n 1 | tr -d '[:space:]')"
    minimum_bytes=$(( minimum_gib * 1024 * 1024 * 1024 ))
    (( available_bytes >= minimum_bytes )) || { ui_error "Espaço insuficiente em ${destination}: mínimo de ${minimum_gib} GiB."; return 1; }
    log_write INFO "Espaço livre validado: ${available_bytes} bytes disponíveis"
}
