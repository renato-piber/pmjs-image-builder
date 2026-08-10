#!/usr/bin/env bash

build_tar_command() {
    local source_root=$1
    local build_dir=$2
    local archive_file=$3
    local output_pattern
    local -n command_ref=$4

    output_pattern="$(realpath -m --relative-to="${source_root}" "${build_dir}")"
    output_pattern="./${output_pattern#./}"

    command_ref=(
        tar
        --create
        --gzip
        --file "${archive_file}"
        --numeric-owner
        --acls
        --xattrs
        --one-file-system
        --exclude='./proc'
        --exclude='./sys'
        --exclude='./dev'
        --exclude='./run'
        --exclude='./tmp/*'
        --exclude='./var/tmp/*'
        --exclude='./mnt/*'
        --exclude='./media/*'
        --exclude='./home/*'
        --exclude='./lost+found'
        --exclude="${output_pattern}"
        --exclude="${output_pattern}/*"
        --directory="${source_root}"
        .
    )
}

generate_rootfs() {
    local source_root=$1
    local build_dir=$2
    local archive_file=$3
    local -a tar_command

    build_tar_command "${source_root}" "${build_dir}" "${archive_file}" tar_command
    log_write INFO "Executando GNU tar para capturar ${source_root}"
    "${tar_command[@]}" 2> >(while IFS= read -r line; do log_write WARN "tar: ${line}"; done)
}

validate_rootfs() {
    local archive_file=$1
    local source_root=$2
    local build_dir=$3
    local entry
    local output_pattern

    output_pattern="$(realpath -m --relative-to="${source_root}" "${build_dir}")"
    output_pattern="./${output_pattern#./}"

    [[ -s "${archive_file}" ]] || {
        ui_error "O rootfs gerado está vazio: ${archive_file}"
        return 1
    }
    gzip -t -- "${archive_file}" || {
        ui_error "Falha na integridade gzip: ${archive_file}"
        return 1
    }

    while IFS= read -r entry; do
        if [[ "${entry}" == "${output_pattern}" ||
              "${entry}" == "${output_pattern}/"* ]]; then
            ui_error "O diretório de saída foi encontrado no archive: ${entry}"
            return 1
        fi
        case "${entry}" in
            ./proc|./proc/*|./sys|./sys/*|./dev|./dev/*|./run|./run/*|\
            ./tmp/?*|./var/tmp/?*|./mnt/?*|./media/?*|./home/?*|\
            ./lost+found|./lost+found/*)
                ui_error "Conteúdo proibido encontrado no archive: ${entry}"
                return 1
                ;;
        esac
    done < <(tar --list --gzip --file "${archive_file}")

    tar --list --gzip --file "${archive_file}" >/dev/null
    log_write INFO "Integridade e exclusões do rootfs validadas"
}

format_file_size() {
    local file=$1
    local bytes

    bytes="$(stat -c '%s' -- "${file}")"
    if (( bytes >= 1024 * 1024 * 1024 )); then
        awk -v bytes="${bytes}" 'BEGIN { printf "%.2f GiB", bytes / 1073741824 }'
    elif (( bytes >= 1024 * 1024 )); then
        awk -v bytes="${bytes}" 'BEGIN { printf "%.2f MiB", bytes / 1048576 }'
    else
        awk -v bytes="${bytes}" 'BEGIN { printf "%.2f KiB", bytes / 1024 }'
    fi
}
