#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fakebin="${tmpdir}/bin"
mkdir -p "${fakebin}" "${tmpdir}/runtime" "${tmpdir}/work"

cat > "${fakebin}/podman" <<'FAKE_PODMAN'
#!/bin/sh
printf '%s\n' "$*" >> "${PODMAN_LOG}"

case "$1" in
  container)
    [ "$2" = "exists" ] && exit 1
    ;;
  pod)
    [ "$2" = "exists" ] && exit 1
    [ "$2" = "create" ] && exit 0
    [ "$2" = "rm" ] && exit 0
    ;;
  rm)
    exit 0
    ;;
  run)
    exit 0
    ;;
  exec)
    exit 0
    ;;
esac

exit 0
FAKE_PODMAN

chmod 755 "${fakebin}/podman"

export PATH="${fakebin}:${PATH}"
export PODMAN_LOG="${tmpdir}/podman.log"
export XDG_RUNTIME_DIR="${tmpdir}/runtime"

PROXY_ENABLE=0 CODEX_RELEASE_CHECK_ON_SPAWN=0 STARTUP_SUMMARY_HOLD_SECONDS=0 "${repo_root}/run-in-container.sh" --wd "${tmpdir}/work" spawn

grep -Fq 'pod create' "${PODMAN_LOG}"
grep -Fq 'run --name codex-work-' "${PODMAN_LOG}"
domain_exec_count=$(grep -Fc 'exec -i codex-work-' "${PODMAN_LOG}")
if [ "${domain_exec_count}" -ne 1 ]; then
  echo "expected one batched domain exec, got ${domain_exec_count}" >&2
  exit 1
fi
grep -Fq 'firewall-allow-domain' "${PODMAN_LOG}"
if grep -Fq '/run/codex-proxy' "${PODMAN_LOG}"; then
  echo "proxy volume should not be mounted when PROXY_ENABLE=0" >&2
  exit 1
fi
grep -Fq '/run/codex-firewall-policy:ro,z' "${PODMAN_LOG}"
