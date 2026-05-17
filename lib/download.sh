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
# Downloads FILTERED_LIST into DEM_DIR using xargs -P for parallelism.
# Set LIDAR_DOWNLOAD_JOBS (default 4) to control concurrency.
#
# Per-tile status lines are written via `flock /dev/stderr` so they don't
# interleave. Per-tile percentage/EWMA ETA is not shown (meaningless when
# many tiles run concurrently); use `lidar list` to track overall progress.

# Per-URL worker called by xargs. Exported so the subshells inherit it.
_lidar_download_one() {
  local url="$1"
  [[ -z "${url}" ]] && return 0
  local basename="${url##*/}"; basename="${basename%.tif}"
  local tile_tif="${DEM_DIR}/${basename}.tif"
  if [[ -f "${tile_tif}" ]]; then
    flock /dev/stderr -c "printf '  cached  %s\n' '${basename}'" 2>&1
    return 0
  fi
  # PID-suffixed partial so concurrent invocations don't clobber each other.
  # If another process finishes the tile first, drop our partial.
  local partial="${tile_tif}.$$.partial"
  if ! curl -L --retry 5 --retry-all-errors --retry-delay 5 \
            --fail-with-body --max-time 1800 -C - -sS \
            -o "${partial}" "${url}"; then
    flock /dev/stderr -c "printf '  ERROR   %s\n' '${basename}'" 2>&1
    rm -f "${partial}"
    return 1
  fi
  if [[ -f "${tile_tif}" ]]; then
    rm -f "${partial}"
  else
    mv -f "${partial}" "${tile_tif}"
  fi
  local sz
  sz=$(stat -c %s "${tile_tif}" 2>/dev/null || echo 0)
  flock /dev/stderr -c "printf '  done    %s  (%s)\n' '${basename}' '$(numfmt --to=iec --suffix=B --format=%.1f "${sz}")'" 2>&1
}
export -f _lidar_download_one

download_tiles() {
  local jobs="${LIDAR_DOWNLOAD_JOBS:-4}"
  echo "=========================================="
  echo "STEP 4: Downloading ${TOTAL_TILES} tiles  (parallel: ${jobs})"
  echo "=========================================="

  export DEM_DIR

  local rc=0
  grep -v '^[[:space:]]*$' "${FILTERED_LIST}" \
    | xargs -P "${jobs}" -n 1 bash -c '_lidar_download_one "$@"' _ \
    || rc=$?

  echo "=========================================="
  if [[ ${rc} -ne 0 ]]; then
    echo "STEP 4 complete — WARNING: some downloads failed (see above)"
  else
    echo "STEP 4 complete"
  fi
  echo "=========================================="
  return ${rc}
}
