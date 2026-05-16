#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(realpath "$(dirname "$0")")
CONTAINER_CLI="${CONTAINER_CLI:-podman}"
trap "popd >> /dev/null" EXIT
pushd "$SCRIPT_DIR/.." >> /dev/null || {
  echo "Error: Failed to change directory to $SCRIPT_DIR/.."
  exit 1
}
pnpm install
pnpm run build
rm -rf ./dist/openai-codex-*.tgz
pnpm pack --pack-destination ./dist
mv ./dist/openai-codex-*.tgz ./dist/codex.tgz
"${CONTAINER_CLI}" build -t codex -f "./Dockerfile" .
"${CONTAINER_CLI}" build -t codex-firewall -f "./Dockerfile.firewall" .
