#!/usr/bin/env bash
# Usage: lidar_hillshade.sh [--kmz] <downloadlist.txt>
#
# Builds a KML super-overlay (tile pyramid) from a list of USGS 3DEP LiDAR
# DEM URLs. Pyramidal LoD with quadtree NetworkLinks — Google Earth's
# intended pattern for large datasets. No lag, no blank zoom-out, constant
# memory regardless of tile count.
#
# Default output: $GIS_DIR/lidar/kml/superoverlay_TIMESTAMP/  (open doc.kml)
# With --kmz:    also produces $GIS_DIR/lidar/kmz/lidar_hillshade_TIMESTAMP.kmz
#                — a portable single-file copy of the pyramid for sharing.
#
# Requires:
#   export GIS_DIR=/mnt/data/gis
#   flatpak app org.qgis.qgis
#   (zip, only if --kmz)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lidar_common.sh
source "${SCRIPT_DIR}/lidar_common.sh"

usage() {
  echo "Usage: $0 [--kmz] <downloadlist.txt>"
  echo "  --kmz   also package the pyramid into a portable .kmz file"
  exit 1
}

PACKAGE_KMZ=0
DOWNLOAD_LIST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kmz)   PACKAGE_KMZ=1; shift ;;
    -h|--help) usage ;;
    -*)      echo "Unknown flag: $1"; usage ;;
    *)
      [[ -n "${DOWNLOAD_LIST}" ]] && { echo "Too many arguments"; usage; }
      DOWNLOAD_LIST="$1"; shift ;;
  esac
done
[[ -z "${DOWNLOAD_LIST}" ]] && usage

KML_DIR="${LIDAR_DIR}/kml"
OUT_DIR="${KML_DIR}/superoverlay_${TIMESTAMP}"

# Work dir lives under $GIS_DIR so the GDAL flatpak sandbox can read it.
# /tmp is not exposed to flatpak by default.
WORK_DIR=$(mktemp -d "${LIDAR_DIR}/.work_XXXXXX")
trap 'rm -rf "${WORK_DIR}"' EXIT

extra_deps=()
[[ ${PACKAGE_KMZ} -eq 1 ]] && extra_deps+=(zip)

check_deps_and_input "${DOWNLOAD_LIST}" "${extra_deps[@]+"${extra_deps[@]}"}"
prescan
make_dirs "${KML_DIR}"
process_tiles

# ─── Step 5: Group WGS84 tiles by USGS project ───────────────────────────────
echo "=========================================="
echo "STEP 5: Grouping tiles by project"
echo "=========================================="

LISTS_DIR="${WORK_DIR}/project_lists"
mkdir -p "${LISTS_DIR}"

MISSING=0
while IFS= read -r URL; do
  [[ -z "${URL}" ]] && continue
  BASENAME=$(basename "${URL}" .tif)
  WGS84_TIF="${WGS84_DIR}/${BASENAME}_wgs84.tif"
  if [[ ! -f "${WGS84_TIF}" ]]; then
    MISSING=$((MISSING + 1))
    continue
  fi
  # Project name lives between "Projects/" and the next slash in the URL
  PROJECT=$(echo "${URL}" | grep -oP '(?<=Projects/)[^/]+' || echo "Unknown")
  echo "${WGS84_TIF}" >> "${LISTS_DIR}/${PROJECT}.list"
done < "${FILTERED_LIST}"

shopt -s nullglob
PROJECT_LISTS=("${LISTS_DIR}"/*.list)
shopt -u nullglob

if [[ ${#PROJECT_LISTS[@]} -eq 0 ]]; then
  echo "ERROR: no WGS84 tiles available to mosaic (${MISSING} missing)"
  exit 1
fi

echo "  Projects found: ${#PROJECT_LISTS[@]}  (${MISSING} tiles missing)"
for LIST in "${PROJECT_LISTS[@]}"; do
  PROJECT=$(basename "${LIST}" .list)
  COUNT=$(wc -l < "${LIST}")
  printf "    %-60s %5d tiles\n" "${PROJECT}" "${COUNT}"
done

# ─── Step 6: Per-project VRT + gdal2tiles super-overlay ──────────────────────
echo "=========================================="
echo "STEP 6: Generating per-project tile pyramids"
echo "=========================================="

mkdir -p "${OUT_DIR}"
PROCESSES=$(nproc 2>/dev/null || echo 4)

PROJECT_NAMES=()
for LIST in "${PROJECT_LISTS[@]}"; do
  PROJECT=$(basename "${LIST}" .list)
  PROJECT_NAMES+=("${PROJECT}")
  COUNT=$(wc -l < "${LIST}")

  echo "------------------------------------------"
  echo "Project: ${PROJECT}  (${COUNT} tiles)"
  echo "------------------------------------------"

  VRT="${WORK_DIR}/${PROJECT}.vrt"
  PROJ_OUT="${OUT_DIR}/${PROJECT}"
  mkdir -p "${PROJ_OUT}"

  set -x
  "${GDALBUILDVRT[@]}" -input_file_list "${LIST}" "${VRT}"
  # -t TITLE sets the sub-doc.kml's <name> so GE's sidebar shows the project
  # name instead of "mosaic.vrt".
  "${GDAL2TILES[@]}" \
    -p geodetic \
    -k \
    -r average \
    -t "${PROJECT}" \
    --processes="${PROCESSES}" \
    "${VRT}" \
    "${PROJ_OUT}"
  set +x
done

# ─── Step 7: Write root doc.kml with NetworkLinks to each project ────────────
echo "=========================================="
echo "STEP 7: Writing root KML"
echo "=========================================="

ROOT_KML="${OUT_DIR}/doc.kml"
if [[ ${#PROJECT_NAMES[@]} -eq 1 ]]; then
  DOC_NAME="${PROJECT_NAMES[0]}"
else
  DOC_NAME="LiDAR Hillshade — ${#PROJECT_NAMES[@]} projects"
fi

{
  cat <<HEAD
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>${DOC_NAME}</name>
  <open>1</open>
HEAD
  for PROJECT in "${PROJECT_NAMES[@]}"; do
    cat <<NL
  <NetworkLink>
    <name>${PROJECT}</name>
    <visibility>1</visibility>
    <Link><href>${PROJECT}/doc.kml</href></Link>
  </NetworkLink>
NL
  done
  cat <<'TAIL'
</Document>
</kml>
TAIL
} > "${ROOT_KML}"

# ─── Step 8: Optional KMZ packaging ──────────────────────────────────────────
KMZ_OUT=""
if [[ ${PACKAGE_KMZ} -eq 1 ]]; then
  echo "=========================================="
  echo "STEP 8: Packaging KMZ"
  echo "=========================================="
  KMZ_DIR="${LIDAR_DIR}/kmz"
  mkdir -p "${KMZ_DIR}"
  KMZ_OUT="${KMZ_DIR}/lidar_hillshade_${TIMESTAMP}.kmz"
  # KMZ = zip with doc.kml at root. Exclude GDAL aux sidecars.
  ( cd "${OUT_DIR}" && zip -rq "${KMZ_OUT}" . -x '*.aux.xml' )
  echo "  KMZ: ${KMZ_OUT} ($(human_bytes "$(stat -c %s "${KMZ_OUT}")"))"
fi

echo "=========================================="
echo "ALL DONE"
echo ""
echo "Root KML : ${ROOT_KML}"
echo "Pyramid  : ${OUT_DIR}/  ($(du -sh "${OUT_DIR}" | cut -f1))"
[[ -n "${KMZ_OUT}" ]] && echo "Portable : ${KMZ_OUT}"
echo ""
echo "Open in Google Earth Pro via File → Open"
echo "  Pyramidal LoD — smooth zoom from extent to native resolution"
echo "=========================================="
