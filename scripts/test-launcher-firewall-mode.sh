#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
fakebin="${tmpdir}/bin"
mkdir -p "${fakebin}" "${tmpdir}/runtime" "${tmpdir}/home"

cat > "${fakebin}/podman" <<'FAKE_PODMAN'
#!/bin/sh
printf '%s\n' "$*" >> "${PODMAN_LOG}"

case "$1" in
  image)
    [ "$2" = "exists" ] && exit 0
    if [ "$2" = "inspect" ]; then
      printf 'default\n'
      exit 0
    fi
    ;;
  container)
    [ "$2" = "exists" ] && exit 1
    ;;
  pod)
    [ "$2" = "exists" ] && exit 1
    [ "$2" = "create" ] && exit 0
    [ "$2" = "rm" ] && exit 0
    ;;
  run)
    case " $* " in
      *" codex.workspace.role=firewall "*)
        [ "${FAKE_FIREWALL_RUN_FAIL:-0}" = "1" ] && exit 42
        ;;
    esac
    exit 0
    ;;
  exec)
    case " $* " in
      *" firewall-init "*|*" firewall-lift "*)
        [ "${FAKE_FIREWALL_EXEC_FAIL:-0}" = "1" ] && exit 43
        ;;
    esac
    exit 0
    ;;
  rm)
    exit 0
    ;;
esac

exit 0
FAKE_PODMAN
chmod 755 "${fakebin}/podman"

export PATH="${fakebin}:${PATH}"
export PODMAN_LOG="${tmpdir}/podman.log"
export XDG_RUNTIME_DIR="${tmpdir}/runtime"
export HOME="${tmpdir}/home"
export CODEX_RELEASE_CHECK_ON_SPAWN=0
export STARTUP_SUMMARY_HOLD_SECONDS=0

mkdir -p "${tmpdir}/lifted"
: > "${PODMAN_LOG}"
"${repo_root}/run-in-container.sh" --no-firewall --wd "${tmpdir}/lifted" spawn > "${tmpdir}/lifted.out"
grep -Fq 'firewall mode: lifted' "${tmpdir}/lifted.out"
grep -Fq 'exec codex-lifted-' "${PODMAN_LOG}"
grep -Fq 'firewall-init' "${PODMAN_LOG}"
grep -Fq 'firewall-lift' "${PODMAN_LOG}"
if grep -Eq 'firewall-allow-(domain|address)|firewall-reload' "${PODMAN_LOG}"; then
  echo "lifted startup configured enforced firewall policy" >&2
  exit 1
fi

mkdir -p "${tmpdir}/env-lifted"
: > "${PODMAN_LOG}"
CODEX_FIREWALL_MODE=lifted \
  "${repo_root}/run-in-container.sh" --wd "${tmpdir}/env-lifted" spawn > "${tmpdir}/env-lifted.out"
grep -Fq 'firewall mode: lifted' "${tmpdir}/env-lifted.out"
grep -Fq 'firewall-lift' "${PODMAN_LOG}"

mkdir -p "${tmpdir}/broken"
: > "${PODMAN_LOG}"
FAKE_FIREWALL_RUN_FAIL=1 PROXY_ENABLE=1 \
  "${repo_root}/run-in-container.sh" --no-firewall --wd "${tmpdir}/broken" spawn \
  > "${tmpdir}/broken.out" 2> "${tmpdir}/broken.err"
grep -Fq 'continuing with firewall disabled' "${tmpdir}/broken.err"
grep -Fq 'disabling proxy relay' "${tmpdir}/broken.err"
grep -Fq 'codex.workspace.role=app' "${PODMAN_LOG}"
if grep -Fq 'codex.workspace.role=proxy' "${PODMAN_LOG}"; then
  echo "proxy container started without its firewall bridge" >&2
  exit 1
fi
broken_hash="$(printf '%s' "${tmpdir}/broken:default" | sha256sum | cut -c1-8)"
grep -Fxq 'CODEX_FIREWALL_MODE=disabled' \
  "${tmpdir}/runtime/codex-broken-${broken_hash}-policy/status.env"

mkdir -p "${tmpdir}/enforced-failure"
: > "${PODMAN_LOG}"
if FAKE_FIREWALL_RUN_FAIL=1 \
  "${repo_root}/run-in-container.sh" --wd "${tmpdir}/enforced-failure" spawn \
  > "${tmpdir}/enforced.out" 2> "${tmpdir}/enforced.err"; then
  echo "enforced startup ignored a broken firewall container" >&2
  exit 1
fi
grep -Fq 'firewall container did not start cleanly' "${tmpdir}/enforced.err"
if grep -Fq 'codex.workspace.role=app' "${PODMAN_LOG}"; then
  echo "app container started after enforced firewall failure" >&2
  exit 1
fi

: > "${PODMAN_LOG}"
if CODEX_FIREWALL_MODE=invalid \
  "${repo_root}/run-in-container.sh" --wd "${tmpdir}/invalid" spawn \
  > "${tmpdir}/invalid.out" 2> "${tmpdir}/invalid.err"; then
  echo "invalid firewall mode was accepted" >&2
  exit 1
fi
grep -Fq 'CODEX_FIREWALL_MODE must be enforced or lifted' "${tmpdir}/invalid.err"
test ! -s "${PODMAN_LOG}"
