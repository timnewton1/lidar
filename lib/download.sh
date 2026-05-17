#!/usr/bin/env bash
# Tile download pipeline: dep-checking, prescan, make_dirs, download.
# Requires lib/common.sh (LIDAR_DIR, DEM_DIR, GDAL_FLATPAK_APP, human_bytes,
# human_duration, project_from_url) and WORK_DIR set by the caller.

[[ -n "${_LIDAR_DOWNLOAD_LOADED:-}" ]] && return 0
_LIDAR_DOWNLOAD_LOADED=1

PRESCAN_SAMPLE=5

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
