#!/usr/bin/env bash
# JSONL run-events index. Append-only at $LIDAR_DIR/logs/runs.jsonl.
#
# On Linux, write(2) with O_APPEND atomically advances the file offset and
# writes; concurrent appenders never interleave or clobber regardless of
# write size. (PIPE_BUF — 4096 on Linux — constrains atomic writes to
# *pipes*, not regular files. The earlier "<4KB" guidance was wrong.)

[[ -n "${_LIDAR_EVENTS_LOADED:-}" ]] && return 0
_LIDAR_EVENTS_LOADED=1

# Requires lib/common.sh (for EVENTS_FILE, LIDAR_DIR, json_escape).

events_emit_start() {
  local id="$1" log="$2" project="$3"; shift 3
  mkdir -p "$(dirname "${EVENTS_FILE}")"
  local ts; ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local urls_json="[" first=1 a
  for a in "$@"; do
    [[ ${first} -eq 1 ]] || urls_json+=","
    urls_json+="\"$(json_escape "${a}")\""
    first=0
  done
  urls_json+="]"
  printf '{"id":"%s","event":"start","ts":"%s","log":"%s","project":"%s","urls":%s}\n' \
    "$(json_escape "${id}")" "${ts}" "$(json_escape "${log}")" \
    "$(json_escape "${project}")" "${urls_json}" \
    >> "${EVENTS_FILE}"
}

events_emit_end() {
  local id="$1" exit_code="$2"
  mkdir -p "$(dirname "${EVENTS_FILE}")"
  local ts; ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  printf '{"id":"%s","event":"end","ts":"%s","exit":%d}\n' \
    "$(json_escape "${id}")" "${ts}" "${exit_code}" \
    >> "${EVENTS_FILE}"
}

# Delete run logs older than N days. Events file is preserved (tiny).
# Default 30 days; failed runs covered by the same blanket retention since
# they're usually fixed within days, not months.
cleanup_old_logs() {
  local days="${1:-30}"
  local log_dir="${LIDAR_DIR}/logs"
  [[ -d "${log_dir}" ]] || return 0
  find "${log_dir}" -maxdepth 1 -type f -name '*.log' \
    -mtime "+${days}" -delete 2>/dev/null || true
}

# ─── Liveness ────────────────────────────────────────────────────────────────
# A PID recorded inside one container means nothing in another, so liveness
# comes from systemd: the host wrapper passes the ids of active lidar@ units
# in LIDAR_ACTIVE (space-separated). Unset → nothing is considered running.
run_is_active() {
  [[ " ${LIDAR_ACTIVE:-} " == *" $1 "* ]]
}

# ─── Run ID resolver ─────────────────────────────────────────────────────────
# Accepts a full run ID or a bare hex prefix; prints the resolved ID.
# Errors (to stderr) and returns 1 on no match or ambiguity.
resolve_run_id() {
  local query="$1"
  command -v jq >/dev/null || { echo "ERROR: jq required" >&2; return 1; }
  [[ -f "${EVENTS_FILE}" ]] || { echo "ERROR: no runs recorded yet" >&2; return 1; }

  local matches
  matches=$(jq -rs --arg q "${query}" '
    [ .[] | select(.event=="start") | .id ] | unique
    | .[] | select(. == $q or startswith($q))
  ' "${EVENTS_FILE}")

  local count=0
  [[ -n "${matches}" ]] && count=$(echo "${matches}" | wc -l)

  if [[ ${count} -eq 0 ]]; then
    echo "ERROR: no run matching '${query}'" >&2; return 1
  elif [[ ${count} -gt 1 ]]; then
    echo "ERROR: '${query}' is ambiguous, matches:" >&2
    echo "${matches}" | sed 's/^/  /' >&2; return 1
  fi

  echo "${matches}"
}

# ─── Unified input resolver ───────────────────────────────────────────────────
# resolve_input <arg>
# Accepts a tile list (local file or https:// URL), a run name, or a hex suffix.
# Sets globals (cleared on each call):
#   INPUT_TYPE       "tile-list" | "run"
#   INPUT_TILE_LIST  path or URL for tile-list type; extracted from run urls for run type
#   INPUT_RUN_ID     resolved run ID for run type; empty for tile-list type
# Returns 0 on success, 1 with an error message on stderr on failure.
resolve_input() {
  local arg="$1"
  INPUT_TYPE="" INPUT_TILE_LIST="" INPUT_RUN_ID=""

  if [[ "${arg}" =~ ^https?:// ]]; then
    INPUT_TYPE="tile-list"
    INPUT_TILE_LIST="${arg}"
    return 0
  fi

  if [[ -f "${arg}" ]]; then
    INPUT_TYPE="tile-list"
    INPUT_TILE_LIST="${arg}"
    return 0
  fi

  local id
  if id=$(resolve_run_id "${arg}" 2>/dev/null); then
    INPUT_TYPE="run"
    INPUT_RUN_ID="${id}"
    INPUT_TILE_LIST=$(jq -rs --arg id "${id}" '
      [ .[] | select(.id == $id and .event == "start") ] | last | .urls[0] // ""
    ' "${EVENTS_FILE}" 2>/dev/null || echo "")
    return 0
  fi

  # Emit the run resolver's error if it looks like a run query, else a generic one.
  resolve_run_id "${arg}" >/dev/null || true
  return 1
}

# ─── --list-runs implementation ──────────────────────────────────────────────
# Renders all recorded runs (newest-first) as a text table to stdout.
list_runs() {
  command -v jq >/dev/null || {
    echo "ERROR: list_runs requires jq" >&2
    exit 1
  }
  if [[ ! -f "${EVENTS_FILE}" ]]; then
    echo "(no runs yet)"
    return
  fi

  # jq collapses events to per-id rows. Fields joined by ASCII US (0x1F) —
  # non-whitespace, so bash IFS preserves empty fields.
  # duration_sec: if ended exists, use (ended - started), else (now - started).
  local rows
  rows=$(jq -s -r '
    group_by(.id) | map(
      (map(select(.event=="start")) | last) as $s
      | .[-1] as $last
      | {
          id:       ($s.id // $last.id),
          project:  ($s.project // ""),
          started:  ($s.ts // ""),
          ended:    (if $last.event=="end" then $last.ts else "" end),
          log:      ($s.log // ""),
          exit:     (if $last.event=="end" then $last.exit else null end),
          last_event: $last.event,
          duration_sec: (
            if (if $last.event=="end" then $last.ts else "" end) != "" then
              (((if $last.event=="end" then $last.ts else "" end) | fromdate) - ($s.ts | fromdate))
            else
              ((now | floor) - ($s.ts | fromdate))
            end
            | if . < 0 then 0 else . end
          )
        }
    ) | sort_by(.started) | reverse
    | .[] | [.id, .project, .started, .ended, .log,
             (.exit // "" | tostring), .last_event, (.duration_sec|tostring)] | join("")
  ' "${EVENTS_FILE}")

  # Color only on TTY
  local C_RESET="" C_OK="" C_FAIL="" C_RUN="" C_CRASH=""
  if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_OK=$'\033[32m'
    C_FAIL=$'\033[31m'
    C_RUN=$'\033[33m'
    C_CRASH=$'\033[35m'
  fi

  printf "%-8s  %-6s  %-19s  %9s  %s\n" "STATUS" "HEX" "STARTED" "DURATION" "PROJECT"
  while IFS=$'\x1f' read -r id project started ended log exit_code last_event duration_sec; do
    [[ -z "${id}" ]] && continue
    local status
    if [[ "${last_event}" == "end" ]]; then
      [[ "${exit_code}" == "0" ]] && status="success" || status="failed"
    else
      if run_is_active "${id}"; then
        status="running"
      else
        status="crashed"
      fi
    fi

    local sym color
    case "${status}" in
      success) sym="✓ ok";    color="${C_OK}" ;;
      failed)  sym="✗ fail";  color="${C_FAIL}" ;;
      running) sym="⏱ run";   color="${C_RUN}" ;;
      crashed) sym="⊘ crash"; color="${C_CRASH}" ;;
      *)       sym="${status}"; color="" ;;
    esac

    # 2026-05-16T22:14:03Z → 2026-05-16 22:14:03
    local started_h="${started/T/ }"; started_h="${started_h%Z}"
    local dur_h; dur_h=$(human_duration "${duration_sec}")
    printf "${color}%-8s${C_RESET}  %-6s  %-19s  %9s  %s\n" \
      "${sym}" "${id}" "${started_h}" "${dur_h}" "${project}"
  done <<< "${rows}"
}
