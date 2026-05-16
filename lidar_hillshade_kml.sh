#!/usr/bin/env bash
# Usage: lidar_hillshade_kml.sh <downloadlist.txt>
#
# Produces a referential KML — PNGs are referenced by absolute file:// path,
# nothing is packaged. Much faster than KMZ for local use.
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

KML_DIR="${LIDAR_DIR}/kml"
KML_OUT="${KML_DIR}/lidar_hillshade_${TIMESTAMP}.kml"

FRAG_DIR=$(mktemp -d /tmp/kml_frags_XXXXXX)
trap 'rm -rf "${FRAG_DIR}"' EXIT

tile_href() { echo "file://${PNG_DIR}/${1}.png"; }

check_deps_and_input "$1"
prescan
make_dirs "${KML_DIR}"
process_tiles

# ─── Step 5: Write KML ────────────────────────────────────────────────────────
echo "=========================================="
echo "STEP 5: Writing KML"
echo "=========================================="

assemble_kml "${KML_OUT}"

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
