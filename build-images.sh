#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(realpath "$(dirname "$0")")
CONTAINER_CLI="${CONTAINER_CLI:-buildah}"
DNF_CACHE_DIR="${DNF_CACHE_DIR:-${SCRIPT_DIR}/.build-cache/dnf-fedora-44}"
GENERATED_DOCKERFILE="${SCRIPT_DIR}/.build-cache/Dockerfile.runtime"
GENERATED_ANSIBLE_COLLECTIONS="${SCRIPT_DIR}/.build-cache/ansible-collections.yml"
CODEX_FIREWALL_DNS_TOOL="${CODEX_FIREWALL_DNS_TOOL:-dig}"
SOPS_VERSION="${SOPS_VERSION:-latest}"
CODEX_PACKAGE_VERSION=""
CODEX_ARTIFACT_TYPE_FOR_BUILD=""
CALLER_CODEX_ARTIFACT_TYPE="${CODEX_ARTIFACT_TYPE:-}"
trap "popd >> /dev/null" EXIT
pushd "$SCRIPT_DIR" >> /dev/null || {
  echo "Error: Failed to change directory to $SCRIPT_DIR"
  exit 1
}

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scripts/codex-artifact-common.sh"

BUILD_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --batch|--non-interactive)
      CODEX_CONTAINER_BATCH=1
      shift
      ;;
    help|-h|--help)
      cat <<'EOF'
Usage:
  build-images.sh [--batch|--non-interactive]

Builds the runtime and firewall images from dist/codex.tgz.

Environment:
  CODEX_FIREWALL_DNS_TOOL=dig|kdig|drill  DNS resolver installed into the firewall image; default dig.
  SOPS_VERSION=latest                    SOPS release version installed into the runtime image.

Collection drop-ins:
  container-collections/*.yml entries are installed with ansible-galaxy collection install.
EOF
      exit 0
      ;;
    *)
      BUILD_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ "${#BUILD_ARGS[@]}" -gt 0 ]; then
  echo "Error: unsupported build argument: ${BUILD_ARGS[0]}" >&2
  exit 1
fi

if [ ! -f ./dist/codex.tgz ]; then
  echo "Error: ./dist/codex.tgz is missing." >&2
  echo "Run ./codex-artifact.sh prepare first to stage the Codex archive used by the container build." >&2
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

case "${CODEX_FIREWALL_DNS_TOOL}" in
  dig|kdig|drill)
    ;;
  *)
    echo "Error: unsupported CODEX_FIREWALL_DNS_TOOL=${CODEX_FIREWALL_DNS_TOOL}." >&2
    echo "Set CODEX_FIREWALL_DNS_TOOL=dig, kdig, or drill." >&2
    exit 1
    ;;
esac

mkdir -p "${DNF_CACHE_DIR}/dnf" "${DNF_CACHE_DIR}/libdnf5" "$(dirname "${GENERATED_DOCKERFILE}")"

generate_runtime_dockerfile() {
  local found_dnf_marker=0
  local found_collection_marker=0
  local dep_file
  local dep_files
  local collection_file
  local collection_files

  shopt -s nullglob
  dep_files=(container-deps/*.dnf)
  collection_files=(container-collections/*.yml container-collections/*.yaml)
  shopt -u nullglob

  if [ "${#dep_files[@]}" -eq 0 ]; then
    echo "Error: no DNF dependency drop-ins found under container-deps/*.dnf" >&2
    exit 1
  fi

  if [ "${#collection_files[@]}" -gt 0 ]; then
    {
      printf 'collections:\n'
      for collection_file in "${collection_files[@]}"; do
        printf '  # %s\n' "${collection_file}"
        awk '
          {
            if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
              next
            }
            print "  " $0
            found = 1
          }
          END {
            if (!found) {
              exit 1
            }
          }
        ' "${collection_file}" || {
          echo "Error: ${collection_file} does not list any Ansible collections." >&2
          exit 1
        }
      done
    } > "${GENERATED_ANSIBLE_COLLECTIONS}"
  else
    rm -f "${GENERATED_ANSIBLE_COLLECTIONS}"
  fi

  {
    while IFS= read -r line || [ -n "${line}" ]; do
      if [ "${line}" = "# DNF_DROPINS" ]; then
        found_dnf_marker=1
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
      elif [ "${line}" = "# ANSIBLE_COLLECTION_DROPINS" ]; then
        found_collection_marker=1
        if [ "${#collection_files[@]}" -gt 0 ]; then
          printf 'RUN printf '\''%%s\\n'\'' \\\n'
          awk '
            {
              gsub(/["\\`$]/, "\\\\&")
              printf "    \"%s\" \\\n", $0
            }
          ' "${GENERATED_ANSIBLE_COLLECTIONS}"
          printf '  > /tmp/codex-ansible-collections.yml \\\n'
          printf '  && ansible-galaxy collection install --force -p /usr/share/ansible/collections -r /tmp/codex-ansible-collections.yml \\\n'
          printf '  && rm -f /tmp/codex-ansible-collections.yml\n\n'
        fi
      else
        printf '%s\n' "${line}"
      fi
    done < ./Dockerfile.in
  } > "${GENERATED_DOCKERFILE}"

  if [ "${found_dnf_marker}" -ne 1 ]; then
    echo "Error: Dockerfile.in is missing the # DNF_DROPINS marker." >&2
    exit 1
  fi
  if [ "${#collection_files[@]}" -gt 0 ] && [ "${found_collection_marker}" -ne 1 ]; then
    echo "Error: Dockerfile.in is missing the # ANSIBLE_COLLECTION_DROPINS marker." >&2
    exit 1
  fi
}

generate_runtime_dockerfile

CODEX_PACKAGE_VERSION="$(tar -xOf ./dist/codex.tgz package/package.json 2>/dev/null | sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
if [ -z "${CODEX_PACKAGE_VERSION}" ]; then
  echo "Error: failed to extract Codex package version from ./dist/codex.tgz." >&2
  exit 1
fi

metadata_version="$(metadata_get CODEX_ARTIFACT_VERSION || true)"
metadata_type="$(metadata_get CODEX_ARTIFACT_TYPE || true)"
if [ -n "${metadata_version}" ] && [ "${metadata_version}" != "${CODEX_PACKAGE_VERSION}" ]; then
  echo "Error: dist/codex.tgz is version ${CODEX_PACKAGE_VERSION}, but metadata records ${metadata_version}." >&2
  echo "Run ./codex-artifact.sh prepare to refresh the staged artifact." >&2
  exit 1
fi

if [ -z "${metadata_version}" ]; then
  echo "Warning: dist/codex-artifact.env is missing; using package metadata from dist/codex.tgz." >&2
fi

CODEX_ARTIFACT_TYPE_FOR_BUILD="${metadata_type:-release}"
if [ -n "${CALLER_CODEX_ARTIFACT_TYPE}" ]; then
  CODEX_ARTIFACT_TYPE_FOR_BUILD="${CALLER_CODEX_ARTIFACT_TYPE}"
fi

check_staged_freshness() {
  local latest_version=""
  local policy="${CODEX_ARTIFACT_STALE_POLICY:-}"
  local choice=""

  latest_version="$(CODEX_CURL_MAX_TIME="${CODEX_ARTIFACT_BUILD_TIMEOUT}" latest_version_for_type "${CODEX_ARTIFACT_TYPE_FOR_BUILD}" 2>/dev/null || true)"
  if [ -z "${latest_version}" ]; then
    echo "Warning: could not check latest Codex ${CODEX_ARTIFACT_TYPE_FOR_BUILD} version." >&2
    return 0
  fi
  if [ "${CODEX_PACKAGE_VERSION}" = "${latest_version}" ]; then
    return 0
  fi

  echo "Warning: staged Codex ${CODEX_ARTIFACT_TYPE_FOR_BUILD} artifact is ${CODEX_PACKAGE_VERSION}; latest is ${latest_version}." >&2

  if [ -n "${policy}" ]; then
    choice="${policy}"
  elif is_batch_mode; then
    choice="fail"
  else
    while true; do
      read -r -p "Stale Codex artifact. refresh, continue, or abort? [r/c/a] " choice
      case "${choice}" in
        r|refresh) choice="refresh"; break ;;
        c|continue) choice="continue"; break ;;
        a|abort|"") choice="abort"; break ;;
        *) echo "Please answer refresh, continue, or abort." >&2 ;;
      esac
    done
  fi

  case "${choice}" in
    refresh)
      "${SCRIPT_DIR}/codex-artifact.sh" prepare type "${CODEX_ARTIFACT_TYPE_FOR_BUILD}"
      CODEX_PACKAGE_VERSION="$(tar -xOf ./dist/codex.tgz package/package.json 2>/dev/null | sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
      ;;
    continue)
      ;;
    fail|abort)
      echo "Error: refusing to build stale Codex artifact." >&2
      exit 1
      ;;
    *)
      echo "Error: invalid CODEX_ARTIFACT_STALE_POLICY: ${choice}" >&2
      exit 1
      ;;
  esac
}

check_staged_freshness

runtime_build_args=(
  --layers
  -t codex
  -f "${GENERATED_DOCKERFILE}"
  --build-arg "SOPS_VERSION=${SOPS_VERSION}"
  --build-arg "CODEX_PACKAGE_VERSION=${CODEX_PACKAGE_VERSION}"
  --label "org.opencontainers.image.title=codex-container-runtime"
  --label "org.opencontainers.image.description=Fedora-based Codex runtime image for codex-container"
  --label "codex.cli.version=${CODEX_PACKAGE_VERSION}"
  --label "org.opencontainers.image.ref.name=codex"
  --label "org.opencontainers.image.version=${CODEX_PACKAGE_VERSION}"
  --label "app.kubernetes.io/name=codex"
  --label "app.kubernetes.io/part-of=codex-container"
  --label "app.kubernetes.io/component=app"
  --label "app.kubernetes.io/version=${CODEX_PACKAGE_VERSION}"
)

runtime_build_args+=(
  --volume "${DNF_CACHE_DIR}/dnf:/var/cache/dnf:Z,rw"
  --volume "${DNF_CACHE_DIR}/libdnf5:/var/cache/libdnf5:Z,rw"
  --volume "${STAGED_ARTIFACT}:/tmp/codex.tgz:ro"
)

"${BUILD_COMMAND[@]}" "${runtime_build_args[@]}" .
"${BUILD_COMMAND[@]}" \
  --layers \
  -t codex-firewall \
  -f "./Dockerfile.firewall" \
  --build-arg "CODEX_FIREWALL_DNS_TOOL=${CODEX_FIREWALL_DNS_TOOL}" \
  --label "org.opencontainers.image.title=codex-container-firewall" \
  --label "org.opencontainers.image.description=Alpine firewall sidecar image for codex-container" \
  --label "org.opencontainers.image.ref.name=codex-firewall" \
  --label "codex.firewall.dns.tool=${CODEX_FIREWALL_DNS_TOOL}" \
  --label "app.kubernetes.io/name=codex-firewall" \
  --label "app.kubernetes.io/part-of=codex-container" \
  --label "app.kubernetes.io/component=firewall" \
  .
