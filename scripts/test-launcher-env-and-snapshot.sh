#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fakebin="${tmpdir}/bin"
mkdir -p "${fakebin}" "${tmpdir}/runtime" "${tmpdir}/home/.local/share/codex-container" "${tmpdir}/work/subdir" "${tmpdir}/gitroot/subdir"

cat > "${fakebin}/podman" <<'FAKE_PODMAN'
#!/bin/sh
printf '%s\n' "$*" >> "${PODMAN_LOG}"

case "$1" in
  container)
    if [ "$2" = "exists" ]; then
      case "${FAKE_APP_EXISTS:-0}:$3" in
        1:*-app) exit 0 ;;
        *) exit 1 ;;
      esac
    fi
    ;;
  inspect)
    if [ "$2" = "--format" ] && [ "$3" = "{{ index .Config.Labels \"codex.cli.version\" }}" ]; then
      printf '%s\n' "${FAKE_IMAGE_CODEX_VERSION:-}"
      exit 0
    fi
    [ "$2" = "--format" ] && [ "$3" = "{{.State.Running}}" ] && [ "${FAKE_APP_EXISTS:-0}" = "1" ] && {
      printf 'true\n'
      exit 0
    }
    ;;
  image)
    if [ "$2" = "inspect" ] && [ "$3" = "--format" ] && [ "$4" = "{{ index .Config.Labels \"codex.cli.version\" }}" ]; then
      printf '%s\n' "${FAKE_IMAGE_CODEX_VERSION:-}"
      exit 0
    fi
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

cat > "${fakebin}/curl" <<'FAKE_CURL'
#!/bin/sh
printf '%s\n' "${FAKE_CURL_RESPONSE:-}" 
FAKE_CURL

chmod 755 "${fakebin}/curl"

cat > "${tmpdir}/home/.local/share/codex-container/env" <<'EOF_GLOBAL'
PROXY_ENABLE=1
STARTUP_SUMMARY_HOLD_SECONDS=0
EXTRA_ALLOWED_DOMAINS=global.example
EOF_GLOBAL

cat > "${tmpdir}/work/.codex-container.env" <<'EOF_WORKSPACE'
PROXY_ENABLE=0
EXTRA_ALLOWED_DOMAINS=workspace.example
EOF_WORKSPACE

cat > "${tmpdir}/extra.env" <<'EOF_EXTRA'
EXTRA_ALLOWED_IPV4=198.51.100.9
CODEX_ENV_SECRET_TOKEN=from-extra
EOF_EXTRA

export PATH="${fakebin}:${PATH}"
export PODMAN_LOG="${tmpdir}/podman.log"
export XDG_RUNTIME_DIR="${tmpdir}/runtime"
export HOME="${tmpdir}/home"
export CODEX_CONTAINER_ENV_FILES="${tmpdir}/extra.env"
export FAKE_CURL_RESPONSE='{"tag_name":"rust-v0.222.0"}'
export FAKE_IMAGE_CODEX_VERSION='0.141.0'

"${repo_root}/run-in-container.sh" --wd "${tmpdir}/work" spawn > "${tmpdir}/spawn.out"

grep -Fq "loaded env files: ${tmpdir}/home/.local/share/codex-container/env ${tmpdir}/work/.codex-container.env ${tmpdir}/extra.env" "${tmpdir}/spawn.out"
grep -Fq "proxy relay: disabled" "${tmpdir}/spawn.out"
grep -Fq "codex cli version: 0.141.0" "${tmpdir}/spawn.out"
grep -Fq "codex cli latest: 0.222.0" "${tmpdir}/spawn.out"
grep -Fq "workspace.example" "${tmpdir}/spawn.out"
grep -Fq "extra allowed IPv4: 198.51.100.9" "${tmpdir}/spawn.out"
grep -Fq "launcher snapshot:" "${tmpdir}/spawn.out"
grep -Fq "spawned: codex-work-" "${tmpdir}/spawn.out"
grep -Fq -- '--label codex.cli.version=0.141.0' "${PODMAN_LOG}"
grep -Fq -- '--label codex.cli.latest=0.222.0' "${PODMAN_LOG}"
grep -Fq -- '--label org.opencontainers.image.version=0.141.0' "${PODMAN_LOG}"
grep -Fq -- '--label app.kubernetes.io/version=0.141.0' "${PODMAN_LOG}"
grep -Fq -- '--label app.kubernetes.io/part-of=codex-container' "${PODMAN_LOG}"
grep -Fq -- "-e SECRET_TOKEN" "${PODMAN_LOG}"
if grep -Fq "CODEX_ENV_SECRET_TOKEN" "${PODMAN_LOG}"; then
  echo "CODEX_ENV_ names should not be passed into the app container" >&2
  exit 1
fi

snapshot_count=$(find "${tmpdir}/runtime/codex-container/launcher-snapshots" -type f -name 'run-in-container.sh-*' | wc -l)
if [ "${snapshot_count}" -ne 1 ]; then
  echo "expected one launcher snapshot, got ${snapshot_count}" >&2
  exit 1
fi

if grep -Fq '/run/codex-proxy' "${PODMAN_LOG}"; then
  echo "proxy volume should not be mounted when workspace env disables proxy" >&2
  exit 1
fi

workspace_state_dir="${tmpdir}/runtime/codex-container/workspaces/state/$(printf '%s' "${tmpdir}/work" | sha256sum | cut -c1-8)"
grep -Fq '0.141.0' "${workspace_state_dir}/codex_cli_version"
grep -Fq '0.222.0' "${workspace_state_dir}/codex_cli_latest"

: > "${PODMAN_LOG}"
"${repo_root}/run-in-container.sh" --wd "${tmpdir}/work/subdir" spawn > "${tmpdir}/nested-env.out"
grep -Fq "workdir: ${tmpdir}/work" "${tmpdir}/nested-env.out"
grep -Fq "loaded env files: ${tmpdir}/home/.local/share/codex-container/env ${tmpdir}/work/.codex-container.env ${tmpdir}/extra.env" "${tmpdir}/nested-env.out"
grep -Fq -- "-e CODEX_WORKDIR=/app${tmpdir}/work" "${PODMAN_LOG}"
grep -Fq -- "-v ${tmpdir}/work:/app${tmpdir}/work" "${PODMAN_LOG}"

git -C "${tmpdir}/gitroot" init -q
: > "${PODMAN_LOG}"
"${repo_root}/run-in-container.sh" --wd "${tmpdir}/gitroot/subdir" spawn > "${tmpdir}/nested-git.out"
grep -Fq "workdir: ${tmpdir}/gitroot" "${tmpdir}/nested-git.out"
grep -Fq -- "-e CODEX_WORKDIR=/app${tmpdir}/gitroot" "${PODMAN_LOG}"
grep -Fq -- "-v ${tmpdir}/gitroot:/app${tmpdir}/gitroot" "${PODMAN_LOG}"

: > "${PODMAN_LOG}"
FAKE_APP_EXISTS=1 "${repo_root}/run-in-container.sh" --id 1 enter env > "${tmpdir}/enter.out"
grep -Fq -- "exec -i -t -e SECRET_TOKEN -w /app${tmpdir}/work codex-work-" "${PODMAN_LOG}"

: > "${PODMAN_LOG}"
FAKE_APP_EXISTS=1 "${repo_root}/run-in-container.sh" --wd "${tmpdir}/work/subdir" > "${tmpdir}/nested-start.out"
grep -Fq -- "exec -i -t -e SECRET_TOKEN -w /app${tmpdir}/work codex-work-" "${PODMAN_LOG}"
grep -Fq -- " bash" "${PODMAN_LOG}"
if grep -Fq "already running" "${tmpdir}/nested-start.out"; then
  echo "nested start should enter parent session without prompting" >&2
  exit 1
fi

: > "${PODMAN_LOG}"
FAKE_APP_EXISTS=1 "${repo_root}/run-in-container.sh" --id 1 rootenter true > "${tmpdir}/rootenter.out"
grep -Fq -- "exec -i -t --privileged --user 0 -e HOME=/root -w /root codex-work-" "${PODMAN_LOG}"

: > "${PODMAN_LOG}"
FAKE_APP_EXISTS=1 "${repo_root}/run-in-container.sh" --id 1 rootshell id > "${tmpdir}/rootshell.out"
grep -Fq -- "exec -i --privileged --user 0 -e HOME=/root -w /root codex-work-" "${PODMAN_LOG}"

PROXY_ENABLE=1 "${repo_root}/run-in-container.sh" --wd "${tmpdir}/work" spawn > "${tmpdir}/caller.out"
grep -Fq "proxy relay: localhost:1080 -> localhost:1080" "${tmpdir}/caller.out"

: > "${PODMAN_LOG}"
FAKE_APP_EXISTS=1 PROXY_ENABLE=0 "${repo_root}/run-in-container.sh" --id 1 respawn > "${tmpdir}/respawn.out"
grep -Fq "respawning codex-work-" "${tmpdir}/respawn.out"
grep -Fq "respawned: codex-work-" "${tmpdir}/respawn.out"
grep -Fq 'rm --time=0 -f codex-work-' "${PODMAN_LOG}"
grep -Fq 'pod create --name codex-work-' "${PODMAN_LOG}"
if grep -Fq 'exec -i -t -e SECRET_TOKEN -w ' "${PODMAN_LOG}"; then
  echo "respawn should not attach to the app container" >&2
  exit 1
fi

"${repo_root}/run-in-container.sh" help > "${tmpdir}/help.out"
if grep -Fq "launcher snapshot:" "${tmpdir}/help.out"; then
  echo "help should not snapshot" >&2
  exit 1
fi
grep -Fq "rootenter" "${tmpdir}/help.out"
grep -Fq "rootshell" "${tmpdir}/help.out"

cat > "${tmpdir}/bad.env" <<'EOF_BAD'
not valid
EOF_BAD

if CODEX_CONTAINER_ENV_FILES="${tmpdir}/bad.env" "${repo_root}/run-in-container.sh" help >"${tmpdir}/bad.out" 2>"${tmpdir}/bad.err"; then
  echo "invalid env file should fail" >&2
  exit 1
fi

grep -Fq "Invalid env file line" "${tmpdir}/bad.err"
