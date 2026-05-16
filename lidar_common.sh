#!/usr/bin/env bash
# Shared library for the lidar hillshade pipeline.
# Source this file; do not execute it directly.
#
# Pipeline produces WGS84 hillshade GeoTIFFs ready to be fed into a
# super-overlay generator (gdal2tiles / gdal_translate KMLSUPEROVERLAY).
# All KML/KMZ packaging is the caller's responsibility.
#
# Required (must be set in environment before sourcing):
#   GIS_DIR  — root GIS data directory (e.g. /mnt/data/gis)

[[ -n "${_LIDAR_COMMON_LOADED:-}" ]] && return 0
_LIDAR_COMMON_LOADED=1

: "${GIS_DIR:?GIS_DIR is not set — add 'export GIS_DIR=/mnt/data/gis' to ~/.bashrc}"

# ─── Directory layout ────────────────────────────────────────────────────────
LIDAR_DIR="${GIS_DIR}/lidar"
TILES_BASE="${LIDAR_DIR}/tiles"
DEM_DIR="${TILES_BASE}/dem"
HILLSHADE_DIR="${TILES_BASE}/hillshade"
WGS84_DIR="${TILES_BASE}/wgs84"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ─── GDAL via QGIS flatpak ───────────────────────────────────────────────────
GDAL_FLATPAK_APP="org.qgis.qgis"
GDALDEM=(flatpak       run --command=gdaldem        "${GDAL_FLATPAK_APP}")
GDALWARP=(flatpak      run --command=gdalwarp       "${GDAL_FLATPAK_APP}")
GDALBUILDVRT=(flatpak  run --command=gdalbuildvrt   "${GDAL_FLATPAK_APP}")
GDAL2TILES=(flatpak    run --command=gdal2tiles.py  "${GDAL_FLATPAK_APP}")

# ─── Hillshade parameters ────────────────────────────────────────────────────
AZIMUTH=315
ALTITUDE=45
Z_FACTOR=1.5

# ─── Helpers ─────────────────────────────────────────────────────────────────
human_bytes() { numfmt --to=iec --suffix=B --format='%.1f' "$1"; }

# Extract USGS project name from URL: ".../Projects/<NAME>/..." → "<NAME>"
# Echoes empty string if URL doesn't match.
project_from_url() {
  local rest="${1#*/Projects/}"
  [[ "${rest}" == "$1" ]] && { echo ""; return; }
  echo "${rest%%/*}"
}

# ─── Step 1: check_deps_and_input <download_list> [extra_cmd...] ─────────────
# Sets: DOWNLOAD_LIST FILTERED_LIST TOTAL_TILES
check_deps_and_input() {
  local download_list="$1"; shift
  local extra_deps=("$@")

  echo "=========================================="
  echo "STEP 1: Checking dependencies"
  echo "=========================================="

  if [[ ! -f "${download_list}" ]]; then
    echo "ERROR: File not found: ${download_list}"
    exit 1
  fi

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

  DOWNLOAD_LIST="${download_list}"
  FILTERED_LIST="${LIDAR_DIR}/filtered_tiles.txt"
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
# Sets: BYTES_DONE BYTES_TOTAL TILES_CACHED TILES_PENDING PENDING_URLS
prescan() {
  echo "=========================================="
  echo "STEP 2: Pre-scanning tile sizes"
  echo "=========================================="

  BYTES_TOTAL=0
  BYTES_DONE=0
  TILES_CACHED=0
  TILES_PENDING=0
  PENDING_URLS=()

  while IFS= read -r URL; do
    [[ -z "${URL}" ]] && continue
    local BASENAME="${URL##*/}"; BASENAME="${BASENAME%.tif}"
    local TILE_TIF="${DEM_DIR}/${BASENAME}.tif"
    if [[ -f "${TILE_TIF}" ]]; then
      local SIZE
      SIZE=$(stat -c %s "${TILE_TIF}")
      BYTES_DONE=$((BYTES_DONE + SIZE))
      TILES_CACHED=$((TILES_CACHED + 1))
    else
      PENDING_URLS+=("${URL}")
      TILES_PENDING=$((TILES_PENDING + 1))
    fi
  done < "${FILTERED_LIST}"

  if [[ ${TILES_PENDING} -eq 0 ]]; then
    echo "  All ${TILES_CACHED} tiles cached — skipping HEAD scan"
    BYTES_TOTAL="${BYTES_DONE}"
  else
    echo "  Cached: ${TILES_CACHED}  Pending: ${TILES_PENDING} — fetching sizes..."
    BYTES_TOTAL="${BYTES_DONE}"
    local SCAN_N=0
    for URL in "${PENDING_URLS[@]}"; do
      SCAN_N=$((SCAN_N + 1))
      printf "\r  HEAD %d/%d..." "${SCAN_N}" "${TILES_PENDING}"
      local SIZE
      SIZE=$(curl -sI "${URL}" | awk 'tolower($1)=="content-length:" {gsub(/\r/,""); print $2}' || true)
      BYTES_TOTAL=$((BYTES_TOTAL + ${SIZE:-0}))
    done
    echo ""
  fi

  echo "  Already cached : ${TILES_CACHED} tiles  ($(human_bytes "${BYTES_DONE}"))"
  echo "  To download    : ${TILES_PENDING} tiles"
  echo "  Total size     : $(human_bytes "${BYTES_TOTAL}")"
}

# ─── Step 3: make_dirs [extra_dir...] ────────────────────────────────────────
make_dirs() {
  echo "=========================================="
  echo "STEP 3: Creating output directories"
  echo "=========================================="
  mkdir -p "${DEM_DIR}" "${HILLSHADE_DIR}" "${WGS84_DIR}" "$@"
}

# ─── Step 4: process_tiles ───────────────────────────────────────────────────
# For each URL in FILTERED_LIST: download DEM → generate hillshade → reproject
# to WGS84. Each step is cached on disk and skipped if already done.
process_tiles() {
  echo "=========================================="
  echo "STEP 4: Processing ${TOTAL_TILES} tiles"
  echo "=========================================="

  local PROCESSED=0
  local ERRORS=0
  local BYTES_DOWNLOADED="${BYTES_DONE}"

  local fetch_dem hillshade_dem
  fetch_dem() {
    curl -f -L --retry 3 --retry-delay 5 -# -o "$1" "$2"
  }
  hillshade_dem() {
    "${GDALDEM[@]}" hillshade "$1" "$2" \
      -az "${AZIMUTH}" -alt "${ALTITUDE}" -z "${Z_FACTOR}" \
      -alg ZevenbergenThorne -combined \
      -co COMPRESS=DEFLATE -co TILED=YES
  }

  while IFS= read -r URL; do
    [[ -z "${URL}" ]] && continue

    local BASENAME="${URL##*/}"; BASENAME="${BASENAME%.tif}"
    local TILE_TIF="${DEM_DIR}/${BASENAME}.tif"
    local HILL_TIF="${HILLSHADE_DIR}/${BASENAME}_hillshade.tif"
    local WGS84_TIF="${WGS84_DIR}/${BASENAME}_wgs84.tif"

    echo "------------------------------------------"
    echo "Tile $((PROCESSED + 1))/${TOTAL_TILES}: ${BASENAME}"
    echo "------------------------------------------"

    # 4a: Download
    if [[ -f "${TILE_TIF}" ]]; then
      echo "  [SKIP] Already downloaded"
    else
      echo "  Downloading... [$(human_bytes "${BYTES_DOWNLOADED}") / $(human_bytes "${BYTES_TOTAL}") total]"
      fetch_dem "${TILE_TIF}" "${URL}"
      local TILE_SIZE
      TILE_SIZE=$(stat -c %s "${TILE_TIF}")
      BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + TILE_SIZE))
      echo "  Downloaded $(human_bytes "${TILE_SIZE}") — total so far: $(human_bytes "${BYTES_DOWNLOADED}") / $(human_bytes "${BYTES_TOTAL}")"
    fi

    # 4b: Hillshade — retry once on corrupt tile by re-downloading
    if [[ ! -f "${HILL_TIF}" ]]; then
      local attempt success=0
      for attempt in 1 2; do
        echo "  Generating hillshade (attempt ${attempt}/2)..."
        if hillshade_dem "${TILE_TIF}" "${HILL_TIF}"; then
          success=1
          break
        fi
        echo "  WARNING: hillshade failed — re-downloading tile and retrying..."
        rm -f "${TILE_TIF}" "${HILL_TIF}"
        fetch_dem "${TILE_TIF}" "${URL}"
      done
      if [[ ${success} -eq 0 ]]; then
        echo "  ERROR: hillshade failed twice — skipping ${BASENAME}"
        rm -f "${HILL_TIF}"
        ERRORS=$((ERRORS + 1))
        PROCESSED=$((PROCESSED + 1))
        continue
      fi
    else
      echo "  [SKIP] Hillshade exists"
    fi

    # 4c: Reproject to WGS84
    if [[ -f "${WGS84_TIF}" ]]; then
      echo "  [SKIP] WGS84 exists"
    else
      echo "  Reprojecting to WGS84..."
      "${GDALWARP[@]}" -t_srs EPSG:4326 -r bilinear -co COMPRESS=DEFLATE \
        "${HILL_TIF}" "${WGS84_TIF}"
    fi

    PROCESSED=$((PROCESSED + 1))
    echo "  Done"

  done < "${FILTERED_LIST}"

  echo "=========================================="
  echo "STEP 4 complete — ${PROCESSED} tiles processed, ${ERRORS} errors"
  echo "=========================================="
}

