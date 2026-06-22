#!/bin/bash
set -euo pipefail

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

repo="${tmpdir}/repo"
fakebin="${tmpdir}/bin"
mkdir -p "${repo}/scripts" "${repo}/container-deps" "${repo}/dist" "${fakebin}" "${tmpdir}/pkg/package"

cp "${source_root}/build-images.sh" "${repo}/build-images.sh"
cp "${source_root}/scripts/codex-artifact-common.sh" "${repo}/scripts/codex-artifact-common.sh"

cat > "${repo}/Dockerfile.in" <<'EOF_DOCKER'
FROM scratch
# DNF_DROPINS
COPY dist/codex.tgz codex.tgz
EOF_DOCKER

cat > "${repo}/Dockerfile.firewall" <<'EOF_FIREWALL'
FROM scratch
EOF_FIREWALL

printf 'bash\n' > "${repo}/container-deps/10-base.dnf"
printf '{"name":"@openai/codex","version":"0.140.0"}\n' > "${tmpdir}/pkg/package/package.json"
tar -C "${tmpdir}/pkg" -czf "${repo}/dist/codex.tgz" package/package.json

cat > "${repo}/dist/codex-artifact.env" <<'EOF_META'
CODEX_ARTIFACT_TYPE=release
CODEX_ARTIFACT_VERSION=0.140.0
CODEX_ARTIFACT_GITHUB_TAG=rust-v0.140.0
CODEX_ARTIFACT_ASSET_NAME=codex-npm-0.140.0.tgz
CODEX_ARTIFACT_ASSET_URL=https://download.example/codex-npm-0.140.0.tgz
CODEX_ARTIFACT_SOURCE_PATH=/tmp/codex-npm-0.140.0.tgz
CODEX_ARTIFACT_FETCHED_EPOCH=1
EOF_META

cat > "${fakebin}/curl" <<'FAKE_CURL'
#!/bin/sh
printf '%s\n' "$*" >> "${CURL_LOG}"
case "$*" in
  *"/releases/latest"*)
    printf '%s\n' '{"tag_name":"rust-v0.141.0","name":"0.141.0","prerelease":false,"assets":[{"name":"codex-npm-0.141.0.tgz","browser_download_url":"https://download.example/codex-npm-0.141.0.tgz"}]}'
    ;;
  *)
    exit 22
    ;;
esac
FAKE_CURL

cat > "${fakebin}/buildah" <<'FAKE_BUILDAH'
#!/bin/sh
printf '%s\n' "$*" >> "${BUILDAH_LOG}"
exit 0
FAKE_BUILDAH

chmod 755 "${fakebin}/curl" "${fakebin}/buildah" "${repo}/build-images.sh" "${repo}/scripts/codex-artifact-common.sh"

export PATH="${fakebin}:${PATH}"
export CODEX_CURL="${fakebin}/curl"
export BUILDAH_LOG="${tmpdir}/buildah.log"
export CURL_LOG="${tmpdir}/curl.log"

if (cd "${repo}" && CODEX_CONTAINER_BATCH=1 ./build-images.sh >"${tmpdir}/batch.out" 2>"${tmpdir}/batch.err"); then
  echo "batch stale build should fail by default" >&2
  exit 1
fi
grep -Fq -- '--max-time 1' "${CURL_LOG}"
grep -Fq 'refusing to build stale Codex artifact' "${tmpdir}/batch.err"
test ! -f "${BUILDAH_LOG}"

if (cd "${repo}" && ./build-images.sh --non-interactive >"${tmpdir}/noninteractive.out" 2>"${tmpdir}/noninteractive.err"); then
  echo "--non-interactive stale build should fail by default" >&2
  exit 1
fi
grep -Fq 'refusing to build stale Codex artifact' "${tmpdir}/noninteractive.err"

(cd "${repo}" && CODEX_ARTIFACT_STALE_POLICY=continue ./build-images.sh >"${tmpdir}/continue.out" 2>"${tmpdir}/continue.err")
grep -Fq 'bud --layers -t codex' "${BUILDAH_LOG}"
grep -Fq -- '--build-arg CODEX_FIREWALL_DNS_TOOL=dig' "${BUILDAH_LOG}"

: > "${BUILDAH_LOG}"
(cd "${repo}" && CODEX_ARTIFACT_STALE_POLICY=continue CODEX_FIREWALL_DNS_TOOL=drill ./build-images.sh >"${tmpdir}/drill.out" 2>"${tmpdir}/drill.err")
grep -Fq -- '--build-arg CODEX_FIREWALL_DNS_TOOL=drill' "${BUILDAH_LOG}"

if (cd "${repo}" && CODEX_ARTIFACT_STALE_POLICY=continue CODEX_FIREWALL_DNS_TOOL=bogus ./build-images.sh >"${tmpdir}/tool.out" 2>"${tmpdir}/tool.err"); then
  echo "invalid firewall DNS tool should fail" >&2
  exit 1
fi
grep -Fq 'unsupported CODEX_FIREWALL_DNS_TOOL=bogus' "${tmpdir}/tool.err"

if (cd "${repo}" && CODEX_ARTIFACT_STALE_POLICY=bogus ./build-images.sh >"${tmpdir}/bogus.out" 2>"${tmpdir}/bogus.err"); then
  echo "invalid stale policy should fail" >&2
  exit 1
fi
grep -Fq 'invalid CODEX_ARTIFACT_STALE_POLICY' "${tmpdir}/bogus.err"
