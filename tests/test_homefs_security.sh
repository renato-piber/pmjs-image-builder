#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${PROJECT_DIR}/lib/archive.sh"
source "${PROJECT_DIR}/lib/homefs.sh"

ui_error() { :; }

test_root="$(mktemp -d)"
trap '[[ -n "${test_root:-}" && "${test_root}" == /tmp/* ]] && rm -rf -- "${test_root}"' EXIT
home_user="$(id -un)"
home_uid="$(id -u)"
home_gid="$(id -g)"
home_source="${test_root}/${home_user}"
mkdir -p -- "${home_source}/.config/autostart" "${test_root}/outside"
ln -s -- "${test_root}/outside" "${home_source}/.config/autostart/external"
if validate_homefs_source_symlinks "${home_source}" "${home_source}/.config/autostart"; then
    printf 'Symlink externo foi aceito\n' >&2
    exit 1
fi

mkdir -p -- "${home_source}/Desktop"
touch -- "${test_root}/outside/target.desktop"
ln -s -- "${test_root}/outside/target.desktop" "${home_source}/Desktop/link.desktop"
desktop_staging=""
standard_directories=(Desktop)
if prepare_homefs_staging "${home_source}" "${home_user}" "${home_uid}" "${home_gid}" \
    standard_directories desktop_staging; then
    printf 'Symlink *.desktop foi aceito\n' >&2
    exit 1
fi
[[ -z "${desktop_staging}" ]] || cleanup_homefs_staging "${desktop_staging}"

staging="${test_root}/staging"
mkdir -p -- "${staging}/${home_user}/.config/autostart" "${staging}/${home_user}/Desktop"
mkfifo -- "${staging}/${home_user}/.config/autostart/channel"
if validate_homefs_staging "${staging}" "${home_user}" "${home_uid}" "${home_gid}" \
    1 Desktop; then
    printf 'FIFO foi aceito no staging\n' >&2
    exit 1
fi

find -P "${staging}" -depth -delete
mkdir -p -- "${test_root}/wrong/home/${home_user}"
wrong_archive="${test_root}/wrong.tar.gz"
tar --create --gzip --file "${wrong_archive}" --directory="${test_root}/wrong" home
if validate_homefs_archive "${wrong_archive}" "${home_user}" Desktop; then
    printf 'Archive com raiz home/ foi aceito\n' >&2
    exit 1
fi

printf 'OK: homefs rejeitou symlink externo, FIFO e raiz incorreta\n'
