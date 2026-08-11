#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=lib/logs.sh
source "${PROJECT_DIR}/lib/logs.sh"
# shellcheck source=lib/ui.sh
source "${PROJECT_DIR}/lib/ui.sh"
# shellcheck source=lib/checks.sh
source "${PROJECT_DIR}/lib/checks.sh"
# shellcheck source=lib/generalize.sh
source "${PROJECT_DIR}/lib/generalize.sh"
# shellcheck source=lib/rootfs.sh
source "${PROJECT_DIR}/lib/rootfs.sh"

readonly START_TIME=${SECONDS}
BUILD_SUCCEEDED=false
ROOTFS_TEMP_FILE=""
GENERALIZATION_STAGING=""
GENERALIZATION_BUILD_DIR=""
BUILD_DIR=""

cleanup() {
    local exit_code=$?

    trap - EXIT ERR INT TERM
    set +e

    if [[ -n "${GENERALIZATION_STAGING:-}" ]]; then
        cleanup_generalization_staging "${GENERALIZATION_STAGING}" \
            "${GENERALIZATION_BUILD_DIR}" || exit_code=1
        GENERALIZATION_STAGING=""
        GENERALIZATION_BUILD_DIR=""
    fi
    if [[ -n "${ROOTFS_TEMP_FILE:-}" && -e "${ROOTFS_TEMP_FILE}" ]]; then
        rm -f -- "${ROOTFS_TEMP_FILE}"
        log_write WARN "Arquivo temporário removido: ${ROOTFS_TEMP_FILE}"
    fi

    if [[ "${BUILD_SUCCEEDED}" != true && ${exit_code} -ne 0 ]]; then
        ui_error "Build interrompido (código ${exit_code}). Consulte: ${LOG_FILE:-log não inicializado}"
    fi

    exit "${exit_code}"
}

on_error() {
    local exit_code=$1
    local line=$2
    local command=$3

    log_write ERROR "Falha na linha ${line} (código ${exit_code}): ${command}"
    return "${exit_code}"
}

on_signal() {
    local signal=$1
    log_write WARN "Sinal ${signal} recebido; interrompendo o build."
    [[ "${signal}" == INT ]] && exit 130
    exit 143
}

trap cleanup EXIT
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

build_rootfs_artifact() {
    local source_root=$1
    local build_dir=$2
    local rootfs_file=$3

    validate_generalization_source "${source_root}"
    GENERALIZATION_BUILD_DIR="${build_dir}"
    prepare_generalization_staging "${build_dir}" GENERALIZATION_STAGING
    log_write INFO "Staging de generalização: ${GENERALIZATION_STAGING}"

    ROOTFS_TEMP_FILE="${rootfs_file}.partial"
    generate_rootfs "${source_root}" "${build_dir}" "${ROOTFS_TEMP_FILE}" \
        "${GENERALIZATION_STAGING}"
    validate_rootfs "${ROOTFS_TEMP_FILE}" "${source_root}" "${build_dir}"
    mv -f -- "${ROOTFS_TEMP_FILE}" "${rootfs_file}"
    ROOTFS_TEMP_FILE=""

    cleanup_generalization_staging "${GENERALIZATION_STAGING}" "${build_dir}"
    GENERALIZATION_STAGING=""
    GENERALIZATION_BUILD_DIR=""
}

main() {
    local config_file="${PROJECT_DIR}/config/image.conf"
    local version_file="${PROJECT_DIR}/VERSION"
    local elapsed size

    ui_header

    check_root
    check_dependencies
    check_config_file "${config_file}"
    # shellcheck source=config/image.conf
    source "${config_file}"
    validate_config
    validate_version_file "${version_file}" "${IMAGE_VERSION}"

    OUTPUT_DIR="$(resolve_project_path "${PROJECT_DIR}" "${OUTPUT_DIR}")"
    LOG_DIR="$(resolve_project_path "${PROJECT_DIR}" "${LOG_DIR}")"
    readonly OUTPUT_DIR LOG_DIR

    init_log "${LOG_DIR}"
    log_write INFO "Iniciando build ${IMAGE_NAME}-${IMAGE_VERSION}"
    log_write INFO "Configuração carregada de ${config_file}"

    check_source_root "${SOURCE_ROOT}"
    prepare_directories "${OUTPUT_DIR}" "${LOG_DIR}"

    BUILD_DIR="${OUTPUT_DIR}/${IMAGE_NAME}-${IMAGE_VERSION}"
    readonly BUILD_DIR
    readonly ROOTFS_FILE="${BUILD_DIR}/${ROOTFS_FILENAME}"

    prepare_build_directory "${BUILD_DIR}"
    check_destination_filesystem "${SOURCE_ROOT}" "${BUILD_DIR}"
    check_free_space "${BUILD_DIR}" "${MIN_FREE_SPACE_GIB}"
    ui_info "Gerando ${ROOTFS_FILE}"
    log_write INFO "A captura é feita com o sistema ativo e pode refletir alterações concorrentes."
    log_write INFO "Identidades da máquina-modelo serão removidas do rootfs."

    build_rootfs_artifact "${SOURCE_ROOT}" "${BUILD_DIR}" "${ROOTFS_FILE}"

    size="$(format_file_size "${ROOTFS_FILE}")"
    elapsed="$(( SECONDS - START_TIME ))"
    BUILD_SUCCEEDED=true

    log_write SUCCESS "Rootfs gerado, generalizado e validado: ${ROOTFS_FILE}"
    ui_success "Build concluído"
    printf 'Arquivo: %s\nTamanho: %s\nDuração: %ss\nLog: %s\n' \
        "${ROOTFS_FILE}" "${size}" "${elapsed}" "${LOG_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
