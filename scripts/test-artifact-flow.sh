#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fakebin="${tmpdir}/bin"
fixtures="${tmpdir}/fixtures"
dist_dir="${tmpdir}/dist"
cache_dir="${tmpdir}/cache"
mkdir -p "${fakebin}" "${fixtures}" "${dist_dir}" "${cache_dir}"

make_package() {
  local version="$1"
  local package_dir="${tmpdir}/pkg-${version}/package"
  mkdir -p "${package_dir}"
  printf '{"name":"@openai/codex","version":"%s"}\n' "${version}" > "${package_dir}/package.json"
  tar -C "${tmpdir}/pkg-${version}" -czf "${fixtures}/codex-npm-${version}.tgz" package/package.json
}

make_package 0.141.0
make_package 0.142.0-alpha.7
make_package 0.142.0-alpha.9

cat > "${fakebin}/curl" <<'FAKE_CURL'
#!/bin/sh
set -eu

output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -f|-L|-fL|-fsSL|-H)
      if [ "$1" = "-H" ]; then
        shift 2
      else
        shift
      fi
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

if [ -n "${output}" ]; then
  case "${url}" in
    *codex-npm-0.141.0.tgz) cp "${FIXTURES}/codex-npm-0.141.0.tgz" "${output}" ;;
    *codex-npm-0.142.0-alpha.7.tgz) cp "${FIXTURES}/codex-npm-0.142.0-alpha.7.tgz" "${output}" ;;
    *codex-npm-0.142.0-alpha.9.tgz) cp "${FIXTURES}/codex-npm-0.142.0-alpha.9.tgz" "${output}" ;;
    *) exit 22 ;;
  esac
  exit 0
fi

case "${url}" in
  */releases/latest)
    printf '%s\n' '{"tag_name":"rust-v0.141.0","name":"0.141.0","prerelease":false,"assets":[{"name":"codex-npm-0.141.0.tgz","browser_download_url":"https://download.example/codex-npm-0.141.0.tgz"}]}'
    ;;
  */releases?per_page=100)
    printf '%s\n' '[{"tag_name":"rust-v0.142.0-alpha.7","name":"0.142.0-alpha.7","prerelease":true,"published_at":"2026-06-20T00:40:41Z","assets":[{"name":"codex-npm-0.142.0-alpha.7.tgz","browser_download_url":"https://download.example/codex-npm-0.142.0-alpha.7.tgz"}]},{"tag_name":"rust-v0.142.0-alpha.9","name":"0.142.0-alpha.9","prerelease":true,"published_at":"2026-06-21T06:42:25Z","assets":[{"name":"codex-npm-0.142.0-alpha.9.tgz","browser_download_url":"https://download.example/codex-npm-0.142.0-alpha.9.tgz"}]}]'
    ;;
  */releases/tags/rust-v0.142.0-alpha.7)
    printf '%s\n' '{"tag_name":"rust-v0.142.0-alpha.7","name":"0.142.0-alpha.7","prerelease":true,"assets":[{"name":"codex-npm-0.142.0-alpha.7.tgz","browser_download_url":"https://download.example/codex-npm-0.142.0-alpha.7.tgz"}]}'
    ;;
  *)
    exit 22
    ;;
esac
FAKE_CURL

chmod 755 "${fakebin}/curl"

export PATH="${fakebin}:${PATH}"
export FIXTURES="${fixtures}"
export CODEX_CURL="${fakebin}/curl"
export DIST_DIR="${dist_dir}"
export UPSTREAM_CACHE_DIR="${cache_dir}"

"${repo_root}/codex-artifact.sh" prepare > "${tmpdir}/release.out"
grep -Fq 'staged Codex 0.141.0 from rust-v0.141.0' "${tmpdir}/release.out"
grep -Fxq 'CODEX_ARTIFACT_TYPE=release' "${dist_dir}/codex-artifact.env"
grep -Fxq 'CODEX_ARTIFACT_VERSION=0.141.0' "${dist_dir}/codex-artifact.env"
test -f "${cache_dir}/codex-npm-0.141.0.tgz"
test -f "${dist_dir}/codex.tgz"
test ! -L "${dist_dir}/codex.tgz"

"${repo_root}/codex-artifact.sh" prepare type alpha > "${tmpdir}/alpha.out"
grep -Fq 'staged Codex 0.142.0-alpha.9 from rust-v0.142.0-alpha.9' "${tmpdir}/alpha.out"
grep -Fxq 'CODEX_ARTIFACT_TYPE=alpha' "${dist_dir}/codex-artifact.env"
grep -Fxq 'CODEX_ARTIFACT_VERSION=0.142.0-alpha.9' "${dist_dir}/codex-artifact.env"

"${repo_root}/codex-artifact.sh" prepare version 0.142.0-alpha.7 > "${tmpdir}/exact.out"
grep -Fq 'staged Codex 0.142.0-alpha.7 from rust-v0.142.0-alpha.7' "${tmpdir}/exact.out"
grep -Fxq 'CODEX_ARTIFACT_TYPE=alpha' "${dist_dir}/codex-artifact.env"
grep -Fxq 'CODEX_ARTIFACT_VERSION=0.142.0-alpha.7' "${dist_dir}/codex-artifact.env"

"${repo_root}/codex-artifact.sh" status > "${tmpdir}/status.out"
grep -Fq 'staged version: 0.142.0-alpha.7' "${tmpdir}/status.out"
grep -Fq 'latest release: 0.141.0' "${tmpdir}/status.out"
grep -Fq 'latest alpha: 0.142.0-alpha.9' "${tmpdir}/status.out"
grep -Fq 'fresh release: no' "${tmpdir}/status.out"
grep -Fq 'fresh alpha: no' "${tmpdir}/status.out"

"${repo_root}/codex-artifact.sh" clean > "${tmpdir}/clean.out"
test ! -e "${dist_dir}/codex.tgz"
test ! -e "${dist_dir}/codex-artifact.env"
test ! -e "${cache_dir}"
