#!/bin/bash

set -euo pipefail

: "${TZ:-Europe/Prague}"
SCRIPT_DIR=$(realpath "$(dirname "$0")")
CONTAINER_CLI="${CONTAINER_CLI:-podman}"
trap "popd >> /dev/null" EXIT
pushd "$SCRIPT_DIR/.." >> /dev/null || {
  echo "Error: Failed to change directory to $SCRIPT_DIR/.."
  exit 1
}

if [ ! -f ./dist/codex.tgz ]; then
  echo "Error: ./dist/codex.tgz is missing." >&2
  echo "Run ./gen-dist.sh first to stage the Codex archive used by the container build." >&2
  exit 1
fi

"${CONTAINER_CLI}" build -t codex -f "./Dockerfile" .
"${CONTAINER_CLI}" build -t codex-firewall -f "./Dockerfile.firewall" .
