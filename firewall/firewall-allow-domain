#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/codex-firewall/firewall-common.sh

ensure_state_dir

if [ "$#" -ne 1 ]; then
  echo "Usage: firewall-allow-domain DOMAIN" >&2
  exit 1
fi

domain="$1"
if ! validate_domain "${domain}"; then
  echo "Invalid domain: ${domain}" >&2
  exit 1
fi

append_unique_line "${DOMAINS_FILE}" "${domain}"
