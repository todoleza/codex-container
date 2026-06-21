#!/bin/bash

set -euo pipefail

CODEX_GITHUB_API_URL="${CODEX_GITHUB_API_URL:-https://api.github.com/repos/openai/codex}"
CODEX_ARTIFACT_TYPE="${CODEX_ARTIFACT_TYPE:-release}"
CODEX_ARTIFACT_STALE_POLICY="${CODEX_ARTIFACT_STALE_POLICY:-}"
CODEX_CONTAINER_BATCH="${CODEX_CONTAINER_BATCH:-0}"
CODEX_CURL="${CODEX_CURL:-curl}"

artifact_repo_root() {
  local source="${BASH_SOURCE[0]}"
  while [ -L "${source}" ]; do
    source="$(readlink -f "${source}")"
  done
  realpath "$(dirname "${source}")/.."
}

REPO_ROOT="${REPO_ROOT:-$(artifact_repo_root)}"
UPSTREAM_CACHE_DIR="${UPSTREAM_CACHE_DIR:-${REPO_ROOT}/.build-cache/upstream/codex}"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"
STAGED_ARTIFACT="${STAGED_ARTIFACT:-${DIST_DIR}/codex.tgz}"
ARTIFACT_METADATA="${ARTIFACT_METADATA:-${DIST_DIR}/codex-artifact.env}"

usage_artifact() {
  cat <<'EOF'
Usage:
  codex-artifact.sh prepare [type release|alpha] [version VERSION] [--batch|--non-interactive]
  codex-artifact.sh status [--batch|--non-interactive]
  codex-artifact.sh clean
EOF
}

is_batch_mode() {
  if [ "${CODEX_CONTAINER_BATCH}" = "1" ]; then
    return 0
  fi
  if [ "${INTERACTIVE:-1}" = "0" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    return 0
  fi
  return 1
}

json_string_field() {
  local key="$1"
  grep -o "\"${key}\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/\"${key}\":[[:space:]]*\"//; s/\"$//"
}

package_version() {
  local file="$1"
  tar -xOf "${file}" package/package.json 2>/dev/null | json_string_field version
}

github_get() {
  local path="$1"
  "${CODEX_CURL}" -fsSL \
    -H 'Accept: application/vnd.github+json' \
    "${CODEX_GITHUB_API_URL}${path}"
}

release_version_from_tag() {
  local tag="$1"
  tag="${tag#rust-v}"
  tag="${tag#v}"
  printf '%s\n' "${tag}"
}

select_latest_release_json() {
  github_get '/releases/latest'
}

select_latest_alpha_json() {
  github_get '/releases?per_page=100' \
    | jq -c '[.[] | select(.prerelease == true) | select((.tag_name | test("-alpha\\.")) or (.name | test("-alpha\\.")))] | sort_by(.published_at) | last'
}

select_exact_release_json() {
  local version="$1"
  github_get "/releases/tags/rust-v${version}"
}

asset_url_for_release_json() {
  local release_json="$1"
  local version="$2"
  local asset_name="codex-npm-${version}.tgz"

  printf '%s\n' "${release_json}" \
    | jq -r --arg name "${asset_name}" '.assets[] | select(.name == $name) | .browser_download_url' \
    | head -1
}

metadata_get() {
  local key="$1"
  [ -f "${ARTIFACT_METADATA}" ] || return 1
  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${ARTIFACT_METADATA}"
}

write_metadata() {
  local type="$1"
  local version="$2"
  local tag="$3"
  local asset_name="$4"
  local asset_url="$5"
  local source_path="$6"

  mkdir -p "${DIST_DIR}"
  {
    printf 'CODEX_ARTIFACT_TYPE=%s\n' "${type}"
    printf 'CODEX_ARTIFACT_VERSION=%s\n' "${version}"
    printf 'CODEX_ARTIFACT_GITHUB_TAG=%s\n' "${tag}"
    printf 'CODEX_ARTIFACT_ASSET_NAME=%s\n' "${asset_name}"
    printf 'CODEX_ARTIFACT_ASSET_URL=%s\n' "${asset_url}"
    printf 'CODEX_ARTIFACT_SOURCE_PATH=%s\n' "${source_path}"
    printf 'CODEX_ARTIFACT_FETCHED_EPOCH=%s\n' "$(date +%s)"
  } > "${ARTIFACT_METADATA}"
}

parse_artifact_args() {
  SELECTED_TYPE="${CODEX_ARTIFACT_TYPE}"
  SELECTED_VERSION=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      type)
        SELECTED_TYPE="${2:-}"
        shift 2
        ;;
      version)
        SELECTED_VERSION="${2:-}"
        shift 2
        ;;
      --batch|--non-interactive)
        CODEX_CONTAINER_BATCH=1
        shift
        ;;
      help|-h|--help)
        usage_artifact
        exit 0
        ;;
      *)
        echo "Error: unknown argument: $1" >&2
        usage_artifact >&2
        exit 1
        ;;
    esac
  done

  case "${SELECTED_TYPE}" in
    release|alpha) ;;
    *)
      echo "Error: unsupported artifact type: ${SELECTED_TYPE}" >&2
      exit 1
      ;;
  esac
}

resolve_release() {
  local type="$1"
  local version="$2"
  local release_json
  local tag

  if [ -n "${version}" ]; then
    release_json="$(select_exact_release_json "${version}")"
  elif [ "${type}" = "alpha" ]; then
    release_json="$(select_latest_alpha_json)"
  else
    release_json="$(select_latest_release_json)"
  fi

  if [ -z "${release_json}" ] || [ "${release_json}" = "null" ]; then
    echo "Error: no matching Codex GitHub release found." >&2
    exit 1
  fi

  tag="$(printf '%s\n' "${release_json}" | jq -r '.tag_name')"
  version="$(release_version_from_tag "${tag}")"
  RESOLVED_RELEASE_JSON="${release_json}"
  RESOLVED_TAG="${tag}"
  RESOLVED_VERSION="${version}"
}

prepare_artifact() {
  parse_artifact_args "$@"
  resolve_release "${SELECTED_TYPE}" "${SELECTED_VERSION}"

  local asset_name="codex-npm-${RESOLVED_VERSION}.tgz"
  local asset_url
  local cache_path
  local staged_version
  local metadata_type="${SELECTED_TYPE}"

  if [ -n "${SELECTED_VERSION}" ]; then
    if [ "$(printf '%s\n' "${RESOLVED_RELEASE_JSON}" | jq -r '.prerelease')" = "true" ]; then
      metadata_type="alpha"
    else
      metadata_type="release"
    fi
  fi

  asset_url="$(asset_url_for_release_json "${RESOLVED_RELEASE_JSON}" "${RESOLVED_VERSION}")"
  if [ -z "${asset_url}" ]; then
    echo "Error: release ${RESOLVED_TAG} does not contain ${asset_name}." >&2
    exit 1
  fi

  mkdir -p "${UPSTREAM_CACHE_DIR}" "${DIST_DIR}"
  cache_path="${UPSTREAM_CACHE_DIR}/${asset_name}"
  if [ ! -f "${cache_path}" ]; then
    "${CODEX_CURL}" -fL -o "${cache_path}" "${asset_url}"
  fi

  staged_version="$(package_version "${cache_path}")"
  if [ "${staged_version}" != "${RESOLVED_VERSION}" ]; then
    echo "Error: ${asset_name} contains package version ${staged_version}, expected ${RESOLVED_VERSION}." >&2
    exit 1
  fi

  rm -f "${STAGED_ARTIFACT}"
  cp "${cache_path}" "${STAGED_ARTIFACT}"
  write_metadata "${metadata_type}" "${RESOLVED_VERSION}" "${RESOLVED_TAG}" "${asset_name}" "${asset_url}" "${cache_path}"
  printf 'staged Codex %s from %s\n' "${RESOLVED_VERSION}" "${RESOLVED_TAG}"
}

latest_version_for_type() {
  local type="$1"
  local release_json
  local tag

  if [ "${type}" = "alpha" ]; then
    release_json="$(select_latest_alpha_json)"
  else
    release_json="$(select_latest_release_json)"
  fi
  tag="$(printf '%s\n' "${release_json}" | jq -r '.tag_name')"
  release_version_from_tag "${tag}"
}

artifact_status() {
  parse_artifact_args "$@"

  local staged_version=""
  local metadata_version=""
  local metadata_type=""
  local latest_release=""
  local latest_alpha=""

  if [ -f "${STAGED_ARTIFACT}" ]; then
    staged_version="$(package_version "${STAGED_ARTIFACT}" || true)"
  fi
  metadata_version="$(metadata_get CODEX_ARTIFACT_VERSION || true)"
  metadata_type="$(metadata_get CODEX_ARTIFACT_TYPE || true)"
  latest_release="$(latest_version_for_type release)"
  latest_alpha="$(latest_version_for_type alpha)"

  printf 'artifact: %s\n' "${STAGED_ARTIFACT}"
  printf 'metadata: %s\n' "${ARTIFACT_METADATA}"
  printf 'metadata type: %s\n' "${metadata_type:-missing}"
  printf 'staged version: %s\n' "${staged_version:-missing}"
  printf 'metadata version: %s\n' "${metadata_version:-missing}"
  printf 'latest release: %s\n' "${latest_release}"
  printf 'latest alpha: %s\n' "${latest_alpha}"
  printf 'fresh release: %s\n' "$(if [ -n "${staged_version}" ] && [ "${staged_version}" = "${latest_release}" ]; then printf yes; else printf no; fi)"
  printf 'fresh alpha: %s\n' "$(if [ -n "${staged_version}" ] && [ "${staged_version}" = "${latest_alpha}" ]; then printf yes; else printf no; fi)"
}

clean_artifacts() {
  rm -rf "${UPSTREAM_CACHE_DIR}"
  rm -f "${STAGED_ARTIFACT}" "${ARTIFACT_METADATA}"
  printf 'removed Codex upstream artifact cache and staged artifact\n'
}

artifact_main() {
  local command="${1:-help}"
  shift || true

  case "${command}" in
    prepare)
      prepare_artifact "$@"
      ;;
    status)
      artifact_status "$@"
      ;;
    clean)
      clean_artifacts "$@"
      ;;
    help|-h|--help)
      usage_artifact
      ;;
    *)
      echo "Error: unknown command: ${command}" >&2
      usage_artifact >&2
      exit 1
      ;;
  esac
}
