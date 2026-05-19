#!/usr/bin/env bash
# Process-level helpers: liveness checks and graceful termination for lidar runs.
# Requires lib/events.sh (for EVENTS_FILE).

[[ -n "${_LIDAR_PROCESS_LOADED:-}" ]] && return 0
_LIDAR_PROCESS_LOADED=1

# Emit "pid id" pairs for every run that is alive per the events index.
running_pids() {
  [[ -f "${EVENTS_FILE}" ]] || return 0
  command -v jq >/dev/null || return 0
  jq -s -r '
    group_by(.id) | map(
      (map(select(.event=="start"))[0]) as $s
      | .[-1] as $last
      | select($last.event != "end")
      | [$s.id, ($s.pid|tostring)] | join("")
    ) | .[]
  ' "${EVENTS_FILE}" | while IFS=$'\x1f' read -r id pid; do
    [[ -z "${pid}" || "${pid}" == "0" ]] && continue
    kill -0 "${pid}" 2>/dev/null && echo "${pid} ${id}" || true
  done
}

# TERM the whole process group, not just the leader PID. The pipeline blocks
# in `wait` on long-running GDAL children (bwrap/gdaldem/gdalwarp/curl): a
# signal to the bash leader sits queued until wait returns, and wait won't
# return until the child finishes. Signaling the pgrp reaches every member.
kill_target() {
  local pid="$1" label="$2" pgid
  pgid=$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ' || true)
  echo "  TERM ${label} (pid=${pid}${pgid:+, pgid=${pgid}})"
  if [[ -n "${pgid}" ]]; then
    kill -TERM -- "-${pgid}" 2>/dev/null || true
  else
    kill -TERM "${pid}" 2>/dev/null || true
  fi
}

# Given a run ID, return the PID if the process is currently alive, else empty.
live_pid_for() {
  local id="$1"
  local pid
  pid=$(jq -rs --arg id "$id" '
    [ .[] | select(.id==$id and .event=="start") ] | last | .pid // 0
  ' "${EVENTS_FILE}" 2>/dev/null || echo 0)
  [[ "${pid}" -gt 0 ]] && kill -0 "${pid}" 2>/dev/null && echo "${pid}" || true
}
