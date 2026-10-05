#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(realpath "$(dirname "$0")")
exec python3 "${SCRIPT_DIR}/build-images.py" "$@"
