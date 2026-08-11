#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_PROJECT_DIR}/build-image.sh"

integration_root="$(mktemp -d)"
trap '[[ -n "${integration_root:-}" && "${integration_root}" == /tmp/* ]] && rm -rf -- "${integration_root}"' EXIT

if getent passwd usuario >/dev/null; then
    home_user=usuario
else
    home_user="$(id -un)"
fi
home_uid="$(id -u -- "${home_user}")"
home_gid="$(id -g -- "${home_user}")"
home_source="${integration_root}/${home_user}"
build_dir="${integration_root}/build"
archive_file="${build_dir}/homefs.tar.gz"
mkdir -p -- \
    "${home_source}/.config/autostart" \
    "${home_source}/.config/dconf" \
    "${home_source}/.config/google-chrome/OptGuideOnDeviceModel" \
    "${home_source}/.local/share/applications" \
    "${home_source}/.local/share/Trash/files" \
    "${home_source}/.cache" \
    "${home_source}/.mozilla" \
    "${home_source}/Área de Trabalho" \
    "${home_source}/Downloads" \
    "${home_source}/Imagens" \
    "${build_dir}" \
    "${integration_root}/logs"
printf '%s\n' '[Desktop Entry]' > "${home_source}/.config/autostart/institucional.desktop"
printf '%s\n' 'dconf-data' > "${home_source}/.config/dconf/user"
printf '%s\n' '[Desktop Entry]' > "${home_source}/.local/share/applications/app.desktop"
printf '%s\n' '[Desktop Entry]' > "${home_source}/.local/share/applications/google-chrome.desktop"
printf '%s\n' 'chrome-model' > "${home_source}/.config/google-chrome/OptGuideOnDeviceModel/model.bin"
printf '%s\n' 'trash' > "${home_source}/.local/share/Trash/files/pessoal.txt"
printf '%s\n' 'cache' > "${home_source}/.cache/cache.bin"
printf '%s\n' 'firefox' > "${home_source}/.mozilla/profile"
printf '%s\n' 'history' > "${home_source}/.bash_history"
printf '%s\n' 'personal' > "${home_source}/arquivo-pessoal.txt"
printf '%s\n' 'download real' > "${home_source}/Downloads/arquivo.iso"
printf '%s\n' 'imagem pessoal' > "${home_source}/Imagens/foto.jpg"
cat > "${home_source}/.config/user-dirs.dirs" <<'EOF'
XDG_DESKTOP_DIR="$HOME/Área de Trabalho"
XDG_DOCUMENTS_DIR="$HOME/Documentos"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_PICTURES_DIR="$HOME/Imagens"
XDG_MUSIC_DIR="$HOME/Música"
XDG_VIDEOS_DIR="$HOME/Vídeos"
XDG_PUBLICSHARE_DIR="$HOME/Público"
XDG_TEMPLATES_DIR="$HOME/Modelos"
EOF

if (( EUID == 0 )); then
    chown -R -- "${home_uid}:${home_gid}" "${home_source}"
    chown -- 0:0 "${home_source}/.local/share/applications/google-chrome.desktop"
fi

init_log "${integration_root}/logs"
build_homefs_artifact "${home_source}" "${home_user}" "${home_uid}" "${home_gid}" \
    16 "${build_dir}" "${archive_file}"
staging_path="$(awk -F': ' '/Staging do homefs:/ { value=$NF } END { print value }' "${LOG_FILE}")"
[[ "$(dirname -- "${staging_path}")" == /var/tmp || "$(dirname -- "${staging_path}")" == /tmp ]]
[[ "${staging_path}" != "${build_dir}" && "${staging_path}" != "${build_dir}/"* ]]
grep -Fq -- 'Filesystem do staging do homefs:' "${LOG_FILE}"
grep -Fq -- "Archive final do homefs: ${archive_file}" "${LOG_FILE}"
mapfile -t entries < <(tar --list --gzip --file "${archive_file}")
printf '%s\n' "${entries[@]}"

[[ "${entries[0]%/}" == "${home_user}" ]]
for required in \
    "${home_user}/.config/autostart/institucional.desktop" \
    "${home_user}/.config/dconf/user" \
    "${home_user}/.local/share/applications/app.desktop" \
    "${home_user}/.local/share/applications/google-chrome.desktop" \
    "${home_user}/Área de Trabalho/" \
    "${home_user}/Documentos/" \
    "${home_user}/Downloads/" \
    "${home_user}/Imagens/" \
    "${home_user}/Música/" \
    "${home_user}/Vídeos/" \
    "${home_user}/Público/" \
    "${home_user}/Modelos/"; do
    printf '%s\n' "${entries[@]}" | grep -Fqx -- "${required}"
done

for forbidden_fragment in \
    'home/' '.config/google-chrome' '.mozilla' '.cache' '.local/share/Trash' \
    '.bash_history' 'arquivo-pessoal.txt' 'arquivo.iso' 'foto.jpg'; do
    if printf '%s\n' "${entries[@]}" | grep -Fq -- "${forbidden_fragment}"; then
        printf 'Conteúdo proibido no homefs: %s\n' "${forbidden_fragment}" >&2
        exit 1
    fi
done

profile_owner="$(tar --list --verbose --numeric-owner --gzip --file "${archive_file}" "${home_user}/" | awk 'NR == 1 { print $2 }')"
[[ "${profile_owner}" == "${home_uid}/${home_gid}" ]]
if (( EUID == 0 )); then
    chrome_owner="$(tar --list --verbose --numeric-owner --gzip --file "${archive_file}" \
        "${home_user}/.local/share/applications/google-chrome.desktop" | awk 'NR == 1 { print $2 }')"
    [[ "${chrome_owner}" == 0/0 ]]
    grep -Fq -- "Owner preservado da whitelist: ${home_user}/.local/share/applications/google-chrome.desktop (0:0)" "${LOG_FILE}"
fi

printf 'OK: fluxo integrado do homefs respeitou raiz, whitelist e diretórios vazios\n'
