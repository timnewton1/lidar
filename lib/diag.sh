#!/usr/bin/env bash
# Pre-run environment diagnostics: disk, RAM, tmpfs, GDAL version.
# Requires lib/common.sh (GDAL_FLATPAK_APP, GDAL array, human_bytes).

[[ -n "${_LIDAR_DIAG_LOADED:-}" ]] && return 0
_LIDAR_DIAG_LOADED=1

# Print a one-line environment snapshot to stdout.
# Args: <output_dir>  — the disk to measure free space on
# Output format:
#   disk_avail=12.3GB  ram_avail_mb=4096  tmpfs_avail=8.0GB  load=1.23
diag_system_snapshot() {
  local output_dir="${1:-/tmp}"
  local disk_kb ram_avail_mb tmpfs_kb load1
  disk_kb=$(df -k "${output_dir}" 2>/dev/null | awk 'NR==2{print $4}')
  ram_avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  tmpfs_kb=$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}')
  load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "?")
  printf 'disk_avail=%s  ram_avail_mb=%s  tmpfs_avail=%s  load=%s\n' \
    "$(human_bytes "$(( disk_kb * 1024 ))" 2>/dev/null || echo "${disk_kb}KB")" \
    "${ram_avail_mb}" \
    "$(human_bytes "$(( tmpfs_kb * 1024 ))" 2>/dev/null || echo "${tmpfs_kb}KB")" \
    "${load1}"
}

# Print a full pre-run environment block to stdout.
# Includes: flatpak app, GDAL version (if flatpak accessible), disk/RAM/tmpfs.
# Designed to be called inside the per-project log (exec > log already in place).
# Args: <output_dir>
diag_pre_run() {
  local output_dir="${1:-/tmp}"
  echo "=========================================="
  echo "ENVIRONMENT"
  echo "=========================================="
  echo "  Flatpak app : ${GDAL_FLATPAK_APP}"
  local gdal_ver
  gdal_ver=$("${GDAL[@]}" --version 2>/dev/null || echo "unknown")
  echo "  GDAL version: ${gdal_ver}"
  echo "  $(diag_system_snapshot "${output_dir}")"
  local disk_kb
  disk_kb=$(df -k "${output_dir}" 2>/dev/null | awk 'NR==2{print $4}')
  # Warn if output disk has less than 20 GB free — a county-scale run with
  # hillshade + KML pyramid routinely needs 10–15 GB.
  if [[ -n "${disk_kb}" && "${disk_kb}" -lt $((20 * 1024 * 1024)) ]]; then
    echo "  WARNING: output disk has less than 20 GB free — large runs may fail with 'no space left on device'"
  fi
  local ram_avail_mb
  ram_avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 999999)
  if [[ "${ram_avail_mb}" -lt 2048 ]]; then
    echo "  WARNING: less than 2 GB RAM available — GDAL operations may be very slow or OOM-killed"
  fi
  echo "=========================================="
}
