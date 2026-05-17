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
#   --background         detach and run in the background; log to
#                        $GIS_DIR/lidar/logs/<name>.log. Prints PID + log path.
#   --list-running       list active background runs (PID, log path) and exit
#   --install-service N  install as a systemd --user service named N
#                        (auto-restarts, survives reboot). Forwards all other
#                        flags + the URL/list to the unit's env file.
#   --uninstall-service N  stop, disable, and remove service N's env file
#   -h, --help           show this help
#
# Output: $GIS_DIR/lidar/kml/<name>/doc.kml
#   Layout: kml/<name>/<shading>/<project>/doc.kml
#   Root KML NetworkLinks one entry per shading; each shading's intermediate
#   KML NetworkLinks one entry per project.

set -euo pipefail

usage() {
  sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

SHADINGS_CSV="hillshade"
NAME=""
PACKAGE_KMZ=0
GIS_DIR_OVERRIDE=""
DOWNLOAD_LIST=""
ALGORITHM=""
MULTIDIRECTIONAL=0
BACKGROUND=0
LIST_RUNNING=0
INSTALL_SERVICE=""
UNINSTALL_SERVICE=""

ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shading)            SHADINGS_CSV="$2"; shift 2 ;;
    --algorithm)          ALGORITHM="$2"; shift 2 ;;
    --multidirectional)   MULTIDIRECTIONAL=1; shift ;;
    --name)               NAME="$2"; shift 2 ;;
    --gis-dir)            GIS_DIR_OVERRIDE="$2"; shift 2 ;;
    --kmz)                PACKAGE_KMZ=1; shift ;;
    --background)         BACKGROUND=1; shift ;;
    --list-running)       LIST_RUNNING=1; shift ;;
    --install-service)    INSTALL_SERVICE="$2"; shift 2 ;;
    --uninstall-service)  UNINSTALL_SERVICE="$2"; shift 2 ;;
    -h|--help)            usage 0 ;;
    -*)                   echo "Unknown flag: $1" >&2; usage ;;
    *)
      [[ -n "${DOWNLOAD_LIST}" ]] && { echo "Too many arguments" >&2; usage; }
      DOWNLOAD_LIST="$1"; shift ;;
  esac
done

# ─── --uninstall-service: stop + disable + remove env file, then exit ────────
if [[ -n "${UNINSTALL_SERVICE}" ]]; then
  UNIT="lidar-hillshade@${UNINSTALL_SERVICE}.service"
  ENV_FILE="${HOME}/.config/lidar/${UNINSTALL_SERVICE}.env"
  echo "Uninstalling ${UNIT}..."
  systemctl --user stop    "${UNIT}" 2>/dev/null || true
  systemctl --user disable "${UNIT}" 2>/dev/null || true
  rm -f "${ENV_FILE}"
  systemctl --user daemon-reload
  echo "  Stopped + disabled. Env file removed: ${ENV_FILE}"
  echo "  (Unit template + linger state left intact.)"
  exit 0
fi

# ─── --install-service: wire up systemd --user unit + env file, then exit ───
if [[ -n "${INSTALL_SERVICE}" ]]; then
  [[ -z "${DOWNLOAD_LIST}" ]] && { echo "ERROR: --install-service needs a URL or list path" >&2; usage; }
  SCRIPT_DIR_ABS=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
  UNIT_SRC="${SCRIPT_DIR_ABS}/systemd/lidar-hillshade@.service"
  [[ -f "${UNIT_SRC}" ]] || { echo "ERROR: unit template not found: ${UNIT_SRC}" >&2; exit 1; }

  UNIT_DST_DIR="${HOME}/.config/systemd/user"
  UNIT_DST="${UNIT_DST_DIR}/lidar-hillshade@.service"
  ENV_DIR="${HOME}/.config/lidar"
  ENV_FILE="${ENV_DIR}/${INSTALL_SERVICE}.env"
  mkdir -p "${UNIT_DST_DIR}" "${ENV_DIR}"

  # Lingering check — without it the unit dies on logout.
  if ! loginctl show-user "${USER}" 2>/dev/null | grep -q '^Linger=yes'; then
    echo "WARNING: lingering is not enabled for ${USER}." >&2
    echo "  Run:  sudo loginctl enable-linger ${USER}" >&2
    echo "  Without lingering the service will be killed when you log out." >&2
  fi

  # Symlink unit template (idempotent — overwrite if it points elsewhere).
  if [[ -L "${UNIT_DST}" || ! -e "${UNIT_DST}" ]]; then
    ln -sfn "${UNIT_SRC}" "${UNIT_DST}"
    echo "  Linked: ${UNIT_DST} -> ${UNIT_SRC}"
  else
    echo "  Unit file exists and is not a symlink — leaving alone: ${UNIT_DST}"
  fi

  # Build EXTRA_ARGS from the original CLI: everything except the install flag
  # itself, the install name, and the trailing positional (URL/list).
  EXTRA=()
  skip_next=0
  for a in "${ORIG_ARGS[@]}"; do
    if [[ ${skip_next} -eq 1 ]]; then skip_next=0; continue; fi
    case "${a}" in
      --install-service) skip_next=1 ;;
      "${DOWNLOAD_LIST}") : ;;
      *) EXTRA+=("${a}") ;;
    esac
  done

  if [[ -e "${ENV_FILE}" ]]; then
    echo "ERROR: env file already exists: ${ENV_FILE}" >&2
    echo "  Run with --uninstall-service ${INSTALL_SERVICE} first, or edit by hand." >&2
    exit 1
  fi
  {
    echo "# Generated by lidar_hillshade.sh --install-service ${INSTALL_SERVICE}"
    echo "GIS_DIR=${GIS_DIR_OVERRIDE:-${GIS_DIR:-/mnt/data/gis}}"
    echo "DOWNLOAD_LIST=${DOWNLOAD_LIST}"
    printf 'EXTRA_ARGS=%q\n' "${EXTRA[*]:-}"
  } > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  echo "  Wrote env : ${ENV_FILE}"

  systemctl --user daemon-reload
  UNIT="lidar-hillshade@${INSTALL_SERVICE}.service"
  systemctl --user enable --now "${UNIT}"
  echo ""
  echo "Service ${UNIT} is enabled and started."
  echo "  Follow logs:  journalctl --user -u ${UNIT} -f"
  echo "  Status     :  systemctl --user status ${UNIT}"
  echo "  Stop       :  ${BASH_SOURCE[0]} --uninstall-service ${INSTALL_SERVICE}"
  exit 0
fi

# ─── --list-running: scan PID sidecars and exit ──────────────────────────────
if [[ ${LIST_RUNNING} -eq 1 ]]; then
  EFFECTIVE_GIS_DIR="${GIS_DIR_OVERRIDE:-${GIS_DIR:-}}"
  [[ -z "${EFFECTIVE_GIS_DIR}" ]] && { echo "ERROR: GIS_DIR not set" >&2; exit 1; }
  LOG_DIR="${EFFECTIVE_GIS_DIR}/lidar/logs"
  if [[ ! -d "${LOG_DIR}" ]]; then
    echo "No background runs (no ${LOG_DIR})"
    exit 0
  fi
  shopt -s nullglob
  COUNT=0
  printf "%-8s  %-19s  %s\n" "PID" "STARTED" "LOG"
  for pidfile in "${LOG_DIR}"/*.log.pid; do
    pid=$(cat "${pidfile}" 2>/dev/null || true)
    [[ -z "${pid}" ]] && continue
    if kill -0 "${pid}" 2>/dev/null; then
      started=$(stat -c %y "${pidfile}" 2>/dev/null | cut -d. -f1)
      printf "%-8s  %-19s  %s\n" "${pid}" "${started}" "${pidfile%.pid}"
      COUNT=$((COUNT + 1))
    else
      rm -f "${pidfile}"
    fi
  done
  [[ ${COUNT} -eq 0 ]] && echo "(none)"
  exit 0
fi

[[ -z "${DOWNLOAD_LIST}" ]] && usage

# ─── --background: re-exec detached, log to file, print PID, exit ────────────
if [[ ${BACKGROUND} -eq 1 ]]; then
  # Strip --background from forwarded args so the child doesn't recurse.
  CHILD_ARGS=()
  for a in "${ORIG_ARGS[@]}"; do
    [[ "${a}" == "--background" ]] && continue
    CHILD_ARGS+=("${a}")
  done
  # Resolve GIS_DIR the same way the child will, just for the log path.
  EFFECTIVE_GIS_DIR="${GIS_DIR_OVERRIDE:-${GIS_DIR:-}}"
  [[ -z "${EFFECTIVE_GIS_DIR}" ]] && { echo "ERROR: GIS_DIR not set" >&2; exit 1; }
  LOG_DIR="${EFFECTIVE_GIS_DIR}/lidar/logs"
  mkdir -p "${LOG_DIR}"
  LOG_NAME="${NAME:-superoverlay_$(date +%Y%m%d_%H%M%S)}"
  LOG_FILE="${LOG_DIR}/${LOG_NAME}.log"
  if [[ -e "${LOG_FILE}" ]]; then
    echo "ERROR: log file already exists: ${LOG_FILE}" >&2
    echo "  Use --name to disambiguate." >&2
    exit 1
  fi
  echo "Starting in background..."
  echo "  Log : ${LOG_FILE}"
  nohup "${BASH_SOURCE[0]}" "${CHILD_ARGS[@]}" >"${LOG_FILE}" 2>&1 </dev/null &
  CHILD_PID=$!
  echo "${CHILD_PID}" > "${LOG_FILE}.pid"
  echo "  PID : ${CHILD_PID}"
  disown
  exit 0
fi

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

# ─── Single-instance lock (per --name) ───────────────────────────────────────
# Prevents accidental dual-runs of the same NAME. Exits 0 (clean) when the
# lock is held so systemd Restart=on-failure doesn't loop on it. Lock is
# released automatically when the process exits.
LOCK_DIR="${LIDAR_DIR}/locks"
mkdir -p "${LOCK_DIR}"
LOCK_FILE="${LOCK_DIR}/${NAME}.lock"
exec {LOCK_FD}>"${LOCK_FILE}"
if ! flock -n "${LOCK_FD}"; then
  HOLDER=$(cat "${LOCK_FILE}" 2>/dev/null || true)
  echo "Another instance is already running (lock ${LOCK_FILE}${HOLDER:+, PID ${HOLDER}})"
  exit 0
fi
echo $$ > "${LOCK_FILE}"

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
LISTS_DIR="${WORK_DIR}/project_lists"
prescan
make_dirs "${KML_DIR}"
download_tiles

# ─── Step 5: Materialize per-project tile-file lists ─────────────────────────
# prescan already grouped URLs into ${LISTS_DIR}/<project>.urls. Here we
# resolve each URL to its on-disk path, dropping any tile whose download
# failed, and emit ${LISTS_DIR}/<project>.list for gdalbuildvrt.
echo "=========================================="
echo "STEP 5: Resolving downloaded tiles by project"
echo "=========================================="

MISSING=0
declare -A PROJECT_READY=()
for PROJECT in "${PROJECT_NAMES[@]}"; do
  URLS_FILE="${LISTS_DIR}/${PROJECT}.urls"
  LIST_FILE="${LISTS_DIR}/${PROJECT}.list"
  : > "${LIST_FILE}"
  N=0
  while IFS= read -r URL; do
    [[ -z "${URL}" ]] && continue
    BASENAME="${URL##*/}"; BASENAME="${BASENAME%.tif}"
    TILE_TIF="${DEM_DIR}/${BASENAME}.tif"
    if [[ -f "${TILE_TIF}" ]]; then
      echo "${TILE_TIF}" >> "${LIST_FILE}"
      N=$((N + 1))
    else
      MISSING=$((MISSING + 1))
    fi
  done < "${URLS_FILE}"
  PROJECT_READY["${PROJECT}"]="${N}"
done

# Filter out projects with zero successful tiles.
READY_PROJECTS=()
for PROJECT in "${PROJECT_NAMES[@]}"; do
  [[ "${PROJECT_READY[${PROJECT}]}" -gt 0 ]] && READY_PROJECTS+=("${PROJECT}")
done
PROJECT_NAMES=("${READY_PROJECTS[@]}")

if [[ ${#PROJECT_NAMES[@]} -eq 0 ]]; then
  echo "ERROR: no DEM tiles available to mosaic (${MISSING} missing)"
  exit 1
fi

echo "  Projects ready: ${#PROJECT_NAMES[@]}  (${MISSING} missing tiles)"
for PROJECT in "${PROJECT_NAMES[@]}"; do
  printf "    %-60s %5d tiles\n" "${PROJECT}" "${PROJECT_READY[${PROJECT}]}"
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
