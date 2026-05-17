#!/usr/bin/env bash
# Usage: lidar_hillshade.sh [options] <downloadlist.txt|URL>
#
# Options:
#   --shading LIST       comma-separated shadings to render. Default: hillshade
#                        Known: hillshade, slopeshade
#   --algorithm ALG      hillshade algorithm: Horn (default) | ZevenbergenThorne
#                        Horn is the safer default for noisy lidar DEMs.
#   --multidirectional   use gdaldem -multidirectional (USGS's choice);
#                        otherwise -combined with az=315 alt=45.
#   --name NAME          output directory + root KML <name>.
#                        Default: superoverlay_TIMESTAMP
#   --gis-dir PATH       override GIS_DIR for this run
#   --kmz                also package the pyramid into a portable .kmz file
#   -h, --help           show this help
#
# Output: $GIS_DIR/lidar/kml/<name>/doc.kml
#   Layout: kml/<name>/<shading>/<project>/doc.kml
#   Root KML NetworkLinks one entry per shading; each shading's intermediate
#   KML NetworkLinks one entry per project.

set -euo pipefail

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

SHADINGS_CSV="hillshade"
NAME=""
PACKAGE_KMZ=0
GIS_DIR_OVERRIDE=""
DOWNLOAD_LIST=""
ALGORITHM=""
MULTIDIRECTIONAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shading)          SHADINGS_CSV="$2"; shift 2 ;;
    --algorithm)        ALGORITHM="$2"; shift 2 ;;
    --multidirectional) MULTIDIRECTIONAL=1; shift ;;
    --name)             NAME="$2"; shift 2 ;;
    --gis-dir)          GIS_DIR_OVERRIDE="$2"; shift 2 ;;
    --kmz)              PACKAGE_KMZ=1; shift ;;
    -h|--help)          usage 0 ;;
    -*)                 echo "Unknown flag: $1" >&2; usage ;;
    *)
      [[ -n "${DOWNLOAD_LIST}" ]] && { echo "Too many arguments" >&2; usage; }
      DOWNLOAD_LIST="$1"; shift ;;
  esac
done
[[ -z "${DOWNLOAD_LIST}" ]] && usage

[[ -n "${GIS_DIR_OVERRIDE}" ]] && export GIS_DIR="${GIS_DIR_OVERRIDE}"

SCRIPT_DIR=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lidar_common.sh
source "${SCRIPT_DIR}/lidar_common.sh"

# ─── Parse + validate shadings ───────────────────────────────────────────────
IFS=',' read -r -a SHADINGS <<< "${SHADINGS_CSV}"
for s in "${SHADINGS[@]}"; do
  is_known_shading "${s}" || {
    echo "ERROR: unknown shading: ${s}" >&2
    echo "  Known: ${KNOWN_SHADINGS[*]}" >&2
    exit 1
  }
done

# ─── Apply hillshade tuning flags (override lidar_common.sh defaults) ────────
if [[ -n "${ALGORITHM}" ]]; then
  case "${ALGORITHM}" in
    Horn|ZevenbergenThorne) HS_ALGORITHM="${ALGORITHM}" ;;
    *) echo "ERROR: --algorithm must be Horn or ZevenbergenThorne" >&2; exit 1 ;;
  esac
fi
[[ ${MULTIDIRECTIONAL} -eq 1 ]] && HS_MULTIDIRECTIONAL=1

[[ -z "${NAME}" ]] && NAME="superoverlay_${TIMESTAMP}"

KML_DIR="${LIDAR_DIR}/kml"
OUT_DIR="${KML_DIR}/${NAME}"

if [[ -e "${OUT_DIR}" ]]; then
  echo "ERROR: output directory already exists: ${OUT_DIR}" >&2
  echo "  Choose a different --name or remove the existing directory." >&2
  exit 1
fi

# Flatpak sandbox cannot read /tmp — work dir must live under LIDAR_DIR.
WORK_DIR=$(mktemp -d "${LIDAR_DIR}/.work_XXXXXX")
trap 'rm -rf "${WORK_DIR}"' EXIT

extra_deps=()
[[ ${PACKAGE_KMZ} -eq 1 ]] && extra_deps+=(zip)

check_deps_and_input "${DOWNLOAD_LIST}" "${extra_deps[@]+"${extra_deps[@]}"}"
prescan
make_dirs "${KML_DIR}"
download_tiles

# ─── Step 5: Group downloaded DEM tiles by USGS project ──────────────────────
echo "=========================================="
echo "STEP 5: Grouping tiles by project"
echo "=========================================="

LISTS_DIR="${WORK_DIR}/project_lists"
mkdir -p "${LISTS_DIR}"

declare -A PROJECT_COUNT=()
MISSING=0
SKIPPED_NO_PROJECT=0
while IFS= read -r URL; do
  [[ -z "${URL}" ]] && continue
  BASENAME="${URL##*/}"; BASENAME="${BASENAME%.tif}"
  TILE_TIF="${DEM_DIR}/${BASENAME}.tif"
  if [[ ! -f "${TILE_TIF}" ]]; then
    MISSING=$((MISSING + 1))
    continue
  fi
  PROJECT=$(project_from_url "${URL}")
  if [[ -z "${PROJECT}" ]]; then
    SKIPPED_NO_PROJECT=$((SKIPPED_NO_PROJECT + 1))
    echo "  WARNING: no Projects/<name>/ segment in URL — skipping: ${URL}"
    continue
  fi
  echo "${TILE_TIF}" >> "${LISTS_DIR}/${PROJECT}.list"
  PROJECT_COUNT["${PROJECT}"]=$((${PROJECT_COUNT["${PROJECT}"]:-0} + 1))
done < "${FILTERED_LIST}"

mapfile -t PROJECT_NAMES < <(printf '%s\n' "${!PROJECT_COUNT[@]}" | sort)

if [[ ${#PROJECT_NAMES[@]} -eq 0 ]]; then
  echo "ERROR: no DEM tiles available to mosaic (${MISSING} missing, ${SKIPPED_NO_PROJECT} skipped)"
  exit 1
fi

echo "  Projects found: ${#PROJECT_NAMES[@]}  (${MISSING} missing, ${SKIPPED_NO_PROJECT} skipped)"
for PROJECT in "${PROJECT_NAMES[@]}"; do
  printf "    %-60s %5d tiles\n" "${PROJECT}" "${PROJECT_COUNT[${PROJECT}]}"
done

# ─── Step 6: Per-shading × per-project pyramids ──────────────────────────────
echo "=========================================="
echo "STEP 6: Generating tile pyramids (${#SHADINGS[@]} shading(s) × ${#PROJECT_NAMES[@]} project(s))"
echo "=========================================="

mkdir -p "${OUT_DIR}"

# Per-project DEM VRT is built once and reused across shadings.
# Pin nodata explicitly: adjacent USGS projects sometimes ship different
# NoData defaults, which causes bright/dark seam artifacts at boundaries.
declare -A DEM_VRT=()
for PROJECT in "${PROJECT_NAMES[@]}"; do
  VRT="${WORK_DIR}/${PROJECT}_dem.vrt"
  "${GDALBUILDVRT[@]}" \
    -srcnodata "${DEM_NODATA}" -vrtnodata "${DEM_NODATA}" \
    -input_file_list "${LISTS_DIR}/${PROJECT}.list" "${VRT}"
  DEM_VRT["${PROJECT}"]="${VRT}"
done

for SHADING in "${SHADINGS[@]}"; do
  SHADING_DIR="${OUT_DIR}/${SHADING}"
  mkdir -p "${SHADING_DIR}"

  for PROJECT in "${PROJECT_NAMES[@]}"; do
    PROJ_OUT="${SHADING_DIR}/${PROJECT}"
    mkdir -p "${PROJ_OUT}"
    SHADE_TIF="${WORK_DIR}/${SHADING}_${PROJECT}.tif"
    WGS84_TIF="${WORK_DIR}/${SHADING}_${PROJECT}_wgs84.tif"

    echo "------------------------------------------"
    echo "${SHADING} / ${PROJECT}  (${PROJECT_COUNT[${PROJECT}]} tiles)"
    echo "------------------------------------------"

    echo "  Deriving ${SHADING}..."
    derive_shading "${SHADING}" "${DEM_VRT[${PROJECT}]}" "${SHADE_TIF}"

    echo "  Reprojecting to WGS84..."
    reproject_to_wgs84 "${SHADE_TIF}" "${WGS84_TIF}"

    echo "  Building tile pyramid..."
    # `gdal raster tile` (GDAL 3.11+) — C++ port of gdal2tiles, 3-6× faster.
    # --title sets the project sub-doc.kml <name> shown in the GE sidebar.
    "${GDAL[@]}" raster tile \
      --tiling-scheme WorldCRS84Quad \
      --kml \
      --webviewer none \
      -r average \
      -f JPEG --co JPEG_QUALITY=88 \
      --title "${PROJECT}" \
      -j ALL_CPUS \
      "${WGS84_TIF}" "${PROJ_OUT}"

    rm -f "${SHADE_TIF}" "${WGS84_TIF}"
  done
done

# ─── Step 7: Write intermediate per-shading KMLs and root KML ────────────────
echo "=========================================="
echo "STEP 7: Writing KML index"
echo "=========================================="

# Per-shading intermediate doc.kml: NetworkLinks one entry per project
for SHADING in "${SHADINGS[@]}"; do
  SHADING_KML="${OUT_DIR}/${SHADING}/doc.kml"
  {
    cat <<HEAD
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>${SHADING}</name>
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
  } > "${SHADING_KML}"
done

# Root doc.kml: NetworkLinks one entry per shading
ROOT_KML="${OUT_DIR}/doc.kml"
{
  cat <<HEAD
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>${NAME}</name>
  <open>1</open>
HEAD
  for SHADING in "${SHADINGS[@]}"; do
    cat <<NL
  <NetworkLink>
    <name>${SHADING}</name>
    <visibility>1</visibility>
    <Link><href>${SHADING}/doc.kml</href></Link>
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
  KMZ_OUT="${KMZ_DIR}/${NAME}.kmz"
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
echo "=========================================="
