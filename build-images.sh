#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(realpath "$(dirname "$0")")
CONTAINER_CLI="${CONTAINER_CLI:-buildah}"
DNF_CACHE_DIR="${DNF_CACHE_DIR:-${SCRIPT_DIR}/.build-cache/dnf-fedora-44}"
GENERATED_DOCKERFILE="${SCRIPT_DIR}/.build-cache/Dockerfile.runtime"
trap "popd >> /dev/null" EXIT
pushd "$SCRIPT_DIR" >> /dev/null || {
  echo "Error: Failed to change directory to $SCRIPT_DIR"
  exit 1
}

if [ ! -f ./dist/codex.tgz ]; then
  echo "Error: ./dist/codex.tgz is missing." >&2
  echo "Run ./gen-dist.sh first to stage the Codex archive used by the container build." >&2
  exit 1
fi

case "${CONTAINER_CLI}" in
  buildah)
    BUILD_COMMAND=(buildah bud)
    ;;
  podman)
    BUILD_COMMAND=(podman build)
    ;;
  *)
    echo "Error: unsupported CONTAINER_CLI=${CONTAINER_CLI}." >&2
    echo "Set CONTAINER_CLI=buildah or CONTAINER_CLI=podman." >&2
    exit 1
    ;;
esac

mkdir -p "${DNF_CACHE_DIR}/dnf" "${DNF_CACHE_DIR}/libdnf5" "$(dirname "${GENERATED_DOCKERFILE}")"

generate_runtime_dockerfile() {
  local found_marker=0
  local dep_file
  local dep_files

  shopt -s nullglob
  dep_files=(container-deps/*.dnf)
  shopt -u nullglob

  if [ "${#dep_files[@]}" -eq 0 ]; then
    echo "Error: no DNF dependency drop-ins found under container-deps/*.dnf" >&2
    exit 1
  fi

  {
    while IFS= read -r line || [ -n "${line}" ]; do
      if [ "${line}" = "# DNF_DROPINS" ]; then
        found_marker=1
        for dep_file in "${dep_files[@]}"; do
          printf '# %s\n' "${dep_file}"
          printf 'RUN printf '\''Installing DNF drop-in: %s\\n'\'' \\\n' "${dep_file}"
          printf '  && dnf -y install --setopt=install_weak_deps=False \\\n'
          awk '
            {
              sub(/[[:space:]]*#.*/, "")
              gsub(/^[[:space:]]+|[[:space:]]+$/, "")
              if ($0 != "") {
                packages[++count] = $0
              }
            }
            END {
              if (count == 0) {
                exit 1
              }
              for (i = 1; i <= count; i++) {
                printf "    %s \\\n", packages[i]
              }
            }
          ' "${dep_file}" || {
            echo "Error: ${dep_file} does not list any packages." >&2
            exit 1
          }
          printf '  && true\n\n'
        done
      else
        printf '%s\n' "${line}"
      fi
    done < ./Dockerfile.in
  } > "${GENERATED_DOCKERFILE}"

  if [ "${found_marker}" -ne 1 ]; then
    echo "Error: Dockerfile.in is missing the # DNF_DROPINS marker." >&2
    exit 1
  fi
}

generate_runtime_dockerfile

runtime_build_args=(
  --layers
  -t codex
  -f "${GENERATED_DOCKERFILE}"
)

runtime_build_args+=(
  --volume "${DNF_CACHE_DIR}/dnf:/var/cache/dnf:Z,rw"
  --volume "${DNF_CACHE_DIR}/libdnf5:/var/cache/libdnf5:Z,rw"
)

"${BUILD_COMMAND[@]}" "${runtime_build_args[@]}" .
"${BUILD_COMMAND[@]}" --layers -t codex-firewall -f "./Dockerfile.firewall" .
