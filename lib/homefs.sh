#!/usr/bin/env bash

readonly -a HOMEFS_WHITELIST=(
    .config/autostart
    .config/dconf
    .config/mate
    .config/menus
    .config/caja
    .config/pluma
    .config/vlc
    .local/share/applications
)

readonly -a HOMEFS_XDG_SPECS=(
    'DESKTOP:Desktop'
    'DOCUMENTS:Documentos'
    'DOWNLOAD:Downloads'
    'PICTURES:Imagens'
    'MUSIC:Música'
    'VIDEOS:Vídeos'
    'PUBLICSHARE:Público'
    'TEMPLATES:Modelos'
)

detect_home_identity() {
    local home_source=$1
    local home_user=$2
    local -n uid_ref=$3
    local -n gid_ref=$4

    [[ -d "${home_source}" && -r "${home_source}" ]] || {
        ui_error "HOME_SOURCE inexistente ou ilegível: ${home_source}"
        return 1
    }
    [[ "$(basename -- "${home_source}")" == "${home_user}" ]] || {
        ui_error "HOME_SOURCE deve terminar com HOME_USER (${home_user})"
        return 1
    }
    getent passwd "${home_user}" >/dev/null || {
        ui_error "Usuário não encontrado: ${home_user}"
        return 1
    }
    uid_ref="$(id -u -- "${home_user}")"
    gid_ref="$(id -g -- "${home_user}")"
    [[ "${uid_ref}" =~ ^[0-9]+$ && "${gid_ref}" =~ ^[0-9]+$ ]] || {
        ui_error "UID/GID inválidos para ${home_user}"
        return 1
    }
}

detect_home_standard_directories() {
    local home_source=$1
    local -n directories_ref=$2
    local config_file="${home_source}/.config/user-dirs.dirs"
    local spec key fallback line candidate
    local -A used=()

    directories_ref=()
    for spec in "${HOMEFS_XDG_SPECS[@]}"; do
        key=${spec%%:*}
        fallback=${spec#*:}
        candidate=""
        if [[ -r "${config_file}" ]]; then
            line="$(grep -E -m1 "^XDG_${key}_DIR=\"\\\$HOME/[^/\"]+\"$" \
                "${config_file}" || true)"
            [[ -z "${line}" ]] || candidate=${line#*\$HOME/}
            candidate=${candidate%\"}
        fi
        [[ -n "${candidate}" && -d "${home_source}/${candidate}" ]] || candidate=${fallback}
        [[ "${candidate}" != . && "${candidate}" != .. && "${candidate}" != */* ]] || {
            ui_error "Nome XDG inseguro detectado: ${candidate}"
            return 1
        }
        if [[ -z "${used[${candidate}]+x}" ]]; then
            directories_ref+=("${candidate}")
            used[${candidate}]=1
        fi
    done
}

validate_homefs_source_symlinks() {
    local home_source=$1
    local approved_path=$2
    local link target resolved

    while IFS= read -r -d '' link; do
        target="$(readlink -- "${link}")"
        if [[ "${target}" == /* ]]; then
            resolved="$(realpath -m -- "${target}")"
        else
            resolved="$(realpath -m -- "$(dirname -- "${link}")/${target}")"
        fi
        [[ "${resolved}" == "${home_source}" || "${resolved}" == "${home_source}/"* ]] || {
            ui_error "Symlink aponta para fora da home: ${link} -> ${target}"
            return 1
        }
    done < <(find -P "${approved_path}" -type l -print0)
}

prepare_homefs_staging() {
    local home_source=$1 home_user=$2 home_uid=$3 home_gid=$4
    local -n standard_directories_ref=$5
    local -n staging_ref=$6
    local relative source_path directory

    if [[ -d /var/tmp && -w /var/tmp ]] &&
       staging_ref="$(mktemp --directory --tmpdir=/var/tmp 'pmjs-homefs-staging.XXXXXX' 2>/dev/null)"; then
        :
    elif [[ -d /tmp && -w /tmp ]] &&
         staging_ref="$(mktemp --directory --tmpdir=/tmp 'pmjs-homefs-staging.XXXXXX')"; then
        :
    else
        ui_error "Não foi possível criar staging local em /var/tmp ou /tmp"
        return 1
    fi
    install -d -m 0755 -o "${home_uid}" -g "${home_gid}" -- "${staging_ref}/${home_user}"

    for relative in "${HOMEFS_WHITELIST[@]}"; do
        source_path="${home_source}/${relative}"
        [[ -e "${source_path}" || -L "${source_path}" ]] || continue
        validate_homefs_source_symlinks "${home_source}" "${source_path}"
        rsync -aAX --numeric-ids \
            --exclude='*.lock' --exclude='*.tmp' --exclude='*~' --exclude='.#*' \
            --relative -- "${home_source}/./${relative}" "${staging_ref}/${home_user}/"
    done

    for directory in "${standard_directories_ref[@]}"; do
        install -d -m 0755 -o "${home_uid}" -g "${home_gid}" -- \
            "${staging_ref}/${home_user}/${directory}"
    done
}

homefs_path_is_allowed() {
    local relative=$1 home_user=$2
    shift 2
    local directory

    case "${relative}" in
        "${home_user}"|"${home_user}/.config"|"${home_user}/.local"|\
        "${home_user}/.local/share"|\
        "${home_user}/.config/autostart"|"${home_user}/.config/autostart/"*|\
        "${home_user}/.config/dconf"|"${home_user}/.config/dconf/"*|\
        "${home_user}/.config/mate"|"${home_user}/.config/mate/"*|\
        "${home_user}/.config/menus"|"${home_user}/.config/menus/"*|\
        "${home_user}/.config/caja"|"${home_user}/.config/caja/"*|\
        "${home_user}/.config/pluma"|"${home_user}/.config/pluma/"*|\
        "${home_user}/.config/vlc"|"${home_user}/.config/vlc/"*|\
        "${home_user}/.local/share/applications"|\
        "${home_user}/.local/share/applications/"*) return 0 ;;
    esac
    for directory in "$@"; do
        [[ "${relative}" == "${home_user}/${directory}" ]] && return 0
    done
    return 1
}

validate_homefs_staging() {
    local staging_dir=$1 home_user=$2 home_uid=$3 home_gid=$4 max_size_mib=$5
    shift 5
    local path relative owner_uid owner_gid size_bytes max_bytes directory

    [[ -d "${staging_dir}/${home_user}" ]] || {
        ui_error "Raiz do usuário ausente no staging: ${home_user}"
        return 1
    }
    owner_uid="$(stat -c '%u' -- "${staging_dir}/${home_user}")"
    owner_gid="$(stat -c '%g' -- "${staging_dir}/${home_user}")"
    [[ "${owner_uid}" == "${home_uid}" && "${owner_gid}" == "${home_gid}" ]] || {
        ui_error "Owner inesperado na raiz do perfil: ${owner_uid}:${owner_gid}"
        return 1
    }
    for directory in "$@"; do
        [[ -d "${staging_dir}/${home_user}/${directory}" ]] || {
            ui_error "Diretório padrão ausente no staging: ${directory}"
            return 1
        }
        owner_uid="$(stat -c '%u' -- "${staging_dir}/${home_user}/${directory}")"
        owner_gid="$(stat -c '%g' -- "${staging_dir}/${home_user}/${directory}")"
        [[ "${owner_uid}" == "${home_uid}" && "${owner_gid}" == "${home_gid}" ]] || {
            ui_error "Owner inesperado no diretório padrão ${directory}: ${owner_uid}:${owner_gid}"
            return 1
        }
    done
    if find -P "${staging_dir}" \( -type s -o -type b -o -type c -o -type p \) -print -quit | grep -q .; then
        ui_error "Socket, device ou FIFO encontrado no staging do homefs"
        return 1
    fi
    if find -P "${staging_dir}" -name $'*\n*' -print -quit | grep -q .; then
        ui_error "Nome com quebra de linha encontrado no staging do homefs"
        return 1
    fi

    while IFS= read -r -d '' path; do
        relative=${path#"${staging_dir}/"}
        homefs_path_is_allowed "${relative}" "${home_user}" "$@" || {
            ui_error "Caminho fora da whitelist no staging: ${relative}"
            return 1
        }
        case "$(basename -- "${relative}")" in
            *.lock|*.tmp|*~|.#*) ui_error "Arquivo temporário/lock no staging: ${relative}"; return 1 ;;
        esac
        owner_uid="$(stat -c '%u' -- "${path}")"
        owner_gid="$(stat -c '%g' -- "${path}")"
        if [[ "${owner_uid}" != "${home_uid}" || "${owner_gid}" != "${home_gid}" ]]; then
            declare -F log_write >/dev/null && \
                log_write WARN "Owner preservado da whitelist: ${relative} (${owner_uid}:${owner_gid})"
        fi
    done < <(find -P "${staging_dir}" -mindepth 1 -print0)

    size_bytes="$(du -sb -- "${staging_dir}" | awk '{print $1}')"
    max_bytes=$(( max_size_mib * 1024 * 1024 ))
    (( size_bytes <= max_bytes )) || {
        ui_error "Staging do homefs excede ${max_size_mib} MiB: ${size_bytes} bytes"
        return 1
    }
}

generate_homefs() {
    local staging_dir=$1 home_user=$2 archive_file=$3
    tar --create --gzip --file "${archive_file}" --numeric-owner --acls --xattrs \
        --directory="${staging_dir}" "${home_user}"
}

validate_homefs_archive() {
    local archive_file=$1 home_user=$2
    shift 2
    local listing entry normalized first_useful="" directory

    [[ -s "${archive_file}" ]] || { ui_error "homefs vazio: ${archive_file}"; return 1; }
    gzip -t -- "${archive_file}" || { ui_error "Falha gzip no homefs: ${archive_file}"; return 1; }
    listing="$(tar --list --gzip --file "${archive_file}")" || {
        ui_error "Falha ao listar homefs: ${archive_file}"
        return 1
    }
    while IFS= read -r entry; do
        normalized=${entry#./}
        normalized=${normalized%/}
        [[ -n "${normalized}" ]] || continue
        [[ -n "${first_useful}" ]] || first_useful=${normalized}
        [[ "${entry}" != /* && "${normalized}" != .. && "${normalized}" != ../* &&
           "${normalized}" != */../* && "${normalized}" != */.. ]] || {
            ui_error "Caminho inseguro no homefs: ${entry}"
            return 1
        }
        [[ "${normalized}" == "${home_user}" || "${normalized}" == "${home_user}/"* ]] || {
            ui_error "Raiz inválida no homefs: ${entry}"
            return 1
        }
        [[ "${normalized}" != home && "${normalized}" != home/* ]] || {
            ui_error "Prefixo home/ proibido no homefs: ${entry}"
            return 1
        }
        homefs_path_is_allowed "${normalized}" "${home_user}" "$@" || {
            ui_error "Entrada fora da whitelist no homefs: ${entry}"
            return 1
        }
    done <<< "${listing}"
    [[ "${first_useful}" == "${home_user}" ]] || {
        ui_error "Primeira raiz útil do homefs não é ${home_user}/"
        return 1
    }
    for directory in "$@"; do
        grep -Fqx -- "${home_user}/${directory}/" <<< "${listing}" || {
            ui_error "Diretório padrão ausente do homefs: ${directory}"
            return 1
        }
    done
    tar --list --gzip --file "${archive_file}" >/dev/null
}

cleanup_homefs_staging() {
    local staging_dir=$1 resolved_staging staging_parent
    [[ -n "${staging_dir}" && -e "${staging_dir}" ]] || return 0
    resolved_staging="$(realpath -m -- "${staging_dir}")"
    staging_parent="$(dirname -- "${resolved_staging}")"
    [[ ( "${staging_parent}" == /var/tmp || "${staging_parent}" == /tmp ) &&
       "$(basename -- "${resolved_staging}")" == pmjs-homefs-staging.* &&
       ! -L "${resolved_staging}" && -d "${resolved_staging}" ]] || {
        ui_error "Recusa ao limpar staging inesperado do homefs: ${staging_dir}"
        return 1
    }
    find -P "${resolved_staging}" -depth -delete
}
