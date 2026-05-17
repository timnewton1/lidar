#!/usr/bin/env bash
# Strict mode + ERR trap with line-number diagnostics.
# Sourced first by every sub-binary and every bats test.
[[ -n "${_LIDAR_STRICT_LOADED:-}" ]] && return 0
_LIDAR_STRICT_LOADED=1
set -Eeuo pipefail
trap 'rc=$?; printf "\nERROR rc=%d at %s:%d in %s\n" "$rc" \
  "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" "${FUNCNAME[1]:-main}" >&2' ERR
