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
  local id="$1" log="$2"; shift 2
  mkdir -p "$(dirname "${EVENTS_FILE}")"
  local ts; ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local args_json="[" first=1 a
  for a in "$@"; do
    [[ ${first} -eq 1 ]] || args_json+=","
    args_json+="\"$(json_escape "${a}")\""
    first=0
  done
  args_json+="]"
  printf '{"id":"%s","event":"start","ts":"%s","pid":%d,"log":"%s","args":%s}\n' \
    "$(json_escape "${id}")" "${ts}" "$$" "$(json_escape "${log}")" "${args_json}" \
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

# ─── Run ID resolver ─────────────────────────────────────────────────────────
# Accepts a full run ID or a bare hex suffix; prints the resolved ID.
# Errors (to stderr) and returns 1 on no match or ambiguity.
resolve_run_id() {
  local query="$1"
  command -v jq >/dev/null || { echo "ERROR: jq required" >&2; return 1; }
  [[ -f "${EVENTS_FILE}" ]] || { echo "ERROR: no runs recorded yet" >&2; return 1; }

  local matches
  matches=$(jq -rs --arg q "${query}" '
    [ .[] | select(.event=="start") | .id ] | unique
    | .[] | select(. == $q or endswith("_" + $q))
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
#   INPUT_TILE_LIST  path or URL for tile-list type; extracted from run args for run type
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
    # First non-flag positional in the stored args is the tile list path/URL.
    INPUT_TILE_LIST=$(jq -rs --arg id "${id}" '
      .[] | select(.id == $id and .event == "start") | .args
      | map(select(startswith("-") | not)) | first // ""
    ' "${EVENTS_FILE}" 2>/dev/null || echo "")
    return 0
  fi

  # Emit the run resolver's error if it looks like a run query, else a generic one.
  resolve_run_id "${arg}" >/dev/null || true
  return 1
}

# ─── Restart arg reconstruction ──────────────────────────────────────────────
# Given a run ID, emit the args to use for a restart — one arg per line.
# --background/-b is stripped (the caller adds it). --name/-n is stripped and
# re-emitted with an incremented suffix: foo → foo_2, foo_2 → foo_3. If the
# run had no --name, none is emitted (lets lidar-run generate a fresh one).
strip_restart_flags() {
  local id="$1"

  local orig_name
  orig_name=$(jq -rs --arg id "$id" '
    [ .[] | select(.id==$id and .event=="start") ] | last | .args // []
    | . as $a
    | [ range(length) | . as $i
        | if ($a[$i] == "--name" or $a[$i] == "-n") then $a[$i+1] // empty
          else empty
          end ] | first // ""
  ' "${EVENTS_FILE}")

  jq -rs --arg id "$id" '
    [ .[] | select(.id==$id and .event=="start") ] | last | .args // []
    | . as $a
    | [ range(length) | . as $i
        | if $a[$i] == "--background" or $a[$i] == "-b" then empty
          elif ($a[$i] == "--name" or $a[$i] == "-n") then empty
          elif $i > 0 and ($a[$i-1] == "--name" or $a[$i-1] == "-n") then empty
          else $a[$i]
          end ]
    | .[]
  ' "${EVENTS_FILE}"

  if [[ -n "${orig_name}" ]]; then
    local new_name
    if [[ "${orig_name}" =~ ^(.+)_([0-9]+)$ ]]; then
      new_name="${BASH_REMATCH[1]}_$(( BASH_REMATCH[2] + 1 ))"
    else
      new_name="${orig_name}_2"
    fi
    echo "--name"
    echo "${new_name}"
  fi
}

# ─── --list-runs implementation ──────────────────────────────────────────────
# Args: filter_status limit since_secs show_all json_mode
# Empty filter_status = all statuses; show_all=1 disables limit.
list_runs() {
  local filter_status="$1" limit="${2:-20}" since_secs="$3" show_all="$4" json_mode="$5"

  command -v jq >/dev/null || {
    echo "ERROR: --list-runs requires jq (sudo dnf install jq)" >&2
    exit 1
  }
  if [[ ! -f "${EVENTS_FILE}" ]]; then
    [[ "${json_mode}" == "1" ]] && echo "[]" || echo "(no runs yet)"
    return
  fi

  local now_epoch; now_epoch=$(date +%s)

  # jq collapses events to per-id rows: id, started, ended, pid, log, exit, last_event
  # Sorted newest-first. Fields joined by ASCII US (0x1F) — non-whitespace, so
  # bash IFS preserves empty fields (tabs collapse under default whitespace IFS).
  local rows
  rows=$(jq -s -r '
    group_by(.id) | map(
      (map(select(.event=="start"))[0]) as $s
      | .[-1] as $last
      | {
          id: ($s.id // $last.id),
          started: ($s.ts // ""),
          ended: (if $last.event=="end" then $last.ts else "" end),
          pid: ($s.pid // 0),
          log: ($s.log // ""),
          exit: (if $last.event=="end" then $last.exit else null end),
          last_event: $last.event
        }
    ) | sort_by(.started) | reverse
    | .[] | [.id, .started, .ended, (.pid|tostring), .log,
             (.exit // "" | tostring), .last_event] | join("")
  ' "${EVENTS_FILE}")

  # Walk rows, compute status (including PID liveness) and duration,
  # apply filters, accumulate.
  local out_rows=()
  local count=0
  while IFS=$'\x1f' read -r id started ended pid log exit_code last_event; do
    [[ -z "${id}" ]] && continue
    local status
    if [[ "${last_event}" == "end" ]]; then
      [[ "${exit_code}" == "0" ]] && status="success" || status="failed"
    else
      if [[ "${pid}" -gt 0 ]] && kill -0 "${pid}" 2>/dev/null; then
        status="running"
      else
        status="crashed"
      fi
    fi

    [[ -n "${filter_status}" && "${filter_status}" != "${status}" ]] && continue

    local start_epoch; start_epoch=$(date -d "${started}" +%s 2>/dev/null || echo 0)
    if [[ -n "${since_secs}" && ${start_epoch} -gt 0 ]]; then
      (( now_epoch - start_epoch > since_secs )) && continue
    fi

    local dur
    if [[ -n "${ended}" ]]; then
      local end_epoch; end_epoch=$(date -d "${ended}" +%s 2>/dev/null || echo "${now_epoch}")
      dur=$(( end_epoch - start_epoch ))
    else
      dur=$(( now_epoch - start_epoch ))
    fi
    (( dur < 0 )) && dur=0

    out_rows+=("${status}|${started}|${dur}|${id}|${log}|${exit_code}|${pid}")
    count=$((count + 1))
    if [[ "${show_all}" != "1" && ${count} -ge ${limit} ]]; then break; fi
  done <<< "${rows}"

  if [[ "${json_mode}" == "1" ]]; then
    # Re-emit filtered set as JSON
    local first=1
    printf '['
    for r in "${out_rows[@]+"${out_rows[@]}"}"; do
      IFS='|' read -r status started dur id log exit_code pid <<< "${r}"
      [[ ${first} -eq 1 ]] || printf ','
      printf '{"status":"%s","started":"%s","duration_sec":%d,"id":"%s","log":"%s","exit":%s,"pid":%d}' \
        "${status}" "${started}" "${dur}" "$(json_escape "${id}")" "$(json_escape "${log}")" \
        "${exit_code:-null}" "${pid}"
      first=0
    done
    printf ']\n'
    return
  fi

  if [[ ${#out_rows[@]} -eq 0 ]]; then
    echo "(no matching runs)"
    return
  fi

  # Color only on TTY
  local C_RESET="" C_OK="" C_FAIL="" C_RUN="" C_CRASH=""
  if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_OK=$'\033[32m'     # green
    C_FAIL=$'\033[31m'   # red
    C_RUN=$'\033[33m'    # yellow
    C_CRASH=$'\033[35m'  # magenta
  fi

  printf "%-9s  %-19s  %9s  %-24s  %s\n" "STATUS" "STARTED" "DURATION" "NAME" "LOG"
  for r in "${out_rows[@]}"; do
    IFS='|' read -r status started dur id log exit_code pid <<< "${r}"
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
    local dur_h; dur_h=$(human_duration "${dur}")
    local log_base="${log##*/}"
    printf "${color}%-9s${C_RESET}  %-19s  %9s  %-24s  %s\n" \
      "${sym}" "${started_h}" "${dur_h}" "${id}" "${log_base}"
  done
}
