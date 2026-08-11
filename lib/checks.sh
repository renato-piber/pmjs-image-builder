#!/usr/bin/env bash

check_config_file() {
    local config_file=$1
    [[ -r "${config_file}" ]] || { ui_error "Configuração não encontrada ou ilegível: ${config_file}"; return 1; }
}

validate_config() {
    local variable
    local required=(IMAGE_NAME IMAGE_VERSION OUTPUT_DIR LOG_DIR ROOTFS_FILENAME SOURCE_ROOT ROOTFS_COMPRESSION MIN_FREE_SPACE_GIB)
    for variable in "${required[@]}"; do
        [[ -n "${!variable:-}" ]] || { ui_error "Configuração obrigatória ausente: ${variable}"; return 1; }
    done
    [[ "${ROOTFS_COMPRESSION}" == gzip ]] || { ui_error "ROOTFS_COMPRESSION deve ser 'gzip' nesta sprint."; return 1; }
    [[ "${ROOTFS_FILENAME}" == rootfs.tar.gz ]] || { ui_error "ROOTFS_FILENAME deve ser 'rootfs.tar.gz' nesta sprint."; return 1; }
    [[ "${MIN_FREE_SPACE_GIB}" =~ ^[0-9]+$ ]] || { ui_error "MIN_FREE_SPACE_GIB deve ser um inteiro não negativo."; return 1; }
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
    local dependencies=(tar gzip stat df realpath readlink date mkdir mktemp install chmod find dirname basename mv rm tr tail awk grep)
    for command in "${dependencies[@]}"; do
        command -v "${command}" >/dev/null 2>&1 || { ui_error "Dependência ausente: ${command}"; return 1; }
    done
    tar_version="$(tar --version)"
    [[ "${tar_version}" == *"GNU tar"* ]] || { ui_error "GNU tar é obrigatório para ACLs e atributos estendidos."; return 1; }
}

check_source_root() {
    local source_root=$1
    [[ "${source_root}" == / ]] || { ui_error "SOURCE_ROOT deve ser '/' nesta sprint."; return 1; }
    [[ -d "${source_root}" && -r "${source_root}" ]] || { ui_error "Raiz de origem inválida: ${source_root}"; return 1; }
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
