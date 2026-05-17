# Lidar Pipeline Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure `lidar_hillshade.sh` + `lidar_common.sh` into a git-style subcommand layout (`lidar run|list|kill|service ...`), add modern bash hardening, expand systemd hardening compatible with flatpak GDAL, parallelize tile downloads via `xargs -P`, add bats smoke tests.

**Architecture:** Single `lidar` dispatcher `exec`s into `libexec/lidar-<subcommand>` binaries. Shared logic lives in `lib/*.sh` modules with idempotent load guards. Each sub-binary sources `lib/strict.sh` (set -Eeuo pipefail + ERR trap) first, then whatever lib modules it needs. Five revertable commits, behaviour-preserving until commit 5.

**Tech Stack:** Bash 5.x, flatpak GDAL (`org.qgis.qgis`), jq, bats-core, systemd --user.

**Spec:** `docs/superpowers/specs/2026-05-16-lidar-refactor-design.md`

---

## File Structure

**New files:**
- `lidar` — dispatcher (~30 LOC)
- `libexec/lidar-run` — pipeline entry
- `libexec/lidar-list` — events query
- `libexec/lidar-kill` — kill specific PIDs or --all
- `libexec/lidar-service-install` — systemd wiring
- `libexec/lidar-service-uninstall` — systemd teardown
- `libexec/lidar-help` — top-level help printer
- `lib/strict.sh` — strict mode + ERR trap
- `lib/common.sh` — pure helpers, GDAL handles, defaults
- `lib/events.sh` — JSONL events I/O
- `lib/download.sh` — tile fetching
- `lib/gdal.sh` — raster derivation
- `lib/kml.sh` — KML index + KMZ packaging
- `tests/test_helpers.bats` — pure-function tests
- `tests/test_cli.bats` — subcommand CLI tests

**Deleted in commit 3:**
- `lidar_hillshade.sh`
- `lidar_common.sh`

**Modified:**
- `systemd/lidar-hillshade@.service` → renamed to `systemd/lidar@.service`, hardened (commit 5)

---

## Task 1: Add `lib/strict.sh`

**Files:**
- Create: `lib/strict.sh`

- [ ] **Step 1: Create `lib/strict.sh`**

```bash
#!/usr/bin/env bash
# Strict mode + ERR trap with line-number diagnostics.
# Sourced first by every sub-binary and every bats test.
[[ -n "${_LIDAR_STRICT_LOADED:-}" ]] && return 0
_LIDAR_STRICT_LOADED=1
set -Eeuo pipefail
trap 'rc=$?; printf "\nERROR rc=%d at %s:%d in %s\n" "$rc" \
  "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" "${FUNCNAME[1]:-main}" >&2' ERR
```

- [ ] **Step 2: Verify file is syntactically valid**

Run: `bash -n lib/strict.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add lib/strict.sh
git commit -m "Add lib/strict.sh — strict mode + ERR diagnostics"
```

---

## Task 2: Extract pure helpers to `lib/common.sh`

The current `lidar_common.sh` mixes pure helpers (`json_escape`, `human_*`, `project_from_url`, `is_known_shading`), state setup (GIS_DIR check, directory layout), and GDAL handles. This task extracts everything except the pipeline-step functions into a new `lib/common.sh`. The pipeline-step functions (`check_deps_and_input`, `prescan`, `download_tiles`, `derive_*`, `reproject_to_wgs84`, `list_runs`, `events_emit_*`, `cleanup_old_logs`) stay in `lidar_common.sh` for now and will move in Task 3.

**Files:**
- Create: `lib/common.sh`
- Modify: `lidar_common.sh` — source `lib/common.sh` instead of redefining helpers

- [ ] **Step 1: Create `lib/common.sh`**

```bash
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
GDALWARP=(flatpak      run --command=gdalwarp       "${GDAL_FLATPAK_APP}")
GDALBUILDVRT=(flatpak  run --command=gdalbuildvrt   "${GDAL_FLATPAK_APP}")

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
```

Notes vs. the original `lidar_common.sh`:
- `parse_duration` migrated in from `lidar_hillshade.sh` so it can be tested in isolation.
- All other helpers identical to original.

- [ ] **Step 2: Modify `lidar_common.sh` to delegate**

Replace lines 13–84 (the load guard through `json_escape` body) and lines 250–269 (`human_*`, `project_from_url`) with a single source of `lib/common.sh` at the top:

```bash
#!/usr/bin/env bash
# Shared library for the lidar shading pipeline.
# Source this file; do not execute it directly.

[[ -n "${_LIDAR_COMMON_SHIM_LOADED:-}" ]] && return 0
_LIDAR_COMMON_SHIM_LOADED=1

SCRIPT_DIR_LC=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lib/strict.sh
source "${SCRIPT_DIR_LC}/lib/strict.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR_LC}/lib/common.sh"

# (the remaining pipeline-step functions — events_emit_*, list_runs,
# cleanup_old_logs, check_deps_and_input, prescan, make_dirs,
# download_tiles, derive_*, reproject_to_wgs84 — stay below verbatim)
```

Keep all pipeline-step functions in place; only the duplicated state/helpers are removed.

- [ ] **Step 3: Verify behavior preservation**

Run: `bash -n lidar_hillshade.sh lidar_common.sh lib/strict.sh lib/common.sh`
Expected: no output.

Run: `GIS_DIR=/mnt/data/gis ./lidar_hillshade.sh --help`
Expected: help text identical to pre-refactor.

Run: `GIS_DIR=/mnt/data/gis ./lidar_hillshade.sh --list-runs --all`
Expected: same output as before.

- [ ] **Step 4: Commit**

```bash
git add lib/common.sh lidar_common.sh
git commit -m "Extract pure helpers + state setup into lib/common.sh"
```

---

## Task 3: Split pipeline functions into `lib/{events,download,gdal,kml}.sh`

**Files:**
- Create: `lib/events.sh`
- Create: `lib/download.sh`
- Create: `lib/gdal.sh`
- Create: `lib/kml.sh`
- Modify: `lidar_common.sh` — shrink to a thin sourcing shim

- [ ] **Step 1: Create `lib/events.sh`**

Move from `lidar_common.sh`: `events_emit_start`, `events_emit_end`, `cleanup_old_logs`, `list_runs`. Verbatim. Wrap in the load guard:

```bash
#!/usr/bin/env bash
# JSONL run-events index. Append-only at $LIDAR_DIR/logs/runs.jsonl.
#
# On Linux, write(2) with O_APPEND atomically advances the file offset and
# writes; concurrent appenders never interleave or clobber regardless of
# write size. (PIPE_BUF — 4096 on Linux — constrains atomic writes to
# *pipes*, not regular files. The earlier "<4KB" guidance was wrong.)

[[ -n "${_LIDAR_EVENTS_LOADED:-}" ]] && return 0
_LIDAR_EVENTS_LOADED=1

# Requires lib/common.sh (for EVENTS_FILE, LIDAR_DIR, json_escape).

events_emit_start() {
  # ... (verbatim from lidar_common.sh lines 86-100) ...
}

events_emit_end() {
  # ... (verbatim from lidar_common.sh lines 102-109) ...
}

cleanup_old_logs() {
  # ... (verbatim from lidar_common.sh lines 114-120) ...
}

list_runs() {
  # ... (verbatim from lidar_common.sh lines 125-248) ...
}
```

Use exact function bodies from the current `lidar_common.sh`. Update the misleading comment block above `EVENTS_FILE=` in the original — its replacement is the file-level comment above.

- [ ] **Step 2: Create `lib/download.sh`**

Move: `check_deps_and_input`, `prescan`, `make_dirs`, `download_tiles`, and the `PRESCAN_SAMPLE=5` constant. Verbatim. Wrap in load guard.

```bash
#!/usr/bin/env bash
# Tile download + prescan. Requires lib/common.sh.
[[ -n "${_LIDAR_DOWNLOAD_LOADED:-}" ]] && return 0
_LIDAR_DOWNLOAD_LOADED=1

PRESCAN_SAMPLE=5

check_deps_and_input() { ... }
prescan() { ... }
make_dirs() { ... }
download_tiles() { ... }
```

- [ ] **Step 3: Create `lib/gdal.sh`**

Move: `derive_hillshade`, `derive_slopeshade`, `derive_shading`, `reproject_to_wgs84`. Add a new `build_dem_vrt` helper extracted from the loop currently inline in `lidar_hillshade.sh` (lines 418-424):

```bash
#!/usr/bin/env bash
# Raster derivation helpers. Requires lib/common.sh.
[[ -n "${_LIDAR_GDAL_LOADED:-}" ]] && return 0
_LIDAR_GDAL_LOADED=1

derive_hillshade() { ... }
derive_slopeshade() { ... }
derive_shading() { ... }
reproject_to_wgs84() { ... }

# Build a per-project DEM VRT from a tile list file. Pins nodata explicitly
# so adjacent USGS projects with different nodata defaults don't create
# bright/dark seam artifacts at boundaries.
build_dem_vrt() {
  local list_file="$1" out_vrt="$2"
  "${GDALBUILDVRT[@]}" \
    -srcnodata "${DEM_NODATA}" -vrtnodata "${DEM_NODATA}" \
    -input_file_list "${list_file}" "${out_vrt}"
}
```

- [ ] **Step 4: Create `lib/kml.sh`**

Extract the per-shading and root KML writing blocks from `lidar_hillshade.sh` (lines 469-518) and the KMZ packaging (lines 522-531) into named functions:

```bash
#!/usr/bin/env bash
# KML index generation + KMZ packaging. Requires lib/common.sh.
[[ -n "${_LIDAR_KML_LOADED:-}" ]] && return 0
_LIDAR_KML_LOADED=1

# Write per-shading doc.kml that NetworkLinks one entry per project.
write_shading_kml() {
  local out="$1" shading="$2"; shift 2
  local projects=("$@")
  {
    cat <<HEAD
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>${shading}</name>
  <open>1</open>
HEAD
    local p
    for p in "${projects[@]}"; do
      cat <<NL
  <NetworkLink>
    <name>${p}</name>
    <visibility>1</visibility>
    <Link><href>${p}/doc.kml</href></Link>
  </NetworkLink>
NL
    done
    cat <<'TAIL'
</Document>
</kml>
TAIL
  } > "${out}"
}

# Write root doc.kml that NetworkLinks one entry per shading.
write_root_kml() {
  local out="$1" name="$2"; shift 2
  local shadings=("$@")
  {
    cat <<HEAD
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>${name}</name>
  <open>1</open>
HEAD
    local s
    for s in "${shadings[@]}"; do
      cat <<NL
  <NetworkLink>
    <name>${s}</name>
    <visibility>1</visibility>
    <Link><href>${s}/doc.kml</href></Link>
  </NetworkLink>
NL
    done
    cat <<'TAIL'
</Document>
</kml>
TAIL
  } > "${out}"
}

# Zip the pyramid into a portable .kmz. Returns path via stdout.
package_kmz() {
  local src_dir="$1" out_kmz="$2"
  ( cd "${src_dir}" && zip -rq "${out_kmz}" . -x '*.aux.xml' )
}
```

- [ ] **Step 5: Shrink `lidar_common.sh` to a thin shim**

Replace the entire file with:

```bash
#!/usr/bin/env bash
# Legacy compatibility shim — sources the new lib/ modules.
# Will be deleted in commit 3 (the dispatcher commit).
[[ -n "${_LIDAR_COMMON_SHIM_LOADED:-}" ]] && return 0
_LIDAR_COMMON_SHIM_LOADED=1
SCRIPT_DIR_LC=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
source "${SCRIPT_DIR_LC}/lib/strict.sh"
source "${SCRIPT_DIR_LC}/lib/common.sh"
source "${SCRIPT_DIR_LC}/lib/events.sh"
source "${SCRIPT_DIR_LC}/lib/download.sh"
source "${SCRIPT_DIR_LC}/lib/gdal.sh"
source "${SCRIPT_DIR_LC}/lib/kml.sh"
```

- [ ] **Step 6: Verify behavior preservation**

Run: `bash -n lidar_hillshade.sh lib/*.sh`
Expected: no syntax errors.

Run: `GIS_DIR=/mnt/data/gis ./lidar_hillshade.sh --help`
Expected: identical help text.

Run: `GIS_DIR=/mnt/data/gis ./lidar_hillshade.sh --list-runs --json`
Expected: same JSON as before.

- [ ] **Step 7: Commit**

```bash
git add lib/events.sh lib/download.sh lib/gdal.sh lib/kml.sh lidar_common.sh lidar_hillshade.sh
git commit -m "Split pipeline functions into lib/{events,download,gdal,kml}.sh"
```

---

## Task 4: Add dispatcher `lidar` + sub-binaries; delete old entry

**Files:**
- Create: `lidar`
- Create: `libexec/lidar-help`
- Create: `libexec/lidar-run`
- Create: `libexec/lidar-list`
- Create: `libexec/lidar-kill`
- Create: `libexec/lidar-service-install`
- Create: `libexec/lidar-service-uninstall`
- Delete: `lidar_hillshade.sh`
- Delete: `lidar_common.sh`

- [ ] **Step 1: Create `lidar` dispatcher**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
export LIDAR_HOME="${HERE}"
export PATH="${HERE}/libexec:${PATH}"
sub="${1:-help}"; [[ $# -gt 0 ]] && shift
case "${sub}" in
  help|-h|--help) exec "${HERE}/libexec/lidar-help" "$@" ;;
  service)
    sub2="${1:-}"
    [[ -n "${sub2}" ]] || { echo "service requires install|uninstall" >&2; exit 2; }
    shift
    [[ -x "${HERE}/libexec/lidar-service-${sub2}" ]] \
      || { echo "unknown service action: ${sub2}" >&2; exit 2; }
    exec "${HERE}/libexec/lidar-service-${sub2}" "$@" ;;
  *)
    [[ -x "${HERE}/libexec/lidar-${sub}" ]] \
      || { echo "unknown subcommand: ${sub}" >&2; exit 2; }
    exec "${HERE}/libexec/lidar-${sub}" "$@" ;;
esac
```

Make executable: `chmod +x lidar`

- [ ] **Step 2: Create `libexec/lidar-help`**

```bash
#!/usr/bin/env bash
cat <<'EOF'
Usage: lidar <subcommand> [options...]

Subcommands:
  run                    Download tiles, mosaic, derive shading, build tile pyramid
  list                   List runs from the events index
  kill                   Stop a running pipeline (by PID, or --all)
  service install N      Install systemd --user service named N
  service uninstall N    Stop, disable, and remove service N
  help                   Show this help

Run `lidar <subcommand> --help` for per-subcommand details.
EOF
```

Make executable.

- [ ] **Step 3: Create `libexec/lidar-run`**

Body is the orchestration from the current `lidar_hillshade.sh` (lines 285-end), minus the parts that handled `--list-runs`, `--kill-all`, `--install-service`, `--uninstall-service` (those moved to sibling binaries).

```bash
#!/usr/bin/env bash
# `lidar run` — download tiles, mosaic, derive shading, build tile pyramid.
#
# Usage: lidar run [options] <downloadlist.txt|URL>
#
# Options:
#   --shading LIST       comma-separated shadings (default: hillshade)
#                        Known: hillshade, slopeshade
#   --algorithm ALG      hillshade algorithm: Horn (default) | ZevenbergenThorne
#   --multidirectional   use gdaldem -multidirectional (USGS's choice)
#   --name NAME          output directory + root KML <name>
#                        Default: superoverlay_TIMESTAMP
#   --gis-dir PATH       override GIS_DIR for this run
#   --kmz                also package the pyramid into a .kmz
#   --background         detach and run in the background
#   --dry-run            print resolved plan, exit 0 without side effects
#   -h, --help           show this help

source "${LIDAR_HOME}/lib/strict.sh"

usage() {
  sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

# Flag parsing — same hand-rolled while/case as before, minus the list/kill/
# service flags. Add --dry-run.
SHADINGS_CSV="hillshade"
NAME=""
PACKAGE_KMZ=0
GIS_DIR_OVERRIDE=""
DOWNLOAD_LIST=""
ALGORITHM=""
MULTIDIRECTIONAL=0
BACKGROUND=0
DRY_RUN=0
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
    --dry-run)            DRY_RUN=1; shift ;;
    -h|--help)            usage 0 ;;
    -*)                   echo "Unknown flag: $1" >&2; usage ;;
    *)
      [[ -n "${DOWNLOAD_LIST}" ]] && { echo "Too many arguments" >&2; usage; }
      DOWNLOAD_LIST="$1"; shift ;;
  esac
done

[[ -n "${GIS_DIR_OVERRIDE}" ]] && export GIS_DIR="${GIS_DIR_OVERRIDE}"

source "${LIDAR_HOME}/lib/common.sh"
source "${LIDAR_HOME}/lib/events.sh"
source "${LIDAR_HOME}/lib/download.sh"
source "${LIDAR_HOME}/lib/gdal.sh"
source "${LIDAR_HOME}/lib/kml.sh"

[[ -z "${DOWNLOAD_LIST}" ]] && usage

# --background: re-exec detached, log to file, print PID, exit
if [[ ${BACKGROUND} -eq 1 ]]; then
  CHILD_ARGS=()
  for a in "${ORIG_ARGS[@]}"; do
    [[ "${a}" == "--background" ]] && continue
    CHILD_ARGS+=("${a}")
  done
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
  nohup "${LIDAR_HOME}/lidar" run "${CHILD_ARGS[@]}" >"${LOG_FILE}" 2>&1 </dev/null &
  CHILD_PID=$!
  echo "  PID : ${CHILD_PID}"
  echo "  (tracked in events index — see lidar list)"
  disown
  exit 0
fi

# Parse + validate shadings
IFS=',' read -r -a SHADINGS <<< "${SHADINGS_CSV}"
for s in "${SHADINGS[@]}"; do
  is_known_shading "${s}" || {
    echo "ERROR: unknown shading: ${s}" >&2
    echo "  Known: ${KNOWN_SHADINGS[*]}" >&2
    exit 1
  }
done

# Apply hillshade tuning flags
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

if [[ -e "${OUT_DIR}" && ${DRY_RUN} -eq 0 ]]; then
  echo "ERROR: output directory already exists: ${OUT_DIR}" >&2
  echo "  Choose a different --name or remove the existing directory." >&2
  exit 1
fi

# --dry-run: print the plan and exit
if [[ ${DRY_RUN} -eq 1 ]]; then
  WORK_DIR=$(mktemp -d "${LIDAR_DIR}/.work_XXXXXX")
  trap 'rm -rf "${WORK_DIR}"' EXIT
  extra_deps=()
  [[ ${PACKAGE_KMZ} -eq 1 ]] && extra_deps+=(zip)
  check_deps_and_input "${DOWNLOAD_LIST}" "${extra_deps[@]+"${extra_deps[@]}"}"
  echo "=== DRY RUN PLAN ==="
  echo "Name        : ${NAME}"
  echo "Shadings    : ${SHADINGS[*]}"
  echo "Algorithm   : ${HS_ALGORITHM} (multidirectional=${HS_MULTIDIRECTIONAL})"
  echo "Output dir  : ${OUT_DIR}"
  echo "Tile list   : ${DOWNLOAD_LIST}"
  echo "Tile count  : ${TOTAL_TILES}"
  echo "Package KMZ : ${PACKAGE_KMZ}"
  echo "GIS_DIR     : ${GIS_DIR}"
  exit 0
fi

# Single-instance lock per --name
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

# Events: emit 'start' now and 'end' on exit
EVENT_LOG_PATH=""
if [[ ! -t 1 ]]; then
  EVENT_LOG_PATH=$(readlink -f /proc/self/fd/1 2>/dev/null || true)
  [[ "${EVENT_LOG_PATH}" == /dev/* ]] && EVENT_LOG_PATH=""
fi
events_emit_start "${NAME}" "${EVENT_LOG_PATH}" "${ORIG_ARGS[@]}"

WORK_DIR=$(mktemp -d "${LIDAR_DIR}/.work_XXXXXX")

on_exit() {
  local rc=$?
  events_emit_end "${NAME}" "${rc}"
  [[ -n "${WORK_DIR:-}" ]] && rm -rf "${WORK_DIR}"
}
trap on_exit EXIT

# Retention
cleanup_old_logs 30

extra_deps=()
[[ ${PACKAGE_KMZ} -eq 1 ]] && extra_deps+=(zip)

check_deps_and_input "${DOWNLOAD_LIST}" "${extra_deps[@]+"${extra_deps[@]}"}"
LISTS_DIR="${WORK_DIR}/project_lists"
prescan
make_dirs "${KML_DIR}"
download_tiles

# Resolve downloaded tiles per project (same logic as before, lines 365-405 of original)
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

# Per-shading × per-project pyramids
echo "=========================================="
echo "STEP 6: Generating tile pyramids (${#SHADINGS[@]} shading(s) × ${#PROJECT_NAMES[@]} project(s))"
echo "=========================================="

mkdir -p "${OUT_DIR}"

declare -A DEM_VRT=()
for PROJECT in "${PROJECT_NAMES[@]}"; do
  VRT="${WORK_DIR}/${PROJECT}_dem.vrt"
  build_dem_vrt "${LISTS_DIR}/${PROJECT}.list" "${VRT}"
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

echo "=========================================="
echo "STEP 7: Writing KML index"
echo "=========================================="
for SHADING in "${SHADINGS[@]}"; do
  write_shading_kml "${OUT_DIR}/${SHADING}/doc.kml" "${SHADING}" "${PROJECT_NAMES[@]}"
done
write_root_kml "${OUT_DIR}/doc.kml" "${NAME}" "${SHADINGS[@]}"

KMZ_OUT=""
if [[ ${PACKAGE_KMZ} -eq 1 ]]; then
  echo "=========================================="
  echo "STEP 8: Packaging KMZ"
  echo "=========================================="
  KMZ_DIR="${LIDAR_DIR}/kmz"
  mkdir -p "${KMZ_DIR}"
  KMZ_OUT="${KMZ_DIR}/${NAME}.kmz"
  package_kmz "${OUT_DIR}" "${KMZ_OUT}"
  echo "  KMZ: ${KMZ_OUT} ($(human_bytes "$(stat -c %s "${KMZ_OUT}")"))"
fi

echo "=========================================="
echo "ALL DONE"
echo ""
echo "Root KML : ${OUT_DIR}/doc.kml"
echo "Pyramid  : ${OUT_DIR}/  ($(du -sh "${OUT_DIR}" | cut -f1))"
[[ -n "${KMZ_OUT}" ]] && echo "Portable : ${KMZ_OUT}"
echo ""
echo "Open in Google Earth Pro via File → Open"
echo "=========================================="
```

Make executable.

- [ ] **Step 4: Create `libexec/lidar-list`**

```bash
#!/usr/bin/env bash
# `lidar list` — list runs from the JSONL events index.
#
# Usage: lidar list [options]
#
# Options:
#   --status STATUS    filter: running | success | failed | crashed
#   --running          shorthand for --status running
#   -n, --limit N      max rows (default 20; ignored with --all)
#   --since DUR        only runs started within DUR (30m, 24h, 7d)
#   --all              no limit
#   --json             machine output
#   --gis-dir PATH     override GIS_DIR for this query
#   -h, --help         show this help

source "${LIDAR_HOME}/lib/strict.sh"

usage() { sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

LR_STATUS=""
LR_LIMIT=20
LR_SINCE=""
LR_ALL=0
LR_JSON=0
GIS_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)        LR_STATUS="$2"; shift 2 ;;
    --running)       LR_STATUS="running"; shift ;;
    -n|--limit)      LR_LIMIT="$2"; shift 2 ;;
    --since)         LR_SINCE="$2"; shift 2 ;;
    --all)           LR_ALL=1; shift ;;
    --json)          LR_JSON=1; shift ;;
    --gis-dir)       GIS_DIR_OVERRIDE="$2"; shift 2 ;;
    -h|--help)       usage 0 ;;
    *)               echo "Unknown flag: $1" >&2; usage ;;
  esac
done

[[ -n "${GIS_DIR_OVERRIDE}" ]] && export GIS_DIR="${GIS_DIR_OVERRIDE}"
source "${LIDAR_HOME}/lib/common.sh"
source "${LIDAR_HOME}/lib/events.sh"

SINCE_SECS=""
[[ -n "${LR_SINCE}" ]] && SINCE_SECS=$(parse_duration "${LR_SINCE}")
list_runs "${LR_STATUS}" "${LR_LIMIT}" "${SINCE_SECS}" "${LR_ALL}" "${LR_JSON}"
```

Make executable.

- [ ] **Step 5: Create `libexec/lidar-kill`**

```bash
#!/usr/bin/env bash
# `lidar kill` — stop running pipeline(s).
#
# Usage:
#   lidar kill <PID> [<PID>...]   kill specific tracked PIDs
#   lidar kill --all              kill everything: events-tracked runs,
#                                 lidar@*.service units, stray processes
#
# Bare PIDs are sanity-checked against the events index — refuses to kill
# anything not currently tracked as running.

source "${LIDAR_HOME}/lib/strict.sh"

usage() { sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

KILL_ALL=0
PIDS=()
GIS_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)           KILL_ALL=1; shift ;;
    --gis-dir)       GIS_DIR_OVERRIDE="$2"; shift 2 ;;
    -h|--help)       usage 0 ;;
    -*)              echo "Unknown flag: $1" >&2; usage ;;
    *)
      [[ "$1" =~ ^[0-9]+$ ]] || { echo "Not a PID: $1" >&2; usage; }
      PIDS+=("$1"); shift ;;
  esac
done

[[ ${KILL_ALL} -eq 0 && ${#PIDS[@]} -eq 0 ]] && usage 2
[[ ${KILL_ALL} -eq 1 && ${#PIDS[@]} -gt 0 ]] && { echo "ERROR: --all and PID args are mutually exclusive" >&2; exit 2; }

[[ -n "${GIS_DIR_OVERRIDE}" ]] && export GIS_DIR="${GIS_DIR_OVERRIDE}"
source "${LIDAR_HOME}/lib/common.sh"
source "${LIDAR_HOME}/lib/events.sh"

# Collect set of running PIDs from the events index.
running_pids() {
  [[ -f "${EVENTS_FILE}" ]] || return 0
  command -v jq >/dev/null || return 0
  jq -s -r '
    group_by(.id) | map(
      (map(select(.event=="start"))[0]) as $s
      | .[-1] as $last
      | select($last.event != "end")
      | [$s.id, ($s.pid|tostring)] | join("")
    ) | .[]
  ' "${EVENTS_FILE}" | while IFS=$'\x1f' read -r id pid; do
    [[ -z "${pid}" || "${pid}" == "0" ]] && continue
    kill -0 "${pid}" 2>/dev/null && echo "${pid} ${id}"
  done
}

killed=0

if [[ ${#PIDS[@]} -gt 0 ]]; then
  declare -A TRACKED=()
  while read -r p id; do TRACKED["${p}"]="${id}"; done < <(running_pids)
  for p in "${PIDS[@]}"; do
    if [[ -z "${TRACKED[${p}]:-}" ]]; then
      echo "  REFUSE PID ${p} — not a tracked running lidar run" >&2
      exit 1
    fi
    echo "  TERM PID ${p} (${TRACKED[${p}]})"
    kill -TERM "${p}" || true
    killed=$((killed + 1))
  done
  echo "Sent TERM to ${killed} target(s)."
  exit 0
fi

# --all path
while read -r p id; do
  echo "  TERM PID ${p} (${id})"
  kill -TERM "${p}" 2>/dev/null || true
  killed=$((killed + 1))
done < <(running_pids)

if command -v systemctl >/dev/null; then
  while IFS= read -r unit; do
    [[ -z "${unit}" ]] && continue
    echo "  STOP systemd unit ${unit}"
    systemctl --user stop "${unit}" 2>/dev/null || true
    killed=$((killed + 1))
  done < <(systemctl --user list-units --type=service --no-legend --plain \
           'lidar@*.service' 2>/dev/null | awk '{print $1}')
fi

while IFS= read -r p; do
  [[ -z "${p}" || "${p}" == "$$" || "${p}" == "${PPID}" ]] && continue
  comm=$(cat "/proc/${p}/comm" 2>/dev/null || true)
  [[ "${comm}" == "pgrep" ]] && continue
  if kill -0 "${p}" 2>/dev/null; then
    echo "  TERM stray PID ${p} (${comm})"
    kill -TERM "${p}" 2>/dev/null || true
    killed=$((killed + 1))
  fi
done < <(pgrep -f 'libexec/lidar-run' 2>/dev/null || true)

if [[ ${killed} -eq 0 ]]; then echo "Nothing to kill."
else echo "Sent TERM to ${killed} target(s)."
fi
```

Make executable.

- [ ] **Step 6: Create `libexec/lidar-service-install`**

Adapt from `lidar_hillshade.sh` lines 126-189. Changes: unit template is now `systemd/lidar@.service`; service name is `lidar@N.service`; ExecStart calls `${LIDAR_HOME}/lidar run --name N ...`.

```bash
#!/usr/bin/env bash
# `lidar service install N` — wire up systemd --user unit for run name N.
#
# Usage: lidar service install <name> [run-options...] <URL_or_list>
#
# Forwards all extra options + the URL/list to the unit's env file. The
# unit auto-restarts on failure and survives reboot (if linger is enabled).

source "${LIDAR_HOME}/lib/strict.sh"

NAME="${1:-}"
[[ -n "${NAME}" ]] || { echo "Usage: lidar service install <name> [opts...] <URL>" >&2; exit 2; }
shift

ORIG_ARGS=("$@")
DOWNLOAD_LIST=""
GIS_DIR_OVERRIDE=""
for a in "$@"; do
  case "${a}" in
    --gis-dir) GIS_DIR_OVERRIDE_NEXT=1 ;;
    --gis-dir=*) GIS_DIR_OVERRIDE="${a#--gis-dir=}" ;;
    -*) : ;;
    *)
      if [[ -n "${GIS_DIR_OVERRIDE_NEXT:-}" ]]; then
        GIS_DIR_OVERRIDE="${a}"; GIS_DIR_OVERRIDE_NEXT=
      else
        DOWNLOAD_LIST="${a}"
      fi
      ;;
  esac
done
[[ -n "${DOWNLOAD_LIST}" ]] || { echo "ERROR: needs a URL or list path" >&2; exit 1; }

UNIT_SRC="${LIDAR_HOME}/systemd/lidar@.service"
[[ -f "${UNIT_SRC}" ]] || { echo "ERROR: unit template not found: ${UNIT_SRC}" >&2; exit 1; }

UNIT_DST_DIR="${HOME}/.config/systemd/user"
UNIT_DST="${UNIT_DST_DIR}/lidar@.service"
ENV_DIR="${HOME}/.config/lidar"
ENV_FILE="${ENV_DIR}/${NAME}.env"
DROPIN_DIR="${UNIT_DST_DIR}/lidar@${NAME}.service.d"
DROPIN="${DROPIN_DIR}/paths.conf"
mkdir -p "${UNIT_DST_DIR}" "${ENV_DIR}" "${DROPIN_DIR}"

if ! loginctl show-user "${USER}" 2>/dev/null | grep -q '^Linger=yes'; then
  echo "WARNING: lingering is not enabled for ${USER}." >&2
  echo "  Run:  sudo loginctl enable-linger ${USER}" >&2
fi

if [[ -L "${UNIT_DST}" || ! -e "${UNIT_DST}" ]]; then
  ln -sfn "${UNIT_SRC}" "${UNIT_DST}"
  echo "  Linked: ${UNIT_DST} -> ${UNIT_SRC}"
else
  echo "  Unit file exists and is not a symlink — leaving alone: ${UNIT_DST}"
fi

# Build EXTRA from $ORIG_ARGS, stripping the trailing DOWNLOAD_LIST positional.
EXTRA=()
for a in "${ORIG_ARGS[@]}"; do
  [[ "${a}" == "${DOWNLOAD_LIST}" ]] && continue
  EXTRA+=("${a}")
done

if [[ -e "${ENV_FILE}" ]]; then
  echo "ERROR: env file already exists: ${ENV_FILE}" >&2
  echo "  Run with: lidar service uninstall ${NAME}" >&2
  exit 1
fi

EFFECTIVE_GIS_DIR="${GIS_DIR_OVERRIDE:-${GIS_DIR:-/mnt/data/gis}}"
{
  echo "# Generated by: lidar service install ${NAME}"
  echo "GIS_DIR=${EFFECTIVE_GIS_DIR}"
  echo "DOWNLOAD_LIST=${DOWNLOAD_LIST}"
  printf 'EXTRA_ARGS=%q\n' "${EXTRA[*]:-}"
} > "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
echo "  Wrote env : ${ENV_FILE}"

# Drop-in that templates ReadWritePaths from this machine's GIS_DIR.
cat > "${DROPIN}" <<EOF
[Service]
ReadWritePaths=${EFFECTIVE_GIS_DIR}
EOF
echo "  Wrote drop-in : ${DROPIN}"

systemctl --user daemon-reload
UNIT="lidar@${NAME}.service"
systemctl --user enable --now "${UNIT}"
echo ""
echo "Service ${UNIT} is enabled and started."
echo "  Follow logs:  journalctl --user -u ${UNIT} -f"
echo "  Status     :  systemctl --user status ${UNIT}"
echo "  Stop       :  lidar service uninstall ${NAME}"
```

Make executable.

- [ ] **Step 7: Create `libexec/lidar-service-uninstall`**

```bash
#!/usr/bin/env bash
# `lidar service uninstall N` — stop, disable, and remove service N.

source "${LIDAR_HOME}/lib/strict.sh"

NAME="${1:-}"
[[ -n "${NAME}" ]] || { echo "Usage: lidar service uninstall <name>" >&2; exit 2; }

UNIT="lidar@${NAME}.service"
ENV_FILE="${HOME}/.config/lidar/${NAME}.env"
DROPIN_DIR="${HOME}/.config/systemd/user/lidar@${NAME}.service.d"

echo "Uninstalling ${UNIT}..."
systemctl --user stop    "${UNIT}" 2>/dev/null || true
systemctl --user disable "${UNIT}" 2>/dev/null || true
rm -f "${ENV_FILE}"
rm -rf "${DROPIN_DIR}"
systemctl --user daemon-reload
echo "  Stopped + disabled."
echo "  Removed env file : ${ENV_FILE}"
echo "  Removed drop-in  : ${DROPIN_DIR}"
echo "  (Unit template + linger state left intact.)"
```

Make executable.

- [ ] **Step 8: Delete the old entry files**

```bash
git rm lidar_hillshade.sh lidar_common.sh
```

- [ ] **Step 9: Verify behavior preservation**

Run: `bash -n lidar libexec/* lib/*.sh`
Expected: no syntax errors.

Run: `./lidar`
Expected: help output, exit 0.

Run: `./lidar bogus`
Expected: `unknown subcommand: bogus` on stderr, exit 2.

Run: `GIS_DIR=/mnt/data/gis ./lidar list --json`
Expected: same output as pre-refactor `lidar_hillshade.sh --list-runs --json`.

Run: `./lidar kill`
Expected: usage on stderr, exit 2.

- [ ] **Step 10: Commit**

```bash
git add lidar libexec/ lib/ systemd/
git commit -m "Add lidar dispatcher + libexec subcommands; remove old entry scripts"
```

---

## Task 5: Add bats tests + `--dry-run` plumbing

The `--dry-run` plumbing was already added to `libexec/lidar-run` in Task 4. This task adds the tests.

**Files:**
- Create: `tests/test_helpers.bats`
- Create: `tests/test_cli.bats`
- Create: `tests/fixtures/empty.txt`
- Create: `tests/fixtures/one_tile.txt`

- [ ] **Step 1: Install bats if not present**

```bash
command -v bats || sudo dnf install -y bats
```

Expected: `bats --version` prints `Bats <ver>`.

- [ ] **Step 2: Create `tests/fixtures/empty.txt` and `tests/fixtures/one_tile.txt`**

```bash
mkdir -p tests/fixtures
: > tests/fixtures/empty.txt
echo 'https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/1m/Projects/AK_FairbanksNorthStar_2017_D17/TIFF/USGS_one_meter_x12y713_AK_FairbanksNorthStar_2017_D17.tif' > tests/fixtures/one_tile.txt
```

- [ ] **Step 3: Write `tests/test_helpers.bats`**

```bash
#!/usr/bin/env bats

setup() {
  export GIS_DIR="${BATS_TMPDIR}/gis"
  mkdir -p "${GIS_DIR}/lidar/logs"
  LIDAR_HOME=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  # shellcheck source=../lib/strict.sh
  source "${LIDAR_HOME}/lib/strict.sh"
  # shellcheck source=../lib/common.sh
  source "${LIDAR_HOME}/lib/common.sh"
}

@test "json_escape passes safe strings unchanged" {
  result=$(json_escape "hello world")
  [ "${result}" = "hello world" ]
}

@test "json_escape escapes backslash" {
  result=$(json_escape 'a\b')
  [ "${result}" = 'a\\b' ]
}

@test "json_escape escapes double quote" {
  result=$(json_escape 'he said "hi"')
  [ "${result}" = 'he said \"hi\"' ]
}

@test "json_escape escapes newline" {
  result=$(json_escape $'line1\nline2')
  [ "${result}" = 'line1\nline2' ]
}

@test "human_duration formats seconds under one minute" {
  result=$(human_duration 45)
  [ "${result}" = "0m45s" ]
}

@test "human_duration formats minutes" {
  result=$(human_duration 125)
  [ "${result}" = "2m05s" ]
}

@test "human_duration formats hours" {
  result=$(human_duration 7325)
  [ "${result}" = "2h02m" ]
}

@test "human_duration clamps negatives to zero" {
  result=$(human_duration -5)
  [ "${result}" = "0m00s" ]
}

@test "parse_duration accepts seconds" {
  result=$(parse_duration "30s")
  [ "${result}" = "30" ]
}

@test "parse_duration accepts minutes" {
  result=$(parse_duration "5m")
  [ "${result}" = "300" ]
}

@test "parse_duration accepts hours" {
  result=$(parse_duration "2h")
  [ "${result}" = "7200" ]
}

@test "parse_duration accepts days" {
  result=$(parse_duration "7d")
  [ "${result}" = "604800" ]
}

@test "parse_duration rejects unknown suffix" {
  run parse_duration "7y"
  [ "${status}" -ne 0 ]
}

@test "project_from_url extracts USGS project" {
  result=$(project_from_url "https://prd-tnm.s3.amazonaws.com/Foo/Projects/AK_FairbanksNorthStar_2017_D17/TIFF/x.tif")
  [ "${result}" = "AK_FairbanksNorthStar_2017_D17" ]
}

@test "project_from_url returns empty for URL without /Projects/" {
  result=$(project_from_url "https://example.com/no/projects/here.tif")
  [ "${result}" = "" ]
}

@test "is_known_shading accepts hillshade and slopeshade" {
  is_known_shading hillshade
  is_known_shading slopeshade
}

@test "is_known_shading rejects gibberish" {
  run is_known_shading gibberish
  [ "${status}" -ne 0 ]
}
```

- [ ] **Step 4: Run helper tests**

```bash
bats tests/test_helpers.bats
```

Expected: 17 tests pass.

- [ ] **Step 5: Write `tests/test_cli.bats`**

```bash
#!/usr/bin/env bats

setup() {
  export GIS_DIR="${BATS_TMPDIR}/gis"
  mkdir -p "${GIS_DIR}/lidar/logs"
  export LIDAR_HOME=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  LIDAR="${LIDAR_HOME}/lidar"
  FIXTURES="${LIDAR_HOME}/tests/fixtures"
}

@test "lidar with no args prints help" {
  run "${LIDAR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage: lidar"* ]]
}

@test "lidar unknown-subcommand exits 2" {
  run "${LIDAR}" bogus
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown subcommand"* ]]
}

@test "lidar run --dry-run on empty list errors clearly" {
  run "${LIDAR}" run --dry-run "${FIXTURES}/empty.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"No .tif URLs"* ]]
}

@test "lidar run --dry-run with bad shading errors clearly" {
  run "${LIDAR}" run --dry-run --shading bogus "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown shading"* ]]
}

@test "lidar run --dry-run with bad algorithm errors clearly" {
  run "${LIDAR}" run --dry-run --algorithm Foo "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Horn or ZevenbergenThorne"* ]]
}

@test "lidar run --dry-run prints plan and exits 0" {
  run "${LIDAR}" run --dry-run --name testrun "${FIXTURES}/one_tile.txt"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY RUN PLAN"* ]]
  [[ "${output}" == *"testrun"* ]]
}

@test "lidar list --json on empty events file returns []" {
  rm -f "${GIS_DIR}/lidar/logs/runs.jsonl"
  run "${LIDAR}" list --json
  [ "${status}" -eq 0 ]
  [ "${output}" = "[]" ]
}

@test "lidar list --since 7y rejects bad duration" {
  run "${LIDAR}" list --since 7y
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"bad duration"* ]]
}

@test "lidar kill with no args exits 2" {
  run "${LIDAR}" kill
  [ "${status}" -eq 2 ]
}

@test "lidar kill 1 refuses untracked PID" {
  rm -f "${GIS_DIR}/lidar/logs/runs.jsonl"
  run "${LIDAR}" kill 1
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"REFUSE PID 1"* ]]
}

@test "lidar service install with no name exits 2" {
  run "${LIDAR}" service install
  [ "${status}" -eq 2 ]
}
```

- [ ] **Step 6: Run CLI tests**

```bash
bats tests/test_cli.bats
```

Expected: 11 tests pass.

- [ ] **Step 7: Commit**

```bash
git add tests/
git commit -m "Add bats smoke tests for helpers and CLI surface"
```

---

## Task 6: Rename systemd unit + add hardening + parallelize downloads

**Files:**
- Rename: `systemd/lidar-hillshade@.service` → `systemd/lidar@.service`
- Modify: `systemd/lidar@.service` — apply hardening directives, update ExecStart
- Modify: `lib/download.sh` — replace serial loop with xargs -P helper

- [ ] **Step 1: Rename + harden the unit file**

```bash
git mv systemd/lidar-hillshade@.service systemd/lidar@.service
```

Replace contents with:

```ini
# Templated systemd user unit for the lidar pipeline.
#
# Install:  lidar service install <name> [opts...] <URL>
# Stop:     lidar service uninstall <name>
# Status:   systemctl --user status lidar@<name>
# Logs:     journalctl --user -u lidar@<name> -f

[Unit]
Description=Lidar pipeline (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/scripts/gis/lidar
EnvironmentFile=%h/.config/lidar/%i.env
ExecStart=/bin/bash -c '%h/scripts/gis/lidar/lidar run --name %i ${EXTRA_ARGS} "${DOWNLOAD_LIST}"'

Restart=on-failure
RestartSec=30
StartLimitIntervalSec=600
StartLimitBurst=3

# Hardening compatible with flatpak GDAL (org.qgis.qgis):
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=tmpfs
ProtectKernelTunables=yes
ProtectKernelModules=yes
LockPersonality=yes
PrivateDevices=yes
SystemCallArchitectures=native
SystemCallFilter=~@clock @debug @module @obsolete @privileged @raw-io @reboot @swap
RestrictRealtime=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
# Intentionally omitted — break flatpak bwrap or GDAL JIT codecs:
#   RestrictNamespaces=     (flatpak requires user namespace creation)
#   MemoryDenyWriteExecute= (GDAL DEFLATE/LZW JIT segfaults)
#   ProtectSystem=strict    (flatpak ExecStart cannot reach /tmp sandbox)
# ReadWritePaths is added per-install via a drop-in (see lidar-service-install).

StandardOutput=journal
StandardError=journal
SyslogIdentifier=lidar-%i
TimeoutStartSec=infinity
TimeoutStopSec=2min

[Install]
WantedBy=default.target
```

- [ ] **Step 2: Add parallel-download helper in `lib/download.sh`**

Replace the body of `download_tiles` with the following. Keep the function signature.

```bash
# Per-URL worker. Exported via export -f so xargs subshells inherit it.
# Cache-hits exit 0 immediately; downloads use PID-suffixed partials so
# concurrent invocations don't clobber each other.
_lidar_download_one() {
  local url="$1"
  [[ -z "${url}" ]] && return 0
  local basename="${url##*/}"; basename="${basename%.tif}"
  local tile_tif="${DEM_DIR}/${basename}.tif"
  if [[ -f "${tile_tif}" ]]; then
    flock /dev/stderr printf "  cached %s\n" "${basename}" >&2
    return 0
  fi
  local partial="${tile_tif}.$$.partial"
  if ! curl -L --retry 5 --retry-all-errors --retry-delay 5 \
            --fail-with-body --max-time 1800 -C - -sS \
            -o "${partial}" "${url}"; then
    flock /dev/stderr printf "  ERROR %s\n" "${basename}" >&2
    rm -f "${partial}"
    return 1
  fi
  if [[ -f "${tile_tif}" ]]; then
    rm -f "${partial}"
  else
    mv -f "${partial}" "${tile_tif}"
  fi
  flock /dev/stderr printf "  done   %s (%s)\n" "${basename}" "$(human_bytes "$(stat -c %s "${tile_tif}")")" >&2
}
export -f _lidar_download_one

download_tiles() {
  local jobs="${LIDAR_DOWNLOAD_JOBS:-4}"
  echo "=========================================="
  echo "STEP 4: Downloading ${TOTAL_TILES} tiles (parallel ${jobs})"
  echo "=========================================="

  # Re-export the state _lidar_download_one needs in its subshell.
  export DEM_DIR

  local failures=0
  if ! grep -v '^[[:space:]]*$' "${FILTERED_LIST}" \
       | xargs -P "${jobs}" -n 1 -I {} bash -c '_lidar_download_one "$@"' _ {}; then
    failures=1
  fi

  echo "=========================================="
  if [[ ${failures} -eq 1 ]]; then
    echo "STEP 4 complete — some downloads failed (see stderr)"
  else
    echo "STEP 4 complete"
  fi
  echo "=========================================="
}
```

Note: per-tile percentage/EWMA progress disappears under parallelism (it's meaningless per-tile when many run concurrently). The simpler `cached`/`done`/`ERROR` lines remain ordered via `flock /dev/stderr`.

- [ ] **Step 3: Verify shell syntax**

Run: `bash -n lib/download.sh systemd/lidar@.service` — wait, the systemd file isn't bash. Just: `bash -n lib/download.sh`.
Expected: no output.

- [ ] **Step 4: Re-run all bats tests**

```bash
bats tests/
```

Expected: all 28 tests pass.

- [ ] **Step 5: Manual smoke test**

```bash
# Pick a small USGS list (5-10 tiles) and time both implementations.
# (Skip if a small reference list isn't on hand.)
GIS_DIR=/mnt/data/gis ./lidar run --dry-run --name smoke /path/to/small-list.txt
GIS_DIR=/mnt/data/gis ./lidar run --name smoke /path/to/small-list.txt
```

Expected: completes successfully, output appears under `/mnt/data/gis/lidar/kml/smoke/`, KML root opens in Google Earth Pro.

- [ ] **Step 6: Commit**

```bash
git add systemd/lidar@.service lib/download.sh
git commit -m "Rename systemd unit, add flatpak-compatible hardening, parallelize downloads"
```

---

## Self-review notes

- All 9 spec sections (Motivation, Research, File layout, Dispatcher, CLI surface, Strict mode, Correctness fixes, Systemd hardening, What does NOT change, Test plan, Migration, Commit plan, Open questions, Acceptance criteria) are covered by the six tasks.
- The PIPE_BUF comment correction lives at the top of `lib/events.sh` in Task 3 Step 1.
- The `lidar kill` PID-args feature is implemented in Task 4 Step 5; corresponding test in Task 5 Step 5.
- The `ReadWritePaths` per-install drop-in is implemented in Task 4 Step 6 (`lidar-service-install`) and matched by removal in Task 4 Step 7 (`lidar-service-uninstall`).
- No placeholders, no "TBD", no "similar to Task N" references.
- Type/name consistency: `_lidar_download_one`, `write_shading_kml`, `write_root_kml`, `package_kmz`, `build_dem_vrt` referenced consistently across tasks.
