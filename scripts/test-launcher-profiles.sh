#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
fakebin="${tmpdir}/bin"
mkdir -p "${fakebin}" "${tmpdir}/runtime" "${tmpdir}/home" \
  "${tmpdir}/custom-work" "${tmpdir}/missing-work" "${tmpdir}/override-work"

cat > "${fakebin}/podman" <<'FAKE_PODMAN'
#!/bin/sh
printf '%s\n' "$*" >> "${PODMAN_LOG}"

case "$1" in
  images)
    [ "${FAKE_IMAGES_FAIL:-0}" = "1" ] && exit 7
    [ "${FAKE_EMPTY_IMAGES:-0}" = "1" ] && exit 0
    printf '%s\n' id-infra-old id-default id-orphan id-custom id-invalid id-mismatch id-infra
    exit 0
    ;;
  image)
    case "$2" in
      exists)
        case "$3" in
          codex:custom|codex:default|codex:infra|codex:mismatch) exit 0 ;;
          *) exit 1 ;;
        esac
        ;;
      inspect)
        template="$4"
        image="$5"
        case "${template}" in
          *codex.container.profile*)
            case "${image}" in
              id-custom|codex:custom) printf 'custom\n' ;;
              id-default|codex:default) printf 'default\n' ;;
              id-infra|id-infra-old|codex:infra) printf 'infra\n' ;;
              id-orphan) printf 'orphan\n' ;;
              id-invalid) printf 'bad/profile\n' ;;
              id-mismatch) printf 'mismatch\n' ;;
              codex:mismatch) printf 'other\n' ;;
            esac
            ;;
          *codex.cli.version*)
            case "${image}" in
              codex:custom) printf '0.3.0\n' ;;
              codex:default) printf '0.1.0\n' ;;
              codex:infra) printf '0.2.0\n' ;;
            esac
            ;;
          *'{{.Id}}'*)
            case "${image}" in
              codex:custom) printf 'sha256:cccccccccccccccc\n' ;;
              codex:default) printf 'sha256:dddddddddddddddd\n' ;;
              codex:infra) printf 'sha256:iiiiiiiiiiiiiiii\n' ;;
            esac
            ;;
        esac
        exit 0
        ;;
    esac
    ;;
  container)
    if [ "$2" = "exists" ]; then
      [ -n "${FAKE_RUNNING_APP:-}" ] && [ "$3" = "${FAKE_RUNNING_APP}" ] && exit 0
      [ "${FAKE_APP_EXISTS:-0}" = "1" ] && exit 0
      exit 1
    fi
    ;;
  inspect)
    if [ "$2" = "--format" ] && [ "$3" = "{{.State.Running}}" ]; then
      [ -n "${FAKE_RUNNING_APP:-}" ] && [ "$4" = "${FAKE_RUNNING_APP}" ] && printf 'true\n'
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

export PATH="${fakebin}:${PATH}"
export PODMAN_LOG="${tmpdir}/podman.log"
export XDG_RUNTIME_DIR="${tmpdir}/runtime"
export HOME="${tmpdir}/home"
export CODEX_RELEASE_CHECK_ON_SPAWN=0
export STARTUP_SUMMARY_HOLD_SECONDS=0

"${repo_root}/run-in-container.sh" profiles > "${tmpdir}/profiles.out"
"${repo_root}/run-in-container.sh" --list-profiles > "${tmpdir}/profiles-flag.out"
cmp "${tmpdir}/profiles.out" "${tmpdir}/profiles-flag.out"
grep -Eq '^PROFILE +IMAGE +CODEX VERSION +IMAGE ID$' "${tmpdir}/profiles.out"
grep -Eq '^custom +codex:custom +0\.3\.0 +cccccccccccc$' "${tmpdir}/profiles.out"
grep -Eq '^default +codex:default +0\.1\.0 +dddddddddddd$' "${tmpdir}/profiles.out"
grep -Eq '^infra +codex:infra +0\.2\.0 +iiiiiiiiiiii$' "${tmpdir}/profiles.out"
test "$(grep -Ec '^(custom|default|infra) ' "${tmpdir}/profiles.out")" -eq 3
sed -n '2p' "${tmpdir}/profiles.out" | grep -Eq '^custom '
sed -n '3p' "${tmpdir}/profiles.out" | grep -Eq '^default '
sed -n '4p' "${tmpdir}/profiles.out" | grep -Eq '^infra '
if grep -Eq 'orphan|mismatch|bad/profile|prev-|candidate-' "${tmpdir}/profiles.out"; then
  echo "non-canonical profile image leaked into profile listing" >&2
  exit 1
fi

FAKE_EMPTY_IMAGES=1 "${repo_root}/run-in-container.sh" profiles > "${tmpdir}/empty.out"
test "$(wc -l < "${tmpdir}/empty.out")" -eq 1
if FAKE_IMAGES_FAIL=1 "${repo_root}/run-in-container.sh" profiles > "${tmpdir}/failed.out" 2> "${tmpdir}/failed.err"; then
  echo "profile listing should report Podman query failures" >&2
  exit 1
fi
grep -Fq 'failed to query local Codex profile images' "${tmpdir}/failed.err"

: > "${PODMAN_LOG}"
"${repo_root}/run-in-container.sh" --profile custom --wd "${tmpdir}/custom-work" spawn > "${tmpdir}/custom.out"
grep -Fq 'runtime profile: custom' "${tmpdir}/custom.out"
grep -Fq 'runtime image: codex:custom' "${tmpdir}/custom.out"

: > "${PODMAN_LOG}"
if FAKE_APP_EXISTS=1 "${repo_root}/run-in-container.sh" --profile missing --wd "${tmpdir}/missing-work" replace > "${tmpdir}/missing.out" 2> "${tmpdir}/missing.err"; then
  echo "missing profile image should reject replace" >&2
  exit 1
fi
grep -Fq 'List available profiles with:' "${tmpdir}/missing.err"
if grep -Eq '^rm | pod rm ' "${PODMAN_LOG}"; then
  echo "replace removed resources before profile image validation" >&2
  exit 1
fi

FAKE_APP_EXISTS=1 "${repo_root}/run-in-container.sh" --profile missing --wd "${tmpdir}/missing-work" name > "${tmpdir}/name.out"
grep -Eq '^codex-missing-work-[a-f0-9]{8}-app$' "${tmpdir}/name.out"
: > "${PODMAN_LOG}"
FAKE_APP_EXISTS=1 "${repo_root}/run-in-container.sh" --profile missing --wd "${tmpdir}/missing-work" destroy > "${tmpdir}/destroy.out"
grep -Fq 'removed codex-missing-work-' "${tmpdir}/destroy.out"
grep -Eq '^rm .*codex-missing-work-.*-app' "${PODMAN_LOG}"

: > "${PODMAN_LOG}"
CONTAINER_IMAGE=custom-override:test \
  "${repo_root}/run-in-container.sh" --profile missing --wd "${tmpdir}/override-work" spawn > "${tmpdir}/override.out"
grep -Fq 'runtime image: custom-override:test' "${tmpdir}/override.out"
grep -Fq 'runtime profile: missing' "${tmpdir}/override.out"

# An implicit launch must prefer the newer running profile record over the
# missing default-profile record for the same workspace. An explicit profile
# selection remains authoritative.
multi_work="${tmpdir}/multi-profile-work"
mkdir -p "${multi_work}"
registry="${XDG_RUNTIME_DIR}/codex-container/workspaces"
mkdir -p "${registry}/state" "${registry}/by-seq" "${registry}/by-path-hash"
for record in "default:5" "typesetting:6"; do
  profile="${record%%:*}"
  seq="${record##*:}"
  hash="$(printf '%s' "${multi_work}:${profile}" | sha256sum | cut -c1-8)"
  state_dir="${registry}/state/${hash}"
  app="codex-multi-profile-work-${hash}-app"
  mkdir -p "${state_dir}"
  printf '%s\n' "${multi_work}" > "${state_dir}/path"
  printf '%s\n' "${profile}" > "${state_dir}/profile"
  printf '%s\n' "multi-profile-work" > "${state_dir}/alias"
  printf '%s\n' "${hash}" > "${state_dir}/hash"
  printf '%s\n' "${seq}" > "${state_dir}/seq"
  printf '%s\n' "codex-multi-profile-work-${hash}" > "${state_dir}/pod"
  printf '%s\n' "${app}" > "${state_dir}/app"
  printf '%s\n' "codex-multi-profile-work-${hash}-fw" > "${state_dir}/fw"
  printf '%s\n' "codex-multi-profile-work-${hash}-proxy" > "${state_dir}/proxy"
  : > "${state_dir}/sidecars"
  ln -s "../state/${hash}" "${registry}/by-seq/${seq}"
  ln -s "../state/${hash}" "${registry}/by-path-hash/${hash}"
done

typesetting_hash="$(printf '%s' "${multi_work}:typesetting" | sha256sum | cut -c1-8)"
typesetting_app="codex-multi-profile-work-${typesetting_hash}-app"
: > "${PODMAN_LOG}"
FAKE_RUNNING_APP="${typesetting_app}" \
  "${repo_root}/run-in-container.sh" --wd "${multi_work}" spawn > "${tmpdir}/implicit-profile.out"
grep -Fq "already running: ${typesetting_app}" "${tmpdir}/implicit-profile.out"
if grep -Eq '^run |^pod create ' "${PODMAN_LOG}"; then
  echo "implicit launch respawned the missing default profile instead of selecting the running profile" >&2
  exit 1
fi

: > "${PODMAN_LOG}"
FAKE_RUNNING_APP="${typesetting_app}" \
  "${repo_root}/run-in-container.sh" --profile default --wd "${multi_work}" spawn > "${tmpdir}/explicit-profile.out"
grep -Fq 'runtime profile: default' "${tmpdir}/explicit-profile.out"
grep -Fq 'spawned: codex-multi-profile-work-' "${tmpdir}/explicit-profile.out"
