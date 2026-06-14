#!/bin/bash
set -euo pipefail

# Usage:
#   ./run-in-container.sh [--work_dir directory] ["COMMAND"]
#
#   Examples:
#     ./run-in-container.sh --work_dir project/code "ls -la"
#     ./run-in-container.sh "echo Hello, world!"
#     ./run-in-container.sh

# Default the work directory to WORKSPACE_ROOT_DIR if not provided.
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

if [ "${1:-}" = "--work_dir" ]; then
  if [ -z "${2:-}" ]; then
    echo "Error: --work_dir flag provided but no directory specified."
    exit 1
  fi
  WORK_DIR="$2"
  shift 2
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

cleanup() {
  if [ -n "${PROXY_RUNTIME_DIR_HOST}" ]; then
    rm -f "${PROXY_RUNTIME_DIR_HOST}/proxy.sock" >/dev/null 2>&1 || true
    rm -f "${PROXY_RUNTIME_DIR_HOST}/proxy-socat.pid" >/dev/null 2>&1 || true
    rm -f "${PROXY_RUNTIME_DIR_HOST}/fw-socat.pid" >/dev/null 2>&1 || true
    rmdir "${PROXY_RUNTIME_DIR_HOST}" >/dev/null 2>&1 || true
  fi
  podman rm --time=1.5 -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  podman rm --time=0 -f "$PROXY_NAME" >/dev/null 2>&1 || true
  podman rm --time=0 -f "$FW_NAME" >/dev/null 2>&1 || true
  podman rm --time=0 -f "$INFRA_NAME" >/dev/null 2>&1 || true
  podman pod rm --time=0 -f "$POD_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

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
elif [ "$#" -eq 0 ]; then
  echo "container exec default: interactive bash"
fi
hold_startup_summary

cleanup
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
  sleep infinity

quoted_args=""
for arg in "$@"; do
  quoted_args+=" $(printf '%q' "$arg")"
done

codex_flags=""
if [ "${CODEX_DANGEROUS_BYPASS}" = "1" ]; then
  codex_flags+=" --dangerously-bypass-approvals-and-sandbox"
else
  codex_flags+=" --sandbox $(printf '%q' "${CODEX_SANDBOX_MODE}")"
  codex_flags+=" --ask-for-approval $(printf '%q' "${CODEX_APPROVAL_POLICY}")"
fi

container_exec_command="${CONTAINER_EXEC_COMMAND}"
if [ -z "${container_exec_command}" ]; then
  if [ "$#" -eq 0 ]; then
    container_exec_command="bash"
  else
    container_exec_command="codex${codex_flags}${quoted_args}"
  fi
fi

podman exec "${PODMAN_EXEC_ARGS_ARRAY[@]}" -it "$CONTAINER_NAME" bash -c "cd \"/app$WORK_DIR\" && ${container_exec_command}"
