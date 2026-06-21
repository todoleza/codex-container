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
if [ "$1" = "+time=2" ] && [ "$2" = "+tries=1" ] && [ "$3" = "+short" ] && [ "$4" = "-f" ]; then
  while read -r domain record_type; do
    case "${domain} ${record_type}" in
      "example.com A") printf '%s\n' 203.0.113.10 ;;
      "example.com AAAA") printf '%s\n' 2001:db8::10 ;;
    esac
  done < "$5"
  exit 0
fi
case "$*" in
  *" A example.com") printf '%s\n' 203.0.113.10 ;;
  *" AAAA example.com") printf '%s\n' 2001:db8::10 ;;
esac
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
grep -Fq '"domains":["example.com"]' "${tmpdir}/policy.json"
grep -Fq '"203.0.113.10"' "${tmpdir}/policy.json"
grep -Fq '"198.51.100.0/24"' "${tmpdir}/policy.json"

bash "${repo_root}/firewall/firewall-lift"
grep -Fxq 'CODEX_FIREWALL_MODE=lifted' "${state_dir}/status.env"
grep -Fxq 'delete table inet codex_firewall' "${NFT_LOG}"

CODEX_FIREWALL_POLICY_DIR="${state_dir}" "${repo_root}/container-runtime/codex-firewall-policy" > "${tmpdir}/lifted.txt"
grep -Fxq 'mode: lifted' "${tmpdir}/lifted.txt"
