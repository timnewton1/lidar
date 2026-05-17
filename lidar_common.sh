#!/usr/bin/env bash
# Shared library for the lidar shading pipeline.
# Source this file; do not execute it directly.

[[ -n "${_LIDAR_COMMON_SHIM_LOADED:-}" ]] && return 0
_LIDAR_COMMON_SHIM_LOADED=1

SCRIPT_DIR_LC=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lib/strict.sh
source "${SCRIPT_DIR_LC}/lib/strict.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR_LC}/lib/common.sh"

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

# ─── Step 1: check_deps_and_input <download_list> [extra_cmd...] ─────────────
# Sets: DOWNLOAD_LIST FILTERED_LIST TOTAL_TILES
check_deps_and_input() {
  local download_list="$1"; shift
  local extra_deps=("$@")

  echo "=========================================="
  echo "STEP 1: Checking dependencies"
  echo "=========================================="

  command -v curl   >/dev/null || { echo "ERROR: curl not found"; exit 1; }
  command -v numfmt >/dev/null || { echo "ERROR: numfmt not found (coreutils)"; exit 1; }
  for dep in "${extra_deps[@]+"${extra_deps[@]}"}"; do
    command -v "${dep}" >/dev/null || { echo "ERROR: ${dep} not found"; exit 1; }
  done
  flatpak list | grep -q "${GDAL_FLATPAK_APP}" \
    || { echo "ERROR: flatpak app '${GDAL_FLATPAK_APP}' not installed"; exit 1; }

  if [[ ! -d "${LIDAR_DIR}" ]]; then
    echo "ERROR: Lidar dir not found: ${LIDAR_DIR}"
    echo "  Is ${GIS_DIR} mounted?"
    exit 1
  fi

  # Accept either a local path or an http(s):// URL to a .txt of tile URLs.
  # Fetched lists land in WORK_DIR (per-run) to avoid collisions between
  # concurrent background runs sharing the same URL basename.
  if [[ "${download_list}" =~ ^https?:// ]]; then
    [[ -n "${WORK_DIR:-}" ]] || { echo "ERROR: WORK_DIR not set"; exit 1; }
    local fetched="${WORK_DIR}/${download_list##*/}"
    echo "  Fetching link list: ${download_list}"
    curl -L --retry 5 --retry-all-errors --fail-with-body --max-time 120 \
      -o "${fetched}.partial" "${download_list}" \
      || { echo "ERROR: failed to fetch ${download_list}"; exit 1; }
    mv -f "${fetched}.partial" "${fetched}"
    download_list="${fetched}"
  elif [[ ! -f "${download_list}" ]]; then
    echo "ERROR: File not found: ${download_list}"
    exit 1
  fi

  DOWNLOAD_LIST="${download_list}"
  # Per-run filtered list under WORK_DIR — two concurrent runs would otherwise
  # clobber each other on this file mid-iteration.
  [[ -n "${WORK_DIR:-}" ]] || { echo "ERROR: WORK_DIR not set"; exit 1; }
  FILTERED_LIST="${WORK_DIR}/filtered_tiles.txt"
  grep -i '\.tif' "${DOWNLOAD_LIST}" | grep -v '^#' | grep -v '^[[:space:]]*$' > "${FILTERED_LIST}" || true

  TOTAL_TILES=$(wc -l < "${FILTERED_LIST}")
  if [[ "${TOTAL_TILES}" -eq 0 ]]; then
    echo "ERROR: No .tif URLs found in ${DOWNLOAD_LIST}"
    exit 1
  fi

  echo "GIS_DIR    : ${GIS_DIR}"
  echo "Input file : ${DOWNLOAD_LIST}"
  echo "Tiles found: ${TOTAL_TILES}"
}

# ─── Step 2: prescan ─────────────────────────────────────────────────────────
# Groups URLs by project (one .list per project under LISTS_DIR), counts
# cached vs pending, and HEAD-samples a few pending URLs for a size estimate.
# Avoids a HEAD-per-URL scan, which dominated wall time on large jobs.
#
# Requires: LISTS_DIR set by caller (under WORK_DIR).
# Sets: BYTES_DONE BYTES_TOTAL_EST TILES_CACHED TILES_PENDING
#       PROJECT_NAMES (array) PROJECT_COUNT (assoc) SKIPPED_NO_PROJECT
PRESCAN_SAMPLE=5
prescan() {
  echo "=========================================="
  echo "STEP 2: Grouping by project + size estimate"
  echo "=========================================="

  [[ -n "${LISTS_DIR:-}" ]] || { echo "ERROR: LISTS_DIR not set"; exit 1; }
  mkdir -p "${LISTS_DIR}"

  BYTES_DONE=0
  TILES_CACHED=0
  TILES_PENDING=0
  SKIPPED_NO_PROJECT=0
  declare -gA PROJECT_COUNT=()
  local PENDING_URLS=()

  while IFS= read -r URL; do
    [[ -z "${URL}" ]] && continue
    local BASENAME="${URL##*/}"; BASENAME="${BASENAME%.tif}"
    local TILE_TIF="${DEM_DIR}/${BASENAME}.tif"
    local PROJECT
    PROJECT=$(project_from_url "${URL}")
    if [[ -z "${PROJECT}" ]]; then
      SKIPPED_NO_PROJECT=$((SKIPPED_NO_PROJECT + 1))
      continue
    fi
    echo "${URL}" >> "${LISTS_DIR}/${PROJECT}.urls"
    PROJECT_COUNT["${PROJECT}"]=$((${PROJECT_COUNT["${PROJECT}"]:-0} + 1))
    if [[ -f "${TILE_TIF}" ]]; then
      BYTES_DONE=$((BYTES_DONE + $(stat -c %s "${TILE_TIF}")))
      TILES_CACHED=$((TILES_CACHED + 1))
    else
      PENDING_URLS+=("${URL}")
      TILES_PENDING=$((TILES_PENDING + 1))
    fi
  done < "${FILTERED_LIST}"

  mapfile -t PROJECT_NAMES < <(printf '%s\n' "${!PROJECT_COUNT[@]}" | sort)

  BYTES_TOTAL_EST="${BYTES_DONE}"
  if [[ ${TILES_PENDING} -gt 0 ]]; then
    # Sample up to PRESCAN_SAMPLE random pending URLs to estimate avg size.
    local N=${PRESCAN_SAMPLE}
    [[ ${N} -gt ${TILES_PENDING} ]] && N=${TILES_PENDING}
    echo "  Sampling ${N} of ${TILES_PENDING} pending tiles for size estimate..."
    local SAMPLE_BYTES=0 SAMPLE_OK=0 i
    for i in $(shuf -i 0-$((TILES_PENDING - 1)) -n "${N}" 2>/dev/null \
               || seq 0 $((N - 1))); do
      local U="${PENDING_URLS[i]}"
      local SIZE
      SIZE=$(curl -sIL --max-time 30 "${U}" \
             | awk 'tolower($1)=="content-length:" {gsub(/\r/,""); v=$2} END{print v}')
      if [[ -n "${SIZE}" && "${SIZE}" -gt 0 ]]; then
        SAMPLE_BYTES=$((SAMPLE_BYTES + SIZE))
        SAMPLE_OK=$((SAMPLE_OK + 1))
      fi
    done
    if [[ ${SAMPLE_OK} -gt 0 ]]; then
      local AVG=$((SAMPLE_BYTES / SAMPLE_OK))
      BYTES_TOTAL_EST=$((BYTES_DONE + AVG * TILES_PENDING))
      echo "  Avg tile size  : $(human_bytes "${AVG}")  (n=${SAMPLE_OK})"
    else
      echo "  WARNING: size sample failed — proceeding without estimate"
    fi
  fi

  echo "  Projects       : ${#PROJECT_NAMES[@]}"
  echo "  Already cached : ${TILES_CACHED} tiles  ($(human_bytes "${BYTES_DONE}"))"
  echo "  To download    : ${TILES_PENDING} tiles"
  echo "  Est. total     : ~$(human_bytes "${BYTES_TOTAL_EST}")"
  if [[ ${SKIPPED_NO_PROJECT} -gt 0 ]]; then
    echo "  Skipped (no Projects/ in URL): ${SKIPPED_NO_PROJECT}"
  fi
}

# ─── Step 3: make_dirs [extra_dir...] ────────────────────────────────────────
make_dirs() {
  echo "=========================================="
  echo "STEP 3: Creating output directories"
  echo "=========================================="
  mkdir -p "${DEM_DIR}" "$@"
}

# ─── Step 4: download_tiles ──────────────────────────────────────────────────
# Download every URL in FILTERED_LIST into DEM_DIR. Skips already-cached files.
# Each tile's progress bar gets its own line with a percentage.
download_tiles() {
  echo "=========================================="
  echo "STEP 4: Downloading ${TOTAL_TILES} tiles"
  echo "=========================================="

  local PROCESSED=0
  local ERRORS=0
  local BYTES_DOWNLOADED="${BYTES_DONE}"
  # EWMA download rate (bytes/sec). Seeds itself from the first completed
  # tile, then updates per tile so recent slow patches fade quickly
  # instead of poisoning the cumulative average forever.
  local SMOOTHED_RATE=0

  while IFS= read -r URL; do
    [[ -z "${URL}" ]] && continue

    local BASENAME="${URL##*/}"; BASENAME="${BASENAME%.tif}"
    local TILE_TIF="${DEM_DIR}/${BASENAME}.tif"
    PROCESSED=$((PROCESSED + 1))

    if [[ -f "${TILE_TIF}" ]]; then
      printf "  [%d/%d] %s — cached\n" "${PROCESSED}" "${TOTAL_TILES}" "${BASENAME}"
      continue
    fi

    local PCT="0"
    if [[ "${BYTES_TOTAL_EST}" -gt 0 ]]; then
      PCT=$(( BYTES_DOWNLOADED * 100 / BYTES_TOTAL_EST ))
    fi
    local ETA_STR="--"
    if [[ ${SMOOTHED_RATE} -gt 0 ]]; then
      local REMAINING=$(( BYTES_TOTAL_EST - BYTES_DOWNLOADED ))
      (( REMAINING < 0 )) && REMAINING=0
      ETA_STR=$(human_duration $(( REMAINING / SMOOTHED_RATE )))
    fi
    printf "  [%d/%d - %d%%] %s — [%s / ~%s] ETA ~%s\n" \
      "${PROCESSED}" "${TOTAL_TILES}" "${PCT}" "${BASENAME}" \
      "$(human_bytes "${BYTES_DOWNLOADED}")" "$(human_bytes "${BYTES_TOTAL_EST}")" \
      "${ETA_STR}"
    # PID-suffixed partial so concurrent background runs covering the same
    # tile don't clobber each other's writes. Cross-run resume is sacrificed,
    # but resume within a single run still works (-C -). If another run wins
    # the race and the final file appears, drop our partial.
    local PARTIAL="${TILE_TIF}.$$.partial"
    local T0=${SECONDS}
    if ! curl -L --retry 5 --retry-all-errors --retry-delay 5 \
              --fail-with-body --max-time 1800 -C - -# \
              -o "${PARTIAL}" "${URL}"; then
      echo "  ERROR: download failed for ${URL}" >&2
      ERRORS=$((ERRORS + 1))
      rm -f "${PARTIAL}"
      continue
    fi
    local TILE_ELAPSED=$(( SECONDS - T0 ))
    (( TILE_ELAPSED < 1 )) && TILE_ELAPSED=1
    if [[ -f "${TILE_TIF}" ]]; then
      # Another concurrent run finished this tile while we were downloading.
      rm -f "${PARTIAL}"
    else
      mv -f "${PARTIAL}" "${TILE_TIF}"
    fi
    local TILE_SIZE
    TILE_SIZE=$(stat -c %s "${TILE_TIF}")
    BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + TILE_SIZE))
    # EWMA update (alpha=0.3): seed on first sample, then blend.
    local TILE_RATE=$(( TILE_SIZE / TILE_ELAPSED ))
    if [[ ${SMOOTHED_RATE} -eq 0 ]]; then
      SMOOTHED_RATE=${TILE_RATE}
    else
      SMOOTHED_RATE=$(( (TILE_RATE * 3 + SMOOTHED_RATE * 7) / 10 ))
    fi
  done < "${FILTERED_LIST}"

  echo "=========================================="
  echo "STEP 4 complete — ${PROCESSED} tiles, ${ERRORS} errors"
  echo "=========================================="
}

# ─── Derivation: shading algorithms ──────────────────────────────────────────
# Each takes a DEM raster (native or WGS84) and writes a single-band byte
# GeoTIFF ready to tile. Compute in the source projection — gdaldem handles
# units when given a degree-spaced grid via -s; for projected (meter) grids
# the default scale works.

derive_hillshade() {
  local in="$1" out="$2"
  local args=(hillshade "${in}" "${out}"
    -z "${HS_Z_FACTOR}"
    -alg "${HS_ALGORITHM}"
    -compute_edges
    -co COMPRESS=DEFLATE -co TILED=YES)
  if [[ ${HS_MULTIDIRECTIONAL} -eq 1 ]]; then
    args+=(-multidirectional)
  else
    args+=(-az "${HS_AZIMUTH}" -alt "${HS_ALTITUDE}" -combined)
  fi
  "${GDALDEM[@]}" "${args[@]}"
}

# Slopeshade: slope in degrees → grayscale via color-relief
# (steep = dark, flat = white). Two-step; uses a tmp slope raster.
derive_slopeshade() {
  local in="$1" out="$2"
  local slope_tif="${out%.tif}_slope.tif"
  local ramp="${out%.tif}_ramp.txt"
  "${GDALDEM[@]}" slope "${in}" "${slope_tif}" \
    -compute_edges -co COMPRESS=DEFLATE -co TILED=YES
  cat > "${ramp}" <<'RAMP'
0   255 255 255
90    0   0   0
RAMP
  "${GDALDEM[@]}" color-relief "${slope_tif}" "${ramp}" "${out}" \
    -co COMPRESS=DEFLATE -co TILED=YES
  rm -f "${slope_tif}" "${ramp}"
}

derive_shading() {
  local shading="$1" in="$2" out="$3"
  case "${shading}" in
    hillshade)  derive_hillshade  "${in}" "${out}" ;;
    slopeshade) derive_slopeshade "${in}" "${out}" ;;
    *) echo "ERROR: unknown shading: ${shading}" >&2; return 1 ;;
  esac
}

# ─── Reproject helper ────────────────────────────────────────────────────────
reproject_to_wgs84() {
  local in="$1" out="$2"
  "${GDALWARP[@]}" -t_srs EPSG:4326 -r bilinear \
    -multi -wo NUM_THREADS=ALL_CPUS \
    -co COMPRESS=DEFLATE -co TILED=YES \
    "${in}" "${out}"
}
