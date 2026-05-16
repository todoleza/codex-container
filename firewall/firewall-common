#!/bin/bash
set -euo pipefail

STATE_DIR="${CODEX_FIREWALL_STATE_DIR:-/etc/codex-firewall}"
DOMAINS_FILE="${STATE_DIR}/domains.txt"
IPV4_FILE="${STATE_DIR}/ipv4.txt"
IPV6_FILE="${STATE_DIR}/ipv6.txt"

ensure_state_dir() {
  mkdir -p "${STATE_DIR}"
  touch "${DOMAINS_FILE}" "${IPV4_FILE}" "${IPV6_FILE}"
}

append_unique_line() {
  local file="$1"
  local entry="$2"

  if grep -Fqx -- "${entry}" "${file}"; then
    return 0
  fi

  printf '%s\n' "${entry}" >> "${file}"
}

validate_domain() {
  local domain="$1"

  [[ "${domain}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]\.[A-Za-z]{2,}$ ]]
}

validate_address() {
  local address="$1"

  if [[ "${address}" == *:* ]]; then
    [[ "${address}" =~ ^[0-9A-Fa-f:/]+$ ]]
    return
  fi

  [[ "${address}" =~ ^[0-9./]+$ ]]
}

is_ipv6_address() {
  local address="$1"
  [[ "${address}" == *:* ]]
}

resolver_addresses() {
  awk '/^nameserver / { print $2 }' /etc/resolv.conf
}
