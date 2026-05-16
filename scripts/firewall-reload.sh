#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/codex-firewall/firewall-common.sh

ensure_state_dir

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

allowed_ipv4_file="${tmpdir}/allowed_ipv4.txt"
allowed_ipv6_file="${tmpdir}/allowed_ipv6.txt"
dns_ipv4_file="${tmpdir}/dns_ipv4.txt"
dns_ipv6_file="${tmpdir}/dns_ipv6.txt"
nft_file="${tmpdir}/rules.nft"

touch "${allowed_ipv4_file}" "${allowed_ipv6_file}" "${dns_ipv4_file}" "${dns_ipv6_file}"

while IFS= read -r entry; do
  [ -n "${entry}" ] || continue
  printf '%s\n' "${entry}" >> "${allowed_ipv4_file}"
done < "${IPV4_FILE}"

while IFS= read -r entry; do
  [ -n "${entry}" ] || continue
  printf '%s\n' "${entry}" >> "${allowed_ipv6_file}"
done < "${IPV6_FILE}"

while IFS= read -r domain; do
  [ -n "${domain}" ] || continue

  while IFS= read -r record; do
    [[ "${record}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    printf '%s\n' "${record}" >> "${allowed_ipv4_file}"
  done < <(dig +short A "${domain}")

  while IFS= read -r record; do
    [[ "${record}" == *:* ]] || continue
    printf '%s\n' "${record}" >> "${allowed_ipv6_file}"
  done < <(dig +short AAAA "${domain}")
done < "${DOMAINS_FILE}"

while IFS= read -r resolver; do
  [ -n "${resolver}" ] || continue
  if is_ipv6_address "${resolver}"; then
    printf '%s\n' "${resolver}" >> "${dns_ipv6_file}"
  else
    printf '%s\n' "${resolver}" >> "${dns_ipv4_file}"
  fi
done < <(resolver_addresses)

sort -u -o "${allowed_ipv4_file}" "${allowed_ipv4_file}"
sort -u -o "${allowed_ipv6_file}" "${allowed_ipv6_file}"
sort -u -o "${dns_ipv4_file}" "${dns_ipv4_file}"
sort -u -o "${dns_ipv6_file}" "${dns_ipv6_file}"

{
  echo "table inet codex_firewall {"
  echo "  set allowed_v4 {"
  echo "    type ipv4_addr"
  echo "    flags interval"
  echo "    elements = {"
  sed 's/^/      /; s/$/,/' "${allowed_ipv4_file}"
  echo "    }"
  echo "  }"
  echo "  set allowed_v6 {"
  echo "    type ipv6_addr"
  echo "    flags interval"
  echo "    elements = {"
  sed 's/^/      /; s/$/,/' "${allowed_ipv6_file}"
  echo "    }"
  echo "  }"
  echo "  set dns_v4 {"
  echo "    type ipv4_addr"
  echo "    elements = {"
  sed 's/^/      /; s/$/,/' "${dns_ipv4_file}"
  echo "    }"
  echo "  }"
  echo "  set dns_v6 {"
  echo "    type ipv6_addr"
  echo "    elements = {"
  sed 's/^/      /; s/$/,/' "${dns_ipv6_file}"
  echo "    }"
  echo "  }"
  echo "  chain input {"
  echo "    type filter hook input priority 0"
  echo "    policy accept"
  echo "  }"
  echo "  chain forward {"
  echo "    type filter hook forward priority 0"
  echo "    policy drop"
  echo "    reject with icmpx type admin-prohibited"
  echo "  }"
  echo "  chain output {"
  echo "    type filter hook output priority 0"
  echo "    policy drop"
  echo "    ct state established,related accept"
  echo "    oifname \"lo\" accept"
  echo "    meta nfproto ipv4 ip daddr @dns_v4 udp dport 53 accept"
  echo "    meta nfproto ipv4 ip daddr @dns_v4 tcp dport 53 accept"
  echo "    meta nfproto ipv6 ip6 daddr @dns_v6 udp dport 53 accept"
  echo "    meta nfproto ipv6 ip6 daddr @dns_v6 tcp dport 53 accept"
  echo "    ip6 daddr fe80::/10 icmpv6 accept"
  echo "    ip6 daddr ff02::/16 icmpv6 accept"
  echo "    meta nfproto ipv4 ip daddr @allowed_v4 tcp accept"
  echo "    meta nfproto ipv4 ip daddr @allowed_v4 udp accept"
  echo "    meta nfproto ipv6 ip6 daddr @allowed_v6 tcp accept"
  echo "    meta nfproto ipv6 ip6 daddr @allowed_v6 udp accept"
  echo "    reject with icmpx type admin-prohibited"
  echo "  }"
  echo "}"
} > "${nft_file}"

nft delete table inet codex_firewall >/dev/null 2>&1 || true
nft -f "${nft_file}"
