#!/usr/bin/env bash

generate_checksums() {
    local build_dir=$1 rootfs_file=$2 homefs_file=$3 output_file=$4
    (
        cd -- "${build_dir}"
        sha256sum -- "$(basename -- "${rootfs_file}")" "$(basename -- "${homefs_file}")"
    ) > "${output_file}"
}

validate_checksums() {
    local build_dir=$1 checksum_file=$2
    [[ -s "${checksum_file}" ]] || { ui_error "SHA256SUMS vazio"; return 1; }
    [[ $(wc -l < "${checksum_file}") -eq 2 ]] || {
        ui_error "SHA256SUMS deve conter exatamente dois artefatos"
        return 1
    }
    ! grep -Fq -- '.partial' "${checksum_file}" || {
        ui_error "SHA256SUMS contém arquivo temporário"
        return 1
    }
    (cd -- "${build_dir}" && sha256sum --check --strict -- "$(basename -- "${checksum_file}")")
}

generate_manifest() {
    local output_file=$1 image_name=$2 image_version=$3 builder_version=$4
    local compression=$5 rootfs_file=$6 homefs_file=$7 source_root=$8
    local created_at architecture distribution kernel root_hash home_hash

    created_at="$(date --utc '+%Y-%m-%dT%H:%M:%SZ')"
    architecture="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    distribution="$(awk -F= '$1 == "PRETTY_NAME" { value=$2; gsub(/^"|"$/, "", value); print value; exit }' \
        "${source_root}/etc/os-release")"
    kernel="$(uname -r)"
    root_hash="$(sha256sum -- "${rootfs_file}" | awk '{print $1}')"
    home_hash="$(sha256sum -- "${homefs_file}" | awk '{print $1}')"

    python3 - "${output_file}" "${image_name}" "${image_version}" "${created_at}" \
        "${builder_version}" "${compression}" "${rootfs_file}" "${root_hash}" \
        "${homefs_file}" "${home_hash}" "${architecture}" "${distribution}" "${kernel}" <<'PY'
import json
import os
import sys

(output, image_name, image_version, created_at, builder_version, compression,
 rootfs, root_hash, homefs, home_hash, architecture, distribution, kernel) = sys.argv[1:]
manifest = {
    "schema_version": 1,
    "image_name": image_name,
    "image_version": image_version,
    "created_at": created_at,
    "builder_version": builder_version,
    "compression": compression,
    "architecture": architecture,
    "distribution": distribution,
    "builder_kernel": kernel,
    "rootfs": {"filename": os.path.basename(rootfs), "sha256": root_hash,
               "size_bytes": os.path.getsize(rootfs)},
    "homefs": {"filename": os.path.basename(homefs), "sha256": home_hash,
               "size_bytes": os.path.getsize(homefs)},
}
with open(output, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY
}

validate_manifest() {
    local manifest_file=$1 rootfs_file=$2 homefs_file=$3 compression=$4
    python3 - "${manifest_file}" "${rootfs_file}" "${homefs_file}" "${compression}" <<'PY'
import hashlib
import json
import os
import sys

manifest_path, rootfs, homefs, compression = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    data = json.load(stream)
assert data["schema_version"] == 1
assert data["compression"] == compression
for key, path in (("rootfs", rootfs), ("homefs", homefs)):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    assert data[key]["filename"] == os.path.basename(path)
    assert data[key]["size_bytes"] == os.path.getsize(path)
    assert data[key]["sha256"] == digest.hexdigest()
PY
}
