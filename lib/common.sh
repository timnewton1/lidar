#!/usr/bin/env bash
# Shared state, defaults, and pure helpers for the lidar pipeline.
# Source this file; do not execute it directly.
#
# Required (must be set before sourcing OR via --gis-dir in the caller):
#   GIS_DIR — root GIS data directory (e.g. /mnt/data/gis)

[[ -n "${_LIDAR_COMMON_LOADED:-}" ]] && return 0
_LIDAR_COMMON_LOADED=1

# strict.sh must be loaded first by the entry script.

if [[ -z "${GIS_DIR:-}" ]]; then
  echo "ERROR: GIS_DIR is not set." >&2
  echo "  Either: export GIS_DIR=/path/to/gis" >&2
  echo "  Or pass: --gis-dir /path/to/gis" >&2
  exit 1
fi

# ─── Directory layout ────────────────────────────────────────────────────────
LIDAR_DIR="${GIS_DIR}/lidar"
DEM_DIR="${LIDAR_DIR}/tiles/dem"
EVENTS_FILE="${LIDAR_DIR}/logs/runs.jsonl"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ─── GDAL via QGIS flatpak ───────────────────────────────────────────────────
# Migrated from gdal2tiles.py to `gdal raster tile` (GDAL 3.11+). gdal2tiles.py
# is deprecated in GDAL 3.13 and removed in 3.15.
GDAL_FLATPAK_APP="org.qgis.qgis"
GDAL=(flatpak          run --command=gdal           "${GDAL_FLATPAK_APP}")
GDALDEM=(flatpak       run --command=gdaldem        "${GDAL_FLATPAK_APP}")
GDALINFO=(flatpak      run --command=gdalinfo       "${GDAL_FLATPAK_APP}")
GDALWARP=(flatpak      run --command=gdalwarp       "${GDAL_FLATPAK_APP}")
GDALBUILDVRT=(flatpak  run --command=gdalbuildvrt   "${GDAL_FLATPAK_APP}")
GDALTRANSLATE=(flatpak run --command=gdal_translate "${GDAL_FLATPAK_APP}")

# ─── Hillshade parameters ────────────────────────────────────────────────────
HS_ALGORITHM=Horn          # Horn | ZevenbergenThorne
HS_MULTIDIRECTIONAL=0      # 1 = use -multidirectional (USGS's choice)
HS_AZIMUTH=315
HS_ALTITUDE=45
HS_Z_FACTOR=1.5

# ─── USGS 3DEP NoData value ──────────────────────────────────────────────────
DEM_NODATA=-9999

# ─── Known shadings ──────────────────────────────────────────────────────────
KNOWN_SHADINGS=(hillshade slopeshade)

is_known_shading() {
  local s="$1" k
  for k in "${KNOWN_SHADINGS[@]}"; do [[ "${k}" == "${s}" ]] && return 0; done
  return 1
}

# ─── Pure helpers ────────────────────────────────────────────────────────────

# Minimal JSON string escape — handles chars that show up in run names, paths,
# and CLI args. Not a general-purpose JSON encoder.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "${s}"
}

human_bytes() { numfmt --to=iec --suffix=B --format='%.1f' "$1"; }

# Format a duration in seconds as Hh:MMm or MMm:SSs.
human_duration() {
  local s="$1"
  (( s < 0 )) && s=0
  if (( s >= 3600 )); then
    printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  else
    printf '%dm%02ds' $((s / 60)) $((s % 60))
  fi
}

# Parse human duration suffixes: 30m, 24h, 7d → seconds.
parse_duration() {
  local s="$1" n="${1%[smhd]}" u="${1: -1}"
  [[ "${s}" =~ ^[0-9]+[smhd]?$ ]] || { echo "bad duration: ${s}" >&2; exit 1; }
  case "${u}" in
    s) echo $((n)) ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
    *) echo $((s)) ;;
  esac
}

# Extract USGS project name from URL: ".../Projects/<NAME>/..." → "<NAME>"
project_from_url() {
  local rest="${1#*/Projects/}"
  [[ "${rest}" == "$1" ]] && { echo ""; return; }
  echo "${rest%%/*}"
}
