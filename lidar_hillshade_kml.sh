#!/usr/bin/env bash
# Usage: lidar_hillshade_kml.sh <downloadlist.txt>
#
# Produces a referential KML using NetworkLink + Region/LoD tiling.
# Tiles load on demand as you navigate; PNGs are referenced by absolute path.
#
# Requires GIS_DIR env var (set in ~/.bashrc):
#   export GIS_DIR="/mnt/data/gis"
#
# Output layout under $GIS_DIR/lidar/kml/:
#   lidar_hillshade_TIMESTAMP.kml   — root KML (open this in Google Earth)
#   tiles/BASENAME.kml              — per-tile KMLs (persistent, referenced by root)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lidar_common.sh
source "${SCRIPT_DIR}/lidar_common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <downloadlist.txt>"
  echo "  e.g: $0 ~/Downloads/downloadlist\(1\).txt"
  exit 1
fi

KML_DIR="${LIDAR_DIR}/kml"
KML_OUT="${KML_DIR}/lidar_hillshade_${TIMESTAMP}.kml"
TILE_KMLS_DIR="${KML_DIR}/tiles"

FRAG_DIR=$(mktemp -d /tmp/kml_frags_XXXXXX)
trap 'rm -rf "${FRAG_DIR}"' EXIT

tile_png_href() { echo "file://${PNG_DIR}/${1}.png"; }

check_deps_and_input "$1"
prescan
make_dirs "${KML_DIR}" "${TILE_KMLS_DIR}"
process_tiles

# ─── Step 5: Write root KML ───────────────────────────────────────────────────
echo "=========================================="
echo "STEP 5: Writing root KML"
echo "=========================================="

assemble_kml "${KML_OUT}"

echo "=========================================="
echo "ALL DONE"
echo ""
echo "KML  : ${KML_OUT}"
echo "Tiles: ${TILE_KMLS_DIR}/"
echo "Size : $(human_bytes "$(stat -c %s "${KML_OUT}")")"
echo ""
echo "Open in Google Earth Pro via File → Open"
echo "  Tiles load on demand as you navigate (NetworkLink + Region/LoD)"
echo "  Folder checkbox = toggle all tiles at once"
echo "=========================================="
