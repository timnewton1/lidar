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

# Explain why a signal-based exit happened, for the run log's EXIT banner.
# Args: <signame>   the signal name without the SIG prefix (TERM, INT, HUP)
#                   or a raw number if `kill -l` could not name it.
# Echoes a one-line human-readable reason. Best-effort; never fails.
#
# A bare SIGTERM is ambiguous on its own — it could be a manual kill, a
# `lidar kill`, a systemd unit stop, or the broadcast systemd sends to every
# process during shutdown/reboot. We can pin down the reboot case: systemd
# reports the whole system as "stopping" for the entire shutdown grace
# window, so a TERM arriving while `is-system-running` says "stopping" is the
# reboot — not a targeted kill. Note an OOM-kill never reaches this trap at
# all: the kernel uses SIGKILL, which is untrappable, so we must NOT guess
# "OOM" for a signal we were able to catch.
signal_exit_reason() {
  local signame="$1"
  case "${signame}" in
    INT) echo "interrupted (SIGINT / Ctrl-C)"; return 0 ;;
    HUP) echo "terminal hangup (SIGHUP)"; return 0 ;;
    TERM)
      local sys=""
      command -v systemctl >/dev/null 2>&1 && sys=$(systemctl is-system-running 2>/dev/null || true)
      if [[ "${sys}" == "stopping" ]]; then
        echo "SIGTERM from system shutdown/reboot in progress"
      else
        echo "SIGTERM from outside the run (manual kill, lidar kill, or systemd stop/timeout)"
      fi
      return 0
      ;;
    *) echo "killed by signal ${signame}"; return 0 ;;
  esac
}
