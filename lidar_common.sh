#!/usr/bin/env bash
# Compatibility shim — sources the modular lib/ stack.
# Will be removed once lidar_hillshade.sh is replaced by libexec subcommands.

[[ -n "${_LIDAR_COMMON_SHIM_LOADED:-}" ]] && return 0
_LIDAR_COMMON_SHIM_LOADED=1

SCRIPT_DIR_LC=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lib/strict.sh
source "${SCRIPT_DIR_LC}/lib/strict.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR_LC}/lib/common.sh"
# shellcheck source=lib/events.sh
source "${SCRIPT_DIR_LC}/lib/events.sh"
# shellcheck source=lib/download.sh
source "${SCRIPT_DIR_LC}/lib/download.sh"
# shellcheck source=lib/gdal.sh
source "${SCRIPT_DIR_LC}/lib/gdal.sh"
# shellcheck source=lib/kml.sh
source "${SCRIPT_DIR_LC}/lib/kml.sh"
