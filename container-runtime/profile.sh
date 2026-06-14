#!/bin/bash

if [ -n "${CODEX_WORKDIR:-}" ] && [ -d "${CODEX_WORKDIR}" ]; then
  case "${PWD}" in
    "${CODEX_WORKDIR}"|"${CODEX_WORKDIR}"/*)
      ;;
    *)
      cd "${CODEX_WORKDIR}" || true
      ;;
  esac
fi
