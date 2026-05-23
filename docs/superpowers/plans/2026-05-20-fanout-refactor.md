# Fan-out Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote lidar's internal per-project loop to the unit of a run — one invocation against an N-project tile list produces N independent runs, each with its own hex ID, log, output directory, and events row.

**Architecture:** A parent process fans out one child process per USGS project (bounded by `--jobs`), detaches, and returns immediately. Each child owns the full pipeline for its project. The existing per-project loop inside `lidar-run` (steps 5–8) becomes the body of `_run_one_project` with minimal changes. Cascading simplifications: `--background`/`--name` disappear, the run lock disappears, restart trivialises, and `log` is renamed `list`.

**Tech Stack:** bash 5+, bats, jq, GNU coreutils (`wait -n` requires bash 5.0+)

---

## File Map

| File | Change |
|---|---|
| `libexec/lidar-service-install` | **DELETE** |
| `libexec/lidar-service-uninstall` | **DELETE** |
| `systemd/lidar@.service` | **DELETE** |
| `lidar` | modify: remove service routing |
| `libexec/lidar-help` | modify: update subcommand list |
| `libexec/lidar-run` | major rewrite: multi-input, fan-out, drop --background/--name/lock |
| `libexec/lidar-log` | **DELETE** (replaced by lidar-list) |
| `libexec/lidar-list` | **CREATE**: simplified table + log view |
| `libexec/lidar-rerun` | **DELETE** (replaced by lidar-restart) |
| `libexec/lidar-restart` | **CREATE**: reads .urls from event, re-execs lidar run |
| `libexec/lidar-kill` | modify: remove systemd unit section from --all |
| `libexec/lidar-size` | modify: update resolve_input usage (urls field) |
| `lib/common.sh` | add: `gen_hex_id`, `PROJECTS_DIR`, `fanout_by_project` |
| `lib/events.sh` | add project field; replace args→urls; delete strip_restart_flags; update list_runs |
| `lib/download.sh` | add: FANOUT_PROJECT fallback in prescan |
| `tests/test_cli.bats` | update throughout |
| `tests/test_helpers.bats` | add: gen_hex_id, fanout_by_project tests |
| `README.md` | update usage section |

---

## Task 1: Delete systemd integration

**Files:**
- Delete: `libexec/lidar-service-install`
- Delete: `libexec/lidar-service-uninstall`
- Delete: `systemd/lidar@.service`
- Modify: `lidar` (dispatcher)
- Modify: `libexec/lidar-help`
- Modify: `libexec/lidar-kill` (remove systemd unit block from `--all`)
- Modify: `tests/test_cli.bats` (remove service test)

- [ ] **Step 1: Remove the service subcommand routing from `lidar`**

In `lidar`, delete the `service)` case block (lines 11–16):

```bash
# Remove this block entirely:
  service)
    sub2="${1:-}"
    [[ -n "${sub2}" ]] || { echo "lidar service: requires install|uninstall" >&2; exit 2; }
    shift
    bin="${HERE}/libexec/lidar-service-${sub2}"
    [[ -x "${bin}" ]] || { echo "lidar service: unknown action: ${sub2}" >&2; exit 2; }
    exec "${bin}" "$@" ;;
```

- [ ] **Step 2: Update `libexec/lidar-help`**

Replace the help file content:

```bash
#!/usr/bin/env bash
cat <<'EOF'
Usage: lidar <subcommand> [options...]

Subcommands:
  run                    Download tiles, mosaic, derive shading, build tile pyramid
  list [<hex>]           List runs, or stream/page one run's log
  size <name|hex>        Show disk usage for a run's output files
  kill <hex|PID>         Stop a running pipeline (or --all)
  restart <hex>          Re-run one or more completed/failed runs
  help                   Show this help

Run `lidar <subcommand> --help` for per-subcommand details.
EOF
```

- [ ] **Step 3: Remove the systemd unit block from `lidar-kill --all`**

In `libexec/lidar-kill`, delete lines 97–105 (the `systemctl` block):

```bash
# Remove this block entirely:
# systemd lidar@*.service units
if command -v systemctl >/dev/null; then
  while IFS= read -r unit; do
    [[ -z "${unit}" ]] && continue
    echo "  STOP systemd unit ${unit}"
    systemctl --user stop "${unit}" 2>/dev/null || true
    killed=$((killed + 1))
  done < <(systemctl --user list-units --type=service --no-legend --plain \
           'lidar@*.service' 2>/dev/null | awk '{print $1}')
fi
```

- [ ] **Step 4: Delete the service files**

```bash
rm libexec/lidar-service-install libexec/lidar-service-uninstall systemd/lidar@.service
rmdir systemd 2>/dev/null || true
```

- [ ] **Step 5: Remove the service test from `tests/test_cli.bats`**

Delete the last test:

```bash
# Remove this test:
@test "lidar service install with no name exits 2" {
  run "${LIDAR}" service install
  [ "${status}" -eq 2 ]
}
```

- [ ] **Step 6: Run tests to verify no regressions**

```bash
bats tests/
```

Expected: all remaining tests pass.

- [ ] **Step 7: Commit**

```bash
git add -u
git commit -m "feat: remove systemd service integration

The systemd wrapper was redundant — every run already logs to a file
and the pgrp-TERM kill works correctly. Removes install/uninstall
subcommands, the unit template, and the systemd block in kill --all.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 2: Multi-positional inputs in `lidar run`

**Files:**
- Modify: `libexec/lidar-run`
- Modify: `tests/test_cli.bats`

**Goal:** Accept `lidar run a.txt b.txt https://...foo.tif` on the same invocation. After this step the combined URL stream still runs as one monolithic job (single project loop). Step 5 flips that.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_cli.bats`:

```bash
@test "lidar run with no positionals prints usage" {
  run "${LIDAR}" run
  [ "${status}" -ne 0 ]
}

@test "lidar run rejects unknown flag" {
  run "${LIDAR}" run --bogus "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unknown flag"* ]]
}
```

Run: `bats tests/test_cli.bats`
Expected: new tests PASS (the `no positionals` case already fails at the `[[ -z "${DOWNLOAD_LIST}" ]] && usage` guard; the unknown-flag test may already pass too — confirm, don't fix yet).

- [ ] **Step 2: Replace single DOWNLOAD_LIST with INPUTS array**

In `libexec/lidar-run`, change the variable declarations (lines 39–51) from:

```bash
DOWNLOAD_LIST=""
...
ORIG_ARGS=("$@")
```

to:

```bash
INPUTS=()
...
ORIG_ARGS=("$@")
```

- [ ] **Step 3: Update arg-parse to accumulate positionals**

Replace the `*` catch-all in the `while [[ $# -gt 0 ]]` loop (lines 66–69):

```bash
# Old:
    *)
      [[ -n "${DOWNLOAD_LIST}" ]] && { echo "Too many arguments" >&2; usage; }
      DOWNLOAD_LIST="$1"; shift ;;

# New:
    *)  INPUTS+=("$1"); shift ;;
```

- [ ] **Step 4: Update the "no input" guard (line 119)**

```bash
# Old:
[[ -z "${DOWNLOAD_LIST}" ]] && usage

# New:
[[ ${#INPUTS[@]} -eq 0 ]] && usage
```

- [ ] **Step 5: Update the `--background` re-exec block (lines 128–130)**

The block currently strips `-b`/`--background` from `ORIG_ARGS` and passes `CHILD_ARGS`. `ORIG_ARGS` still captures `"$@"` before any variable changes, so it still works. No change needed here for now — the `--background` re-exec block is removed entirely in Task 5.

- [ ] **Step 6: Build the combined URL file after sourcing libs (before check_deps_and_input)**

After the `source` lines (line 118) and after the `--background` block, add a step that combines all inputs into a single temp file. This replaces the single `DOWNLOAD_LIST` that was used before.

Find the dry-run block start (around line 200: `if [[ ${DRY_RUN} -eq 1 ]]; then`) and just before it, add:

```bash
# ─── Combine all inputs into one URL stream ──────────────────────────────────
# Each positional is either a local .txt file or an https:// URL.
# Remote list files are fetched here; bare .tif URLs are written directly.
_COMBINED_LIST=$(mktemp "${LIDAR_DIR}/.combined_XXXXXX.txt")
trap 'rm -f "${_COMBINED_LIST}"' EXIT

for _inp in "${INPUTS[@]}"; do
  if [[ "${_inp}" =~ ^https?://.*\.tif([?#]|$) ]]; then
    # Bare tile URL — add directly
    echo "${_inp}" >> "${_COMBINED_LIST}"
  elif [[ "${_inp}" =~ ^https?:// ]]; then
    # Remote list file — fetch into a temp file and append
    _fetched=$(mktemp "${LIDAR_DIR}/.fetch_XXXXXX.txt")
    echo "  Fetching: ${_inp}"
    curl -L --retry 5 --retry-all-errors --fail-with-body --max-time 120 \
      -o "${_fetched}.partial" "${_inp}" \
      || { echo "ERROR: failed to fetch ${_inp}" >&2; rm -f "${_fetched}.partial"; exit 1; }
    mv -f "${_fetched}.partial" "${_fetched}"
    cat "${_fetched}" >> "${_COMBINED_LIST}"
    rm -f "${_fetched}"
  else
    [[ -f "${_inp}" ]] || { echo "ERROR: File not found: ${_inp}" >&2; exit 1; }
    cat "${_inp}" >> "${_COMBINED_LIST}"
  fi
done
DOWNLOAD_LIST="${_COMBINED_LIST}"
```

This restores `DOWNLOAD_LIST` as a single file (so all downstream code is unchanged). The `trap 'rm -f'` on `_COMBINED_LIST` uses a separate trap — add it before the main `WORK_DIR` trap so it doesn't conflict.

**Note:** The `WORK_DIR` mktemp happens later (after dry-run). The combined list needs `LIDAR_DIR` which is set after `source common.sh`. Move the `WORK_DIR` mktemp UP to just after the `source` block (before the dry-run check) so we can use it. Alternatively, use `/tmp` for these early temp files. Using `LIDAR_DIR` directly (as above) is fine since common.sh is already sourced.

- [ ] **Step 7: Update dry-run section to mention multiple inputs**

In the dry-run echo block (around line 225), change:

```bash
echo "Tile list   : ${DOWNLOAD_LIST}"
```

to:

```bash
echo "Inputs      : ${INPUTS[*]}"
```

- [ ] **Step 8: Update help comment at top of lidar-run**

Change:

```
# Usage: lidar run [options] <downloadlist.txt|URL>
```

to:

```
# Usage: lidar run [options] <downloadlist.txt|URL> [<downloadlist.txt|URL>...]
```

And remove `--background` and `--name` from the option list comment (they'll be gone in Task 5; remove them now for cleanliness).

- [ ] **Step 9: Run tests**

```bash
bats tests/
```

Expected: all tests pass. The `no positionals` test passes (falls through to `[[ ${#INPUTS[@]} -eq 0 ]] && usage`).

- [ ] **Step 10: Commit**

```bash
git add -u
git commit -m "feat(run): accept multiple positional inputs

lidar run a.txt b.txt https://...foo.tif now works.
Inputs are combined into a single URL stream before processing.
Single-input invocations are unchanged.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 3: Add `gen_hex_id`, `PROJECTS_DIR`, `fanout_by_project` to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh`
- Modify: `tests/test_helpers.bats`

Code is dead until Task 5 wires it in. This task is purely additive.

- [ ] **Step 1: Write failing tests in `tests/test_helpers.bats`**

```bash
@test "gen_hex_id returns 6 hex chars" {
  result=$(gen_hex_id)
  [[ "${result}" =~ ^[0-9a-f]{6}$ ]]
}

@test "gen_hex_id returns different values on repeated calls" {
  a=$(gen_hex_id)
  b=$(gen_hex_id)
  c=$(gen_hex_id)
  # At least 2 of 3 should differ (probability of all-same is ~1/16M^2)
  [[ "${a}" != "${b}" || "${b}" != "${c}" ]]
}

@test "fanout_by_project groups by USGS project" {
  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "${WORK_DIR}"' EXIT
  result=$(printf '%s\n%s\n' \
    "https://prd-tnm.s3.amazonaws.com/Foo/Projects/AK_Test_2020/TIFF/a.tif" \
    "https://prd-tnm.s3.amazonaws.com/Foo/Projects/AK_Test_2020/TIFF/b.tif" \
    | fanout_by_project "")
  project=$(echo "${result}" | cut -f1)
  url_file=$(echo "${result}" | cut -f2)
  [ "${project}" = "AK_Test_2020" ]
  [ "$(wc -l < "${url_file}")" -eq 2 ]
}

@test "fanout_by_project uses fallback for non-project URLs" {
  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "${WORK_DIR}"' EXIT
  result=$(printf '%s\n' \
    "https://example.com/no/projects/tile.tif" \
    | fanout_by_project "_myfallback")
  project=$(echo "${result}" | cut -f1)
  [ "${project}" = "_myfallback" ]
}

@test "fanout_by_project drops non-project URLs when no fallback" {
  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "${WORK_DIR}"' EXIT
  result=$(printf '%s\n' \
    "https://example.com/no/projects/tile.tif" \
    | fanout_by_project "")
  [ -z "${result}" ]
}

@test "fanout_by_project splits two projects into separate entries" {
  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "${WORK_DIR}"' EXIT
  result=$(printf '%s\n%s\n' \
    "https://s3/Foo/Projects/Alpha_2020/TIFF/a.tif" \
    "https://s3/Foo/Projects/Beta_2021/TIFF/b.tif" \
    | fanout_by_project "")
  count=$(echo "${result}" | wc -l)
  [ "${count}" -eq 2 ]
  [[ "${result}" == *"Alpha_2020"* ]]
  [[ "${result}" == *"Beta_2021"* ]]
}
```

Run: `bats tests/test_helpers.bats`
Expected: new tests FAIL (functions don't exist yet).

- [ ] **Step 2: Add `gen_hex_id` and `PROJECTS_DIR` to `lib/common.sh`**

After the `EVENTS_FILE` line (line 23), add:

```bash
PROJECTS_DIR="${LIDAR_DIR}/projects"
```

After `gen_run_name` (line 117), add:

```bash
# Generate a unique 6-char lowercase hex run ID.
gen_hex_id() {
  printf '%02x%02x%02x' $((RANDOM & 255)) $((RANDOM & 255)) $((RANDOM & 255))
}
```

- [ ] **Step 3: Add `fanout_by_project` to `lib/common.sh`**

After `gen_hex_id`, add:

```bash
# Group a stream of tile URLs by USGS project.
# Reads URLs on stdin. Writes per-project temp files under WORK_DIR.
# Prints "project\turl_file" for each unique project (one per line).
# fallback: project name used for URLs that have no Projects/<X>/ segment.
#           Pass "" to silently drop those URLs.
fanout_by_project() {
  local fallback="$1"
  [[ -n "${WORK_DIR:-}" ]] || { echo "ERROR: WORK_DIR not set" >&2; return 1; }

  declare -A _fp_files=()

  while IFS= read -r _url; do
    [[ -z "${_url}" ]] && continue
    [[ "${_url}" == '#'* ]] && continue
    local _proj
    _proj=$(project_from_url "${_url}")
    if [[ -z "${_proj}" ]]; then
      [[ -n "${fallback}" ]] && _proj="${fallback}" || continue
    fi
    if [[ -z "${_fp_files[${_proj}]:-}" ]]; then
      _fp_files["${_proj}"]=$(mktemp "${WORK_DIR}/fanout_XXXXXX_${_proj}.urls")
    fi
    echo "${_url}" >> "${_fp_files[${_proj}]}"
  done

  local _p
  for _p in "${!_fp_files[@]}"; do
    printf '%s\t%s\n' "${_p}" "${_fp_files[${_p}]}"
  done
}
```

- [ ] **Step 4: Run tests**

```bash
bats tests/test_helpers.bats
```

Expected: all new tests pass.

- [ ] **Step 5: Run full test suite**

```bash
bats tests/
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/common.sh tests/test_helpers.bats
git commit -m "feat(common): add gen_hex_id, PROJECTS_DIR, fanout_by_project

Prepares for per-project fan-out. Code is dead until lidar-run
is wired in Task 5.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 4: Add `project` field to start events

**Files:**
- Modify: `lib/events.sh`
- Modify: `libexec/lidar-run` (caller)
- Modify: `tests/test_cli.bats`

This is additive — existing consumers (list_runs, resolve_run_id, resolve_input, strip_restart_flags) ignore unknown JSON fields.

- [ ] **Step 1: Write failing test**

Add to `tests/test_cli.bats`:

```bash
@test "events_emit_start writes project field" {
  source "${LIDAR_HOME}/lib/events.sh"
  events_emit_start "aabbcc" "" "TestProject"
  local row
  row=$(tail -1 "${GIS_DIR}/lidar/logs/runs.jsonl")
  [[ "${row}" == *'"project":"TestProject"'* ]]
}
```

Run: `bats tests/test_cli.bats`
Expected: FAIL (no project field yet).

- [ ] **Step 2: Update `events_emit_start` signature and output in `lib/events.sh`**

Replace the `events_emit_start` function (lines 14–28):

```bash
events_emit_start() {
  local id="$1" log="$2" project="$3"; shift 3
  mkdir -p "$(dirname "${EVENTS_FILE}")"
  local ts; ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local args_json="[" first=1 a
  for a in "$@"; do
    [[ ${first} -eq 1 ]] || args_json+=","
    args_json+="\"$(json_escape "${a}")\""
    first=0
  done
  args_json+="]"
  printf '{"id":"%s","event":"start","ts":"%s","pid":%d,"log":"%s","project":"%s","args":%s}\n' \
    "$(json_escape "${id}")" "${ts}" "$$" "$(json_escape "${log}")" \
    "$(json_escape "${project}")" "${args_json}" \
    >> "${EVENTS_FILE}"
}
```

- [ ] **Step 3: Update the caller in `libexec/lidar-run` (line 250)**

```bash
# Old:
events_emit_start "${NAME}" "${EVENT_LOG_PATH}" "${ORIG_ARGS[@]}"

# New (PROJECT comes from prescan; for now pass "" since fan-out is in Task 5):
events_emit_start "${NAME}" "${EVENT_LOG_PATH}" "" "${ORIG_ARGS[@]}"
```

- [ ] **Step 4: Run tests**

```bash
bats tests/
```

Expected: the `events_emit_start writes project field` test passes; no regressions.

- [ ] **Step 5: Commit**

```bash
git add lib/events.sh libexec/lidar-run
git commit -m "feat(events): add project field to start events

Backward-compatible — existing consumers ignore unknown JSON fields.
The project value is wired up properly in Task 5 (fan-out).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 5: Flip `lidar run` to fan-out (THE behavioral change)

**Files:**
- Modify: `libexec/lidar-run` (major)
- Modify: `lib/download.sh` (FANOUT_PROJECT fallback in prescan)
- Modify: `tests/test_cli.bats`

This is the single step that changes observable behavior. Everything before it was additive; everything after is cleanup.

### 5a: Add FANOUT_PROJECT fallback to `lib/download.sh`

- [ ] **Step 1: Add fallback to prescan in `lib/download.sh`**

In `prescan`, find the block that skips non-project URLs (around lines 98–101):

```bash
# Old:
    if [[ -z "${PROJECT}" ]]; then
      SKIPPED_NO_PROJECT=$((SKIPPED_NO_PROJECT + 1))
      continue
    fi

# New:
    if [[ -z "${PROJECT}" ]]; then
      if [[ -n "${FANOUT_PROJECT:-}" ]]; then
        PROJECT="${FANOUT_PROJECT}"
      else
        SKIPPED_NO_PROJECT=$((SKIPPED_NO_PROJECT + 1))
        continue
      fi
    fi
```

This is the only change to `lib/download.sh`. When a child runs prescan with `FANOUT_PROJECT` set, non-project URLs are bucketed under that name.

### 5b: Rewrite the fan-out logic in `libexec/lidar-run`

- [ ] **Step 2: Write failing tests for the new behavior**

Add to `tests/test_cli.bats`:

```bash
@test "lidar run --background flag rejected after fan-out" {
  run "${LIDAR}" run --background "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unknown flag"* ]]
}

@test "lidar run --name flag rejected after fan-out" {
  run "${LIDAR}" run --name foo "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unknown flag"* ]]
}

@test "lidar run --jobs requires a positive integer" {
  run "${LIDAR}" run --jobs 0 "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--jobs"* ]]
}

@test "lidar run --jobs flag parsed" {
  # Should reach dependency check, not fail at flag parse
  run bash -c "\"${LIDAR}\" run --jobs 2 --dry-run \"${FIXTURES}/one_tile.txt\" 2>&1 || true"
  [[ "${output}" != *"Unknown flag"* ]]
}
```

Run: `bats tests/test_cli.bats`
Expected: `--background`/`--name` tests FAIL (flags still accepted now), `--jobs` tests FAIL (flag doesn't exist yet).

- [ ] **Step 3: Rewrite `libexec/lidar-run` — argument parsing section**

Replace the entire argument parsing block (lines 39–119, up to the sources) with:

```bash
source "${LIDAR_HOME}/lib/strict.sh"

usage() {
  sed -n '3,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

SHADINGS_CSV="hillshade"
OUTPUTS_CSV=""
COG_CRS=""
COG_NO_REPROJECT=0
GIS_DIR_OVERRIDE=""
INPUTS=()
ALGORITHM=""
MULTIDIRECTIONAL=0
JOBS_OVERRIDE=""
DRY_RUN=0
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--shading)         SHADINGS_CSV="$2"; shift 2 ;;
    -a|--algorithm)       ALGORITHM="$2"; shift 2 ;;
    -m|--multidirectional) MULTIDIRECTIONAL=1; shift ;;
    -g|--gis-dir)         GIS_DIR_OVERRIDE="$2"; shift 2 ;;
    -o|--output)          OUTPUTS_CSV="$2"; shift 2 ;;
    --cog-crs)            COG_CRS="$2"; shift 2 ;;
    --cog-no-reproject)   COG_NO_REPROJECT=1; shift ;;
    -j|--jobs)            JOBS_OVERRIDE="$2"; shift 2 ;;
    -d|--dry-run)         DRY_RUN=1; shift ;;
    -h|--help)            usage 0 ;;
    -*)                   echo "Unknown flag: $1" >&2; usage ;;
    *)                    INPUTS+=("$1"); shift ;;
  esac
done
```

- [ ] **Step 4: Update the help comment at top of `lidar-run`**

Replace lines 3–30 with:

```bash
# `lidar run` — download USGS lidar tiles and produce KML/KMZ/COG outputs.
#
# Usage: lidar run [options] <list.txt|URL> [<list.txt|URL>...]
#
# Each positional is a path to a .txt tile list or a bare tile https:// URL.
# When the tile list spans multiple USGS projects, one independent run is
# dispatched per project. All runs execute concurrently (bounded by --jobs)
# and are detached; the command returns immediately after dispatch.
#
# Options:
#   -s, --shading LIST       comma-separated shadings (default: hillshade)
#                            Known: hillshade, slopeshade
#   -a, --algorithm ALG      hillshade algorithm: Horn (default) | ZevenbergenThorne
#   -m, --multidirectional   use gdaldem -multidirectional
#   -j, --jobs N             max concurrent project runs (default: auto)
#   -g, --gis-dir PATH       override GIS_DIR for this run
#   -o, --output OUTPUTS     comma-separated outputs (default: kml).
#                            Known: kml, kmz, cog.
#       --cog-crs EPSG:NNNN  reproject COG output to this CRS
#       --cog-no-reproject   keep source CRS even if geographic
#   -d, --dry-run            validate inputs and print resolved plan; exit 0
#   -h, --help               show this help
```

- [ ] **Step 5: Update COG / output validation section — no functional changes**

Keep lines 72–118 of the original as-is (they don't reference `NAME`, `DOWNLOAD_LIST`, or `BACKGROUND`).

- [ ] **Step 6: Replace the `--background` re-exec block and `NAME` generation**

Delete lines 121–193 of the original (the re-exec block + `NAME`/`OUT_DIR`/`COG_DIR` setup). Replace the entire section from after the source lines (after `source cog.sh`) through the check `[[ -z "${DOWNLOAD_LIST}" ]] && usage` with:

```bash
[[ ${#INPUTS[@]} -eq 0 ]] && usage

# ─── Validate --jobs ────────────────────────────────────────────────────────
if [[ -n "${JOBS_OVERRIDE}" ]]; then
  [[ "${JOBS_OVERRIDE}" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: --jobs must be a positive integer (got: ${JOBS_OVERRIDE})" >&2; exit 1
  }
fi

# ─── Parse + validate shadings ──────────────────────────────────────────────
IFS=',' read -r -a SHADINGS <<< "${SHADINGS_CSV}"
for s in "${SHADINGS[@]}"; do
  is_known_shading "${s}" || {
    echo "ERROR: unknown shading: ${s}" >&2
    echo "  Known: ${KNOWN_SHADINGS[*]}" >&2
    exit 1
  }
done

# ─── Apply hillshade tuning flags ────────────────────────────────────────────
if [[ -n "${ALGORITHM}" ]]; then
  case "${ALGORITHM}" in
    Horn|ZevenbergenThorne) HS_ALGORITHM="${ALGORITHM}" ;;
    *) echo "ERROR: --algorithm must be Horn or ZevenbergenThorne" >&2; exit 1 ;;
  esac
fi
[[ ${MULTIDIRECTIONAL} -eq 1 ]] && HS_MULTIDIRECTIONAL=1
```

(The shadings validation was previously after the `--background` block, lines 156–173.)

- [ ] **Step 7: Build combined URL stream, fanout, and dry-run support**

After the shadings validation, add:

```bash
# ─── Build combined URL stream ───────────────────────────────────────────────
WORK_DIR=$(mktemp -d "${LIDAR_DIR}/.work_XXXXXX")
trap 'rm -rf "${WORK_DIR}"' EXIT

_COMBINED="${WORK_DIR}/combined.urls"
for _inp in "${INPUTS[@]}"; do
  if [[ "${_inp}" =~ ^https?://.*\.tif([?#]|$) ]]; then
    echo "${_inp}" >> "${_COMBINED}"
  elif [[ "${_inp}" =~ ^https?:// ]]; then
    _fetched="${WORK_DIR}/fetch_$$.txt"
    curl -L --retry 5 --retry-all-errors --fail-with-body --max-time 120 \
      -o "${_fetched}.partial" "${_inp}" \
      || { echo "ERROR: failed to fetch ${_inp}" >&2; exit 1; }
    mv -f "${_fetched}.partial" "${_fetched}"
    grep -i '\.tif' "${_fetched}" | grep -v '^#' >> "${_COMBINED}" || true
  else
    [[ -f "${_inp}" ]] || { echo "ERROR: File not found: ${_inp}" >&2; exit 1; }
    grep -i '\.tif' "${_inp}" | grep -v '^#' >> "${_COMBINED}" || true
  fi
done

if [[ ! -s "${_COMBINED}" ]]; then
  echo "ERROR: No .tif URLs found in inputs: ${INPUTS[*]}" >&2
  exit 1
fi

# Determine fallback project name from first input's basename
_FALLBACK_PROJECT=""
_first_input="${INPUTS[0]}"
if [[ ! "${_first_input}" =~ ^https?:// ]]; then
  _FALLBACK_PROJECT="_$(basename "${_first_input}" .txt)"
fi

# Fan out by project
_FANOUT="${WORK_DIR}/fanout.tsv"
fanout_by_project "${_FALLBACK_PROJECT}" < "${_COMBINED}" > "${_FANOUT}"

if [[ ! -s "${_FANOUT}" ]]; then
  echo "ERROR: no URL groups found — are the URLs in USGS Projects/<name>/ format?" >&2
  exit 1
fi

# Read project/url_file pairs into arrays
mapfile -t _FANOUT_PROJECTS < <(cut -f1 "${_FANOUT}")
mapfile -t _FANOUT_URLFILES < <(cut -f2 "${_FANOUT}")
_N_PROJECTS="${#_FANOUT_PROJECTS[@]}"

# ─── --dry-run: print fan-out plan and exit ──────────────────────────────────
if [[ ${DRY_RUN} -eq 1 ]]; then
  OUTPUTS_PLAN=""
  [[ ${OUTPUT_KML} -eq 1 ]] && OUTPUTS_PLAN+="kml "
  [[ ${OUTPUT_KMZ} -eq 1 ]] && OUTPUTS_PLAN+="kmz "
  [[ ${OUTPUT_COG} -eq 1 ]] && OUTPUTS_PLAN+="cog "

  echo "=== DRY RUN PLAN ==="
  echo "Inputs      : ${INPUTS[*]}"
  echo "Projects    : ${_N_PROJECTS}"
  echo "Jobs        : ${JOBS_OVERRIDE:-auto}"
  echo "Shadings    : ${SHADINGS[*]}"
  echo "Algorithm   : ${HS_ALGORITHM} (multidirectional=${HS_MULTIDIRECTIONAL})"
  echo "Outputs     : ${OUTPUTS_PLAN% }"
  [[ ${OUTPUT_COG} -eq 1 && -n "${COG_CRS}" ]] && echo "COG CRS     : ${COG_CRS} (explicit)"
  [[ ${OUTPUT_COG} -eq 1 && ${COG_NO_REPROJECT} -eq 1 ]] && echo "COG CRS     : native (no-reproject)"
  [[ ${OUTPUT_COG} -eq 1 && -z "${COG_CRS}" && ${COG_NO_REPROJECT} -eq 0 ]] && echo "COG CRS     : auto (source CRS if projected; else UTM)"
  echo ""
  for (( _i=0; _i<_N_PROJECTS; _i++ )); do
    _proj="${_FANOUT_PROJECTS[_i]}"
    _cnt=$(grep -c '.' "${_FANOUT_URLFILES[_i]}" 2>/dev/null || echo 0)
    printf "  [%d/%d] %-50s  %d URL(s)\n" "$((_i+1))" "${_N_PROJECTS}" "${_proj}" "${_cnt}"
  done
  exit 0
fi
```

- [ ] **Step 8: Compute JOBS default and remove old lock/events setup**

After the dry-run block, add:

```bash
# ─── Compute job parallelism ─────────────────────────────────────────────────
if [[ -n "${JOBS_OVERRIDE}" ]]; then
  JOBS="${JOBS_OVERRIDE}"
else
  _ncpu=$(nproc)
  _ram_gb=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
  JOBS=$(( _ncpu / 2 ))
  (( _ram_gb / 2 < JOBS )) && JOBS=$(( _ram_gb / 2 ))
  (( _N_PROJECTS < JOBS )) && JOBS="${_N_PROJECTS}"
  (( JOBS < 1 )) && JOBS=1
fi

extra_deps=()
[[ ${OUTPUT_KMZ} -eq 1 ]] && extra_deps+=(zip)
[[ ${OUTPUT_COG} -eq 1 ]] && extra_deps+=(python3)
```

- [ ] **Step 9: Define `_run_one_project` function**

After the JOBS computation, define the per-project worker. This function captures all the flag variables from the parent scope (OUTPUT_KML, OUTPUT_KMZ, OUTPUT_COG, SHADINGS, HS_ALGORITHM, HS_MULTIDIRECTIONAL, COG_CRS, COG_NO_REPROJECT, extra_deps) via subshell inheritance.

```bash
# ─── Per-project pipeline ────────────────────────────────────────────────────
_run_one_project() {
  local _project="$1" _hex="$2" _url_file="$3"

  local _log_dir="${LIDAR_DIR}/logs"
  local _log="${_log_dir}/${_hex}.log"
  mkdir -p "${_log_dir}"

  # Redirect all output to this run's log file
  exec > "${_log}" 2>&1

  local _proj_work; _proj_work=$(mktemp -d "${LIDAR_DIR}/.work_XXXXXX")
  WORK_DIR="${_proj_work}"

  local _on_exit_called=0
  _on_project_exit() {
    [[ ${_on_exit_called} -eq 1 ]] && return
    _on_exit_called=1
    local _rc=$?
    events_emit_end "${_hex}" "${_rc}"
    rm -rf "${_proj_work}"
  }
  _on_project_signal() { exit "$(( 128 + $(kill -l "$1") ))"; }
  trap '_on_project_signal TERM' TERM
  trap '_on_project_signal INT'  INT
  trap '_on_project_signal HUP'  HUP
  trap _on_project_exit EXIT

  # ── RAM gate ────────────────────────────────────────────────────────────────
  local _mem_total_kb; _mem_total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  local _need_kb=$(( _mem_total_kb * GDAL_CACHE_PCT / 100 ))
  while (( $(awk '/MemAvailable/{print $2}' /proc/meminfo) < _need_kb )); do
    echo "Waiting for $(( _need_kb / 1024 )) MB headroom..."
    sleep 10
  done

  cleanup_old_logs 30

  # ── Steps 1–4: deps, prescan, dirs, download ────────────────────────────────
  LISTS_DIR="${WORK_DIR}/project_lists"
  mkdir -p "${LISTS_DIR}"

  # FANOUT_PROJECT tells prescan what bucket to use for non-Projects/ URLs
  export FANOUT_PROJECT="${_project}"

  check_deps_and_input "${_url_file}" "${extra_deps[@]+"${extra_deps[@]}"}"
  prescan
  make_dirs "${PROJECTS_DIR}/${_project}/${_hex}"
  download_tiles

  # ── Step 5: resolve downloaded tiles ────────────────────────────────────────
  echo "=========================================="
  echo "STEP 5: Resolving downloaded tiles"
  echo "=========================================="

  local _missing=0
  declare -A _project_ready=()
  local _ready_projects=()
  for _proj_name in "${PROJECT_NAMES[@]}"; do
    local _urls_f="${LISTS_DIR}/${_proj_name}.urls"
    local _list_f="${LISTS_DIR}/${_proj_name}.list"
    : > "${_list_f}"
    local _n=0
    while IFS= read -r _url; do
      [[ -z "${_url}" ]] && continue
      local _base="${_url##*/}"; _base="${_base%.tif}"
      local _tile="${DEM_DIR}/${_base}.tif"
      if [[ -f "${_tile}" ]]; then
        echo "${_tile}" >> "${_list_f}"
        _n=$((_n + 1))
      else
        _missing=$((_missing + 1))
      fi
    done < "${_urls_f}"
    _project_ready["${_proj_name}"]="${_n}"
    [[ ${_n} -gt 0 ]] && _ready_projects+=("${_proj_name}")
  done
  PROJECT_NAMES=("${_ready_projects[@]}")

  if [[ ${#PROJECT_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: no DEM tiles available (${_missing} missing)"
    exit 1
  fi

  echo "  Projects ready: ${#PROJECT_NAMES[@]}  (${_missing} missing tiles)"
  for _pn in "${PROJECT_NAMES[@]}"; do
    printf "    %-60s %5d tiles\n" "${_pn}" "${_project_ready[${_pn}]}"
  done

  # ── Steps 6–8: shading + KML + COG + KMZ ────────────────────────────────────
  local _run_out="${PROJECTS_DIR}/${_project}/${_hex}"
  local _out_dir="${_run_out}/kml"
  local _cog_dir="${_run_out}/cog"
  local _kmz_dir="${_run_out}/kmz"

  echo "=========================================="
  if [[ ${OUTPUT_KML} -eq 1 ]]; then
    echo "STEP 6: Deriving shadings + KML tile pyramids"
  else
    echo "STEP 6: Deriving shadings (KML pyramid skipped)"
  fi
  echo "=========================================="

  [[ ${OUTPUT_KML} -eq 1 ]] && mkdir -p "${_out_dir}"

  declare -A _dem_vrt=()
  for _pn in "${PROJECT_NAMES[@]}"; do
    local _vrt="${WORK_DIR}/${_pn}_dem.vrt"
    build_dem_vrt "${LISTS_DIR}/${_pn}.list" "${_vrt}"
    _dem_vrt["${_pn}"]="${_vrt}"
  done

  for _shading in "${SHADINGS[@]}"; do
    [[ ${OUTPUT_KML} -eq 1 ]] && mkdir -p "${_out_dir}/${_shading}"

    for _pn in "${PROJECT_NAMES[@]}"; do
      local _shade_tif="${WORK_DIR}/${_shading}_${_pn}.tif"

      echo "------------------------------------------"
      echo "${_shading} / ${_pn}  (${PROJECT_COUNT[${_pn}]} tiles)"
      echo "------------------------------------------"

      echo "  Deriving ${_shading}..."
      derive_shading "${_shading}" "${_dem_vrt[${_pn}]}" "${_shade_tif}"

      if [[ ${OUTPUT_KML} -eq 1 ]]; then
        local _proj_out="${_out_dir}/${_shading}/${_pn}"
        local _wgs84_tif; _wgs84_tif=$(mktemp --suffix=_wgs84.tif)
        mkdir -p "${_proj_out}"

        echo "  Reprojecting to WGS84..."
        reproject_to_wgs84 "${_shade_tif}" "${_wgs84_tif}"

        echo "  Building tile pyramid..."
        { read -r _max_zoom; read -r _lk_lon _lk_lat _lk_range; } \
          < <(compute_zoom_and_lookat "${_wgs84_tif}") || true
        echo "  Zoom range: 0-${_max_zoom}"
        "${GDAL[@]}" raster tile \
          --tiling-scheme WorldCRS84Quad \
          --kml \
          --webviewer none \
          --min-zoom 0 \
          --max-zoom "${_max_zoom}" \
          -r cubic \
          --overview-resampling cubic \
          --skip-blank \
          --title "${_pn}" \
          -j ALL_CPUS \
          "${_wgs84_tif}" "${_proj_out}"

        if [[ -f "${_proj_out}/doc.kml" ]]; then
          if [[ -n "${_lk_lon:-}" ]]; then
            inject_lookat "${_proj_out}/doc.kml" "${_lk_lon}" "${_lk_lat}" "${_lk_range}"
          fi
          ensure_root_networklink "${_proj_out}/doc.kml" "${_proj_out}"
        fi

        rm -f "${_wgs84_tif}"
      fi

      [[ ${OUTPUT_COG} -eq 1 ]] || rm -f "${_shade_tif}"
    done
  done

  # Step 7: COG
  local _cog_paths=()
  if [[ ${OUTPUT_COG} -eq 1 ]]; then
    echo "=========================================="
    echo "STEP 7: Packaging COG"
    echo "=========================================="
    mkdir -p "${_cog_dir}"
    declare -A _proj_cog_crs=()
    local _cog_crs_summary=""

    for _pn in "${PROJECT_NAMES[@]}"; do
      local _target_crs; _target_crs=$(cog_resolve_crs "${_dem_vrt[${_pn}]}")
      _proj_cog_crs["${_pn}"]="${_target_crs}"
      local _dem_out="${_cog_dir}/${_pn}_dem.tif"
      echo "  ${_pn}/dem → ${_target_crs}"
      build_cog_dem "${_dem_vrt[${_pn}]}" "${_dem_out}" "${_target_crs}"
      _cog_paths+=("${_dem_out}")
      _cog_crs_summary+="${_pn}=${_target_crs} "
    done

    for _shading in "${SHADINGS[@]}"; do
      for _pn in "${PROJECT_NAMES[@]}"; do
        local _shade_tif="${WORK_DIR}/${_shading}_${_pn}.tif"
        local _shade_out="${_cog_dir}/${_shading}__${_pn}.tif"
        local _target_crs="${_proj_cog_crs[${_pn}]}"
        echo "  ${_shading}/${_pn} → ${_target_crs}"
        build_cog_shade "${_shade_tif}" "${_shade_out}" "${_target_crs}"
        _cog_paths+=("${_shade_out}")
      done
    done

    write_cog_readme "${_cog_dir}" "${_cog_crs_summary% }"
  fi

  # Step 8: KMZ
  local _kmz_paths=()
  if [[ ${OUTPUT_KMZ} -eq 1 ]]; then
    echo "=========================================="
    echo "STEP 8: Packaging KMZ"
    echo "=========================================="
    mkdir -p "${_kmz_dir}"
    for _shading in "${SHADINGS[@]}"; do
      for _pn in "${PROJECT_NAMES[@]}"; do
        local _src="${_out_dir}/${_shading}/${_pn}"
        local _kmz_out="${_kmz_dir}/${_shading}__${_pn}.kmz"
        package_kmz "${_src}" "${_kmz_out}"
        echo "  ${_shading}/${_pn}: ${_kmz_out} ($(human_bytes "$(stat -c %s "${_kmz_out}")"))"
        _kmz_paths+=("${_kmz_out}")
      done
    done
  fi

  echo "=========================================="
  echo "ALL DONE  [${_hex}]  ${_project}"
  echo "=========================================="
  [[ ${OUTPUT_KML} -eq 1 ]] && echo "KML : ${_out_dir}/"
  [[ ${#_kmz_paths[@]} -gt 0 ]] && echo "KMZ : ${_kmz_dir}/"
  [[ ${#_cog_paths[@]} -gt 0 ]] && echo "COG : ${_cog_dir}/"
  echo "=========================================="
}
```

- [ ] **Step 10: Add fan-out dispatch to `libexec/lidar-run` (replacing the old pipeline body)**

Replace everything from the old `cleanup_old_logs` call through the end of the file with:

```bash
# ─── Generate hex IDs, emit start events, dispatch ───────────────────────────
mkdir -p "${LIDAR_DIR}/logs"

declare -a _HEXES=()
for (( _i=0; _i<_N_PROJECTS; _i++ )); do
  _hex=$(gen_hex_id)
  _HEXES+=("${_hex}")
  _log="${LIDAR_DIR}/logs/${_hex}.log"
  events_emit_start "${_hex}" "${_log}" "${_FANOUT_PROJECTS[_i]}" "${INPUTS[@]}"
done

echo "Dispatching ${_N_PROJECTS} run(s) (jobs=${JOBS})..."
for (( _i=0; _i<_N_PROJECTS; _i++ )); do
  printf "  [%d/%d] %s  →  %s\n" \
    "$((_i+1))" "${_N_PROJECTS}" \
    "${_FANOUT_PROJECTS[_i]}" "${_HEXES[_i]}"
done

# Supervisor subshell: manages concurrency and runs each project.
# Exported via subshell fork — all functions and variables are inherited.
(
  _active=0
  for (( _i=0; _i<_N_PROJECTS; _i++ )); do
    _run_one_project \
      "${_FANOUT_PROJECTS[_i]}" \
      "${_HEXES[_i]}" \
      "${_FANOUT_URLFILES[_i]}" &
    _active=$((_active + 1))
    if (( _active >= JOBS )); then
      wait -n 2>/dev/null || true
      _active=$((_active - 1))
    fi
  done
  wait
) &
disown

echo "  Log(s) : ${LIDAR_DIR}/logs/"
echo "  Track  : lidar list"
```

- [ ] **Step 11: Run the flag-parsing tests**

```bash
bats tests/test_cli.bats
```

Expected: `--background` rejected, `--name` rejected, `--jobs 0` rejected, `--jobs 2 --dry-run` accepted.

- [ ] **Step 12: Manual dry-run smoke test**

```bash
export GIS_DIR=/tmp/lidar_smoke_$$
mkdir -p "${GIS_DIR}/lidar/logs"
./lidar run --dry-run tests/fixtures/one_tile.txt
```

Expected: prints `=== DRY RUN PLAN ===` with `Projects: 0` (one_tile.txt has a USGS URL with a project) or `Projects: 1`. No crash.

- [ ] **Step 13: Run full test suite**

```bash
bats tests/
```

Expected: all tests pass.

- [ ] **Step 14: Commit**

```bash
git add libexec/lidar-run lib/download.sh tests/test_cli.bats
git commit -m "feat(run): fan-out per-project; detached dispatch; drop --background/--name

One invocation against an N-project tile list now produces N independent
runs. Parent emits start events and returns immediately. Children run
concurrently under a wait -n semaphore bounded by --jobs.

Output paths move to \${PROJECTS_DIR}/\${project}/\${hex}/{kml,cog,kmz}/.
--background and --name are removed; every run is automatically detached.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 6: Simplify events, resolve_input, restart, and kill

**Files:**
- Modify: `lib/events.sh` (replace args→urls, delete strip_restart_flags, add project to list_runs)
- Modify: `lib/events.sh` (update resolve_run_id for bare-hex IDs)
- Modify: `libexec/lidar-kill` (remove stale references)
- Modify: `libexec/lidar-size` (resolve_input uses .urls now)

### 6a: Update events.sh

- [ ] **Step 1: Replace `"args"` with `"urls"` in `events_emit_start`**

In `lib/events.sh`, change the `printf` in `events_emit_start`:

```bash
# Old key:
  printf '{"id":"%s","event":"start","ts":"%s","pid":%d,"log":"%s","project":"%s","args":%s}\n' \

# New key:
  printf '{"id":"%s","event":"start","ts":"%s","pid":%d,"log":"%s","project":"%s","urls":%s}\n' \
```

Also rename the local variable `args_json` → `urls_json` (two occurrences) for clarity.

- [ ] **Step 2: Update `resolve_run_id` for bare hex IDs**

In `lib/events.sh`, replace the jq inside `resolve_run_id` (lines 59–62):

```bash
# Old:
  matches=$(jq -rs --arg q "${query}" '
    [ .[] | select(.event=="start") | .id ] | unique
    | .[] | select(. == $q or endswith("_" + $q))
  ' "${EVENTS_FILE}")

# New (bare hex — support exact match or prefix match):
  matches=$(jq -rs --arg q "${query}" '
    [ .[] | select(.event=="start") | .id ] | unique
    | .[] | select(. == $q or startswith($q))
  ' "${EVENTS_FILE}")
```

- [ ] **Step 3: Update `resolve_input` to read `.urls[0]` instead of `.args`**

In `lib/events.sh`, replace the `INPUT_TILE_LIST` assignment inside `resolve_input` (lines 106–110):

```bash
# Old:
    INPUT_TILE_LIST=$(jq -rs --arg id "${id}" '
      .[] | select(.id == $id and .event == "start") | .args
      | map(select(startswith("-") | not)) | first // ""
    ' "${EVENTS_FILE}" 2>/dev/null || echo "")

# New:
    INPUT_TILE_LIST=$(jq -rs --arg id "${id}" '
      .[] | select(.id == $id and .event == "start") | .urls[0] // ""
    ' "${EVENTS_FILE}" 2>/dev/null || echo "")
```

- [ ] **Step 4: Delete `strip_restart_flags` from `lib/events.sh`**

Delete the entire `strip_restart_flags` function (lines 118–158).

- [ ] **Step 5: Update `list_runs` in `lib/events.sh` to show project column and use hex IDs**

Replace the `list_runs` function's jq query (lines 177–201) and the rendering loop:

```bash
list_runs() {
  command -v jq >/dev/null || {
    echo "ERROR: list_runs requires jq" >&2; exit 1
  }
  if [[ ! -f "${EVENTS_FILE}" ]]; then
    echo "(no runs yet)"; return
  fi

  local rows
  rows=$(jq -s -r '
    group_by(.id) | map(
      (map(select(.event=="start"))[0]) as $s
      | .[-1] as $last
      | {
          id:       ($s.id // $last.id),
          project:  ($s.project // ""),
          started:  ($s.ts // ""),
          ended:    (if $last.event=="end" then $last.ts else "" end),
          pid:      ($s.pid // 0),
          log:      ($s.log // ""),
          exit:     (if $last.event=="end" then $last.exit else null end),
          last_event: $last.event,
          duration_sec: (
            if (if $last.event=="end" then $last.ts else "" end) != "" then
              (((if $last.event=="end" then $last.ts else "" end) | fromdate) - ($s.ts | fromdate))
            else
              ((now | floor) - ($s.ts | fromdate))
            end
            | if . < 0 then 0 else . end
          )
        }
    ) | sort_by(.started) | reverse
    | .[] | [.id, .project, .started, .ended, (.pid|tostring), .log,
             (.exit // "" | tostring), .last_event, (.duration_sec|tostring)] | join("")
  ' "${EVENTS_FILE}")

  local C_RESET="" C_OK="" C_FAIL="" C_RUN="" C_CRASH=""
  if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_FAIL=$'\033[31m'
    C_RUN=$'\033[33m'; C_CRASH=$'\033[35m'
  fi

  printf "%-8s  %-6s  %-19s  %9s  %-44s\n" "STATUS" "HEX" "STARTED" "DURATION" "PROJECT"
  while IFS=$'\x1f' read -r id project started ended pid log exit_code last_event duration_sec; do
    [[ -z "${id}" ]] && continue
    local status
    if [[ "${last_event}" == "end" ]]; then
      [[ "${exit_code}" == "0" ]] && status="success" || status="failed"
    else
      if [[ "${pid}" -gt 0 ]] && kill -0 "${pid}" 2>/dev/null; then
        status="running"
      else
        status="crashed"
      fi
    fi

    local sym color
    case "${status}" in
      success) sym="✓ ok";    color="${C_OK}" ;;
      failed)  sym="✗ fail";  color="${C_FAIL}" ;;
      running) sym="⏱ run";   color="${C_RUN}" ;;
      crashed) sym="⊘ crash"; color="${C_CRASH}" ;;
      *)       sym="${status}"; color="" ;;
    esac

    local started_h="${started/T/ }"; started_h="${started_h%Z}"
    local dur_h; dur_h=$(human_duration "${duration_sec}")
    printf "${color}%-8s${C_RESET}  %-6s  %-19s  %9s  %-44s\n" \
      "${sym}" "${id}" "${started_h}" "${dur_h}" "${project}"
  done <<< "${rows}"
}
```

- [ ] **Step 6: Run tests**

```bash
bats tests/
```

Expected: all pass. (The `events_emit_start writes project field` test may need updating since the field name in the JSON didn't change — just the key `args` → `urls`.)

- [ ] **Step 7: Commit events changes**

```bash
git add lib/events.sh
git commit -m "refactor(events): args→urls, bare-hex resolve, strip_restart_flags deleted

list_runs gains project column and hex as the primary identifier.
resolve_input reads .urls[0] instead of parsing .args.
strip_restart_flags is dead code after fan-out; removed.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 7: Rename `lidar-log` → `lidar-list`; `lidar-rerun` → `lidar-restart`

**Files:**
- Delete: `libexec/lidar-log`
- Create: `libexec/lidar-list`
- Delete: `libexec/lidar-rerun`
- Create: `libexec/lidar-restart`
- Modify: `lidar` (dispatcher — if needed; the `lidar-<sub>` pattern auto-routes)
- Modify: `tests/test_cli.bats`

### 7a: Create `libexec/lidar-list`

The new `lidar list` merges the old `lidar log` table-display path (via `list_runs`) with direct log access. **The fzf chooser and tmux pane code are removed entirely.**

- [ ] **Step 1: Write tests for lidar-list**

Add to `tests/test_cli.bats`:

```bash
@test "lidar list with no args prints table header" {
  run "${LIDAR}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"STATUS"* || "${output}" == *"no runs yet"* ]]
}

@test "lidar list --help exits 0 and shows usage" {
  run "${LIDAR}" list --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"lidar list"* ]]
}
```

Run: `bats tests/test_cli.bats`
Expected: FAIL (lidar-list doesn't exist yet).

- [ ] **Step 2: Create `libexec/lidar-list`**

```bash
#!/usr/bin/env bash
# `lidar list` — list runs or stream/page a single run's log.
#
# Usage: lidar list [options] [<hex>]
#
# With no argument: print the run table (newest first).
# With a hex argument: tail (running) or page (done) that run's log.
#
# Options:
#   -n, --lines N        show last N lines (default: all)
#   --no-follow          use pager even for running logs
#   --pager CMD          pager for completed logs (default: less)
#   --gis-dir PATH       override GIS_DIR
#   -h, --help           show this help

source "${LIDAR_HOME}/lib/strict.sh"

usage() { sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

LINES=""
GIS_DIR_OVERRIDE=""
TARGET=""
NO_FOLLOW=0
PAGER_CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--lines)    LINES="$2"; shift 2 ;;
    --no-follow)   NO_FOLLOW=1; shift ;;
    --pager)       PAGER_CMD="$2"; shift 2 ;;
    --gis-dir)     GIS_DIR_OVERRIDE="$2"; shift 2 ;;
    -h|--help)     usage 0 ;;
    -*)            echo "Unknown flag: $1" >&2; usage ;;
    *)             [[ -n "${TARGET}" ]] && { echo "Too many arguments" >&2; usage; }
                   TARGET="$1"; shift ;;
  esac
done

[[ -n "${GIS_DIR_OVERRIDE}" ]] && export GIS_DIR="${GIS_DIR_OVERRIDE}"
source "${LIDAR_HOME}/lib/common.sh"
source "${LIDAR_HOME}/lib/events.sh"

_get_pager() { printf '%s' "${PAGER_CMD:-${LIDAR_PAGER:-${PAGER:-less}}}"; }

_exec_pager() {
  local log="$1"
  local pager; pager=$(_get_pager)
  if [[ "${pager}" == "less" ]]; then
    if [[ -n "${LINES}" ]]; then
      local total; total=$(wc -l < "${log}")
      local start=$(( total - LINES + 1 ))
      (( start < 1 )) && start=1
      exec less +"${start}g" "${log}"
    else
      exec less +G "${log}"
    fi
  else
    read -ra _pw <<< "${pager}"
    exec "${_pw[@]}" "${log}"
  fi
}

# ─── No argument: print the run table ────────────────────────────────────────
if [[ -z "${TARGET}" ]]; then
  list_runs
  exit 0
fi

# ─── Hex argument: show that run's log ───────────────────────────────────────
RUN_ID=$(resolve_run_id "${TARGET}") || exit 1

# Resolve log path from events
LOG_PATH=$(jq -rs --arg id "${RUN_ID}" '
  .[] | select(.id == $id and .event == "start") | .log // ""
' "${EVENTS_FILE}" 2>/dev/null || echo "")

if [[ -z "${LOG_PATH}" || "${LOG_PATH}" == "null" || ! -f "${LOG_PATH}" ]]; then
  LOG_PATH="${LIDAR_DIR}/logs/${RUN_ID}.log"
fi

if [[ ! -f "${LOG_PATH}" ]]; then
  echo "ERROR: log file not found for '${TARGET}'" >&2
  exit 1
fi

# Check if the run is still in progress
PID=$(jq -rs --arg id "${RUN_ID}" '
  .[] | select(.id == $id and .event == "start") | .pid // 0
' "${EVENTS_FILE}" 2>/dev/null || echo 0)
DONE=$(jq -rs --arg id "${RUN_ID}" '
  [ .[] | select(.id == $id and .event == "end") ] | length > 0
' "${EVENTS_FILE}" 2>/dev/null || echo "false")

RUNNING=0
if [[ "${DONE}" == "false" && -n "${PID}" && "${PID}" != "0" ]]; then
  kill -0 "${PID}" 2>/dev/null && RUNNING=1 || true
fi

if [[ ${RUNNING} -eq 1 && ${NO_FOLLOW} -eq 0 ]]; then
  _tf=(-F)
  [[ -n "${LINES}" ]] && _tf=(-n "${LINES}" -F)
  exec tail "${_tf[@]}" "${LOG_PATH}"
else
  if [[ -t 1 ]]; then
    _exec_pager "${LOG_PATH}"
  else
    [[ -n "${LINES}" ]] && exec tail -n "${LINES}" "${LOG_PATH}" || exec cat "${LOG_PATH}"
  fi
fi
```

```bash
chmod +x libexec/lidar-list
```

- [ ] **Step 3: Delete `libexec/lidar-log`**

```bash
rm libexec/lidar-log
```

- [ ] **Step 4: Run tests**

```bash
bats tests/test_cli.bats
```

Expected: `lidar list` tests pass.

### 7b: Create `libexec/lidar-restart`

- [ ] **Step 5: Write tests for lidar-restart**

Add to `tests/test_cli.bats`:

```bash
@test "lidar restart with no args exits non-zero" {
  run "${LIDAR}" restart
  [ "${status}" -ne 0 ]
}

@test "lidar restart --help exits 0" {
  run "${LIDAR}" restart --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"lidar restart"* ]]
}

@test "lidar restart unknown hex exits non-zero" {
  rm -f "${GIS_DIR}/lidar/logs/runs.jsonl"
  run "${LIDAR}" restart aabbcc
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no run"* || "${output}" == *"no runs"* ]]
}
```

Run: `bats tests/test_cli.bats`
Expected: FAIL (lidar-restart doesn't exist yet).

- [ ] **Step 6: Create `libexec/lidar-restart`**

```bash
#!/usr/bin/env bash
# `lidar restart` — re-run completed or failed runs.
#
# Usage: lidar restart [options] <hex> [<hex>...]
#
# Looks up the original input URLs from the events index and re-dispatches
# them with `lidar run`. If the run is still alive it is killed first.
#
# Options:
#   --gis-dir PATH   override GIS_DIR
#   -h, --help       show this help

source "${LIDAR_HOME}/lib/strict.sh"

usage() { sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

TARGETS=()
GIS_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gis-dir)  GIS_DIR_OVERRIDE="$2"; shift 2 ;;
    -h|--help)  usage 0 ;;
    -*)         echo "Unknown flag: $1" >&2; usage ;;
    *)          TARGETS+=("$1"); shift ;;
  esac
done

[[ ${#TARGETS[@]} -eq 0 ]] && usage 2

[[ -n "${GIS_DIR_OVERRIDE}" ]] && export GIS_DIR="${GIS_DIR_OVERRIDE}"
source "${LIDAR_HOME}/lib/common.sh"
source "${LIDAR_HOME}/lib/events.sh"
source "${LIDAR_HOME}/lib/process.sh"

for target in "${TARGETS[@]}"; do
  echo "=== ${target} ==="

  run_id=$(resolve_run_id "${target}") || exit 1

  pid=$(live_pid_for "${run_id}")
  if [[ -n "${pid}" ]]; then
    echo "  Killing ${run_id} (pid=${pid})..."
    kill_target "${pid}" "PID ${pid} (${run_id})"
    deadline=$(( $(date +%s) + 30 ))
    while kill -0 "${pid}" 2>/dev/null; do
      if [[ $(date +%s) -ge ${deadline} ]]; then
        echo "ERROR: ${run_id} still alive after 30s — aborting restart" >&2
        exit 1
      fi
      sleep 0.5
    done
    echo "  Confirmed dead."
  else
    echo "  Not running — skipping kill."
  fi

  mapfile -t restart_urls < <(jq -rs --arg id "${run_id}" '
    .[] | select(.id == $id and .event == "start") | .urls // [] | .[]
  ' "${EVENTS_FILE}")

  if [[ ${#restart_urls[@]} -eq 0 ]]; then
    echo "ERROR: no URLs recorded for ${run_id}" >&2
    exit 1
  fi

  [[ -n "${GIS_DIR_OVERRIDE}" ]] && _gis_args=("--gis-dir" "${GIS_DIR_OVERRIDE}") || _gis_args=()
  echo "  Restarting: lidar run ${restart_urls[*]}"
  "${LIDAR_HOME}/lidar" run "${_gis_args[@]+"${_gis_args[@]}"}" "${restart_urls[@]}"
done
```

```bash
chmod +x libexec/lidar-restart
```

- [ ] **Step 7: Delete `libexec/lidar-rerun`**

```bash
rm libexec/lidar-rerun
```

- [ ] **Step 8: Update `lidar` dispatcher to remove the `list` special-case (if any)**

The dispatcher already does `exec "${HERE}/libexec/lidar-${sub}"` for all subcommands, so `lidar list` → `libexec/lidar-list` and `lidar restart` → `libexec/lidar-restart` just work. Verify nothing in `lidar` refers to `lidar-log` or `lidar-rerun`.

- [ ] **Step 9: Run full tests**

```bash
bats tests/
```

Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add libexec/lidar-list libexec/lidar-restart
git rm libexec/lidar-log libexec/lidar-rerun
git commit -m "feat: rename log→list, rerun→restart; strip fzf/tmux from list

lidar list [<hex>] — table or single log, no fzf or tmux.
lidar restart <hex> — re-runs using stored .urls; kills first if alive.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 8: Tests, help text, README

**Files:**
- Modify: `tests/test_cli.bats` (comprehensive fan-out coverage)
- Modify: `libexec/lidar-help`
- Modify: `README.md`

- [ ] **Step 1: Add fan-out coverage in `tests/test_cli.bats`**

Add:

```bash
@test "lidar run accepts two positional files" {
  run bash -c "\"${LIDAR}\" run \"${FIXTURES}/one_tile.txt\" \"${FIXTURES}/one_tile.txt\" --dry-run 2>&1 || true"
  [[ "${output}" != *"Unknown flag"* ]]
  [[ "${output}" != *"Too many"* ]]
}

@test "lidar run --dry-run shows Projects count" {
  run bash -c "
    export GIS_DIR=\"${GIS_DIR}\"
    export LIDAR_HOME=\"${LIDAR_HOME}\"
    \"${LIDAR}\" run --dry-run \"${FIXTURES}/one_tile.txt\" 2>&1 || true
  "
  # Dry-run prints the plan header; flatpak absence is fine
  :
}

@test "lidar run --jobs 0 is rejected" {
  run "${LIDAR}" run --jobs 0 "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--jobs"* ]]
}

@test "lidar run --jobs 3 is accepted (reaches downstream)" {
  run bash -c "\"${LIDAR}\" run --jobs 3 --dry-run \"${FIXTURES}/one_tile.txt\" 2>&1 || true"
  [[ "${output}" != *"Unknown flag"* ]]
  [[ "${output}" != *"--jobs must be"* ]]
}

@test "lidar list subcommand exists and exits 0" {
  run "${LIDAR}" list
  [ "${status}" -eq 0 ]
}

@test "lidar restart with no args exits 2" {
  run "${LIDAR}" restart
  [ "${status}" -eq 2 ]
}

@test "lidar log subcommand is gone" {
  run "${LIDAR}" log
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown subcommand"* ]]
}

@test "lidar rerun subcommand is gone" {
  run "${LIDAR}" rerun
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown subcommand"* ]]
}

@test "lidar service subcommand is gone" {
  run "${LIDAR}" service install
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown subcommand"* ]]
}
```

- [ ] **Step 2: Update `libexec/lidar-help`** (already done in Task 1; verify it's current)

Confirm the help shows `list`, `restart`, no `log`/`rerun`/`service`.

- [ ] **Step 3: Update `README.md`**

In the usage section, update the subcommand table and the output path documentation:

- Replace `lidar log`/`lidar rerun`/`lidar service` entries with `lidar list`/`lidar restart`
- Document the new output layout:
  ```
  ${GIS_DIR}/lidar/projects/<project>/<hex>/kml/   # KML super-overlay
  ${GIS_DIR}/lidar/projects/<project>/<hex>/cog/   # Cloud-Optimized GeoTIFFs
  ${GIS_DIR}/lidar/projects/<project>/<hex>/kmz/   # KMZ archives
  ${GIS_DIR}/lidar/logs/<hex>.log                  # Per-run log
  ```
- Note that runs are always detached (no `--background` needed)
- Note `--jobs N` for concurrency control

- [ ] **Step 4: Run full test suite**

```bash
bats tests/
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/test_cli.bats libexec/lidar-help README.md
git commit -m "test+docs: fan-out coverage, updated help and README

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Self-Review Checklist

### Spec coverage

| Spec requirement | Covered by |
|---|---|
| Remove systemd integration | Task 1 |
| Accept multiple positionals | Task 2 |
| `fanout_by_project` + `PROJECTS_DIR` | Task 3 |
| `gen_hex_id` | Task 3 |
| `project` field in start events | Task 4 |
| Drop `--background`/`--name` | Task 5 |
| Drop lock file | Task 5 |
| Drop `gen_run_name` + duplicate-name check | Task 5 |
| `_run_one_project` per-project worker | Task 5 |
| `--jobs N` flag with auto default | Task 5 |
| Output paths → `projects/<proj>/<hex>/` | Task 5 |
| FANOUT_PROJECT fallback for non-project URLs | Task 5 (download.sh) |
| `args` → `urls` in events | Task 6 |
| Delete `strip_restart_flags` | Task 6 |
| `list_runs` gains project column | Task 6 |
| `resolve_run_id` for bare hex | Task 6 |
| `lidar-log` → `lidar-list` (fzf/tmux stripped) | Task 7 |
| `lidar-rerun` → `lidar-restart` | Task 7 |
| `lidar restart` reads `.urls` from event | Task 7 |
| Tests, help, README | Task 8 |
| Verification scenarios (manual) | end-to-end smoke tests in Tasks 5, 8 |

### Verification scenarios (manual, post-Task 5)

1. `lidar run ~/Downloads/downloadlist\(10\).txt` — 5-project list → 5 `lidar list` rows, 5 log files, 5 output trees
2. `lidar run ~/Downloads/downloadlist\(14\).txt` — 1-project list → 1 row
3. `lidar run a.txt b.txt https://...foo.tif` — multi-input combination
4. `lidar run ~/Downloads/downloadlist\(11\).txt` — non-Projects URL → `_downloadlist(11)` bucket
5. `lidar run /dev/null` or a file with no .tif URLs → `ERROR: No .tif URLs`
6. `lidar kill <hex>` mid-run; semaphore advances next queued child; `lidar restart <hex>` re-runs it
7. `bats tests/` full pass

### Known gaps / edge cases to handle during implementation

- **`lidar-size`** uses `resolve_input` which reads `.urls[0]` (updated in Task 6). After Task 6 it should work automatically for hex lookups.
- **`WORK_DIR` race**: the parent's `WORK_DIR` (set up in Task 5 for the combined URL stream and fanout) is cleaned up when the parent exits (EXIT trap). The child's URL files (`_FANOUT_URLFILES[_i]`) live inside that WORK_DIR. The parent must NOT clean up WORK_DIR before the supervisor subshell has read all the url files. Solution: the supervisor subshell reads all url files before the parent's EXIT trap fires, since the parent waits for the `&` to start and then calls `disown` + exits — by that point the supervisor has already made its `_run_one_project` calls with the file paths. However, the children are forked *as subshells*, so they have their own copies of the url file contents in memory. **Actually, since the url files live in WORK_DIR and the parent's EXIT trap removes WORK_DIR, the children must copy the url file path OR the parent must keep WORK_DIR alive.** The clean fix: in `_run_one_project`, copy the url_file into the child's own WORK_DIR at the start.

  Add to start of `_run_one_project`:
  ```bash
  # Copy url_file into this child's WORK_DIR so parent cleanup doesn't affect us
  local _my_urls="${_proj_work}/input.urls"
  cp "${_url_file}" "${_my_urls}"
  _url_file="${_my_urls}"
  ```

- **`events_emit_start` test**: the test in Task 4 checks for `"project":"TestProject"` — this is still correct since we added the project field in Task 4 and only rename `args`→`urls` in Task 6. Verify the test still passes after Task 6 (it should, since the test only checks for `project` field).

- **Old `KML_DIR` / `DEM_DIR` / lock cleanup**: After Task 5, `KML_DIR="${LIDAR_DIR}/kml"` and the `LOCK_DIR` setup are no longer referenced. Remove them from lidar-run's preamble in Task 5.

- **`running_pids` in process.sh**: Currently identifies running runs by checking whether their PID is alive. After fan-out, each child process's PID is stored in the start event. This still works — `running_pids` is not changed. `lidar kill --all` will correctly find and terminate active children.
