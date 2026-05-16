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
OPENAI_ALLOWED_DOMAINS="${OPENAI_ALLOWED_DOMAINS:-api.openai.com auth.openai.com chatgpt.com}"
: "${EXTRA_ALLOWED_DOMAINS:=}"
: "${EXTRA_ALLOWED_IPV4:=}"
: "${EXTRA_ALLOWED_IPV6:=}"
: "${CONTAINER_IMAGE:=codex}"
: "${FIREWALL_CONTAINER_IMAGE:=codex-firewall}"

if [[ -n "${EXTRA_ALLOWED_DOMAINS}" ]]; then
  OPENAI_ALLOWED_DOMAINS+=" ${EXTRA_ALLOWED_DOMAINS}"
fi

read -r -a ALLOWED_DOMAIN_ARRAY <<< "${OPENAI_ALLOWED_DOMAINS}"
read -r -a EXTRA_ALLOWED_IPV4_ARRAY <<< "${EXTRA_ALLOWED_IPV4}"
read -r -a EXTRA_ALLOWED_IPV6_ARRAY <<< "${EXTRA_ALLOWED_IPV6}"

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

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 [--work_dir directory] \"COMMAND\""
  exit 1
fi

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
CONTAINER_NAME="${POD_NAME}-app"

cleanup() {
  podman rm --time=0 -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
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

if [ -z "$WORK_DIR" ]; then
  echo "Error: No work directory provided and WORKSPACE_ROOT_DIR is not set."
  exit 1
fi

if [ -z "$OPENAI_ALLOWED_DOMAINS" ]; then
  echo "Error: OPENAI_ALLOWED_DOMAINS is empty."
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

cleanup

podman pod create \
  --name "$POD_NAME" \
  --infra-name "$INFRA_NAME" \
  --network pasta \
  --userns keep-id

podman run --name "$FW_NAME" -d \
  --pod "$POD_NAME" \
  --user root \
  --cap-add=NET_ADMIN \
  --security-opt=no-new-privileges \
  "${FIREWALL_CONTAINER_IMAGE}" \
  sleep infinity

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

podman run --name "$CONTAINER_NAME" -d \
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

podman exec -it "$CONTAINER_NAME" bash -c "cd \"/app$WORK_DIR\" && codex ${quoted_args}"
