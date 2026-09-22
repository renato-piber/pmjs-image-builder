#!/usr/bin/env bash

# Instrumenta operacoes sem ler o conteudo medido. Os dados de tamanho e
# filesystem abaixo usam somente metadados (stat). Quando o consumidor nao
# carregou o logger, como em alguns testes unitarios das bibliotecas, as
# funcoes continuam neutras.

perf_emit() {
    declare -F log_write >/dev/null || return 0
    log_write PERF "$*"
}

perf_now_ns() {
    date '+%s%N'
}

perf_archive_context() {
    local archive=$1 prefix=${2:-archive}
    local size_bytes filesystem quoted_archive quoted_filesystem

    [[ -e "${archive}" ]] || {
        printf '%s=%q size_bytes=unknown filesystem=unknown' "${prefix}" "${archive}"
        return 0
    }
    size_bytes="$(stat -c '%s' -- "${archive}" 2>/dev/null || true)"
    filesystem="$(stat --file-system --format='%T' -- "${archive}" 2>/dev/null || true)"
    printf -v quoted_archive '%q' "${archive}"
    printf -v quoted_filesystem '%q' "${filesystem:-unknown}"
    printf '%s=%s size_bytes=%s filesystem=%s' \
        "${prefix}" "${quoted_archive}" "${size_bytes:-unknown}" "${quoted_filesystem}"
}

perf_archives_context() {
    local rootfs_file=$1 homefs_file=$2
    local rootfs_size homefs_size rootfs_fs homefs_fs quoted_rootfs quoted_homefs

    rootfs_size="$(stat -c '%s' -- "${rootfs_file}" 2>/dev/null || true)"
    homefs_size="$(stat -c '%s' -- "${homefs_file}" 2>/dev/null || true)"
    rootfs_fs="$(stat --file-system --format='%T' -- "${rootfs_file}" 2>/dev/null || true)"
    homefs_fs="$(stat --file-system --format='%T' -- "${homefs_file}" 2>/dev/null || true)"
    printf -v quoted_rootfs '%q' "${rootfs_file}"
    printf -v quoted_homefs '%q' "${homefs_file}"
    printf 'rootfs_archive=%s rootfs_size_bytes=%s rootfs_filesystem=%q homefs_archive=%s homefs_size_bytes=%s homefs_filesystem=%q' \
        "${quoted_rootfs}" "${rootfs_size:-unknown}" "${rootfs_fs:-unknown}" \
        "${quoted_homefs}" "${homefs_size:-unknown}" "${homefs_fs:-unknown}"
}

perf_operation_start() {
    local operation=$1 start_ref=$2
    shift 2
    printf -v "${start_ref}" '%s' "$(perf_now_ns)"
    perf_emit "${operation} start${*:+ $*}"
}

perf_operation_end() {
    local operation=$1 started_ns=$2 status=$3 size_bytes=${4:-}
    local throughput_basis=${5:-none}
    shift 5 || true
    local ended_ns elapsed throughput="" context=$*

    ended_ns="$(perf_now_ns)"
    elapsed="$(awk -v start="${started_ns}" -v end="${ended_ns}" \
        'BEGIN { value=(end-start)/1000000000; if (value < 0) value=0; printf "%.3f", value }')"
    if [[ "${size_bytes}" =~ ^[0-9]+$ ]]; then
        throughput="$(awk -v bytes="${size_bytes}" -v seconds="${elapsed}" \
            'BEGIN { if (seconds > 0) printf "%.2f", bytes / 1048576 / seconds; else printf "unknown" }')"
    fi
    perf_emit "${operation} end elapsed=${elapsed}s status=${status}" \
        "${throughput:+throughput_mib_s=${throughput} }" \
        "throughput_basis=${throughput_basis}${context:+ ${context}}"
}
