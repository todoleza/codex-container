#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/codex-firewall/firewall-common.sh

ensure_state_dir

printf 'domains:\n'
cat "${DOMAINS_FILE}"
printf '\nipv4:\n'
cat "${IPV4_FILE}"
printf '\nipv6:\n'
cat "${IPV6_FILE}"
