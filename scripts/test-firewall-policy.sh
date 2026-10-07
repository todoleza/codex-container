#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

state_dir="${tmpdir}/state"
fakebin="${tmpdir}/bin"
mkdir -p "${state_dir}" "${fakebin}"

cat > "${fakebin}/dig" <<'FAKE_DIG'
#!/bin/sh
[ "${DNS_FAIL:-0}" = "1" ] && exit 99
printf '%s\n' "$*" >> "${DIG_ARG_LOG}"
query_file=""
for argument in "$@"; do query_file="${argument}"; done
[ -f "${query_file}" ] || exit 2
record_type="$(awk 'NR == 1 { print $2 }' "${query_file}")"
printf 'BEGIN %s\n' "${record_type}" >> "${DIG_QUERY_LOG}"
cat "${query_file}" >> "${DIG_QUERY_LOG}"
printf 'END %s\n' "${record_type}" >> "${DIG_QUERY_LOG}"

if [ -n "${DNS_SLEEP:-}" ]; then sleep "${DNS_SLEEP}"; fi

mkdir -p "${DNS_ATTEMPT_DIR}"
counter_file="${DNS_ATTEMPT_DIR}/${record_type}"
attempt=0
[ -f "${counter_file}" ] && attempt="$(cat "${counter_file}")"
attempt=$((attempt + 1))
printf '%s\n' "${attempt}" > "${counter_file}"
if [ "${attempt}" -le "${DNS_DIAGNOSTIC_RETRIES:-0}" ]; then
  printf '%s\n' ';; communications error to 169.254.1.1#53: timed out'
  exit 9
fi

while read -r domain query_type; do
  case "${domain} ${query_type}" in
    "example.com A") printf '%s\n' 203.0.113.10 ;;
    "example.com AAAA") printf '%s\n' 2001:db8::10 ;;
    "second.example A") printf '%s\n' 203.0.113.11 ;;
    "second.example AAAA") printf '%s\n' 2001:db8::11 ;;
  esac
done < "${query_file}"
FAKE_DIG

cat > "${fakebin}/kdig" <<'FAKE_KDIG'
#!/bin/sh
[ "${DNS_FAIL:-0}" = "1" ] && exit 99
while [ "$#" -gt 0 ]; do
  case "$1" in
    +*) shift ;;
    *)
      domain="$1"
      record_type="${2:-A}"
      case "${domain} ${record_type}" in
        "example.com A") printf '%s\n' 203.0.113.10 ;;
        "example.com AAAA") printf '%s\n' 2001:db8::10 ;;
      esac
      shift 2 || exit 0
      ;;
  esac
done
FAKE_KDIG

cat > "${fakebin}/drill" <<'FAKE_DRILL'
#!/bin/sh
[ "${DNS_FAIL:-0}" = "1" ] && exit 99
[ "$1" = "-Q" ] || exit 1
case "${2} ${3:-A}" in
  "example.com A") printf '%s\n' 203.0.113.10 ;;
  "example.com AAAA") printf '%s\n' 2001:db8::10 ;;
esac
FAKE_DRILL

cat > "${fakebin}/nft" <<'FAKE_NFT'
#!/bin/sh
printf '%s\n' "$*" >> "${NFT_LOG}"
if [ "$1" = "-f" ] && [ -n "${NFT_RULES_COPY:-}" ]; then
  cp "$2" "${NFT_RULES_COPY}"
fi
exit 0
FAKE_NFT

chmod 755 "${fakebin}/dig" "${fakebin}/kdig" "${fakebin}/drill" "${fakebin}/nft"

export PATH="${fakebin}:${PATH}"
export CODEX_FIREWALL_STATE_DIR="${state_dir}"
export NFT_LOG="${tmpdir}/nft.log"
export NFT_RULES_COPY="${tmpdir}/rules.nft"
export DIG_ARG_LOG="${tmpdir}/dig-args.log"
export DIG_QUERY_LOG="${tmpdir}/dig-queries.log"
export DNS_ATTEMPT_DIR="${tmpdir}/dns-attempts"

bash "${repo_root}/firewall/firewall-init"
bash "${repo_root}/firewall/firewall-allow-domain" example.com
bash "${repo_root}/firewall/firewall-allow-address" 198.51.100.0/24
bash "${repo_root}/firewall/firewall-allow-address" 2001:db8:ffff::/48

for dns_tool in dig kdig drill; do
  rm -rf "${state_dir}/dns-cache"
  CODEX_FIREWALL_DNS_TOOL="${dns_tool}" bash "${repo_root}/firewall/firewall-reload"
  grep -Fxq '203.0.113.10' "${state_dir}/resolved_ipv4.txt"
  grep -Fxq '2001:db8::10' "${state_dir}/resolved_ipv6.txt"
  grep -Fxq '203.0.113.10' "${state_dir}/dns-cache/resolved_ipv4.txt"
  grep -Fxq '2001:db8::10' "${state_dir}/dns-cache/resolved_ipv6.txt"
done

grep -Fq '+timeout=1 +tries=1 +short -f' "${DIG_ARG_LOG}"

# One dig invocation receives several targets through its batch file.
bash "${repo_root}/firewall/firewall-allow-domain" second.example
rm -rf "${state_dir}/dns-cache" "${DNS_ATTEMPT_DIR}"
: > "${DIG_QUERY_LOG}"
CODEX_FIREWALL_DNS_TOOL=dig bash "${repo_root}/firewall/firewall-reload"
awk '/BEGIN A$/,/END A$/' "${DIG_QUERY_LOG}" | grep -Fq 'example.com A'
awk '/BEGIN A$/,/END A$/' "${DIG_QUERY_LOG}" | grep -Fq 'second.example A'

# Transient diagnostics are ignored and the complete batch succeeds on attempt five.
rm -rf "${state_dir}/dns-cache" "${DNS_ATTEMPT_DIR}"
DNS_DIAGNOSTIC_RETRIES=4 CODEX_FIREWALL_DNS_TOOL=dig \
  bash "${repo_root}/firewall/firewall-reload"
grep -Fxq 5 "${DNS_ATTEMPT_DIR}/A"
grep -Fxq 5 "${DNS_ATTEMPT_DIR}/AAAA"
if grep -R -Fq ';;' "${state_dir}/dns-cache" "${state_dir}/resolved_ipv6.txt" "${NFT_RULES_COPY}"; then
  echo "dig diagnostic text leaked into firewall address state" >&2
  exit 1
fi

# Exhausted diagnostic-only batches warn but still produce a valid ruleset.
rm -rf "${state_dir}/dns-cache" "${DNS_ATTEMPT_DIR}"
DNS_DIAGNOSTIC_RETRIES=9 CODEX_FIREWALL_DNS_TOOL=dig \
  bash "${repo_root}/firewall/firewall-reload" 2> "${tmpdir}/diagnostic.err"
grep -Fq 'DNS batch exhausted 5 attempts' "${tmpdir}/diagnostic.err"
test ! -s "${state_dir}/dns-cache/resolved_ipv6.txt"
if grep -R -Fq ';;' "${state_dir}/dns-cache" "${state_dir}/resolved_ipv6.txt" "${NFT_RULES_COPY}"; then
  echo "exhausted diagnostic text leaked into firewall address state" >&2
  exit 1
fi

# A malformed cache generation is rejected and replaced by fresh valid answers.
printf '%s\n' ';;' > "${state_dir}/dns-cache/resolved_ipv6.txt"
rm -rf "${DNS_ATTEMPT_DIR}"
CODEX_FIREWALL_DNS_TOOL=dig bash "${repo_root}/firewall/firewall-reload"
grep -Fxq '2001:db8::10' "${state_dir}/dns-cache/resolved_ipv6.txt"
test -s "${DNS_ATTEMPT_DIR}/AAAA"

# The outer timeout accepts fractional seconds and bounds each slow invocation.
rm -rf "${state_dir}/dns-cache" "${DNS_ATTEMPT_DIR}"
start_ns="$(date +%s%N)"
DNS_SLEEP=2 CODEX_FIREWALL_DNS_TIMEOUT=0.05 CODEX_FIREWALL_DNS_TRIES=1 \
  CODEX_FIREWALL_DNS_TOOL=dig bash "${repo_root}/firewall/firewall-reload" 2> "${tmpdir}/timeout.err"
elapsed_ms="$(( ($(date +%s%N) - start_ns) / 1000000 ))"
test "${elapsed_ms}" -lt 1000
grep -Fq 'DNS batch exhausted 1 attempts' "${tmpdir}/timeout.err"
rm -rf "${state_dir}/dns-cache" "${DNS_ATTEMPT_DIR}"
CODEX_FIREWALL_DNS_TOOL=dig bash "${repo_root}/firewall/firewall-reload"

grep -Fxq 'example.com' "${state_dir}/domains.txt"
grep -Fxq '198.51.100.0/24' "${state_dir}/ipv4.txt"
grep -Fxq '2001:db8:ffff::/48' "${state_dir}/ipv6.txt"
grep -Fxq '203.0.113.10' "${state_dir}/resolved_ipv4.txt"
grep -Fxq '2001:db8::10' "${state_dir}/resolved_ipv6.txt"
grep -Fxq 'CODEX_FIREWALL_MODE=enforced' "${state_dir}/status.env"
grep -A3 -F 'set allowed_v4 {' "${NFT_RULES_COPY}" | grep -Fxq '    auto-merge'
grep -A3 -F 'set allowed_v6 {' "${NFT_RULES_COPY}" | grep -Fxq '    auto-merge'
grep -Fxq '203.0.113.10' "${state_dir}/dns-cache/resolved_ipv4.txt"
grep -Fxq '2001:db8::10' "${state_dir}/dns-cache/resolved_ipv6.txt"

DNS_FAIL=1 CODEX_FIREWALL_DNS_TOOL=drill bash "${repo_root}/firewall/firewall-reload"
grep -Fxq '203.0.113.10' "${state_dir}/resolved_ipv4.txt"
grep -Fxq '2001:db8::10' "${state_dir}/resolved_ipv6.txt"

CODEX_FIREWALL_POLICY_DIR="${state_dir}" "${repo_root}/container-runtime/codex-firewall-policy" > "${tmpdir}/policy.txt"
grep -Fxq 'mode: enforced' "${tmpdir}/policy.txt"
grep -Fxq 'domains:' "${tmpdir}/policy.txt"
grep -Fxq '  example.com' "${tmpdir}/policy.txt"
grep -Fxq 'resolved_ipv4:' "${tmpdir}/policy.txt"
grep -Fxq '  203.0.113.10' "${tmpdir}/policy.txt"

CODEX_FIREWALL_POLICY_DIR="${state_dir}" "${repo_root}/container-runtime/codex-firewall-policy" --json > "${tmpdir}/policy.json"
grep -Fq '"mode":"enforced"' "${tmpdir}/policy.json"
grep -Fq '"domains":["example.com","second.example"]' "${tmpdir}/policy.json"
grep -Fq '"203.0.113.10"' "${tmpdir}/policy.json"
grep -Fq '"198.51.100.0/24"' "${tmpdir}/policy.json"

bash "${repo_root}/firewall/firewall-lift"
grep -Fxq 'CODEX_FIREWALL_MODE=lifted' "${state_dir}/status.env"
grep -Fxq 'delete table inet codex_firewall' "${NFT_LOG}"

CODEX_FIREWALL_POLICY_DIR="${state_dir}" "${repo_root}/container-runtime/codex-firewall-policy" > "${tmpdir}/lifted.txt"
grep -Fxq 'mode: lifted' "${tmpdir}/lifted.txt"
