#!/usr/bin/env bash
# Usage: lidar_hillshade_kml.sh <downloadlist.txt>
#
# Produces a referential KML — PNGs are referenced by absolute path,
# nothing is packaged. Much faster than KMZ for local use.
#
# Requires GIS_DIR env var (set in ~/.bashrc):
#   export GIS_DIR="/mnt/data/gis"
#
# Output layout under $GIS_DIR/lidar/:
#   tiles/
#     dem/          raw downloaded DEM tiles  (shared cache)
#     hillshade/    hillshade TIFs            (shared cache)
#     wgs84/        reprojected TIFs           (shared cache)
#     png/          PNG tiles                  (shared cache)
#   kml/            timestamped KML outputs

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
: "${GIS_DIR:?GIS_DIR is not set — add 'export GIS_DIR=/mnt/data/gis' to ~/.bashrc}"

LIDAR_DIR="${GIS_DIR}/lidar"
TILES_BASE="${LIDAR_DIR}/tiles"
DEM_DIR="${TILES_BASE}/dem"
HILLSHADE_DIR="${TILES_BASE}/hillshade"
WGS84_DIR="${TILES_BASE}/wgs84"
PNG_DIR="${TILES_BASE}/png"
KML_DIR="${LIDAR_DIR}/kml"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
KML_OUT="${KML_DIR}/lidar_hillshade_${TIMESTAMP}.kml"
FRAG_DIR=$(mktemp -d /tmp/kml_frags_XXXXXX)
trap 'rm -rf "${FRAG_DIR}"' EXIT

AZIMUTH=315
ALTITUDE=45
Z_FACTOR=1.5

GDALINFO=(flatpak run --command=gdalinfo org.qgis.qgis)
GDALDEM=(flatpak run --command=gdaldem org.qgis.qgis)
GDALWARP=(flatpak run --command=gdalwarp org.qgis.qgis)
GDALTRANSLATE=(flatpak run --command=gdal_translate org.qgis.qgis)

# ─── Helper ───────────────────────────────────────────────────────────────────
human_bytes() {
  local b=$1
  if   [[ $b -ge 1073741824 ]]; then printf "%.2f GB" "$(echo "scale=2; $b/1073741824" | bc)"
  elif [[ $b -ge 1048576    ]]; then printf "%.1f MB" "$(echo "scale=1; $b/1048576"    | bc)"
  elif [[ $b -ge 1024       ]]; then printf "%.1f KB" "$(echo "scale=1; $b/1024"       | bc)"
  else printf "%d B" "$b"
  fi
}

# ─── Step 1: Verify dependencies and input ────────────────────────────────────
echo "=========================================="
echo "STEP 1: Checking dependencies"
echo "=========================================="

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <downloadlist.txt>"
  echo "  e.g: $0 ~/Downloads/downloadlist\(1\).txt"
  exit 1
fi

DOWNLOAD_LIST="$1"

if [[ ! -f "${DOWNLOAD_LIST}" ]]; then
  echo "ERROR: File not found: ${DOWNLOAD_LIST}"
  exit 1
fi

command -v curl >/dev/null || { echo "ERROR: curl not found"; exit 1; }
command -v bc   >/dev/null || { echo "ERROR: bc not found — sudo dnf install bc"; exit 1; }
flatpak list | grep -q "org.qgis.qgis" || { echo "ERROR: QGIS flatpak not installed"; exit 1; }

if [[ ! -d "${LIDAR_DIR}" ]]; then
  echo "ERROR: Lidar dir not found: ${LIDAR_DIR}"
  echo "  Is ${GIS_DIR} mounted?"
  exit 1
fi

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

# ─── Step 2: Pre-scan sizes ───────────────────────────────────────────────────
echo "=========================================="
echo "STEP 2: Pre-scanning tile sizes"
echo "=========================================="

BYTES_TOTAL=0
BYTES_DONE=0
TILES_CACHED=0
TILES_PENDING=0

# Quick pass: stat cached tiles, collect pending URLs
PENDING_URLS=()
while IFS= read -r URL; do
  [[ -z "${URL}" ]] && continue
  BASENAME=$(basename "${URL}" .tif)
  TILE_TIF="${DEM_DIR}/${BASENAME}.tif"
  if [[ -f "${TILE_TIF}" ]]; then
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
  SCAN_N=0
  for URL in "${PENDING_URLS[@]}"; do
    SCAN_N=$((SCAN_N + 1))
    printf "\r  HEAD %d/%d..." "${SCAN_N}" "${TILES_PENDING}"
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

# ─── Step 3: Create output directories ────────────────────────────────────────
echo "=========================================="
echo "STEP 3: Creating output directories"
echo "=========================================="

mkdir -p "${DEM_DIR}" "${HILLSHADE_DIR}" "${WGS84_DIR}" "${PNG_DIR}" "${KML_DIR}"

# ─── Step 4: Process each tile ────────────────────────────────────────────────
echo "=========================================="
echo "STEP 4: Processing ${TOTAL_TILES} tiles"
echo "=========================================="

PROCESSED=0
ERRORS=0
BYTES_DOWNLOADED="${BYTES_DONE}"

while IFS= read -r URL; do
  [[ -z "${URL}" ]] && continue

  BASENAME=$(basename "${URL}" .tif)
  TILE_TIF="${DEM_DIR}/${BASENAME}.tif"
  HILL_TIF="${HILLSHADE_DIR}/${BASENAME}_hillshade.tif"
  WGS84_TIF="${WGS84_DIR}/${BASENAME}_wgs84.tif"
  PNG_FILE="${PNG_DIR}/${BASENAME}.png"

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

  # 4e: Extract bbox and write GroundOverlay fragment
  GINFO=$("${GDALINFO[@]}" "${WGS84_TIF}")
  UL=$(echo "${GINFO}" | grep "Upper Left"  | grep -oP '\(\s*[-0-9.]+,\s*[-0-9.]+\)' || true)
  LR=$(echo "${GINFO}" | grep "Lower Right" | grep -oP '\(\s*[-0-9.]+,\s*[-0-9.]+\)' || true)
  WEST=$(echo  "${UL}" | grep -oP '[-0-9.]+' | head -1 || true)
  NORTH=$(echo "${UL}" | grep -oP '[-0-9.]+' | tail -1 || true)
  EAST=$(echo  "${LR}" | grep -oP '[-0-9.]+' | head -1 || true)
  SOUTH=$(echo "${LR}" | grep -oP '[-0-9.]+' | tail -1 || true)

  if [[ -z "${WEST}" || -z "${NORTH}" || -z "${EAST}" || -z "${SOUTH}" ]]; then
    echo "  WARNING: Could not parse bbox — skipping KML entry"
    ERRORS=$((ERRORS + 1))
    PROCESSED=$((PROCESSED + 1))
    continue
  fi

  echo "  BBox: N=${NORTH} S=${SOUTH} E=${EAST} W=${WEST}"

  PROJECT=$(echo "${URL}" | grep -oP '(?<=Projects/)[^/]+' || echo "Unknown")
  FRAG_FILE="${FRAG_DIR}/${PROJECT}.xml"

  cat >> "${FRAG_FILE}" <<OVERLAY
    <GroundOverlay>
      <name>${BASENAME}</name>
      <visibility>1</visibility>
      <Icon>
        <href>file://${PNG_FILE}</href>
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

# ─── Step 5: Write KML ────────────────────────────────────────────────────────
echo "=========================================="
echo "STEP 5: Writing KML"
echo "=========================================="

cat > "${KML_OUT}" <<'KMLHEADER'
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>USGS LiDAR Hillshade</name>
  <description>USGS QL1 LiDAR hillshade — 0.5m resolution</description>
KMLHEADER

shopt -s nullglob
for FRAG_FILE in "${FRAG_DIR}"/*.xml; do
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

echo "=========================================="
echo "ALL DONE"
echo ""
echo "KML : ${KML_OUT}"
echo "Size: $(human_bytes "$(stat -c %s "${KML_OUT}")")"
echo ""
echo "Open in Google Earth Pro via File → Open"
echo "  PNGs are referenced in-place from ${PNG_DIR}"
echo "  Folder checkbox = toggle all tiles at once"
echo "  Expand folder   = toggle individual tiles"
echo "=========================================="
