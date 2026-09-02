#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_PROJECT_DIR}/build-image.sh"

ui_error() { printf 'ERRO: %s\n' "$*" >&2; }
log_write() { :; }

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT
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
done

IMAGE_COMPRESSION=zstd
root_archive="${build_dir}/rootfs.tar.zst"
home_archive="${build_dir}/homefs.tar.zst"
checksums="${build_dir}/SHA256SUMS"
manifest="${build_dir}/manifest.json"
build_metadata_artifacts "${build_dir}" "${root_archive}" "${home_archive}" \
    "${checksums}" "${manifest}" pmjs-linux 0.1.0 0.1.0 zstd "${source_root}"
validate_checksums "${build_dir}" "${checksums}"
validate_manifest "${manifest}" "${root_archive}" "${home_archive}" zstd
grep -Fq -- 'rootfs.tar.zst' "${manifest}"
grep -Fq -- 'homefs.tar.zst' "${manifest}"
! grep -Fq -- '.partial' "${checksums}"
[[ ! -e "${checksums}.partial" && ! -e "${manifest}.partial" ]]

printf 'corrupção\n' >> "${root_archive}"
if validate_checksums "${build_dir}" "${checksums}" >/dev/null 2>&1; then
    printf 'Checksum incorreto foi aceito\n' >&2
    exit 1
fi

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

printf 'OK: gzip, zstd, extensões, checksums e manifest validados\n'
