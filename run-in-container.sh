#!/bin/bash
set -euo pipefail

# Usage:
#   ./run-in-container.sh [--work_dir directory] "COMMAND"
#
#   Examples:
#     ./run-in-container.sh --work_dir project/code "ls -la"
#     ./run-in-container.sh "echo Hello, world!"

# Default the work directory to WORKSPACE_ROOT_DIR if not provided.
WORK_DIR="${WORKSPACE_ROOT_DIR:-$(pwd)}"
OPENAI_ALLOWED_DOMAINS="${OPENAI_ALLOWED_DOMAINS:-api.openai.com chatgpt.com deb.debian.org auth.openai.com}"
: "${EXTRA_ALLOWED_DOMAINS:=}"
: "${EXTRA_ALLOWED_IPV4:=}"
: "${EXTRA_ALLOWED_IPV6:=}"
: "${CONTAINER_IMAGE:=codex}"
: "${FIREWALL_CONTAINER_IMAGE:=codex-firewall}"
: "${PODMAN_BIN:=podman}"

if [[ -n "${EXTRA_ALLOWED_DOMAINS}" ]]; then
    OPENAI_ALLOWED_DOMAINS+=" $EXTRA_ALLOWED_DOMAINS"
fi

read -r -a ALLOWED_DOMAIN_ARRAY <<< "${OPENAI_ALLOWED_DOMAINS}"
read -r -a EXTRA_ALLOWED_IPV4_ARRAY <<< "${EXTRA_ALLOWED_IPV4}"
read -r -a EXTRA_ALLOWED_IPV6_ARRAY <<< "${EXTRA_ALLOWED_IPV6}"

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 [--work_dir directory] \"COMMAND\""
  exit 1
fi

if [ "${1:-}" = "--work_dir" ]; then
  if [ -z "$2" ]; then
    echo "Error: --work_dir flag provided but no directory specified."
    exit 1
  fi
  WORK_DIR="$2"
  shift 2
fi

WORK_DIR=$(realpath "$WORK_DIR")

CONTAINER_NAME="codex_$(echo "$WORK_DIR" | sed 's/\//_/g' | sed 's/[^a-zA-Z0-9_-]//g')"
POD_NAME="${CONTAINER_NAME}_pod"
FW_NAME="${CONTAINER_NAME}_fw"

cleanup() {
  "${PODMAN_BIN}" rm --time=0 -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  "${PODMAN_BIN}" rm --time=0 -f "$FW_NAME" >/dev/null 2>&1 || true
  "${PODMAN_BIN}" pod rm --time=0 -f "$POD_NAME" >/dev/null 2>&1 || true
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

podman_exec() {
  "${PODMAN_BIN}" exec "$@"
}

if [ -z "$WORK_DIR" ]; then
  echo "Error: No work directory provided and WORKSPACE_ROOT_DIR is not set."
  exit 1
fi

if [ -z "$OPENAI_ALLOWED_DOMAINS" ]; then
  echo "Error: OPENAI_ALLOWED_DOMAINS is empty."
  exit 1
fi

if ! command -v "${PODMAN_BIN}" >/dev/null 2>&1; then
  echo "Error: ${PODMAN_BIN} is not installed." >&2
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

cleanup

"${PODMAN_BIN}" pod create \
  --name "$POD_NAME" \
  --network pasta \
  --userns keep-id

"${PODMAN_BIN}" run --name "$FW_NAME" -d \
  --pod "$POD_NAME" \
  --user root \
  --cap-add=NET_ADMIN \
  --security-opt=no-new-privileges \
  "${FIREWALL_CONTAINER_IMAGE}" \
  sleep infinity

podman_exec "$FW_NAME" firewall-init

for domain in "${ALLOWED_DOMAIN_ARRAY[@]}"; do
  podman_exec "$FW_NAME" firewall-allow-domain "$domain"
done

for address in "${EXTRA_ALLOWED_IPV4_ARRAY[@]}"; do
  podman_exec "$FW_NAME" firewall-allow-address "$address"
done

for address in "${EXTRA_ALLOWED_IPV6_ARRAY[@]}"; do
  podman_exec "$FW_NAME" firewall-allow-address "$address"
done

podman_exec "$FW_NAME" firewall-reload

"${PODMAN_BIN}" run --name "$CONTAINER_NAME" -d \
  --pod "$POD_NAME" \
  -e OPENAI_API_KEY \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --user "$(id -u):$(id -g)" \
  -v "$HOME/.codex:/home/node/.codex:z" \
  -v "$WORK_DIR:/app$WORK_DIR" \
  "${CONTAINER_IMAGE}" \
  sleep infinity

quoted_args=""
for arg in "$@"; do
  quoted_args+=" $(printf '%q' "$arg")"
done

"${PODMAN_BIN}" exec -it "$CONTAINER_NAME" bash -c "cd \"/app$WORK_DIR\" && codex ${quoted_args}"
