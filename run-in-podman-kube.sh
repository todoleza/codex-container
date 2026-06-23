#!/bin/bash
set -euo pipefail

WORK_DIR="${WORKSPACE_ROOT_DIR:-$(pwd)}"
OPENAI_ALLOWED_DOMAINS="${OPENAI_ALLOWED_DOMAINS:-api.openai.com auth.openai.com chatgpt.com api.github.com}"
: "${EXTRA_ALLOWED_DOMAINS:=}"
: "${EXTRA_ALLOWED_IPV4:=}"
: "${EXTRA_ALLOWED_IPV6:=}"
: "${CONTAINER_IMAGE:=codex}"
: "${FIREWALL_CONTAINER_IMAGE:=codex-firewall}"
: "${CODEX_SANDBOX_MODE:=danger-full-access}"
: "${CODEX_APPROVAL_POLICY:=on-request}"
: "${CODEX_DANGEROUS_BYPASS:=0}"

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

qualify_image_ref() {
  local image="$1"
  if [[ "${image}" == *"/"* || "${image}" == *":"* ]]; then
    printf '%s' "${image}"
  else
    printf 'localhost/%s:latest' "${image}"
  fi
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
TMPDIR_CREATED="$(mktemp -d)"
MANIFEST_PATH="${TMPDIR_CREATED}/pod.yaml"
RUNTIME_IMAGE=$(qualify_image_ref "${CONTAINER_IMAGE}")
FIREWALL_IMAGE=$(qualify_image_ref "${FIREWALL_CONTAINER_IMAGE}")
HOST_TZ=$(detect_host_tz)

cleanup() {
  podman kube down "${MANIFEST_PATH}" >/dev/null 2>&1 || true
  rm -rf "${TMPDIR_CREATED}"
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

if [[ "${CODEX_DANGEROUS_BYPASS}" != "0" && "${CODEX_DANGEROUS_BYPASS}" != "1" ]]; then
  echo "Error: CODEX_DANGEROUS_BYPASS must be 0 or 1." >&2
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

cat > "${MANIFEST_PATH}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  annotations:
    io.podman.annotations.userns: keep-id
    io.podman.annotations.infra.name: ${INFRA_NAME}
spec:
  restartPolicy: Never
  volumes:
    - name: codex-home
      hostPath:
        path: "${HOME}/.codex"
        type: DirectoryOrCreate
    - name: workspace
      hostPath:
        path: "${WORK_DIR}"
        type: Directory
  containers:
    - name: firewall
      image: ${FIREWALL_IMAGE}
      command: ["sleep", "infinity"]
      env:
        - name: TZ
          value: "${HOST_TZ}"
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          add:
            - NET_ADMIN
    - name: codex
      image: ${RUNTIME_IMAGE}
      command: ["sleep", "infinity"]
      env:
        - name: OPENAI_API_KEY
          value: "${OPENAI_API_KEY:-}"
        - name: TZ
          value: "${HOST_TZ}"
        - name: CODEX_WORKDIR
          value: "${WORK_DIR}"
        - name: CODEX_SANDBOX_MODE
          value: "${CODEX_SANDBOX_MODE}"
        - name: CODEX_APPROVAL_POLICY
          value: "${CODEX_APPROVAL_POLICY}"
        - name: CODEX_DANGEROUS_BYPASS
          value: "${CODEX_DANGEROUS_BYPASS}"
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: codex-home
          mountPath: /home/node/.codex
        - name: workspace
          mountPath: ${WORK_DIR}
EOF

podman kube play --replace --network pasta "${MANIFEST_PATH}" >/dev/null

FW_NAME=$(podman ps --filter "pod=${POD_NAME}" --format '{{.Names}}' | grep -- '-firewall$' | head -n1)
APP_NAME=$(podman ps --filter "pod=${POD_NAME}" --format '{{.Names}}' | grep -- '-codex$' | head -n1)

if [ -z "${FW_NAME}" ] || [ -z "${APP_NAME}" ]; then
  echo "Error: Failed to discover kube-play container names for pod ${POD_NAME}." >&2
  exit 1
fi

podman exec "${FW_NAME}" firewall-init

for domain in "${ALLOWED_DOMAIN_ARRAY[@]}"; do
  podman exec "${FW_NAME}" firewall-allow-domain "${domain}"
done

for address in "${EXTRA_ALLOWED_IPV4_ARRAY[@]}"; do
  podman exec "${FW_NAME}" firewall-allow-address "${address}"
done

for address in "${EXTRA_ALLOWED_IPV6_ARRAY[@]}"; do
  podman exec "${FW_NAME}" firewall-allow-address "${address}"
done

podman exec "${FW_NAME}" firewall-reload

quoted_args=""
for arg in "$@"; do
  quoted_args+=" $(printf '%q' "$arg")"
done

podman exec -it "${APP_NAME}" bash -c "cd \"${WORK_DIR}\" && codex ${quoted_args}"
