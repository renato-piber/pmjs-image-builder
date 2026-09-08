#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

for test_file in "${TEST_DIR}"/test_*.sh; do
    printf '==> %s\n' "$(basename -- "${test_file}")"
    bash "${test_file}"
done
