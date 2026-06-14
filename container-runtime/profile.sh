#!/bin/bash

workspace_dir="${CODEX_WORKDIR:-}"

if [ -n "${workspace_dir}" ] && [ -d "${workspace_dir}" ]; then
  case "${PWD}" in
    "${workspace_dir}"|"${workspace_dir}"/*)
      ;;
    *)
      cd "${workspace_dir}" || true
      ;;
  esac
fi
