#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/codex-firewall/firewall-common.sh

ensure_state_dir

if [ "$#" -ne 1 ]; then
  echo "Usage: firewall-allow-address ADDRESS_OR_CIDR" >&2
  exit 1
fi

address="$1"
if ! validate_address "${address}"; then
  echo "Invalid address: ${address}" >&2
  exit 1
fi

if is_ipv6_address "${address}"; then
  append_unique_line "${IPV6_FILE}" "${address}"
else
  append_unique_line "${IPV4_FILE}" "${address}"
fi
