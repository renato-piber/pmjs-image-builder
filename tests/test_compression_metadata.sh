#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_PROJECT_DIR}/build-image.sh"

ui_error() { printf 'ERRO: %s\n' "$*" >&2; }

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT
mkdir -p -- "${test_root}/logs"
init_log "${test_root}/logs"

root_reads=0
root_decompressions=0
home_reads=0
home_decompressions=0
derive_build_io_pass_counts false root_reads root_decompressions home_reads home_decompressions
[[ "${root_reads}:${root_decompressions}:${home_reads}:${home_decompressions}" == 7:5:6:4 ]]
derive_build_io_pass_counts true root_reads root_decompressions home_reads home_decompressions
[[ "${root_reads}:${root_decompressions}:${home_reads}:${home_decompressions}" == 14:9:13:8 ]]

# VERSION identifica o software Builder; IMAGE_VERSION identifica somente o
# artefato produzido. Uma divergência deliberada não pode bloquear o build.
printf '%s\n' '1.2.3-builder' > "${test_root}/VERSION"
IMAGE_VERSION=9.8.7-image
builder_version=""
load_builder_version "${test_root}/VERSION" builder_version
[[ "${builder_version}" == 1.2.3-builder ]]
[[ "${IMAGE_VERSION}" == 9.8.7-image ]]

source_root="${test_root}/source"
staging="${test_root}/home-staging"
build_dir="${test_root}/build"
mkdir -p -- "${source_root}/etc/ssh" "${source_root}/etc/ocsinventory" \
    "${source_root}/usr/sbin" "${source_root}/var/lib/dbus" "${build_dir}" \
    "${staging}/usuario"/{Desktop,Documentos,Downloads,Imagens,Música,Vídeos,Público,Modelos}
touch -- "${source_root}/etc/passwd" "${source_root}/etc/group" \
    "${source_root}/etc/hostname" "${source_root}/etc/ssh/sshd_config" \
    "${source_root}/etc/ocsinventory/ocsinventory-agent.cfg" \
    "${source_root}/etc/x11vnc.pass" "${source_root}/usr/sbin/sshd"
printf '%s\n' 'PRETTY_NAME="PMJS Test"' > "${source_root}/etc/os-release"
printf '%s\n' 'model-id' > "${source_root}/etc/machine-id"
ln -s -- /etc/machine-id "${source_root}/var/lib/dbus/machine-id"

for compression in gzip zstd; do
    extension="$(archive_extension "${compression}")"
    root_archive="${build_dir}/rootfs.${extension}"
    home_archive="${build_dir}/homefs.${extension}"
    generalization_staging=""
    prepare_generalization_staging "${build_dir}" generalization_staging
    generate_rootfs "${source_root}" "${build_dir}" "${root_archive}" \
        "${generalization_staging}" "${compression}" 3
    validate_rootfs "${root_archive}" "${source_root}" "${build_dir}" "${compression}"
    cleanup_generalization_staging "${generalization_staging}" "${build_dir}"

    IMAGE_COMPRESSION=${compression}
    generate_homefs "${staging}" usuario "${home_archive}" "${compression}" 3
    validate_homefs_archive "${home_archive}" usuario \
        Desktop Documentos Downloads Imagens Música Vídeos Público Modelos
    [[ -s "${root_archive}" && -s "${home_archive}" ]]
    if [[ "${compression}" == gzip ]]; then
        gzip_checksums="${build_dir}/SHA256SUMS.gzip"
        generate_checksums "${build_dir}" "${root_archive}" "${home_archive}" \
            "${gzip_checksums}"
        validate_checksums "${build_dir}" "${gzip_checksums}"
    fi
done

IMAGE_COMPRESSION=zstd
root_archive="${build_dir}/rootfs.tar.zst"
home_archive="${build_dir}/homefs.tar.zst"
checksums="${build_dir}/SHA256SUMS"
manifest="${build_dir}/manifest.json"
sha_events="${test_root}/metadata-sha-events"
sha256sum() {
    printf '%s\n' "$*" >> "${sha_events}"
    command sha256sum "$@"
}
build_metadata_artifacts "${build_dir}" "${root_archive}" "${home_archive}" \
    "${checksums}" "${manifest}" pmjs-linux "${IMAGE_VERSION}" \
    "${builder_version}" zstd "${source_root}"
unset -f sha256sum
[[ "$(wc -l < "${sha_events}")" -eq 1 ]]
mapfile -t checksum_hashes < <(awk '{print $1}' "${checksums}")
mapfile -t manifest_hashes < <(python3 - "${manifest}" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
print(data["rootfs"]["sha256"])
print(data["homefs"]["sha256"])
PY
)
[[ "${checksum_hashes[0]}" == "${manifest_hashes[0]}" ]]
[[ "${checksum_hashes[1]}" == "${manifest_hashes[1]}" ]]
validate_checksums "${build_dir}" "${checksums}"
validate_manifest "${manifest}" "${root_archive}" "${home_archive}" zstd
grep -Fq -- 'rootfs.tar.zst' "${manifest}"
grep -Fq -- 'homefs.tar.zst' "${manifest}"
grep -Fq -- '"image_version": "9.8.7-image"' "${manifest}"
grep -Fq -- '"builder_version": "1.2.3-builder"' "${manifest}"
! grep -Fq -- '.partial' "${checksums}"
[[ ! -e "${checksums}.partial" && ! -e "${manifest}.partial" ]]

copy_valid_bundle() {
    local parent=$1 bundle filename
    bundle="${parent}/pmjs-linux-${IMAGE_VERSION}"
    mkdir -p -- "${bundle}"
    for filename in rootfs.tar.zst homefs.tar.zst SHA256SUMS manifest.json; do
        cp -- "${build_dir}/${filename}" "${bundle}/${filename}"
    done
    printf '%s\n' "${bundle}"
}

valid_bundle="$(copy_valid_bundle "${test_root}/valid")"
validate_image_directory "${valid_bundle}"

corrupt_root_bundle="$(copy_valid_bundle "${test_root}/corrupt-root")"
printf 'corrupção-root\n' >> "${corrupt_root_bundle}/rootfs.tar.zst"
if validate_image_directory "${corrupt_root_bundle}" >/dev/null 2>&1; then
    printf 'Corrupção do rootfs foi aceita\n' >&2
    exit 1
fi

corrupt_home_bundle="$(copy_valid_bundle "${test_root}/corrupt-home")"
printf 'corrupção-home\n' >> "${corrupt_home_bundle}/homefs.tar.zst"
if validate_image_directory "${corrupt_home_bundle}" >/dev/null 2>&1; then
    printf 'Corrupção do homefs foi aceita\n' >&2
    exit 1
fi

truncated_bundle="$(copy_valid_bundle "${test_root}/truncated")"
truncate -s -1 -- "${truncated_bundle}/rootfs.tar.zst"
if validate_image_directory "${truncated_bundle}" >/dev/null 2>&1; then
    printf 'Archive truncado foi aceito\n' >&2
    exit 1
fi

printf 'corrupção\n' >> "${root_archive}"
if validate_checksums "${build_dir}" "${checksums}" >/dev/null 2>&1; then
    printf 'Checksum incorreto foi aceito\n' >&2
    exit 1
fi
grep -Eq -- '\[PERF\] metadata.sha256sums.generate end .*status=0 .*throughput_mib_s=' "${LOG_FILE}"
grep -Eq -- '\[PERF\] metadata.sha256sums.verify end .*status=1' "${LOG_FILE}"
grep -Eq -- '\[PERF\] metadata.sha256sums.verify.reused end .*status=0 .*access=no_archive_read' "${LOG_FILE}"
grep -Eq -- '\[PERF\] metadata.manifest.hashes.reused end .*status=0 .*access=no_archive_read' "${LOG_FILE}"
grep -Eq -- '\[PERF\] metadata.manifest.validate.reused end .*status=0 .*access=no_archive_read' "${LOG_FILE}"
grep -Eq -- '\[PERF\] metadata.manifest.validate end .*status=0 .*access=two_full_reads' "${LOG_FILE}"

(
    command() {
        if [[ "$1" == -v && "$2" == zstd ]]; then return 1; fi
        builtin command "$@"
    }
    if check_compression_dependency zstd; then
        printf 'Ausência de zstd foi aceita\n' >&2
        exit 1
    fi
)

(
    # O suporte gzip permanece nos helpers, mas não no formato publicável.
    source "${TEST_PROJECT_DIR}/config/image.conf"
    IMAGE_COMPRESSION=gzip
    if validate_config; then
        printf 'Configuração publicável aceitou gzip\n' >&2
        exit 1
    fi
)

printf 'OK: gzip, zstd, extensões, checksums e manifest validados\n'
