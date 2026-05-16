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

# ─── Step 5: Build VRT mosaic of WGS84 hillshades ────────────────────────────
echo "=========================================="
echo "STEP 5: Building VRT mosaic"
echo "=========================================="

WGS84_LIST="${WORK_DIR}/wgs84_list.txt"
TILES_IN_MOSAIC=$(build_wgs84_list "${WGS84_LIST}")
echo "  Mosaic inputs: ${TILES_IN_MOSAIC} tiles"
if [[ "${TILES_IN_MOSAIC}" -eq 0 ]]; then
  echo "ERROR: no WGS84 tiles available to mosaic"
  exit 1
fi

MOSAIC_VRT="${WORK_DIR}/mosaic.vrt"
set -x
"${GDALBUILDVRT[@]}" -input_file_list "${WGS84_LIST}" "${MOSAIC_VRT}"
set +x

# ─── Step 6: gdal2tiles super-overlay ────────────────────────────────────────
echo "=========================================="
echo "STEP 6: Generating tile pyramid (gdal2tiles)"
echo "=========================================="

mkdir -p "${OUT_DIR}"
PROCESSES=$(nproc 2>/dev/null || echo 4)

# -p geodetic   : lat/lon tiling, native to Google Earth
# -k            : emit KML super-overlay files alongside imagery tiles
# -r average    : averaging resampler — correct for continuous data (hillshade)
# --processes=N : parallel tile generation
set -x
"${GDAL2TILES[@]}" \
  -p geodetic \
  -k \
  -r average \
  --processes="${PROCESSES}" \
  "${MOSAIC_VRT}" \
  "${OUT_DIR}"
set +x

ROOT_KML="${OUT_DIR}/doc.kml"

# ─── Step 7: Optional KMZ packaging ──────────────────────────────────────────
KMZ_OUT=""
if [[ ${PACKAGE_KMZ} -eq 1 ]]; then
  echo "=========================================="
  echo "STEP 7: Packaging KMZ"
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
