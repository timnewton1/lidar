#!/usr/bin/env bash
# Shared library for the lidar shading pipeline.
# Source this file; do not execute it directly.
#
# Pipeline: download DEMs → per-project VRT of native DEMs → derive shading
# (hillshade/slopeshade) on the mosaic → reproject to WGS84 → gdal2tiles
# super-overlay. Per-project mosaics eliminate seam artifacts that arise from
# per-tile sun-angle calculations.
#
# Required (must be set before sourcing OR via --gis-dir in the caller):
#   GIS_DIR  — root GIS data directory (e.g. /mnt/data/gis)

[[ -n "${_LIDAR_COMMON_LOADED:-}" ]] && return 0
_LIDAR_COMMON_LOADED=1

if [[ -z "${GIS_DIR:-}" ]]; then
  echo "ERROR: GIS_DIR is not set." >&2
  echo "  Either: export GIS_DIR=/path/to/gis" >&2
  echo "  Or pass: --gis-dir /path/to/gis" >&2
  exit 1
fi

# ─── Directory layout ────────────────────────────────────────────────────────
# Only DEM_DIR is persistent — the download cache. All derived rasters
# (hillshade, slopeshade, reprojected) are per-run scratch under WORK_DIR
# (created by the caller, cleaned via trap). Flatpak GDAL sandbox cannot
# read /tmp, so WORK_DIR must live under LIDAR_DIR.
LIDAR_DIR="${GIS_DIR}/lidar"
DEM_DIR="${LIDAR_DIR}/tiles/dem"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ─── GDAL via QGIS flatpak ───────────────────────────────────────────────────
GDAL_FLATPAK_APP="org.qgis.qgis"
GDALDEM=(flatpak       run --command=gdaldem        "${GDAL_FLATPAK_APP}")
GDALWARP=(flatpak      run --command=gdalwarp       "${GDAL_FLATPAK_APP}")
GDALBUILDVRT=(flatpak  run --command=gdalbuildvrt   "${GDAL_FLATPAK_APP}")
GDAL2TILES=(flatpak    run --command=gdal2tiles.py  "${GDAL_FLATPAK_APP}")

# ─── Hillshade parameters ────────────────────────────────────────────────────
HS_AZIMUTH=315
HS_ALTITUDE=45
HS_Z_FACTOR=1.5

# ─── Known shadings ──────────────────────────────────────────────────────────
KNOWN_SHADINGS=(hillshade slopeshade)

is_known_shading() {
  local s="$1" k
  for k in "${KNOWN_SHADINGS[@]}"; do [[ "${k}" == "${s}" ]] && return 0; done
  return 1
}

# ─── Helpers ─────────────────────────────────────────────────────────────────
human_bytes() { numfmt --to=iec --suffix=B --format='%.1f' "$1"; }

# Extract USGS project name from URL: ".../Projects/<NAME>/..." → "<NAME>"
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

  while IFS= read -r URL; do
    [[ -z "${URL}" ]] && continue

    local BASENAME="${URL##*/}"; BASENAME="${BASENAME%.tif}"
    local TILE_TIF="${DEM_DIR}/${BASENAME}.tif"
    PROCESSED=$((PROCESSED + 1))

    if [[ -f "${TILE_TIF}" ]]; then
      printf "  [%d/%d] %s — cached\n" "${PROCESSED}" "${TOTAL_TILES}" "${BASENAME}"
      continue
    fi

    printf "  [%d/%d] %s — downloading [%s / %s]\n" \
      "${PROCESSED}" "${TOTAL_TILES}" "${BASENAME}" \
      "$(human_bytes "${BYTES_DOWNLOADED}")" "$(human_bytes "${BYTES_TOTAL}")"
    if ! curl -f -L --retry 3 --retry-delay 5 -# -o "${TILE_TIF}" "${URL}"; then
      echo "  ERROR: download failed for ${URL}" >&2
      ERRORS=$((ERRORS + 1))
      continue
    fi
    local TILE_SIZE
    TILE_SIZE=$(stat -c %s "${TILE_TIF}")
    BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + TILE_SIZE))
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
  "${GDALDEM[@]}" hillshade "${in}" "${out}" \
    -az "${HS_AZIMUTH}" -alt "${HS_ALTITUDE}" -z "${HS_Z_FACTOR}" \
    -alg ZevenbergenThorne -combined -compute_edges \
    -co COMPRESS=DEFLATE -co TILED=YES
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
    -co COMPRESS=DEFLATE -co TILED=YES \
    "${in}" "${out}"
}
