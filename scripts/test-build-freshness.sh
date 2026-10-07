#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"; trap 'rm -rf "${tmpdir}"' EXIT
mkdir -p "${tmpdir}/bin"
package_version="$(tar -xOf "${repo_root}/dist/codex.tgz" package/package.json | sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
cat > "${tmpdir}/bin/curl" <<EOF
#!/bin/sh
printf '%s\n' '{"tag_name":"rust-v${package_version}"}'
EOF
cat > "${tmpdir}/bin/buildah" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${BUILDAH_LOG}"
case "$1" in inspect) exit 1 ;; esac
EOF
chmod 755 "${tmpdir}/bin/curl" "${tmpdir}/bin/buildah"
export PATH="${tmpdir}/bin:${PATH}" CODEX_CURL="${tmpdir}/bin/curl" BUILDAH_LOG="${tmpdir}/buildah.log" DNF_CACHE_DIR="${tmpdir}/dnf-cache" TZ="Europe/Prague"
(cd "${repo_root}" && ./build-images.sh --batch)
grep -Eq 'bud --layers --target codex-profile -t codex:candidate-default-' "${BUILDAH_LOG}"
grep -Fq -- '--target codex-profile' "${BUILDAH_LOG}"
grep -Fq 'tag codex:default codex:latest' "${BUILDAH_LOG}"
grep -Fq 'bud --layers -t codex-firewall' "${BUILDAH_LOG}"
grep -Fq -- '--label codex.container.profile=default' "${BUILDAH_LOG}"
grep -Fq -- '--build-arg TZ=Europe/Prague' "${BUILDAH_LOG}"
firewall_line="$(grep -n -m1 'bud --layers -t codex-firewall' "${BUILDAH_LOG}" | cut -d: -f1)"
runtime_line="$(grep -n -m1 -- '--target codex-profile' "${BUILDAH_LOG}" | cut -d: -f1)"
test "${firewall_line}" -lt "${runtime_line}"
grep -Fq '# Profile: default' "${repo_root}/.build-cache/profiles/default/Containerfile"
: > "${BUILDAH_LOG}"
(cd "${repo_root}" && ./build-images.sh --all-profiles --batch)
mapfile -t build_profiles < <(find "${repo_root}/container-profiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
test "$(grep -c -- '--target codex-profile' "${BUILDAH_LOG}")" -eq "${#build_profiles[@]}"
for profile in "${build_profiles[@]}"; do
  grep -Eq "bud --layers --target codex-profile -t codex:candidate-${profile}-" "${BUILDAH_LOG}"
done
test "$(grep -c 'bud --layers -t codex-firewall' "${BUILDAH_LOG}")" -eq 1
firewall_line="$(grep -n -m1 'bud --layers -t codex-firewall' "${BUILDAH_LOG}" | cut -d: -f1)"
runtime_line="$(grep -n -m1 -- '--target codex-profile' "${BUILDAH_LOG}" | cut -d: -f1)"
test "${firewall_line}" -lt "${runtime_line}"
cat > "${tmpdir}/bin/curl" <<EOF
#!/bin/sh
printf '%s\n' '{"tag_name":"rust-v999.0.0"}'
EOF
before="$(wc -l < "${BUILDAH_LOG}")"
if (cd "${repo_root}" && ./build-images.sh --batch >"${tmpdir}/out" 2>"${tmpdir}/err"); then echo "batch stale build should fail" >&2; exit 1; fi
grep -Fq 'refusing to build stale Codex artifact' "${tmpdir}/err"
test "$(wc -l < "${BUILDAH_LOG}")" -eq "${before}"
