#!/usr/bin/env bash
# Shared library for lidar hillshade pipeline scripts.
# Source this file; do not execute it directly.
#
# Required (must be set in environment before sourcing):
#   GIS_DIR               — root GIS data directory
#
# Required (caller must define as a function):
#   tile_href <BASENAME>  — echoes the <href> value for a tile's PNG
#                           KMZ: "tiles/${1}.png"
#                           KML: "file://${PNG_DIR}/${1}.png"

[[ -n "${_LIDAR_COMMON_LOADED:-}" ]] && return 0
_LIDAR_COMMON_LOADED=1

# ─── Validate required environment ───────────────────────────────────────────
: "${GIS_DIR:?GIS_DIR is not set — add 'export GIS_DIR=/mnt/data/gis' to ~/.bashrc}"

# ─── Directory layout ─────────────────────────────────────────────────────────
LIDAR_DIR="${GIS_DIR}/lidar"
TILES_BASE="${LIDAR_DIR}/tiles"
DEM_DIR="${TILES_BASE}/dem"
HILLSHADE_DIR="${TILES_BASE}/hillshade"
WGS84_DIR="${TILES_BASE}/wgs84"
PNG_DIR="${TILES_BASE}/png"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ─── GDAL via QGIS flatpak ───────────────────────────────────────────────────
GDAL_FLATPAK_APP="org.qgis.qgis"
GDALINFO=(flatpak run --command=gdalinfo      "${GDAL_FLATPAK_APP}")
GDALDEM=(flatpak  run --command=gdaldem       "${GDAL_FLATPAK_APP}")
GDALWARP=(flatpak run --command=gdalwarp      "${GDAL_FLATPAK_APP}")
GDALTRANSLATE=(flatpak run --command=gdal_translate "${GDAL_FLATPAK_APP}")

# ─── Hillshade parameters ────────────────────────────────────────────────────
AZIMUTH=315
ALTITUDE=45
Z_FACTOR=1.5

# ─── Helpers ──────────────────────────────────────────────────────────────────
human_bytes() {
  local b=$1
  if   [[ $b -ge 1073741824 ]]; then printf "%.2f GB" "$(echo "scale=2; $b/1073741824" | bc)"
  elif [[ $b -ge 1048576    ]]; then printf "%.1f MB" "$(echo "scale=1; $b/1048576"    | bc)"
  elif [[ $b -ge 1024       ]]; then printf "%.1f KB" "$(echo "scale=1; $b/1024"       | bc)"
  else printf "%d B" "$b"
  fi
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

  command -v curl >/dev/null || { echo "ERROR: curl not found"; exit 1; }
  command -v bc   >/dev/null || { echo "ERROR: bc not found — sudo dnf install bc"; exit 1; }
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

# ─── Step 2: prescan ──────────────────────────────────────────────────────────
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
    local BASENAME
    BASENAME=$(basename "${URL}" .tif)
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
      SIZE=$(curl -sI "${URL}" \
             | grep -i '^content-length:' \
             | awk '{print $2}' | tr -d '\r' || echo 0)
      SIZE=${SIZE:-0}
      BYTES_TOTAL=$((BYTES_TOTAL + SIZE))
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
  mkdir -p "${DEM_DIR}" "${HILLSHADE_DIR}" "${WGS84_DIR}" "${PNG_DIR}" "$@"
}

# ─── Step 4: process_tiles ───────────────────────────────────────────────────
# Requires: FRAG_DIR (set by caller), tile_href() (defined by caller)
process_tiles() {
  echo "=========================================="
  echo "STEP 4: Processing ${TOTAL_TILES} tiles"
  echo "=========================================="

  local PROCESSED=0
  local ERRORS=0
  local BYTES_DOWNLOADED="${BYTES_DONE}"

  while IFS= read -r URL; do
    [[ -z "${URL}" ]] && continue

    local BASENAME
    BASENAME=$(basename "${URL}" .tif)
    local TILE_TIF="${DEM_DIR}/${BASENAME}.tif"
    local HILL_TIF="${HILLSHADE_DIR}/${BASENAME}_hillshade.tif"
    local WGS84_TIF="${WGS84_DIR}/${BASENAME}_wgs84.tif"
    local PNG_FILE="${PNG_DIR}/${BASENAME}.png"

    echo "------------------------------------------"
    echo "Tile $((PROCESSED + 1))/${TOTAL_TILES}: ${BASENAME}"
    echo "------------------------------------------"

    # 4a: Download
    if [[ -f "${TILE_TIF}" ]]; then
      echo "  [SKIP] Already downloaded"
    else
      echo "  Downloading... [$(human_bytes "${BYTES_DOWNLOADED}") / $(human_bytes "${BYTES_TOTAL}") total]"
      set -x
      curl -f -L --retry 3 --retry-delay 5 -# -o "${TILE_TIF}" "${URL}"
      set +x
      local TILE_SIZE
      TILE_SIZE=$(stat -c %s "${TILE_TIF}")
      BYTES_DOWNLOADED=$((BYTES_DOWNLOADED + TILE_SIZE))
      echo "  Downloaded $(human_bytes "${TILE_SIZE}") — total so far: $(human_bytes "${BYTES_DOWNLOADED}") / $(human_bytes "${BYTES_TOTAL}")"
    fi

    # 4b: Hillshade — retry once on corrupt tile
    if [[ -f "${HILL_TIF}" ]]; then
      echo "  [SKIP] Hillshade exists"
    else
      echo "  Generating hillshade..."
      set -x
      if ! "${GDALDEM[@]}" hillshade "${TILE_TIF}" "${HILL_TIF}" \
          -az "${AZIMUTH}" -alt "${ALTITUDE}" -z "${Z_FACTOR}" \
          -alg ZevenbergenThorne -combined \
          -co COMPRESS=DEFLATE -co TILED=YES; then
        set +x
        echo "  WARNING: corrupt tile — re-downloading and retrying..."
        rm -f "${TILE_TIF}" "${HILL_TIF}"
        set -x
        curl -f -L --retry 3 --retry-delay 5 -# -o "${TILE_TIF}" "${URL}"
        if ! "${GDALDEM[@]}" hillshade "${TILE_TIF}" "${HILL_TIF}" \
            -az "${AZIMUTH}" -alt "${ALTITUDE}" -z "${Z_FACTOR}" \
            -alg ZevenbergenThorne -combined \
            -co COMPRESS=DEFLATE -co TILED=YES; then
          set +x
          echo "  ERROR: hillshade failed twice — skipping ${BASENAME}"
          rm -f "${HILL_TIF}"
          ERRORS=$((ERRORS + 1))
          PROCESSED=$((PROCESSED + 1))
          continue
        fi
        set +x
      else
        set +x
      fi
    fi

    # 4c: Reproject to WGS84
    if [[ -f "${WGS84_TIF}" ]]; then
      echo "  [SKIP] WGS84 exists"
    else
      echo "  Reprojecting to WGS84..."
      set -x
      "${GDALWARP[@]}" -t_srs EPSG:4326 -r bilinear -co COMPRESS=DEFLATE \
        "${HILL_TIF}" "${WGS84_TIF}"
      set +x
    fi

    # 4d: Convert to PNG
    if [[ -f "${PNG_FILE}" ]]; then
      echo "  [SKIP] PNG exists"
    else
      echo "  Converting to PNG..."
      set -x
      "${GDALTRANSLATE[@]}" -of PNG "${WGS84_TIF}" "${PNG_FILE}"
      set +x
    fi

    # 4e: Extract bbox (cached in .bbox sidecar to avoid repeated flatpak calls)
    local BBOX_FILE="${WGS84_DIR}/${BASENAME}.bbox"
    local WEST NORTH EAST SOUTH
    if [[ -f "${BBOX_FILE}" ]]; then
      read -r NORTH SOUTH EAST WEST < "${BBOX_FILE}"
    else
      local GINFO
      GINFO=$("${GDALINFO[@]}" "${WGS84_TIF}")
      local UL LR
      UL=$(echo "${GINFO}" | grep "Upper Left"  | grep -oP '\(\s*[-0-9.]+,\s*[-0-9.]+\)' || true)
      LR=$(echo "${GINFO}" | grep "Lower Right" | grep -oP '\(\s*[-0-9.]+,\s*[-0-9.]+\)' || true)
      WEST=$(echo  "${UL}" | grep -oP '[-0-9.]+' | head -1 || true)
      NORTH=$(echo "${UL}" | grep -oP '[-0-9.]+' | tail -1 || true)
      EAST=$(echo  "${LR}" | grep -oP '[-0-9.]+' | head -1 || true)
      SOUTH=$(echo "${LR}" | grep -oP '[-0-9.]+' | tail -1 || true)
      if [[ -n "${NORTH}" && -n "${SOUTH}" && -n "${EAST}" && -n "${WEST}" ]]; then
        echo "${NORTH} ${SOUTH} ${EAST} ${WEST}" > "${BBOX_FILE}"
      fi
    fi

    if [[ -z "${WEST}" || -z "${NORTH}" || -z "${EAST}" || -z "${SOUTH}" ]]; then
      echo "  WARNING: Could not parse bbox — skipping KML entry"
      ERRORS=$((ERRORS + 1))
      PROCESSED=$((PROCESSED + 1))
      continue
    fi

    echo "  BBox: N=${NORTH} S=${SOUTH} E=${EAST} W=${WEST}"

    local PROJECT
    PROJECT=$(echo "${URL}" | grep -oP '(?<=Projects/)[^/]+' || echo "Unknown")
    local FRAG_FILE="${FRAG_DIR}/${PROJECT}.xml"
    local HREF
    HREF=$(tile_href "${BASENAME}")

    cat >> "${FRAG_FILE}" <<OVERLAY
    <GroundOverlay>
      <name>${BASENAME}</name>
      <visibility>1</visibility>
      <Icon>
        <href>${HREF}</href>
      </Icon>
      <LatLonBox>
        <north>${NORTH}</north>
        <south>${SOUTH}</south>
        <east>${EAST}</east>
        <west>${WEST}</west>
      </LatLonBox>
    </GroundOverlay>
OVERLAY

    PROCESSED=$((PROCESSED + 1))
    echo "  Done"

  done < "${FILTERED_LIST}"

  echo "=========================================="
  echo "STEP 4 complete — ${PROCESSED} tiles processed, ${ERRORS} errors"
  echo "=========================================="
}

# ─── assemble_kml <output_path> ──────────────────────────────────────────────
# Requires: FRAG_DIR (set by caller)
# KML document name is derived from the project names found in FRAG_DIR.
assemble_kml() {
  local KML_OUT="$1"

  # Derive document name from the projects actually present in the fragments
  local PROJECTS=()
  shopt -s nullglob
  for f in "${FRAG_DIR}"/*.xml; do
    PROJECTS+=("$(basename "${f}" .xml)")
  done
  shopt -u nullglob
  local DOC_NAME
  DOC_NAME=$(IFS=', '; echo "${PROJECTS[*]:-LiDAR Hillshade}")

  cat > "${KML_OUT}" <<KMLHEADER
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>${DOC_NAME}</name>
KMLHEADER

  shopt -s nullglob
  for FRAG_FILE in "${FRAG_DIR}"/*.xml; do
    local PROJECT_NAME
    PROJECT_NAME=$(basename "${FRAG_FILE}" .xml)
    echo "  <Folder>" >> "${KML_OUT}"
    echo "    <name>${PROJECT_NAME}</name>" >> "${KML_OUT}"
    echo "    <visibility>1</visibility>" >> "${KML_OUT}"
    cat "${FRAG_FILE}" >> "${KML_OUT}"
    echo "  </Folder>" >> "${KML_OUT}"
  done
  shopt -u nullglob

  cat >> "${KML_OUT}" <<'KMLFOOTER'
</Document>
</kml>
KMLFOOTER
}
