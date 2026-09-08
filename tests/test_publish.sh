#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${PROJECT_DIR}/lib/ui.sh"
source "${PROJECT_DIR}/lib/archive.sh"
source "${PROJECT_DIR}/lib/checks.sh"
source "${PROJECT_DIR}/lib/metadata.sh"
source "${PROJECT_DIR}/lib/publish.sh"

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT

image_dir="${test_root}/pmjs-linux-0.1.0"
root_content="${test_root}/root"
home_content="${test_root}/home"
source_root="${test_root}/source"
destination="${test_root}/destination"
mkdir -p -- "${image_dir}" "${root_content}/etc" "${home_content}/usuario" \
    "${source_root}/etc" "${destination}"
printf '%s\n' test > "${root_content}/etc/issue"
printf '%s\n' profile > "${home_content}/usuario/profile"
printf '%s\n' 'PRETTY_NAME="PMJS Test"' > "${source_root}/etc/os-release"
tar --create --zstd --file "${image_dir}/rootfs.tar.zst" --directory="${root_content}" .
tar --create --zstd --file "${image_dir}/homefs.tar.zst" --directory="${home_content}" usuario
generate_checksums "${image_dir}" "${image_dir}/rootfs.tar.zst" \
    "${image_dir}/homefs.tar.zst" "${image_dir}/SHA256SUMS"
generate_manifest "${image_dir}/manifest.json" pmjs-linux 0.1.0 0.1.0 zstd \
    "${image_dir}/rootfs.tar.zst" "${image_dir}/homefs.tar.zst" "${source_root}"
validate_image_directory "${image_dir}"

local_output="${test_root}/local-output"
mkdir -- "${local_output}"
check_local_staging_filesystem "${local_output}"
(
    stat() {
        if [[ "$*" == *--file-system* ]]; then
            printf '%s\n' nfs
        else
            command stat "$@"
        fi
    }
    if check_local_staging_filesystem "${local_output}" >/dev/null 2>&1; then
        printf 'Staging NFS foi aceito como local\n' >&2
        exit 1
    fi
)
local_workspace=""
local_final=""
prepare_build_workspace "${local_output}" pmjs-linux-0.1.0 \
    local_workspace local_final
for filename in rootfs.tar.zst homefs.tar.zst SHA256SUMS manifest.json; do
    cp -- "${image_dir}/${filename}" "${local_workspace}/${filename}"
done
validate_image_directory "${local_workspace}"
finalize_build_workspace "${local_workspace}" "${local_final}"
[[ -d "${local_final}" && ! -e "${local_workspace}" ]]

publication_staging=""
prepare_image_publication "${image_dir}" "${destination}" publication_staging
[[ -d "${publication_staging}" ]]
[[ ! -e "${destination}/pmjs-linux-0.1.0" ]]
validate_image_directory "${publication_staging}"
commit_image_publication "${publication_staging}" "${destination}"
publication_staging=""
[[ -d "${destination}/pmjs-linux-0.1.0" ]]
validate_image_directory "${destination}/pmjs-linux-0.1.0"

if prepare_image_publication "${image_dir}" "${destination}" publication_staging; then
    printf 'Versão publicada foi substituída\n' >&2
    exit 1
fi

cp -a -- "${image_dir}" "${test_root}/invalid-name"
if validate_image_directory "${test_root}/invalid-name" >/dev/null 2>&1; then
    printf 'Diretório com identidade divergente foi aceito\n' >&2
    exit 1
fi

tampered_parent="${test_root}/tampered"
mkdir -- "${tampered_parent}"
cp -a -- "${image_dir}" "${tampered_parent}/pmjs-linux-0.1.0"
sed -i '0,/"sha256":/s/"sha256": "./"sha256": "x/' \
    "${tampered_parent}/pmjs-linux-0.1.0/manifest.json"
if validate_image_directory "${tampered_parent}/pmjs-linux-0.1.0" >/dev/null 2>&1; then
    printf 'Manifest divergente dos archives foi aceito\n' >&2
    exit 1
fi

ventoy_dir="${test_root}/pmjs-images"
mkdir -- "${ventoy_dir}"
findmnt() {
    case "$*" in
        *FSTYPE*) printf '%s\n' exfat ;;
        *TARGET*) printf '%s\n' /media/ventoy ;;
    esac
}
validate_publish_destination ventoy "${ventoy_dir}"
if validate_publish_destination ventoy "${destination}" >/dev/null 2>&1; then
    printf 'Destino Ventoy sem nome pmjs-images foi aceito\n' >&2
    exit 1
fi
if validate_publish_destination nfs "${destination}" >/dev/null 2>&1; then
    printf 'Destino não NFS foi aceito como NFS\n' >&2
    exit 1
fi

findmnt() {
    case "$*" in
        *FSTYPE*) printf '%s\n' nfs4 ;;
        *TARGET*) printf '%s\n' /mnt/pmjs-nfs ;;
    esac
}
validate_publish_destination nfs "${destination}"

fake_bin="${test_root}/fake-bin"
end_to_end_ventoy="${test_root}/mounted/pmjs-images"
mkdir -p -- "${fake_bin}" "${end_to_end_ventoy}"
cat > "${fake_bin}/findmnt" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *FSTYPE*) printf '%s\n' exfat ;;
    *TARGET*) printf '%s\n' /media/ventoy ;;
esac
EOF
chmod +x -- "${fake_bin}/findmnt"
PATH="${fake_bin}:${PATH}" "${PROJECT_DIR}/publish-image.sh" \
    --image-dir "${image_dir}" --ventoy-dir "${end_to_end_ventoy}"
[[ -d "${end_to_end_ventoy}/pmjs-linux-0.1.0" ]]
validate_image_directory "${end_to_end_ventoy}/pmjs-linux-0.1.0"

first_target="${test_root}/first/pmjs-images"
second_target="${test_root}/second/pmjs-images"
mkdir -p -- "${first_target}" "${second_target}"
cp -a -- "${image_dir}" "${second_target}/pmjs-linux-0.1.0"
if PATH="${fake_bin}:${PATH}" "${PROJECT_DIR}/publish-image.sh" \
    --image-dir "${image_dir}" --ventoy-dir "${first_target}" \
    --ventoy-dir "${second_target}" >/dev/null 2>&1; then
    printf 'Publicação múltipla aceitou uma versão existente\n' >&2
    exit 1
fi
[[ ! -e "${first_target}/pmjs-linux-0.1.0" ]]
[[ -z "$(find "${first_target}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

printf 'OK: formato completo e publicação atômica/imutável validados\n'
