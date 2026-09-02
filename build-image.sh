#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=lib/logs.sh
source "${PROJECT_DIR}/lib/logs.sh"
# shellcheck source=lib/ui.sh
source "${PROJECT_DIR}/lib/ui.sh"
# shellcheck source=lib/checks.sh
source "${PROJECT_DIR}/lib/checks.sh"
# shellcheck source=lib/archive.sh
source "${PROJECT_DIR}/lib/archive.sh"
# shellcheck source=lib/source_detect.sh
source "${PROJECT_DIR}/lib/source_detect.sh"
# shellcheck source=lib/generalize.sh
source "${PROJECT_DIR}/lib/generalize.sh"
# shellcheck source=lib/homefs.sh
source "${PROJECT_DIR}/lib/homefs.sh"
# shellcheck source=lib/rootfs.sh
source "${PROJECT_DIR}/lib/rootfs.sh"
# shellcheck source=lib/metadata.sh
source "${PROJECT_DIR}/lib/metadata.sh"

readonly START_TIME=${SECONDS}
BUILD_SUCCEEDED=false
ROOTFS_TEMP_FILE=""
HOMEFS_TEMP_FILE=""
CHECKSUM_TEMP_FILE=""
MANIFEST_TEMP_FILE=""
HOMEFS_STAGING=""
GENERALIZATION_STAGING=""
GENERALIZATION_BUILD_DIR=""
BUILD_DIR=""
ROOTFS_GENERATE_SECONDS=0
ROOTFS_VALIDATE_SECONDS=0
HOMEFS_GENERATE_SECONDS=0
HOMEFS_VALIDATE_SECONDS=0

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
    if [[ -n "${HOMEFS_STAGING:-}" ]]; then
        cleanup_homefs_staging "${HOMEFS_STAGING}" || exit_code=1
        HOMEFS_STAGING=""
    fi
    if [[ -n "${HOMEFS_TEMP_FILE:-}" && -e "${HOMEFS_TEMP_FILE}" ]]; then
        rm -f -- "${HOMEFS_TEMP_FILE}"
        log_write WARN "Homefs temporário removido: ${HOMEFS_TEMP_FILE}"
    fi
    if [[ -n "${ROOTFS_TEMP_FILE:-}" && -e "${ROOTFS_TEMP_FILE}" ]]; then
        rm -f -- "${ROOTFS_TEMP_FILE}"
        log_write WARN "Arquivo temporário removido: ${ROOTFS_TEMP_FILE}"
    fi
    if [[ -n "${CHECKSUM_TEMP_FILE:-}" && -e "${CHECKSUM_TEMP_FILE}" ]]; then
        rm -f -- "${CHECKSUM_TEMP_FILE}"
    fi
    if [[ -n "${MANIFEST_TEMP_FILE:-}" && -e "${MANIFEST_TEMP_FILE}" ]]; then
        rm -f -- "${MANIFEST_TEMP_FILE}"
    fi
    if [[ -n "${SOURCE_DETECT_DIR:-}" ]]; then
        cleanup_detected_capture_source || exit_code=1
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
    local rootfs_file=$3 compression=${4:-gzip} zstd_level=${5:-3}
    local phase_start

    validate_generalization_source "${source_root}"
    GENERALIZATION_BUILD_DIR="${build_dir}"
    prepare_generalization_staging "${build_dir}" GENERALIZATION_STAGING
    log_write INFO "Staging de generalização: ${GENERALIZATION_STAGING}"

    ROOTFS_TEMP_FILE="${rootfs_file}.partial"
    phase_start=${SECONDS}
    generate_rootfs "${source_root}" "${build_dir}" "${ROOTFS_TEMP_FILE}" \
        "${GENERALIZATION_STAGING}" "${compression}" "${zstd_level}"
    ROOTFS_GENERATE_SECONDS=$(( SECONDS - phase_start ))
    phase_start=${SECONDS}
    validate_rootfs "${ROOTFS_TEMP_FILE}" "${source_root}" "${build_dir}" "${compression}"
    ROOTFS_VALIDATE_SECONDS=$(( SECONDS - phase_start ))
    mv -f -- "${ROOTFS_TEMP_FILE}" "${rootfs_file}"
    ROOTFS_TEMP_FILE=""

    cleanup_generalization_staging "${GENERALIZATION_STAGING}" "${build_dir}"
    GENERALIZATION_STAGING=""
    GENERALIZATION_BUILD_DIR=""
}

build_homefs_artifact() {
    local home_source=$1 home_user=$2 home_uid=$3 home_gid=$4
    local max_size_mib=$5 build_dir=$6 homefs_file=$7
    local compression=${8:-gzip} zstd_level=${9:-3} phase_start
    local -a standard_directories

    detect_home_standard_directories "${home_source}" standard_directories
    prepare_homefs_staging "${home_source}" "${home_user}" "${home_uid}" "${home_gid}" \
        standard_directories HOMEFS_STAGING
    log_write INFO "Staging do homefs: ${HOMEFS_STAGING}"
    log_write INFO "Filesystem do staging do homefs: $(stat --file-system --format='%T' -- "${HOMEFS_STAGING}")"
    log_write INFO "Archive final do homefs: ${homefs_file}"
    validate_homefs_staging "${HOMEFS_STAGING}" "${home_user}" "${home_uid}" "${home_gid}" \
        "${max_size_mib}" "${standard_directories[@]}"

    HOMEFS_TEMP_FILE="${homefs_file}.partial"
    phase_start=${SECONDS}
    generate_homefs "${HOMEFS_STAGING}" "${home_user}" "${HOMEFS_TEMP_FILE}" \
        "${compression}" "${zstd_level}"
    HOMEFS_GENERATE_SECONDS=$(( SECONDS - phase_start ))
    phase_start=${SECONDS}
    validate_homefs_archive "${HOMEFS_TEMP_FILE}" "${home_user}" "${standard_directories[@]}"
    HOMEFS_VALIDATE_SECONDS=$(( SECONDS - phase_start ))
    mv -f -- "${HOMEFS_TEMP_FILE}" "${homefs_file}"
    HOMEFS_TEMP_FILE=""

    cleanup_homefs_staging "${HOMEFS_STAGING}"
    HOMEFS_STAGING=""
}

build_metadata_artifacts() {
    local build_dir=$1 rootfs_file=$2 homefs_file=$3 checksum_file=$4 manifest_file=$5
    local image_name=$6 image_version=$7 builder_version=$8 compression=$9 source_root=${10}

    CHECKSUM_TEMP_FILE="${checksum_file}.partial"
    MANIFEST_TEMP_FILE="${manifest_file}.partial"
    generate_checksums "${build_dir}" "${rootfs_file}" "${homefs_file}" "${CHECKSUM_TEMP_FILE}"
    validate_checksums "${build_dir}" "${CHECKSUM_TEMP_FILE}"
    generate_manifest "${MANIFEST_TEMP_FILE}" "${image_name}" "${image_version}" \
        "${builder_version}" "${compression}" "${rootfs_file}" "${homefs_file}" "${source_root}"
    validate_manifest "${MANIFEST_TEMP_FILE}" "${rootfs_file}" "${homefs_file}" "${compression}"
    mv -f -- "${CHECKSUM_TEMP_FILE}" "${checksum_file}"
    CHECKSUM_TEMP_FILE=""
    mv -f -- "${MANIFEST_TEMP_FILE}" "${manifest_file}"
    MANIFEST_TEMP_FILE=""
}

main() {
    local config_file="${PROJECT_DIR}/config/image.conf"
    local version_file="${PROJECT_DIR}/VERSION"
    local elapsed rootfs_size homefs_size home_uid home_gid resolved_source_root
    local extension preparation_seconds metadata_seconds metadata_start builder_version

    ui_header

    check_root
    check_dependencies
    check_config_file "${config_file}"
    # shellcheck source=config/image.conf
    source "${config_file}"
    validate_config
    check_compression_dependency "${IMAGE_COMPRESSION}"
    validate_version_file "${version_file}" "${IMAGE_VERSION}"
    builder_version="$(tr -d '[:space:]' < "${version_file}")"
    extension="$(archive_extension "${IMAGE_COMPRESSION}")"
    ROOTFS_FILENAME="rootfs.${extension}"
    HOMEFS_FILENAME="homefs.${extension}"

    OUTPUT_DIR="$(resolve_project_path "${PROJECT_DIR}" "${OUTPUT_DIR}")"
    LOG_DIR="$(resolve_project_path "${PROJECT_DIR}" "${LOG_DIR}")"
    readonly OUTPUT_DIR LOG_DIR

    init_log "${LOG_DIR}"
    log_write INFO "Iniciando build ${IMAGE_NAME}-${IMAGE_VERSION}"
    log_write INFO "Configuração carregada de ${config_file}"

    if [[ "${SOURCE_ROOT}" == auto ]]; then
        [[ "${HOME_SOURCE}" == auto ]] || {
            ui_error "HOME_SOURCE também deve ser 'auto' quando SOURCE_ROOT='auto'"
            return 1
        }
        detect_capture_sources "${HOME_USER}" SOURCE_ROOT HOME_SOURCE
    fi
    resolve_source_root "${SOURCE_ROOT}" resolved_source_root
    if [[ "${resolved_source_root}" != "$(realpath -e -- "${SOURCE_ROOT}")" ]]; then
        log_write INFO "Subvolume @rootfs detectado automaticamente: ${resolved_source_root}"
    fi
    SOURCE_ROOT="${resolved_source_root}"
    readonly SOURCE_ROOT
    readonly HOME_SOURCE
    log_write INFO "Raiz efetiva da captura: ${SOURCE_ROOT}"
    check_source_root "${SOURCE_ROOT}"
    validate_detected_capture_source "${SOURCE_ROOT}"
    prepare_directories "${OUTPUT_DIR}" "${LOG_DIR}"

    BUILD_DIR="${OUTPUT_DIR}/${IMAGE_NAME}-${IMAGE_VERSION}"
    readonly BUILD_DIR
    readonly ROOTFS_FILE="${BUILD_DIR}/${ROOTFS_FILENAME}"
    readonly HOMEFS_FILE="${BUILD_DIR}/${HOMEFS_FILENAME}"
    readonly CHECKSUM_FILE="${BUILD_DIR}/SHA256SUMS"
    readonly MANIFEST_FILE="${BUILD_DIR}/manifest.json"

    prepare_build_directory "${BUILD_DIR}"
    rm -f -- "${CHECKSUM_FILE}" "${MANIFEST_FILE}" \
        "${CHECKSUM_FILE}.partial" "${MANIFEST_FILE}.partial"
    check_destination_filesystem "${SOURCE_ROOT}" "${BUILD_DIR}"
    check_free_space "${BUILD_DIR}" "${MIN_FREE_SPACE_GIB}"
    ui_info "Gerando ${ROOTFS_FILE}"
    log_write INFO "A captura é feita com o sistema ativo e pode refletir alterações concorrentes."
    log_write INFO "Identidades da máquina-modelo serão removidas do rootfs."
    if [[ "${IMAGE_COMPRESSION}" == zstd ]]; then
        log_write INFO "Compressão: zstd; nível: ${ZSTD_LEVEL}"
    else
        log_write INFO "Compressão: gzip; nível padrão do GNU tar"
    fi
    preparation_seconds=$(( SECONDS - START_TIME ))

    build_rootfs_artifact "${SOURCE_ROOT}" "${BUILD_DIR}" "${ROOTFS_FILE}" \
        "${IMAGE_COMPRESSION}" "${ZSTD_LEVEL}"

    detect_home_identity "${HOME_SOURCE}" "${HOME_USER}" home_uid home_gid
    ui_info "Gerando ${HOMEFS_FILE}"
    build_homefs_artifact "${HOME_SOURCE}" "${HOME_USER}" "${home_uid}" "${home_gid}" \
        "${HOMEFS_MAX_SIZE_MIB}" "${BUILD_DIR}" "${HOMEFS_FILE}" \
        "${IMAGE_COMPRESSION}" "${ZSTD_LEVEL}"

    metadata_start=${SECONDS}
    build_metadata_artifacts "${BUILD_DIR}" "${ROOTFS_FILE}" "${HOMEFS_FILE}" \
        "${CHECKSUM_FILE}" "${MANIFEST_FILE}" "${IMAGE_NAME}" "${IMAGE_VERSION}" \
        "${builder_version}" "${IMAGE_COMPRESSION}" "${SOURCE_ROOT}"
    metadata_seconds=$(( SECONDS - metadata_start ))

    cleanup_detected_capture_source

    rootfs_size="$(format_file_size "${ROOTFS_FILE}")"
    homefs_size="$(format_file_size "${HOMEFS_FILE}")"
    elapsed="$(( SECONDS - START_TIME ))"
    BUILD_SUCCEEDED=true

    log_write SUCCESS "Rootfs gerado, generalizado e validado: ${ROOTFS_FILE}"
    log_write SUCCESS "Homefs gerado e validado: ${HOMEFS_FILE}"
    log_write SUCCESS "Metadados gerados e validados: ${CHECKSUM_FILE}, ${MANIFEST_FILE}"
    log_write INFO "Tamanho rootfs: ${rootfs_size}; tamanho homefs: ${homefs_size}"
    log_write INFO "Tempos: preparação=${preparation_seconds}s; rootfs_geração=${ROOTFS_GENERATE_SECONDS}s; rootfs_validação=${ROOTFS_VALIDATE_SECONDS}s; homefs_geração=${HOMEFS_GENERATE_SECONDS}s; homefs_validação=${HOMEFS_VALIDATE_SECONDS}s; metadata=${metadata_seconds}s; total=${elapsed}s"
    ui_success "Build concluído"
    printf 'Rootfs: %s (%s)\nHomefs: %s (%s)\nTempos do build:\n  Preparação: %ss\n  Rootfs: %ss (geração %ss, validação %ss)\n  Homefs: %ss (geração %ss, validação %ss)\n  Metadata: %ss\n  Total: %ss\nLog: %s\n' \
        "${ROOTFS_FILE}" "${rootfs_size}" "${HOMEFS_FILE}" "${homefs_size}" \
        "${preparation_seconds}" "$(( ROOTFS_GENERATE_SECONDS + ROOTFS_VALIDATE_SECONDS ))" \
        "${ROOTFS_GENERATE_SECONDS}" "${ROOTFS_VALIDATE_SECONDS}" \
        "$(( HOMEFS_GENERATE_SECONDS + HOMEFS_VALIDATE_SECONDS ))" \
        "${HOMEFS_GENERATE_SECONDS}" "${HOMEFS_VALIDATE_SECONDS}" \
        "${metadata_seconds}" "${elapsed}" "${LOG_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
