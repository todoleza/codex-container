#!/bin/bash
set -euo pipefail

WORK_DIR="${WORKSPACE_ROOT_DIR:-$(pwd)}"

CALLER_ENV_NAMES="$(env | sed 's/=.*//')"
LOADED_ENV_FILES=()
SKIPPED_ENV_FILES=()

caller_env_has() {
  local name="$1"
  grep -Fxq -- "${name}" <<< "${CALLER_ENV_NAMES}"
}

set_from_env_file() {
  local name="$1"
  local value="$2"

  if caller_env_has "${name}"; then
    return 0
  fi

  printf -v "${name}" '%s' "${value}"
}

load_env_file() {
  local file="$1"
  local line_number=0
  local line
  local name
  local value

  if [ -z "${file}" ]; then
    return 0
  fi

  if [ ! -f "${file}" ]; then
    SKIPPED_ENV_FILES+=("${file}")
    return 0
  fi

  while IFS= read -r line || [ -n "${line}" ]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    case "${line}" in
      ""|\#*) continue ;;
    esac

    if [[ "${line}" != *=* ]]; then
      echo "Invalid env file line ${file}:${line_number}: ${line}" >&2
      exit 1
    fi

    name="${line%%=*}"
    value="${line#*=}"
    if ! [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "Invalid env file variable ${file}:${line_number}: ${name}" >&2
      exit 1
    fi

    set_from_env_file "${name}" "${value}"
  done < "${file}"

  LOADED_ENV_FILES+=("${file}")
}

detect_requested_work_dir() {
  local args=("$@")
  local idx=0

  while [ "${idx}" -lt "${#args[@]}" ]; do
    case "${args[$idx]}" in
      --wd)
        if [ -n "${args[$((idx + 1))]:-}" ]; then
          printf '%s\n' "${args[$((idx + 1))]}"
          return
        fi
        ;;
      --)
        break
        ;;
    esac
    idx=$((idx + 1))
  done

  printf '%s\n' "${WORK_DIR}"
}

EARLY_WORK_DIR="$(realpath -m "$(detect_requested_work_dir "$@")")"
: "${CODEX_CONTAINER_GLOBAL_ENV_FILE:=${HOME}/.local/share/codex-container/env}"
: "${CODEX_CONTAINER_WORKSPACE_ENV_FILE:=${EARLY_WORK_DIR}/.codex-container.env}"

load_env_file "${CODEX_CONTAINER_GLOBAL_ENV_FILE}"
load_env_file "${CODEX_CONTAINER_WORKSPACE_ENV_FILE}"
if [ -n "${CODEX_CONTAINER_ENV_FILES:-}" ]; then
  IFS=: read -r -a CODEX_CONTAINER_ENV_FILE_ARRAY <<< "${CODEX_CONTAINER_ENV_FILES}"
  for env_file in "${CODEX_CONTAINER_ENV_FILE_ARRAY[@]}"; do
    load_env_file "${env_file}"
  done
fi

: "${CODEX_ALLOWED_DOMAIN_CATEGORIES:=openai source_control os_packages containers language_packages jvm_dotnet schema_docs}"
: "${CODEX_ALLOWED_DOMAINS_OPENAI:=api.openai.com auth.openai.com chatgpt.com}"
: "${CODEX_ALLOWED_DOMAINS_SOURCE_CONTROL:=github.com githubusercontent.com api.github.com gitlab.com bitbucket.org}"
: "${CODEX_ALLOWED_DOMAINS_OS_PACKAGES:=alpinelinux.org archlinux.org centos.org debian.org fedoraproject.org ppa.launchpad.net ubuntu.com packages.microsoft.com}"
: "${CODEX_ALLOWED_DOMAINS_CONTAINERS:=docker.com docker.io ghcr.io gcr.io mcr.microsoft.com quay.io}"
: "${CODEX_ALLOWED_DOMAINS_LANGUAGE_PACKAGES:=cpan.org crates.io golang.org goproxy.io haskell.org hex.pm metacpan.org nodejs.org npmjs.com npmjs.org packagist.org pkg.go.dev pub.dev pypa.io pypi.org pypi.python.org pythonhosted.org ruby-lang.org rubygems.org rubyonrails.org rustup.rs yarnpkg.com}"
: "${CODEX_ALLOWED_DOMAINS_JVM_DOTNET:=apt.llvm.org dot.net dotnet.microsoft.com gradle.org maven.org nuget.org}"
: "${CODEX_ALLOWED_DOMAINS_SCHEMA_DOCS:=json-schema.org json.schemastore.org}"
: "${CODEX_ALLOWED_DOMAINS_VENDOR_OPT_IN:=anaconda.com apache.org azure.com cocoapods.org eclipse.org google.com hashicorp.com java.com java.net k8s.io launchpad.net microsoft.com oracle.com packagecloud.io sourceforge.net spring.io swift.org visualstudio.com}"
: "${CODEX_OMITTED_DOMAINS:=bower.io continuum.io jcenter.bintray.com rubyforge.org rvm.io}"
: "${OPENAI_ALLOWED_DOMAINS:=}"
: "${EXTRA_ALLOWED_DOMAINS:=}"
: "${EXTRA_ALLOWED_IPV4:=}"
: "${EXTRA_ALLOWED_IPV6:=}"
: "${CONTAINER_IMAGE:=codex}"
: "${FIREWALL_CONTAINER_IMAGE:=codex-firewall}"
: "${PROXY_CONTAINER_IMAGE:=${FIREWALL_CONTAINER_IMAGE}}"
: "${PROXY_ENABLE:=0}"
: "${PROXY_RUNTIME_DIR:=/run/codex-proxy}"
: "${PROXY_SOCKET_PATH:=/run/codex-proxy/proxy.sock}"
: "${PROXY_LISTEN_HOST:=localhost}"
: "${PROXY_LISTEN_PORT:=1080}"
: "${PROXY_UPSTREAM_HOST:=localhost}"
: "${PROXY_UPSTREAM_PORT:=1080}"
: "${CODEX_FIREWALL_POLICY_DIR:=/run/codex-firewall-policy}"
: "${CODEX_SANDBOX_MODE:=danger-full-access}"
: "${CODEX_APPROVAL_POLICY:=on-request}"
: "${CODEX_DANGEROUS_BYPASS:=0}"
: "${CODEX_RELEASE_API_URL:=https://api.github.com/repos/openai/codex/releases/latest}"
: "${CODEX_RELEASE_API_TIMEOUT_SECONDS:=5}"
: "${CODEX_RELEASE_CHECK_ON_SPAWN:=1}"
: "${PODMAN_POD_CREATE_ARGS:=}"
: "${PODMAN_FIREWALL_RUN_ARGS:=}"
: "${PODMAN_CODEX_RUN_ARGS:=}"
: "${PODMAN_EXEC_ARGS:=}"
: "${CONTAINER_EXEC_COMMAND:=}"
: "${STARTUP_SUMMARY_HOLD_SECONDS:=1.2}"

append_domain_list() {
  local values="$1"
  local value

  read -r -a values_array <<< "${values}"
  for value in "${values_array[@]}"; do
    [ -n "${value}" ] || continue
    OPENAI_ALLOWED_DOMAINS+=" ${value}"
  done
}

append_domain_category() {
  local category="$1"

  case "${category}" in
    openai) append_domain_list "${CODEX_ALLOWED_DOMAINS_OPENAI}" ;;
    source_control) append_domain_list "${CODEX_ALLOWED_DOMAINS_SOURCE_CONTROL}" ;;
    os_packages) append_domain_list "${CODEX_ALLOWED_DOMAINS_OS_PACKAGES}" ;;
    containers) append_domain_list "${CODEX_ALLOWED_DOMAINS_CONTAINERS}" ;;
    language_packages) append_domain_list "${CODEX_ALLOWED_DOMAINS_LANGUAGE_PACKAGES}" ;;
    jvm_dotnet) append_domain_list "${CODEX_ALLOWED_DOMAINS_JVM_DOTNET}" ;;
    schema_docs) append_domain_list "${CODEX_ALLOWED_DOMAINS_SCHEMA_DOCS}" ;;
    vendor_opt_in) append_domain_list "${CODEX_ALLOWED_DOMAINS_VENDOR_OPT_IN}" ;;
    *)
      echo "Error: Unknown CODEX_ALLOWED_DOMAIN_CATEGORIES entry: ${category}" >&2
      exit 1
      ;;
  esac
}

domain_is_omitted() {
  local domain="$1"
  local omitted

  for omitted in ${CODEX_OMITTED_DOMAINS}; do
    if [ "${domain}" = "${omitted}" ]; then
      return 0
    fi
  done

  return 1
}

if [[ -z "${OPENAI_ALLOWED_DOMAINS}" ]]; then
  read -r -a ALLOWED_CATEGORY_ARRAY <<< "${CODEX_ALLOWED_DOMAIN_CATEGORIES}"
  for category in "${ALLOWED_CATEGORY_ARRAY[@]}"; do
    append_domain_category "${category}"
  done
fi

if [[ -n "${EXTRA_ALLOWED_DOMAINS}" ]]; then
  OPENAI_ALLOWED_DOMAINS+=" ${EXTRA_ALLOWED_DOMAINS}"
fi

FINAL_ALLOWED_DOMAINS=()
for domain in ${OPENAI_ALLOWED_DOMAINS}; do
  domain_is_omitted "${domain}" && continue
  FINAL_ALLOWED_DOMAINS+=("${domain}")
done

OPENAI_ALLOWED_DOMAINS="$(printf '%s\n' "${FINAL_ALLOWED_DOMAINS[@]}" | sort -u | xargs)"
PROXY_VOLUME_ARGS_ARRAY=()
FIREWALL_POLICY_VOLUME_ARGS_ARRAY=()
APP_POLICY_VOLUME_ARGS_ARRAY=()
CODEX_APP_ENV_ARGS_ARRAY=()
ACTION="start"
ACTION_ARGS=()
START_ARGS=()
SELECTOR_ID=""
SELECTOR_STATE_DIR=""
WORK_DIR_SELECTED=0
WORKSPACE_ALIAS=""
WORKSPACE_SEQ=""
REGISTRY_ROOT=""
WORKSPACE_STATE_DIR=""
CODEX_LOCAL_VERSION=""
CODEX_LATEST_VERSION=""
CODEX_VERSION_LABEL_ARGS_ARRAY=()
CODEX_APP_RUNTIME_LABEL_ARGS_ARRAY=()
CODEX_POD_RUNTIME_LABEL_ARGS_ARRAY=()

collect_codex_app_env_args() {
  local source_name
  local target_name
  local source_names=()

  while IFS= read -r source_name; do
    [ -n "${source_name}" ] || continue
    source_names+=("${source_name}")
  done < <(compgen -v CODEX_ENV_ | sort)

  for source_name in "${source_names[@]}"; do
    target_name="${source_name#CODEX_ENV_}"
    if ! [[ "${target_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "Error: Invalid CODEX_ENV_ target variable: ${source_name}" >&2
      exit 1
    fi

    printf -v "${target_name}" '%s' "${!source_name}"
    export "${target_name}"
    CODEX_APP_ENV_ARGS_ARRAY+=(-e "${target_name}")
  done
}

refresh_runtime_arrays() {
  read -r -a ALLOWED_DOMAIN_ARRAY <<< "${OPENAI_ALLOWED_DOMAINS}"
  read -r -a EXTRA_ALLOWED_IPV4_ARRAY <<< "${EXTRA_ALLOWED_IPV4}"
  read -r -a EXTRA_ALLOWED_IPV6_ARRAY <<< "${EXTRA_ALLOWED_IPV6}"
  read -r -a PODMAN_POD_CREATE_ARGS_ARRAY <<< "${PODMAN_POD_CREATE_ARGS}"
  read -r -a PODMAN_FIREWALL_RUN_ARGS_ARRAY <<< "${PODMAN_FIREWALL_RUN_ARGS}"
  read -r -a PODMAN_CODEX_RUN_ARGS_ARRAY <<< "${PODMAN_CODEX_RUN_ARGS}"
  read -r -a PODMAN_EXEC_ARGS_ARRAY <<< "${PODMAN_EXEC_ARGS}"
  CODEX_APP_ENV_ARGS_ARRAY=()
  collect_codex_app_env_args
}

refresh_runtime_arrays

parse_first_json_string_field() {
  local key="$1"
  local value=""

  value=$(grep -o "\"${key}\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/\"${key}\":[[:space:]]*\"//; s/\"$//")
  printf '%s\n' "${value}"
}

normalize_codex_release_version() {
  local version="$1"

  version="${version#rust-v}"
  version="${version#v}"
  printf '%s\n' "${version}"
}

parse_codex_version_from_text() {
  sed -n 's/.*\([0-9][0-9.]*[0-9]\).*/\1/p' | head -1
}

detect_image_label_codex_version() {
  local version=""

  version=$(
    podman image inspect \
      --format '{{ index .Config.Labels "codex.cli.version" }}' \
      "${CONTAINER_IMAGE}" 2>/dev/null || true
  )

  if [ -n "${version}" ] && [ "${version}" != "<no value>" ]; then
    CODEX_LOCAL_VERSION="${version}"
  fi
}

probe_image_codex_version() {
  local output=""
  local version=""

  output=$(
    podman run --rm \
      --entrypoint codex \
      "${CONTAINER_IMAGE}" \
      --version 2>/dev/null || true
  )

  if [ -z "${output}" ]; then
    return 0
  fi

  version=$(printf '%s\n' "${output}" | parse_codex_version_from_text || true)
  if [ -n "${version}" ]; then
    CODEX_LOCAL_VERSION="${version}"
  fi
}

fetch_latest_codex_version() {
  local response=""
  local tag=""

  if [ "${CODEX_RELEASE_CHECK_ON_SPAWN}" != "1" ]; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi

  response=$(
    curl -fsSL \
      --max-time "${CODEX_RELEASE_API_TIMEOUT_SECONDS}" \
      -H 'Accept: application/vnd.github+json' \
      "${CODEX_RELEASE_API_URL}" 2>/dev/null || true
  )

  if [ -z "${response}" ]; then
    return 0
  fi

  tag=$(printf '%s' "${response}" | parse_first_json_string_field tag_name || true)
  if [ -z "${tag}" ]; then
    return 0
  fi

  CODEX_LATEST_VERSION="$(normalize_codex_release_version "${tag}")"
}

refresh_codex_version_labels() {
  CODEX_VERSION_LABEL_ARGS_ARRAY=()
  CODEX_APP_RUNTIME_LABEL_ARGS_ARRAY=()
  CODEX_POD_RUNTIME_LABEL_ARGS_ARRAY=()

  if [ -n "${CODEX_LOCAL_VERSION}" ]; then
    CODEX_VERSION_LABEL_ARGS_ARRAY+=(--label "codex.cli.version=${CODEX_LOCAL_VERSION}")
    CODEX_APP_RUNTIME_LABEL_ARGS_ARRAY+=(--label "org.opencontainers.image.version=${CODEX_LOCAL_VERSION}")
    CODEX_APP_RUNTIME_LABEL_ARGS_ARRAY+=(--label "app.kubernetes.io/version=${CODEX_LOCAL_VERSION}")
    CODEX_POD_RUNTIME_LABEL_ARGS_ARRAY+=(--label "org.opencontainers.image.version=${CODEX_LOCAL_VERSION}")
    CODEX_POD_RUNTIME_LABEL_ARGS_ARRAY+=(--label "app.kubernetes.io/version=${CODEX_LOCAL_VERSION}")
  fi

  if [ -n "${CODEX_LATEST_VERSION}" ]; then
    CODEX_VERSION_LABEL_ARGS_ARRAY+=(--label "codex.cli.latest=${CODEX_LATEST_VERSION}")
  fi

  CODEX_APP_RUNTIME_LABEL_ARGS_ARRAY+=(--label "org.opencontainers.image.title=codex-container-runtime")
  CODEX_APP_RUNTIME_LABEL_ARGS_ARRAY+=(--label "app.kubernetes.io/name=codex")
  CODEX_APP_RUNTIME_LABEL_ARGS_ARRAY+=(--label "app.kubernetes.io/part-of=codex-container")
  CODEX_APP_RUNTIME_LABEL_ARGS_ARRAY+=(--label "app.kubernetes.io/component=app")
  CODEX_POD_RUNTIME_LABEL_ARGS_ARRAY+=(--label "app.kubernetes.io/name=codex")
  CODEX_POD_RUNTIME_LABEL_ARGS_ARRAY+=(--label "app.kubernetes.io/part-of=codex-container")
  CODEX_POD_RUNTIME_LABEL_ARGS_ARRAY+=(--label "app.kubernetes.io/component=pod")
}

write_optional_state_file() {
  local state_dir="$1"
  local name="$2"
  local value="$3"

  if [ -n "${value}" ]; then
    write_state_file "${state_dir}" "${name}" "${value}"
  else
    rm -f "${state_dir}/${name}" >/dev/null 2>&1 || true
  fi
}

usage() {
  cat <<'EOF'
Usage:
  run-in-container.sh [--wd DIR] [CODEX_ARGS...]
  run-in-container.sh list
  run-in-container.sh [--id ID|--wd DIR] status [ID]
  run-in-container.sh [--id ID|--wd DIR] name [ID]
  run-in-container.sh [--wd DIR] help
  run-in-container.sh [--id ID|--wd DIR] spawn [ID]
  run-in-container.sh [--id ID|--wd DIR] enter [COMMAND...]
  run-in-container.sh [--id ID|--wd DIR] shell COMMAND...
  run-in-container.sh [--id ID|--wd DIR] fwenter [COMMAND...]
  run-in-container.sh [--id ID|--wd DIR] fwshell COMMAND...
  run-in-container.sh [--id ID|--wd DIR] replace [CODEX_ARGS...]
  run-in-container.sh [--id ID|--wd DIR] destroy|rm|kill [ID]
  run-in-container.sh [--id ID|--wd DIR] copy|push LOCAL_PATH CONTAINER_PATH
  run-in-container.sh [--id ID|--wd DIR] pull|fetch CONTAINER_PATH LOCAL_PATH

Launcher commands:
  help          Show this help. Use --help for Codex CLI help.
  list          List known workspace containers.
  status        Show resolved workspace container names and state.
  name          Print the resolved app container name.
  spawn         Start the workspace pod in the background and exit.
  enter         Enter the running workspace container with a TTY. Defaults to bash.
  shell         Run a command in the running workspace container without a TTY.
  fwenter       Enter the firewall container with a TTY. Defaults to bash.
  fwshell       Run a command in the firewall container without a TTY.
  replace       Remove any existing workspace pod, then start Codex normally.
  destroy, rm   Remove the workspace pod and exit.
  kill          Immediately remove the workspace pod and exit.
  copy, push    Copy from the host into the workspace container.
  pull, fetch   Copy from the workspace container to the host.

Only --wd and --id are parsed by this launcher. Other dash arguments are passed
to Codex. Relative container copy paths resolve under the preserved /app host
path. Local copy paths are resolved to absolute host paths before calling
podman cp.
EOF
}

slugify() {
  local value="$1"
  value=$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')
  value=$(printf '%s' "${value}" | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
  if [ -z "${value}" ]; then
    value="workspace"
  fi
  printf '%s' "${value}"
}

stable_hash() {
  local value="$1"
  printf '%s' "${value}" | sha256sum | cut -c1-8
}

workspace_alias() {
  local path="$1"
  local leaf
  local parent

  leaf=$(basename "${path}")
  parent=$(basename "$(dirname "${path}")")
  if [ -z "${parent}" ] || [ "${parent}" = "/" ]; then
    slugify "${leaf}"
  else
    slugify "${parent}-${leaf}"
  fi
}

detect_host_tz() {
  local tz_candidate=""
  local localtime_target=""

  if [ -n "${TZ:-}" ]; then
    printf '%s' "${TZ}"
    return
  fi

  if [ -L /etc/localtime ]; then
    localtime_target=$(readlink /etc/localtime)
    case "${localtime_target}" in
      /usr/share/zoneinfo/*)
        tz_candidate="${localtime_target#/usr/share/zoneinfo/}"
        ;;
      ../usr/share/zoneinfo/*)
        tz_candidate="${localtime_target#../usr/share/zoneinfo/}"
        ;;
    esac
    if [ -n "${tz_candidate}" ]; then
      printf '%s' "${tz_candidate}"
      return
    fi
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    tz_candidate=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    if [ -n "${tz_candidate}" ]; then
      printf '%s' "${tz_candidate}"
      return
    fi
  fi

  printf 'UTC'
}

validate_domain() {
  local domain="$1"
  [[ "${domain}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]\.[A-Za-z]{2,}$ ]]
}

validate_ipv4() {
  local address="$1"
  [[ "${address}" =~ ^[0-9./]+$ ]]
}

validate_ipv6() {
  local address="$1"
  [[ "${address}" =~ ^[0-9A-Fa-f:/]+$ ]]
}

validate_port() {
  local port="$1"

  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

validate_non_negative_integer() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]]
}

validate_sandbox_mode() {
  local mode="$1"
  case "${mode}" in
    read-only|workspace-write|danger-full-access) return 0 ;;
    *) return 1 ;;
  esac
}

validate_approval_policy() {
  local policy="$1"
  case "${policy}" in
    untrusted|on-failure|on-request|never) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wd)
        if [ -z "${2:-}" ]; then
          echo "Error: --wd flag provided but no directory specified." >&2
          exit 1
        fi
        WORK_DIR="$2"
        WORK_DIR_SELECTED=1
        shift 2
        ;;
      --id)
        if [ -z "${2:-}" ]; then
          echo "Error: --id flag provided but no identifier specified." >&2
          exit 1
        fi
        SELECTOR_ID="$2"
        shift 2
        ;;
      --work_dir)
        echo "Error: --work_dir has been replaced by --wd." >&2
        exit 1
        ;;
      --)
        shift
        START_ARGS=("$@")
        return
        ;;
      -*)
        START_ARGS=("$@")
        return
        ;;
      *)
        case "$1" in
          help|list|status|name|spawn|enter|shell|fwenter|fwshell|replace|destroy|rm|kill|copy|push|pull|fetch)
            ACTION="$1"
            shift
            ACTION_ARGS=("$@")
            ;;
          *)
            START_ARGS=("$@")
            ;;
        esac
        return
        ;;
    esac
  done
}

apply_trailing_selector() {
  case "${ACTION}" in
    status|name|spawn|destroy|rm|kill)
      ;;
    *)
      return
      ;;
  esac

  if [ "${#ACTION_ARGS[@]}" -eq 0 ]; then
    return
  fi

  if [ "${#ACTION_ARGS[@]}" -eq 1 ] && [ -z "${SELECTOR_ID}" ] && [ "${WORK_DIR_SELECTED}" = "0" ]; then
    SELECTOR_ID="${ACTION_ARGS[0]}"
    ACTION_ARGS=()
    return
  fi

  echo "Error: ${ACTION} accepts at most one trailing workspace id, and only without --id or --wd." >&2
  usage >&2
  exit 1
}

load_selected_workspace_env_if_needed() {
  local selected_file

  if caller_env_has CODEX_CONTAINER_WORKSPACE_ENV_FILE; then
    return 0
  fi

  selected_file="$(realpath -m "${WORK_DIR}/.codex-container.env")"
  if [ "${selected_file}" = "${CODEX_CONTAINER_WORKSPACE_ENV_FILE}" ]; then
    return 0
  fi

  CODEX_CONTAINER_WORKSPACE_ENV_FILE="${selected_file}"
  load_env_file "${CODEX_CONTAINER_WORKSPACE_ENV_FILE}"
  refresh_runtime_arrays
}

hold_startup_summary() {
  if [ "${STARTUP_SUMMARY_HOLD_SECONDS}" = "0" ]; then
    return
  fi

  if [ -t 0 ] && [ -t 1 ]; then
    read -r -t "${STARTUP_SUMMARY_HOLD_SECONDS}" -p "Press Enter to continue, or wait ${STARTUP_SUMMARY_HOLD_SECONDS}s..." _ || true
    printf '\n'
  else
    sleep "${STARTUP_SUMMARY_HOLD_SECONDS}"
  fi
}

proxy_enabled() {
  (( PROXY_ENABLE ))
}

prepare_proxy_runtime_dir() {
  proxy_enabled || return 0

  mkdir -p "${PROXY_RUNTIME_DIR_HOST}" || {
    echo "Warning: could not create proxy runtime dir at ${PROXY_RUNTIME_DIR_HOST}; disabling proxy relay." >&2
    PROXY_ENABLE=0
  }

  chmod 0777 "${PROXY_RUNTIME_DIR_HOST}" || {
    echo "Warning: could not relax proxy runtime dir permissions at ${PROXY_RUNTIME_DIR_HOST}; disabling proxy relay." >&2
    PROXY_ENABLE=0
  }
}

prepare_firewall_policy_runtime_dir() {
  mkdir -p "${FIREWALL_POLICY_RUNTIME_DIR_HOST}" || {
    echo "Error: could not create firewall policy runtime dir at ${FIREWALL_POLICY_RUNTIME_DIR_HOST}." >&2
    exit 1
  }

  chmod 0755 "${FIREWALL_POLICY_RUNTIME_DIR_HOST}" || {
    echo "Error: could not set firewall policy runtime dir permissions at ${FIREWALL_POLICY_RUNTIME_DIR_HOST}." >&2
    exit 1
  }
}

registry_init() {
  mkdir -p "${REGISTRY_ROOT}/state" "${REGISTRY_ROOT}/by-seq" "${REGISTRY_ROOT}/by-alias" "${REGISTRY_ROOT}/by-path-hash"
}

next_sequence() {
  local entry
  local base
  local max=0

  registry_init
  shopt -s nullglob
  for entry in "${REGISTRY_ROOT}/by-seq/"*; do
    base=$(basename "${entry}")
    if [[ "${base}" =~ ^[0-9]+$ ]] && (( base > max )); then
      max="${base}"
    fi
  done
  shopt -u nullglob

  printf '%s\n' "$((max + 1))"
}

sequence_for_state_dir() {
  local state_dir="$1"
  local entry

  registry_init
  shopt -s nullglob
  for entry in "${REGISTRY_ROOT}/by-seq/"*; do
    if [ "$(readlink -f "${entry}")" = "$(readlink -f "${state_dir}")" ]; then
      basename "${entry}"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

read_state_file() {
  local state_dir="$1"
  local name="$2"

  if [ -f "${state_dir}/${name}" ]; then
    sed -n '1p' "${state_dir}/${name}"
  fi
}

write_state_file() {
  local state_dir="$1"
  local name="$2"
  local value="$3"

  printf '%s\n' "${value}" > "${state_dir}/${name}"
}

ensure_workspace_record() {
  local path="$1"
  local hash
  local alias
  local state_dir
  local seq

  registry_init
  hash=$(stable_hash "${path}")
  alias=$(workspace_alias "${path}")

  if [ -L "${REGISTRY_ROOT}/by-path-hash/${hash}" ]; then
    state_dir=$(readlink -f "${REGISTRY_ROOT}/by-path-hash/${hash}")
    seq=$(sequence_for_state_dir "${state_dir}" || true)
  else
    state_dir="${REGISTRY_ROOT}/state/${hash}"
    mkdir -p "${state_dir}"
    seq=$(next_sequence)
    ln -s "../state/${hash}" "${REGISTRY_ROOT}/by-seq/${seq}"
    ln -s "../state/${hash}" "${REGISTRY_ROOT}/by-path-hash/${hash}"
  fi

  if [ -z "${seq}" ]; then
    seq=$(next_sequence)
    ln -s "../state/${hash}" "${REGISTRY_ROOT}/by-seq/${seq}"
  fi

  mkdir -p "${state_dir}" "${REGISTRY_ROOT}/by-alias/${alias}"
  ln -sfn "../../state/${hash}" "${REGISTRY_ROOT}/by-alias/${alias}/${hash}"

  write_state_file "${state_dir}" path "${path}"
  write_state_file "${state_dir}" alias "${alias}"
  write_state_file "${state_dir}" hash "${hash}"
  write_state_file "${state_dir}" seq "${seq}"
  write_state_file "${state_dir}" pod "${POD_NAME}"
  write_state_file "${state_dir}" app "${CONTAINER_NAME}"
  write_state_file "${state_dir}" fw "${FW_NAME}"
  write_state_file "${state_dir}" proxy "${PROXY_NAME}"
  write_optional_state_file "${state_dir}" codex_cli_version "${CODEX_LOCAL_VERSION}"
  write_optional_state_file "${state_dir}" codex_cli_latest "${CODEX_LATEST_VERSION}"
  if [ ! -f "${state_dir}/created_epoch" ]; then
    write_state_file "${state_dir}" created_epoch "$(date +%s)"
  fi

  WORKSPACE_ALIAS="${alias}"
  WORKSPACE_SEQ="${seq}"
  WORKSPACE_STATE_DIR="${state_dir}"
}

resolve_state_by_alias() {
  local alias="$1"
  local entry
  local matches=()

  registry_init
  if [ ! -d "${REGISTRY_ROOT}/by-alias/${alias}" ]; then
    return 1
  fi

  shopt -s nullglob
  for entry in "${REGISTRY_ROOT}/by-alias/${alias}/"*; do
    matches+=("$(readlink -f "${entry}")")
  done
  shopt -u nullglob

  case "${#matches[@]}" in
    0) return 1 ;;
    1)
      printf '%s\n' "${matches[0]}"
      ;;
    *)
      echo "Error: ambiguous workspace alias: ${alias}" >&2
      for entry in "${matches[@]}"; do
        printf '  %s  %s\n' "$(read_state_file "${entry}" seq)" "$(read_state_file "${entry}" path)" >&2
      done
      return 2
      ;;
  esac
}

resolve_target_state() {
  local target="$1"
  local state_dir=""
  local hash
  local name
  local entry

  registry_init
  if [[ "${target}" =~ ^[0-9]+$ ]] && [ -L "${REGISTRY_ROOT}/by-seq/${target}" ]; then
    readlink -f "${REGISTRY_ROOT}/by-seq/${target}"
    return 0
  fi

  if [ -e "${target}" ] || [[ "${target}" = /* ]]; then
    hash=$(stable_hash "$(realpath -m "${target}")")
    if [ -L "${REGISTRY_ROOT}/by-path-hash/${hash}" ]; then
      readlink -f "${REGISTRY_ROOT}/by-path-hash/${hash}"
      return 0
    fi
  fi

  if state_dir=$(resolve_state_by_alias "${target}"); then
    printf '%s\n' "${state_dir}"
    return 0
  elif [ "$?" -eq 2 ]; then
    return 2
  fi

  shopt -s nullglob
  for entry in "${REGISTRY_ROOT}/state/"*; do
    for name in pod app fw proxy; do
      if [ "$(read_state_file "${entry}" "${name}")" = "${target}" ]; then
        printf '%s\n' "${entry}"
        shopt -u nullglob
        return 0
      fi
    done
  done
  shopt -u nullglob

  return 1
}

workspace_state() {
  local name="$1"

  if ! podman container exists "${name}" 2>/dev/null; then
    printf 'missing'
    return
  fi

  if [ "$(podman inspect --format '{{.State.Running}}' "${name}" 2>/dev/null)" = "true" ]; then
    printf 'running'
  else
    printf 'stopped'
  fi
}

workspace_started() {
  local name="$1"
  local fallback="$2"
  local started=""

  if podman container exists "${name}" 2>/dev/null; then
    started=$(podman inspect --format '{{.State.StartedAt}}' "${name}" 2>/dev/null || true)
    if [ -n "${started}" ] && [ "${started}" != "0001-01-01 00:00:00 +0000 UTC" ]; then
      printf '%s' "${started%%.*}"
      return
    fi
  fi

  if [ -n "${fallback}" ]; then
    date -d "@${fallback}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "${fallback}"
  fi
}

list_workspaces() {
  local entry
  local app
  local seq
  local seq_name
  local alias
  local path
  local state
  local started

  registry_init
  printf '%-4s %-28s %-9s %-24s %s\n' ID ALIAS STATE STARTED PATH
  while IFS= read -r seq_name; do
    [ -n "${seq_name}" ] || continue
    entry=$(readlink -f "${REGISTRY_ROOT}/by-seq/${seq_name}")
    seq=$(read_state_file "${entry}" seq)
    alias=$(read_state_file "${entry}" alias)
    path=$(read_state_file "${entry}" path)
    app=$(read_state_file "${entry}" app)
    state=$(workspace_state "${app}")
    started=$(workspace_started "${app}" "$(read_state_file "${entry}" created_epoch)")
    printf '%-4s %-28s %-9s (%s) %s\n' "${seq}" "${alias}" "${state}" "${started}" "${path}"
  done < <(find "${REGISTRY_ROOT}/by-seq" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -n)
}

print_status() {
  local state_dir="$1"
  local name
  local value

  printf 'id: %s\n' "$(read_state_file "${state_dir}" seq)"
  printf 'alias: %s\n' "$(read_state_file "${state_dir}" alias)"
  printf 'path: %s\n' "$(read_state_file "${state_dir}" path)"
  for name in pod app fw proxy; do
    value=$(read_state_file "${state_dir}" "${name}")
    printf '%s: %s' "${name}" "${value}"
    if [ "${name}" = "pod" ]; then
      if podman pod exists "${value}" 2>/dev/null; then
        printf ' exists'
      else
        printf ' missing'
      fi
    else
      printf ' %s' "$(workspace_state "${value}")"
    fi
    printf '\n'
  done
}

resource_exists() {
  podman container exists "${CONTAINER_NAME}" 2>/dev/null \
    || podman container exists "${FW_NAME}" 2>/dev/null \
    || podman container exists "${PROXY_NAME}" 2>/dev/null \
    || podman container exists "${INFRA_NAME}" 2>/dev/null \
    || podman pod exists "${POD_NAME}" 2>/dev/null
}

app_running() {
  podman container exists "${CONTAINER_NAME}" 2>/dev/null \
    && [ "$(podman inspect --format '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null)" = "true" ]
}

firewall_running() {
  podman container exists "${FW_NAME}" 2>/dev/null \
    && [ "$(podman inspect --format '{{.State.Running}}' "${FW_NAME}" 2>/dev/null)" = "true" ]
}

cleanup_resources() {
  local mode="${1:-graceful}"
  local app_time="1.5"

  if [ "${mode}" = "immediate" ]; then
    app_time="0"
  fi

  if [ -n "${PROXY_RUNTIME_DIR_HOST}" ]; then
    rm -f "${PROXY_RUNTIME_DIR_HOST}/proxy.sock" >/dev/null 2>&1 || true
    rm -f "${PROXY_RUNTIME_DIR_HOST}/proxy-socat.pid" >/dev/null 2>&1 || true
    rm -f "${PROXY_RUNTIME_DIR_HOST}/fw-socat.pid" >/dev/null 2>&1 || true
    rmdir "${PROXY_RUNTIME_DIR_HOST}" >/dev/null 2>&1 || true
  fi

  if [ -n "${FIREWALL_POLICY_RUNTIME_DIR_HOST:-}" ]; then
    rm -f "${FIREWALL_POLICY_RUNTIME_DIR_HOST}/domains.txt" \
      "${FIREWALL_POLICY_RUNTIME_DIR_HOST}/ipv4.txt" \
      "${FIREWALL_POLICY_RUNTIME_DIR_HOST}/ipv6.txt" \
      "${FIREWALL_POLICY_RUNTIME_DIR_HOST}/resolved_ipv4.txt" \
      "${FIREWALL_POLICY_RUNTIME_DIR_HOST}/resolved_ipv6.txt" \
      "${FIREWALL_POLICY_RUNTIME_DIR_HOST}/dns_ipv4.txt" \
      "${FIREWALL_POLICY_RUNTIME_DIR_HOST}/dns_ipv6.txt" \
      "${FIREWALL_POLICY_RUNTIME_DIR_HOST}/status.env" >/dev/null 2>&1 || true
    rmdir "${FIREWALL_POLICY_RUNTIME_DIR_HOST}" >/dev/null 2>&1 || true
  fi

  podman rm --time="${app_time}" -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  podman rm --time=0 -f "$PROXY_NAME" >/dev/null 2>&1 || true
  podman rm --time=0 -f "$FW_NAME" >/dev/null 2>&1 || true
  podman rm --time=0 -f "$INFRA_NAME" >/dev/null 2>&1 || true
  podman pod rm --time=0 -f "$POD_NAME" >/dev/null 2>&1 || true
}

exec_in_app() {
  local tty_mode="$1"
  shift
  local exec_args=(-i)

  if [ "${tty_mode}" = "tty" ]; then
    exec_args+=(-t)
  fi

  podman exec "${PODMAN_EXEC_ARGS_ARRAY[@]}" "${exec_args[@]}" "${CODEX_APP_ENV_ARGS_ARRAY[@]}" -w "/app${WORK_DIR}" "${CONTAINER_NAME}" "$@"
}

exec_in_firewall() {
  local tty_mode="$1"
  shift
  local exec_args=(-i)

  if [ "${tty_mode}" = "tty" ]; then
    exec_args+=(-t)
  fi

  podman exec "${PODMAN_EXEC_ARGS_ARRAY[@]}" "${exec_args[@]}" "${FW_NAME}" "$@"
}

exec_shell_action() {
  local tty_mode="$1"
  shift

  if ! app_running; then
    echo "Error: ${CONTAINER_NAME} is not running." >&2
    echo "Start it first with: $0 --wd ${WORK_DIR}" >&2
    exit 1
  fi

  if [ "$#" -eq 0 ]; then
    if [ "${tty_mode}" = "tty" ]; then
      set -- bash
    else
      echo "Error: shell requires a command." >&2
      usage >&2
      exit 1
    fi
  fi

  exec_in_app "${tty_mode}" "$@"
  exit $?
}

exec_firewall_action() {
  local tty_mode="$1"
  shift

  if ! firewall_running; then
    echo "Error: ${FW_NAME} is not running." >&2
    echo "Start it first with: $0 --wd ${WORK_DIR} spawn" >&2
    exit 1
  fi

  if [ "$#" -eq 0 ]; then
    if [ "${tty_mode}" = "tty" ]; then
      set -- bash
    else
      echo "Error: fwshell requires a command." >&2
      usage >&2
      exit 1
    fi
  fi

  exec_in_firewall "${tty_mode}" "$@"
  exit $?
}

local_copy_path() {
  local path="$1"
  local parent
  local base

  if [ -e "${path}" ]; then
    realpath "${path}"
    return
  fi

  parent=$(dirname "${path}")
  base=$(basename "${path}")
  if [ -d "${parent}" ]; then
    printf '%s/%s\n' "$(realpath "${parent}")" "${base}"
    return
  fi

  realpath -m "${path}"
}

container_copy_path() {
  local path="$1"

  case "${path}" in
    /*) printf '%s\n' "${path}" ;;
    *) printf '/app%s/%s\n' "${WORK_DIR}" "${path}" ;;
  esac
}

copy_into_container() {
  if [ "${#ACTION_ARGS[@]}" -ne 2 ]; then
    echo "Error: ${ACTION} requires LOCAL_PATH and CONTAINER_PATH." >&2
    usage >&2
    exit 1
  fi
  if ! app_running; then
    echo "Error: ${CONTAINER_NAME} is not running." >&2
    exit 1
  fi

  local src
  local dst
  src=$(local_copy_path "${ACTION_ARGS[0]}")
  dst=$(container_copy_path "${ACTION_ARGS[1]}")

  echo "copying into container: ${src} -> ${dst}"
  podman cp "${src}" "${CONTAINER_NAME}:${dst}"
}

copy_out_of_container() {
  if [ "${#ACTION_ARGS[@]}" -ne 2 ]; then
    echo "Error: ${ACTION} requires CONTAINER_PATH and LOCAL_PATH." >&2
    usage >&2
    exit 1
  fi
  if ! app_running; then
    echo "Error: ${CONTAINER_NAME} is not running." >&2
    exit 1
  fi

  local src
  local dst
  src=$(container_copy_path "${ACTION_ARGS[0]}")
  dst=$(local_copy_path "${ACTION_ARGS[1]}")

  echo "copying out of container: ${src} -> ${dst}"
  podman cp "${CONTAINER_NAME}:${src}" "${dst}"
}

run_codex_in_app() {
  if [ -n "${CONTAINER_EXEC_COMMAND}" ]; then
    exec_in_app tty bash -lc "${CONTAINER_EXEC_COMMAND}"
    exit $?
  fi

  exec_in_app tty codex "${START_ARGS[@]}"
  exit $?
}

prompt_existing_container() {
  local choice

  if ! [ -t 0 ] || ! [ -t 1 ]; then
    echo "Error: ${CONTAINER_NAME} is already running." >&2
    echo "Use one of: enter, shell, replace, destroy, rm, kill." >&2
    exit 1
  fi

  echo "${CONTAINER_NAME} is already running."
  while true; do
    read -r -p "Enter existing, replace it, or cancel? [e/r/c] " choice
    case "${choice}" in
      e|E|enter|Enter)
        exec_shell_action tty
        ;;
      r|R|replace|Replace)
        ACTION="replace"
        return
        ;;
      c|C|cancel|Cancel|"")
        echo "cancelled"
        exit 0
        ;;
      *)
        echo "Please answer enter, replace, or cancel."
        ;;
    esac
  done
}

print_startup_summary() {
  echo "== Codex Podman Prototype =="
  echo "pod: ${POD_NAME}"
  echo "workdir: ${WORK_DIR}"
  echo "runtime image: ${CONTAINER_IMAGE}"
  echo "firewall image: ${FIREWALL_CONTAINER_IMAGE}"
  echo "proxy image: ${PROXY_CONTAINER_IMAGE}"
  if [ -n "${CODEX_LOCAL_VERSION}" ]; then
    echo "codex cli version: ${CODEX_LOCAL_VERSION}"
  fi
  if [ -n "${CODEX_LATEST_VERSION}" ]; then
    echo "codex cli latest: ${CODEX_LATEST_VERSION}"
  fi
  echo "timezone: ${HOST_TZ}"
  if [ "${#LOADED_ENV_FILES[@]}" -gt 0 ]; then
    echo "loaded env files: ${LOADED_ENV_FILES[*]}"
  fi
  if [ "${#SKIPPED_ENV_FILES[@]}" -gt 0 ]; then
    echo "missing env files: ${SKIPPED_ENV_FILES[*]}"
  fi
  if [ -n "${CODEX_CONTAINER_LAUNCHER_SNAPSHOT_PATH:-}" ]; then
    echo "launcher snapshot: ${CODEX_CONTAINER_LAUNCHER_SNAPSHOT_PATH}"
  fi
  echo "firewall policy dir: ${FIREWALL_POLICY_RUNTIME_DIR_HOST} -> ${CODEX_FIREWALL_POLICY_DIR}"
  echo "allowed domain categories: ${CODEX_ALLOWED_DOMAIN_CATEGORIES}"
  echo "allowed domains: ${OPENAI_ALLOWED_DOMAINS}"
  echo "omitted preset domains: ${CODEX_OMITTED_DOMAINS}"
  if [ -n "${EXTRA_ALLOWED_IPV4}" ]; then
    echo "extra allowed IPv4: ${EXTRA_ALLOWED_IPV4}"
  fi
  if [ -n "${EXTRA_ALLOWED_IPV6}" ]; then
    echo "extra allowed IPv6: ${EXTRA_ALLOWED_IPV6}"
  fi
  if [ -n "${PODMAN_POD_CREATE_ARGS}" ]; then
    echo "podman pod args: ${PODMAN_POD_CREATE_ARGS}"
  fi
  if [ -n "${PODMAN_FIREWALL_RUN_ARGS}" ]; then
    echo "podman firewall args: ${PODMAN_FIREWALL_RUN_ARGS}"
  fi
  if [ -n "${PODMAN_CODEX_RUN_ARGS}" ]; then
    echo "podman codex args: ${PODMAN_CODEX_RUN_ARGS}"
  fi
  if [ -n "${PODMAN_EXEC_ARGS}" ]; then
    echo "podman exec args: ${PODMAN_EXEC_ARGS}"
  fi
  if [ "${PROXY_ENABLE}" = "1" ]; then
    echo "proxy relay: ${PROXY_LISTEN_HOST}:${PROXY_LISTEN_PORT} -> ${PROXY_UPSTREAM_HOST}:${PROXY_UPSTREAM_PORT}"
    echo "proxy socket: ${PROXY_RUNTIME_DIR_HOST}/proxy.sock -> ${PROXY_SOCKET_PATH}"
  else
    echo "proxy relay: disabled"
  fi
  if [ "${CODEX_DANGEROUS_BYPASS}" = "1" ]; then
    echo "codex policy: --dangerously-bypass-approvals-and-sandbox"
  else
    echo "codex sandbox: ${CODEX_SANDBOX_MODE}"
    echo "codex approvals: ${CODEX_APPROVAL_POLICY}"
  fi
  if [ -n "${CONTAINER_EXEC_COMMAND}" ]; then
    echo "container exec override: ${CONTAINER_EXEC_COMMAND}"
  else
    echo "container exec default: codex"
  fi
}

prepare_codex_version_metadata() {
  CODEX_LOCAL_VERSION=""
  CODEX_LATEST_VERSION=""
  detect_image_label_codex_version
  if [ -z "${CODEX_LOCAL_VERSION}" ]; then
    probe_image_codex_version
  fi
  fetch_latest_codex_version
  refresh_codex_version_labels
}

action_should_snapshot() {
  case "${ACTION}" in
    help|list|name|status) return 1 ;;
    *) return 0 ;;
  esac
}

snapshot_reexec_if_needed() {
  local snapshot_dir
  local source_path
  local source_hash
  local snapshot_path

  if [ "${CODEX_CONTAINER_LAUNCHER_SNAPSHOT:-0}" = "1" ]; then
    return 0
  fi

  action_should_snapshot || return 0

  snapshot_dir="${RUNTIME_BASE_DIR}/codex-container/launcher-snapshots"
  mkdir -p "${snapshot_dir}"

  source_path="$(readlink -f "$0")"
  source_hash="$(sha256sum "${source_path}" | cut -c1-12)"
  snapshot_path="${snapshot_dir}/$(basename "${source_path}")-${source_hash}-$$"

  cp "${source_path}" "${snapshot_path}"
  chmod 700 "${snapshot_path}"

  export CODEX_CONTAINER_LAUNCHER_SNAPSHOT=1
  export CODEX_CONTAINER_LAUNCHER_SNAPSHOT_PATH="${snapshot_path}"
  exec "${snapshot_path}" "$@"
}

start_proxy_container() {
  proxy_enabled || return 0

  podman run --name "$PROXY_NAME" -d \
    --network host \
    --label "codex.workspace.path=${WORK_DIR}" \
    --label "codex.workspace.alias=${WORKSPACE_ALIAS}" \
    --label "codex.workspace.seq=${WORKSPACE_SEQ}" \
    --label "codex.workspace.hash=${WORKSPACE_HASH}" \
    --label "codex.workspace.role=proxy" \
    -e TZ="${HOST_TZ}" \
    --security-opt=no-new-privileges \
    "${PROXY_VOLUME_ARGS_ARRAY[@]}" \
    "${PROXY_CONTAINER_IMAGE}" \
    sh -c '
      set -eu
      runtime_dir=$1
      socket_path=$2
      upstream_host=$3
      upstream_port=$4

      install -d -m 777 "$runtime_dir"
      rm -f "$socket_path" "$runtime_dir/proxy-socat.pid"
      umask 000
      printf "%s\n" "$$" > "$runtime_dir/proxy-socat.pid"
      exec socat "UNIX-LISTEN:${socket_path},reuseaddr,fork,mode=777" "TCP:${upstream_host}:${upstream_port}"
    ' sh "${PROXY_RUNTIME_DIR}" "${PROXY_SOCKET_PATH}" "${PROXY_UPSTREAM_HOST}" "${PROXY_UPSTREAM_PORT}" || {
      echo "Warning: proxy container did not start cleanly in ${PROXY_NAME}; continuing without a hard failure." >&2
    }
}

start_proxy() {
  proxy_enabled || return 0

  podman exec -d "$FW_NAME" sh -c '
    set -eu
    runtime_dir=$1
    listen_host=$2
    listen_port=$3
    socket_path=$4

    install -d -m 777 "$runtime_dir"
    rm -f "$runtime_dir/fw-socat.pid"
    umask 000
    printf "%s\n" "$$" > "$runtime_dir/fw-socat.pid"
    exec socat "TCP-LISTEN:${listen_port},bind=${listen_host},reuseaddr,fork" "UNIX-CONNECT:${socket_path}"
  ' sh "${PROXY_RUNTIME_DIR}" "${PROXY_LISTEN_HOST}" "${PROXY_LISTEN_PORT}" "${PROXY_SOCKET_PATH}" || {
    echo "Warning: pod proxy relay did not start cleanly in ${FW_NAME}; continuing without a hard failure." >&2
  }
}

start_new_pod() {
  ensure_workspace_record "${WORK_DIR}"
  cleanup_resources immediate
  trap 'cleanup_resources graceful' EXIT
  prepare_proxy_runtime_dir
  prepare_firewall_policy_runtime_dir
  if proxy_enabled; then
    PROXY_VOLUME_ARGS_ARRAY=(-v "${PROXY_RUNTIME_DIR_HOST}:${PROXY_RUNTIME_DIR}:z")
  fi
  FIREWALL_POLICY_VOLUME_ARGS_ARRAY=(-v "${FIREWALL_POLICY_RUNTIME_DIR_HOST}:/etc/codex-firewall:z")
  APP_POLICY_VOLUME_ARGS_ARRAY=(-v "${FIREWALL_POLICY_RUNTIME_DIR_HOST}:${CODEX_FIREWALL_POLICY_DIR}:ro,z")

  podman pod create \
    --name "$POD_NAME" \
    --infra-name "$INFRA_NAME" \
    --network pasta \
    --userns keep-id \
    --label "codex.workspace.path=${WORK_DIR}" \
    --label "codex.workspace.alias=${WORKSPACE_ALIAS}" \
    --label "codex.workspace.seq=${WORKSPACE_SEQ}" \
    --label "codex.workspace.hash=${WORKSPACE_HASH}" \
    --label "codex.workspace.role=pod" \
    "${CODEX_VERSION_LABEL_ARGS_ARRAY[@]}" \
    "${CODEX_POD_RUNTIME_LABEL_ARGS_ARRAY[@]}" \
    "${PODMAN_POD_CREATE_ARGS_ARRAY[@]}"

  podman run --name "$FW_NAME" -d \
    --pod "$POD_NAME" \
    --user root \
    --label "codex.workspace.path=${WORK_DIR}" \
    --label "codex.workspace.alias=${WORKSPACE_ALIAS}" \
    --label "codex.workspace.seq=${WORKSPACE_SEQ}" \
    --label "codex.workspace.hash=${WORKSPACE_HASH}" \
    --label "codex.workspace.role=firewall" \
    -e TZ="${HOST_TZ}" \
    --cap-add=NET_ADMIN \
    --security-opt=no-new-privileges \
    "${FIREWALL_POLICY_VOLUME_ARGS_ARRAY[@]}" \
    "${PROXY_VOLUME_ARGS_ARRAY[@]}" \
    "${PODMAN_FIREWALL_RUN_ARGS_ARRAY[@]}" \
    "${FIREWALL_CONTAINER_IMAGE}" \
    sleep infinity

  start_proxy_container

  podman exec "$FW_NAME" firewall-init

  if [ "${#ALLOWED_DOMAIN_ARRAY[@]}" -gt 0 ]; then
    printf '%s\n' "${ALLOWED_DOMAIN_ARRAY[@]}" | podman exec -i "$FW_NAME" firewall-allow-domain
  fi

  if [ "${#EXTRA_ALLOWED_IPV4_ARRAY[@]}" -gt 0 ]; then
    printf '%s\n' "${EXTRA_ALLOWED_IPV4_ARRAY[@]}" | podman exec -i "$FW_NAME" firewall-allow-address
  fi

  if [ "${#EXTRA_ALLOWED_IPV6_ARRAY[@]}" -gt 0 ]; then
    printf '%s\n' "${EXTRA_ALLOWED_IPV6_ARRAY[@]}" | podman exec -i "$FW_NAME" firewall-allow-address
  fi

  podman exec "$FW_NAME" firewall-reload
  start_proxy

  podman run --name "$CONTAINER_NAME" -d \
    --pod "$POD_NAME" \
    --label "codex.workspace.path=${WORK_DIR}" \
    --label "codex.workspace.alias=${WORKSPACE_ALIAS}" \
    --label "codex.workspace.seq=${WORKSPACE_SEQ}" \
    --label "codex.workspace.hash=${WORKSPACE_HASH}" \
    --label "codex.workspace.role=app" \
    "${CODEX_VERSION_LABEL_ARGS_ARRAY[@]}" \
    "${CODEX_APP_RUNTIME_LABEL_ARGS_ARRAY[@]}" \
    -e OPENAI_API_KEY \
    -e TZ="${HOST_TZ}" \
    -e CODEX_WORKDIR="/app${WORK_DIR}" \
    -e CODEX_SANDBOX_MODE="${CODEX_SANDBOX_MODE}" \
    -e CODEX_APPROVAL_POLICY="${CODEX_APPROVAL_POLICY}" \
    -e CODEX_DANGEROUS_BYPASS="${CODEX_DANGEROUS_BYPASS}" \
    -e CODEX_FIREWALL_POLICY_DIR="${CODEX_FIREWALL_POLICY_DIR}" \
    "${CODEX_APP_ENV_ARGS_ARRAY[@]}" \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --user "$(id -u):$(id -g)" \
    -v "$HOME/.codex:/home/node/.codex:z" \
    -v "$WORK_DIR:/app$WORK_DIR" \
    "${APP_POLICY_VOLUME_ARGS_ARRAY[@]}" \
    "${PODMAN_CODEX_RUN_ARGS_ARRAY[@]}" \
    "${CONTAINER_IMAGE}" \
    codex-container-init

  trap - EXIT
}

parse_args "$@"
apply_trailing_selector

if [ "${ACTION}" = "help" ]; then
  usage
  exit 0
fi

RUNTIME_BASE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
REGISTRY_ROOT="${RUNTIME_BASE_DIR}/codex-container/workspaces"

if ! command -v podman >/dev/null 2>&1; then
  echo "Error: podman is not installed." >&2
  exit 1
fi

snapshot_reexec_if_needed "$@"

if [ "${ACTION}" = "list" ]; then
  list_workspaces
  exit 0
fi

if [ -n "${SELECTOR_ID}" ] && [ "${WORK_DIR_SELECTED}" = "0" ]; then
  set +e
  SELECTOR_STATE_DIR=$(resolve_target_state "${SELECTOR_ID}")
  resolve_status=$?
  set -e
  if [ "${resolve_status}" -ne 0 ]; then
    if [ "${resolve_status}" -ne 2 ]; then
      echo "Error: unknown workspace id: ${SELECTOR_ID}" >&2
    fi
    exit 1
  fi
  WORK_DIR=$(read_state_file "${SELECTOR_STATE_DIR}" path)
fi

WORK_DIR=$(realpath -m "$WORK_DIR")
load_selected_workspace_env_if_needed
WORKSPACE_SLUG=$(slugify "$(basename "${WORK_DIR}")")
WORKSPACE_HASH=$(stable_hash "${WORK_DIR}")
POD_NAME="codex-${WORKSPACE_SLUG}-${WORKSPACE_HASH}"
INFRA_NAME="${POD_NAME}-infra"
FW_NAME="${POD_NAME}-fw"
PROXY_NAME="${POD_NAME}-proxy"
CONTAINER_NAME="${POD_NAME}-app"
HOST_TZ=$(detect_host_tz)
DEFAULT_PROXY_RUNTIME_DIR_HOST="${RUNTIME_BASE_DIR}/${POD_NAME}-proxy"
: "${PROXY_RUNTIME_DIR_HOST:=${DEFAULT_PROXY_RUNTIME_DIR_HOST}}"
DEFAULT_FIREWALL_POLICY_RUNTIME_DIR_HOST="${RUNTIME_BASE_DIR}/${POD_NAME}-policy"
: "${FIREWALL_POLICY_RUNTIME_DIR_HOST:=${DEFAULT_FIREWALL_POLICY_RUNTIME_DIR_HOST}}"

if [ -z "$WORK_DIR" ]; then
  echo "Error: No work directory provided and WORKSPACE_ROOT_DIR is not set."
  exit 1
fi

if [ -z "$OPENAI_ALLOWED_DOMAINS" ]; then
  echo "Error: OPENAI_ALLOWED_DOMAINS is empty."
  exit 1
fi

if [[ "${CODEX_DANGEROUS_BYPASS}" != "0" && "${CODEX_DANGEROUS_BYPASS}" != "1" ]]; then
  echo "Error: CODEX_DANGEROUS_BYPASS must be 0 or 1." >&2
  exit 1
fi

if [[ "${PROXY_ENABLE}" != "0" && "${PROXY_ENABLE}" != "1" ]]; then
  echo "Error: PROXY_ENABLE must be 0 or 1." >&2
  exit 1
fi

if [[ "${CODEX_RELEASE_CHECK_ON_SPAWN}" != "0" && "${CODEX_RELEASE_CHECK_ON_SPAWN}" != "1" ]]; then
  echo "Error: CODEX_RELEASE_CHECK_ON_SPAWN must be 0 or 1." >&2
  exit 1
fi

if ! validate_sandbox_mode "${CODEX_SANDBOX_MODE}"; then
  echo "Error: Invalid CODEX_SANDBOX_MODE: ${CODEX_SANDBOX_MODE}" >&2
  exit 1
fi

if ! validate_approval_policy "${CODEX_APPROVAL_POLICY}"; then
  echo "Error: Invalid CODEX_APPROVAL_POLICY: ${CODEX_APPROVAL_POLICY}" >&2
  exit 1
fi

if ! validate_port "${PROXY_LISTEN_PORT}"; then
  echo "Error: Invalid PROXY_LISTEN_PORT: ${PROXY_LISTEN_PORT}" >&2
  exit 1
fi

if ! validate_port "${PROXY_UPSTREAM_PORT}"; then
  echo "Error: Invalid PROXY_UPSTREAM_PORT: ${PROXY_UPSTREAM_PORT}" >&2
  exit 1
fi

if ! validate_non_negative_integer "${CODEX_RELEASE_API_TIMEOUT_SECONDS}"; then
  echo "Error: Invalid CODEX_RELEASE_API_TIMEOUT_SECONDS: ${CODEX_RELEASE_API_TIMEOUT_SECONDS}" >&2
  exit 1
fi

for domain in "${ALLOWED_DOMAIN_ARRAY[@]}"; do
  if ! validate_domain "${domain}"; then
    echo "Error: Invalid domain format: ${domain}" >&2
    exit 1
  fi
done

for address in "${EXTRA_ALLOWED_IPV4_ARRAY[@]}"; do
  if ! validate_ipv4 "${address}"; then
    echo "Error: Invalid IPv4/CIDR format: ${address}" >&2
    exit 1
  fi
done

for address in "${EXTRA_ALLOWED_IPV6_ARRAY[@]}"; do
  if ! validate_ipv6 "${address}"; then
    echo "Error: Invalid IPv6/CIDR format: ${address}" >&2
    exit 1
  fi
done

if [ -z "${SELECTOR_STATE_DIR}" ] && [ -L "${REGISTRY_ROOT}/by-path-hash/${WORKSPACE_HASH}" ]; then
  SELECTOR_STATE_DIR=$(readlink -f "${REGISTRY_ROOT}/by-path-hash/${WORKSPACE_HASH}")
fi

case "${ACTION}" in
  status)
    if [ -n "${SELECTOR_STATE_DIR}" ]; then
      print_status "${SELECTOR_STATE_DIR}"
    else
      printf 'path: %s\n' "${WORK_DIR}"
      printf 'pod: %s %s\n' "${POD_NAME}" "$(podman pod exists "${POD_NAME}" 2>/dev/null && printf exists || printf missing)"
      printf 'app: %s %s\n' "${CONTAINER_NAME}" "$(workspace_state "${CONTAINER_NAME}")"
      printf 'fw: %s %s\n' "${FW_NAME}" "$(workspace_state "${FW_NAME}")"
      printf 'proxy: %s %s\n' "${PROXY_NAME}" "$(workspace_state "${PROXY_NAME}")"
    fi
    exit 0
    ;;
  name)
    if [ -n "${SELECTOR_STATE_DIR}" ]; then
      read_state_file "${SELECTOR_STATE_DIR}" app
    else
      printf '%s\n' "${CONTAINER_NAME}"
    fi
    exit 0
    ;;
  spawn)
    if app_running; then
      ensure_workspace_record "${WORK_DIR}"
      echo "already running: ${CONTAINER_NAME}"
      exit 0
    fi
    prepare_codex_version_metadata
    print_startup_summary
    hold_startup_summary
    start_new_pod
    echo "spawned: ${CONTAINER_NAME}"
    exit 0
    ;;
  enter)
    exec_shell_action tty "${ACTION_ARGS[@]}"
    ;;
  shell)
    exec_shell_action notty "${ACTION_ARGS[@]}"
    ;;
  fwenter)
    exec_firewall_action tty "${ACTION_ARGS[@]}"
    ;;
  fwshell)
    exec_firewall_action notty "${ACTION_ARGS[@]}"
    ;;
  destroy|rm)
    if resource_exists; then
      cleanup_resources graceful
      echo "removed ${POD_NAME}"
    else
      echo "nothing to remove for ${POD_NAME}"
    fi
    exit 0
    ;;
  kill)
    if resource_exists; then
      cleanup_resources immediate
      echo "killed ${POD_NAME}"
    else
      echo "nothing to kill for ${POD_NAME}"
    fi
    exit 0
    ;;
  copy|push)
    copy_into_container
    exit 0
    ;;
  pull|fetch)
    copy_out_of_container
    exit 0
    ;;
  replace)
    if resource_exists; then
      echo "replacing ${POD_NAME}"
      cleanup_resources immediate
    else
      echo "nothing to replace for ${POD_NAME}; starting new pod"
    fi
    START_ARGS=("${ACTION_ARGS[@]}")
    ;;
  start)
    if app_running; then
      ensure_workspace_record "${WORK_DIR}"
      if [ "${#START_ARGS[@]}" -eq 0 ]; then
        prompt_existing_container
        if [ "${ACTION}" = "replace" ]; then
          cleanup_resources immediate
        fi
      else
        run_codex_in_app
      fi
    fi
    ;;
esac

prepare_codex_version_metadata
print_startup_summary
hold_startup_summary
start_new_pod
run_codex_in_app
