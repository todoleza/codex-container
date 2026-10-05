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
export PATH="${tmpdir}/bin:${PATH}" CODEX_CURL="${tmpdir}/bin/curl" BUILDAH_LOG="${tmpdir}/buildah.log" DNF_CACHE_DIR="${tmpdir}/dnf-cache"
(cd "${repo_root}" && ./build-images.sh --batch)
grep -Eq 'bud --layers -t codex:candidate-default-' "${BUILDAH_LOG}"
grep -Fq 'tag codex:default codex:latest' "${BUILDAH_LOG}"
grep -Fq 'bud --layers -t codex-firewall' "${BUILDAH_LOG}"
grep -Fq -- '--label codex.container.profile=default' "${BUILDAH_LOG}"
grep -Fq '# Profile: default' "${repo_root}/.build-cache/profiles/default/Containerfile"
cat > "${tmpdir}/bin/curl" <<EOF
#!/bin/sh
printf '%s\n' '{"tag_name":"rust-v999.0.0"}'
EOF
before="$(wc -l < "${BUILDAH_LOG}")"
if (cd "${repo_root}" && ./build-images.sh --batch >"${tmpdir}/out" 2>"${tmpdir}/err"); then echo "batch stale build should fail" >&2; exit 1; fi
grep -Fq 'refusing to build stale Codex artifact' "${tmpdir}/err"
test "$(wc -l < "${BUILDAH_LOG}")" -eq "${before}"
