#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONDONTWRITEBYTECODE=1 python3 "${TEST_DIR}/test_image_naming.py"
