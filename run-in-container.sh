#!/bin/bash
set -euo pipefail

WORK_DIR="${WORKSPACE_ROOT_DIR:-$(pwd)}"
: "${OPENAI_ALLOWED_DOMAINS:=api.openai.com auth.openai.com chatgpt.com}"
: "${EXTRA_ALLOWED_DOMAINS:=}"
: "${EXTRA_ALLOWED_IPV4:=}"
: "${EXTRA_ALLOWED_IPV6:=}"
: "${CONTAINER_IMAGE:=codex}"
: "${FIREWALL_CONTAINER_IMAGE:=codex-firewall}"
: "${PROXY_CONTAINER_IMAGE:=${FIREWALL_CONTAINER_IMAGE}}"
: "${PROXY_ENABLE:=1}"
: "${PROXY_RUNTIME_DIR:=/run/codex-proxy}"
: "${PROXY_SOCKET_PATH:=/run/codex-proxy/proxy.sock}"
: "${PROXY_LISTEN_HOST:=localhost}"
: "${PROXY_LISTEN_PORT:=1080}"
: "${PROXY_UPSTREAM_HOST:=localhost}"
: "${PROXY_UPSTREAM_PORT:=1080}"
: "${CODEX_SANDBOX_MODE:=danger-full-access}"
: "${CODEX_APPROVAL_POLICY:=on-request}"
: "${CODEX_DANGEROUS_BYPASS:=0}"
: "${PODMAN_POD_CREATE_ARGS:=}"
: "${PODMAN_FIREWALL_RUN_ARGS:=}"
: "${PODMAN_CODEX_RUN_ARGS:=}"
: "${PODMAN_EXEC_ARGS:=}"
: "${CONTAINER_EXEC_COMMAND:=}"
: "${STARTUP_SUMMARY_HOLD_SECONDS:=1.2}"

if [[ -n "${EXTRA_ALLOWED_DOMAINS}" ]]; then
  OPENAI_ALLOWED_DOMAINS+=" ${EXTRA_ALLOWED_DOMAINS}"
fi

read -r -a ALLOWED_DOMAIN_ARRAY <<< "${OPENAI_ALLOWED_DOMAINS}"
read -r -a EXTRA_ALLOWED_IPV4_ARRAY <<< "${EXTRA_ALLOWED_IPV4}"
read -r -a EXTRA_ALLOWED_IPV6_ARRAY <<< "${EXTRA_ALLOWED_IPV6}"
read -r -a PODMAN_POD_CREATE_ARGS_ARRAY <<< "${PODMAN_POD_CREATE_ARGS}"
read -r -a PODMAN_FIREWALL_RUN_ARGS_ARRAY <<< "${PODMAN_FIREWALL_RUN_ARGS}"
read -r -a PODMAN_CODEX_RUN_ARGS_ARRAY <<< "${PODMAN_CODEX_RUN_ARGS}"
read -r -a PODMAN_EXEC_ARGS_ARRAY <<< "${PODMAN_EXEC_ARGS}"
PROXY_VOLUME_ARGS_ARRAY=()
ACTION="start"
ACTION_ARGS=()
START_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  run-in-container.sh [--wd DIR] [CODEX_ARGS...]
  run-in-container.sh [--wd DIR] help
  run-in-container.sh [--wd DIR] spawn
  run-in-container.sh [--wd DIR] enter [COMMAND...]
  run-in-container.sh [--wd DIR] shell COMMAND...
  run-in-container.sh [--wd DIR] replace [CODEX_ARGS...]
  run-in-container.sh [--wd DIR] destroy|rm|kill
  run-in-container.sh [--wd DIR] copy|push LOCAL_PATH CONTAINER_PATH
  run-in-container.sh [--wd DIR] pull|fetch CONTAINER_PATH LOCAL_PATH

Launcher commands:
  help          Show this help. Use --help for Codex CLI help.
  spawn         Start the workspace pod in the background and exit.
  enter         Enter the running workspace container with a TTY. Defaults to bash.
  shell         Run a command in the running workspace container without a TTY.
  replace       Remove any existing workspace pod, then start Codex normally.
  destroy, rm   Remove the workspace pod and exit.
  kill          Immediately remove the workspace pod and exit.
  copy, push    Copy from the host into the workspace container.
  pull, fetch   Copy from the workspace container to the host.

Only --wd is parsed by this launcher. Other dash arguments are passed to Codex.
Relative container copy paths resolve under the preserved /app host path. Local
copy paths are resolved to absolute host paths before calling podman cp.
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
          help|spawn|enter|shell|replace|destroy|rm|kill|copy|push|pull|fetch)
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
  proxy_enabled || return

  mkdir -p "${PROXY_RUNTIME_DIR_HOST}" || {
    echo "Warning: could not create proxy runtime dir at ${PROXY_RUNTIME_DIR_HOST}; disabling proxy relay." >&2
    PROXY_ENABLE=0
  }

  chmod 0777 "${PROXY_RUNTIME_DIR_HOST}" || {
    echo "Warning: could not relax proxy runtime dir permissions at ${PROXY_RUNTIME_DIR_HOST}; disabling proxy relay." >&2
    PROXY_ENABLE=0
  }
}

resource_exists() {
  podman container exists "${CONTAINER_NAME}" \
    || podman container exists "${FW_NAME}" \
    || podman container exists "${PROXY_NAME}" \
    || podman container exists "${INFRA_NAME}" \
    || podman pod exists "${POD_NAME}"
}

app_running() {
  podman container exists "${CONTAINER_NAME}" \
    && [ "$(podman inspect --format '{{.State.Running}}' "${CONTAINER_NAME}")" = "true" ]
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

  podman exec "${PODMAN_EXEC_ARGS_ARRAY[@]}" "${exec_args[@]}" -w "/app${WORK_DIR}" "${CONTAINER_NAME}" "$@"
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
  echo "timezone: ${HOST_TZ}"
  echo "allowed domains: ${OPENAI_ALLOWED_DOMAINS}"
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

start_proxy_container() {
  proxy_enabled || return

  podman run --name "$PROXY_NAME" -d \
    --network host \
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
  proxy_enabled || return

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
  cleanup_resources immediate
  trap 'cleanup_resources graceful' EXIT
  prepare_proxy_runtime_dir
  proxy_enabled && PROXY_VOLUME_ARGS_ARRAY=(-v "${PROXY_RUNTIME_DIR_HOST}:${PROXY_RUNTIME_DIR}:z")

  podman pod create \
    --name "$POD_NAME" \
    --infra-name "$INFRA_NAME" \
    --network pasta \
    --userns keep-id \
    "${PODMAN_POD_CREATE_ARGS_ARRAY[@]}"

  podman run --name "$FW_NAME" -d \
    --pod "$POD_NAME" \
    --user root \
    -e TZ="${HOST_TZ}" \
    --cap-add=NET_ADMIN \
    --security-opt=no-new-privileges \
    "${PROXY_VOLUME_ARGS_ARRAY[@]}" \
    "${PODMAN_FIREWALL_RUN_ARGS_ARRAY[@]}" \
    "${FIREWALL_CONTAINER_IMAGE}" \
    sleep infinity

  start_proxy_container

  podman exec "$FW_NAME" firewall-init

  for domain in "${ALLOWED_DOMAIN_ARRAY[@]}"; do
    podman exec "$FW_NAME" firewall-allow-domain "$domain"
  done

  for address in "${EXTRA_ALLOWED_IPV4_ARRAY[@]}"; do
    podman exec "$FW_NAME" firewall-allow-address "$address"
  done

  for address in "${EXTRA_ALLOWED_IPV6_ARRAY[@]}"; do
    podman exec "$FW_NAME" firewall-allow-address "$address"
  done

  podman exec "$FW_NAME" firewall-reload
  start_proxy

  podman run --name "$CONTAINER_NAME" -d \
    --pod "$POD_NAME" \
    -e OPENAI_API_KEY \
    -e TZ="${HOST_TZ}" \
    -e CODEX_WORKDIR="/app${WORK_DIR}" \
    -e CODEX_SANDBOX_MODE="${CODEX_SANDBOX_MODE}" \
    -e CODEX_APPROVAL_POLICY="${CODEX_APPROVAL_POLICY}" \
    -e CODEX_DANGEROUS_BYPASS="${CODEX_DANGEROUS_BYPASS}" \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --user "$(id -u):$(id -g)" \
    -v "$HOME/.codex:/home/node/.codex:z" \
    -v "$WORK_DIR:/app$WORK_DIR" \
    "${PODMAN_CODEX_RUN_ARGS_ARRAY[@]}" \
    "${CONTAINER_IMAGE}" \
    codex-container-init

  trap - EXIT
}

parse_args "$@"

if [ "${ACTION}" = "help" ]; then
  usage
  exit 0
fi

WORK_DIR=$(realpath "$WORK_DIR")
WORKSPACE_SLUG=$(slugify "$(basename "${WORK_DIR}")")
WORKSPACE_HASH=$(stable_hash "${WORK_DIR}")
POD_NAME="codex-${WORKSPACE_SLUG}-${WORKSPACE_HASH}"
INFRA_NAME="${POD_NAME}-infra"
FW_NAME="${POD_NAME}-fw"
PROXY_NAME="${POD_NAME}-proxy"
CONTAINER_NAME="${POD_NAME}-app"
HOST_TZ=$(detect_host_tz)
RUNTIME_BASE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
DEFAULT_PROXY_RUNTIME_DIR_HOST="${RUNTIME_BASE_DIR}/${POD_NAME}-proxy"
: "${PROXY_RUNTIME_DIR_HOST:=${DEFAULT_PROXY_RUNTIME_DIR_HOST}}"

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

if ! command -v podman >/dev/null 2>&1; then
  echo "Error: podman is not installed." >&2
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

case "${ACTION}" in
  spawn)
    if app_running; then
      echo "already running: ${CONTAINER_NAME}"
      exit 0
    fi
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
      prompt_existing_container
      if [ "${ACTION}" = "replace" ]; then
        cleanup_resources immediate
      fi
    fi
    ;;
esac

print_startup_summary
hold_startup_summary
start_new_pod
run_codex_in_app
