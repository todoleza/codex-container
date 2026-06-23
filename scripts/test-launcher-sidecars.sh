#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fakebin="${tmpdir}/bin"
mkdir -p "${fakebin}" "${tmpdir}/runtime" "${tmpdir}/work" "${tmpdir}/bad-work"

cat > "${fakebin}/podman" <<'FAKE_PODMAN'
#!/bin/sh
printf '%s\n' "$*" >> "${PODMAN_LOG}"

case "$1" in
  container)
    if [ "$2" = "exists" ]; then
      [ "${FAKE_CONTAINER_EXISTS:-0}" = "1" ] && exit 0
      exit 1
    fi
    ;;
  image)
    [ "$2" = "inspect" ] && exit 1
    ;;
  pod)
    [ "$2" = "exists" ] && exit 1
    [ "$2" = "create" ] && exit 0
    [ "$2" = "rm" ] && exit 0
    ;;
  rm|run|exec)
    exit 0
    ;;
esac

exit 0
FAKE_PODMAN

chmod 755 "${fakebin}/podman"

export PATH="${fakebin}:${PATH}"
export PODMAN_LOG="${tmpdir}/podman.log"
export XDG_RUNTIME_DIR="${tmpdir}/runtime"

SIDECARS=hcloud:metrics \
SIDECAR_hcloud_IMAGE=localhost/hcloud-acl-proxy:latest \
SIDECAR_hcloud_ENV_PREFIX=HCLOUD_PROXY_ENV_ \
SIDECAR_hcloud_RUN_ARGS='-v ${CODEX_POLICY_DIR}/hcloud-acl-policy.yaml:/config/policy.yaml:ro --read-only' \
SIDECAR_hcloud_COMMAND="run-proxy --listen 127.0.0.1:8090" \
SIDECAR_metrics_IMAGE=localhost/metrics-proxy:latest \
SIDECAR_metrics_ENV_PREFIX=METRICS_PROXY_ENV_ \
CODEX_POLICY_DIR="${HOME}/local/codex" \
CODEX_ENV_HCLOUD_ENDPOINT=http://localhost:8090/v1 \
CODEX_ENV_HCLOUD_TOKEN=local-proxy-token \
HCLOUD_PROXY_ENV_HCLOUD_TOKEN=real-upstream-token \
HCLOUD_PROXY_ENV_HCLOUD_PROXY_TOKEN=local-proxy-token \
METRICS_PROXY_ENV_METRICS_TOKEN=metrics-token \
CODEX_RELEASE_CHECK_ON_SPAWN=0 \
STARTUP_SUMMARY_HOLD_SECONDS=0 \
"${repo_root}/run-in-container.sh" --wd "${tmpdir}/work" spawn > "${tmpdir}/spawn.out"

grep -Fq "sidecars: hcloud:metrics" "${tmpdir}/spawn.out"
grep -Fq "sidecar hcloud image: localhost/hcloud-acl-proxy:latest" "${tmpdir}/spawn.out"
grep -Fq "sidecar metrics env prefix: METRICS_PROXY_ENV_" "${tmpdir}/spawn.out"
grep -Fq "run --name codex-work-" "${PODMAN_LOG}"
grep -Fq "sidecar-hcloud" "${PODMAN_LOG}"
grep -Fq "sidecar-metrics" "${PODMAN_LOG}"
grep -Fq -- "--pod codex-work-" "${PODMAN_LOG}"
grep -Fq -- "--env-file ${tmpdir}/runtime/codex-container/sidecar-env/codex-work-" "${PODMAN_LOG}"
grep -Fq -- "-e HCLOUD_ENDPOINT" "${PODMAN_LOG}"
grep -Fq -- "-e HCLOUD_TOKEN" "${PODMAN_LOG}"
grep -Fq -- "-v ${HOME}/local/codex/hcloud-acl-policy.yaml:/config/policy.yaml:ro" "${PODMAN_LOG}"
grep -Fq -- "--read-only" "${PODMAN_LOG}"
grep -Fq -- "sh -lc run-proxy --listen 127.0.0.1:8090" "${PODMAN_LOG}"

if grep -Fq "HCLOUD_PROXY_ENV_HCLOUD_TOKEN" "${PODMAN_LOG}"; then
  echo "sidecar env prefix names should not be passed to containers" >&2
  exit 1
fi
if grep -Fq "real-upstream-token" "${PODMAN_LOG}"; then
  echo "sidecar secret values should not be passed on the podman command line" >&2
  exit 1
fi
grep -R -Fxq "HCLOUD_TOKEN=real-upstream-token" "${tmpdir}/runtime/codex-container/sidecar-env"
grep -R -Fxq "HCLOUD_PROXY_TOKEN=local-proxy-token" "${tmpdir}/runtime/codex-container/sidecar-env"
grep -R -Fxq "METRICS_TOKEN=metrics-token" "${tmpdir}/runtime/codex-container/sidecar-env"

workspace_state_dir="${tmpdir}/runtime/codex-container/workspaces/state/$(printf '%s' "${tmpdir}/work" | sha256sum | cut -c1-8)"
grep -Fxq "hcloud:metrics" "${workspace_state_dir}/sidecars"
grep -Fq "sidecar-hcloud" "${workspace_state_dir}/sidecar_hcloud"
grep -Fq "sidecar-metrics" "${workspace_state_dir}/sidecar_metrics"

: > "${PODMAN_LOG}"
env -u SIDECARS \
  -u SIDECAR_hcloud_IMAGE \
  -u SIDECAR_hcloud_ENV_PREFIX \
  -u SIDECAR_metrics_IMAGE \
  -u SIDECAR_metrics_ENV_PREFIX \
  FAKE_CONTAINER_EXISTS=1 \
  CODEX_RELEASE_CHECK_ON_SPAWN=0 \
  STARTUP_SUMMARY_HOLD_SECONDS=0 \
  "${repo_root}/run-in-container.sh" --id 1 destroy > "${tmpdir}/destroy.out"

grep -Fq "rm --time=0 -f codex-work-" "${PODMAN_LOG}"
grep -Fq "sidecar-hcloud" "${PODMAN_LOG}"
grep -Fq "sidecar-metrics" "${PODMAN_LOG}"

: > "${PODMAN_LOG}"
if SIDECARS=bad \
  SIDECAR_bad_ENV_PREFIX=BAD_PROXY_ENV_ \
  CODEX_RELEASE_CHECK_ON_SPAWN=0 \
  STARTUP_SUMMARY_HOLD_SECONDS=0 \
  "${repo_root}/run-in-container.sh" --wd "${tmpdir}/bad-work" spawn >"${tmpdir}/bad.out" 2>"${tmpdir}/bad.err"; then
  echo "missing sidecar image should fail" >&2
  exit 1
fi
grep -Fq "SIDECAR_bad_IMAGE is required" "${tmpdir}/bad.err"
test ! -s "${PODMAN_LOG}"
