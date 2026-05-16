#!/usr/bin/env bash
# Usage: lidar_hillshade_kmz.sh <downloadlist.txt>
#
# Packages a self-contained KMZ using NetworkLink + Region/LoD tiling.
# Tiles load on demand as you navigate.
#
# Requires GIS_DIR env var (set in ~/.bashrc):
#   export GIS_DIR="/mnt/data/gis"

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lidar_common.sh
source "${SCRIPT_DIR}/lidar_common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <downloadlist.txt>"
  echo "  e.g: $0 ~/Downloads/downloadlist\(1\).txt"
  exit 1
fi

KMZ_DIR="${LIDAR_DIR}/kmz"
KMZ_OUT="${KMZ_DIR}/lidar_hillshade_${TIMESTAMP}.kmz"

STAGE_DIR=$(mktemp -d /tmp/kmz_stage_XXXXXX)
FRAG_DIR="${STAGE_DIR}/fragments"
TILE_KMLS_DIR="${STAGE_DIR}/tiles"
trap 'rm -rf "${STAGE_DIR}"' EXIT
mkdir -p "${FRAG_DIR}" "${TILE_KMLS_DIR}"

# PNG href is relative: per-tile KMLs and PNGs both live in tiles/ inside the KMZ
tile_png_href() { echo "${1}.png"; }

check_deps_and_input "$1" zip
prescan
make_dirs "${KMZ_DIR}"
process_tiles

# ─── Step 5: Build KMZ ────────────────────────────────────────────────────────
echo "=========================================="
echo "STEP 5: Building KMZ"
echo "=========================================="

assemble_kml "${STAGE_DIR}/doc.kml"

# Stage PNGs alongside their tile KMLs
while IFS= read -r URL; do
  [[ -z "${URL}" ]] && continue
  BASENAME=$(basename "${URL}" .tif)
  PNG_FILE="${PNG_DIR}/${BASENAME}.png"
  [[ -f "${PNG_FILE}" ]] && cp "${PNG_FILE}" "${TILE_KMLS_DIR}/"
done < "${FILTERED_LIST}"

STAGED_PNGS=()
shopt -s nullglob
STAGED_PNGS+=("${TILE_KMLS_DIR}/"*.png)
shopt -u nullglob

if [[ ${#STAGED_PNGS[@]} -eq 0 ]]; then
  echo "ERROR: No PNG tiles to package"
  exit 1
fi

echo "Packaging ${#STAGED_PNGS[@]} tiles into KMZ..."
(cd "${STAGE_DIR}" && zip -r "${KMZ_OUT}" doc.kml tiles/)

echo "=========================================="
echo "ALL DONE"
echo ""
echo "KMZ : ${KMZ_OUT}"
echo "Size: $(human_bytes "$(stat -c %s "${KMZ_OUT}")")"
echo ""
echo "Open in Google Earth Pro via File → Open"
echo "  Tiles load on demand as you navigate (NetworkLink + Region/LoD)"
echo "  Folder checkbox = toggle all tiles at once"
echo "=========================================="
