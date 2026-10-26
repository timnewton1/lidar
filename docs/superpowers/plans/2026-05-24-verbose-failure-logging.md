# Verbose Failure Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every lidar run log self-explanatory — each failure mode surfaces with enough context (what was running, what resource state was, what signal arrived) that the cause is unambiguous without needing to re-run.

**Architecture:** Add `lib/diag.sh` for environment snapshot functions (disk, RAM, tmpfs, GDAL version) called at run start; add a `run_gdal` wrapper in `lib/gdal.sh` that logs the full command before exec; improve download failure accounting in `lib/download.sh`; add `--strict-downloads` flag to `libexec/lidar-run`; tighten the exit trap to log the exit reason (signal vs normal, exit code, last step).

**Tech Stack:** bash, bats (tests)

---

## Failure mode inventory

These are all the cases the logging improvements must surface:

**Before the run starts**
1. `GIS_DIR` not set / not mounted → already caught in `common.sh`, good
2. `LIDAR_DIR` not writable (disk full, permissions) → only caught implicitly on first `mkdir -p`
3. Output disk nearly full → not checked at all; GDAL runs for hours then dies
4. tmpfs (`/tmp`) too small for intermediate rasters → partially mitigated by `TMPDIR` pin, but not reported
5. RAM too low to start even one job → the memory gate loops forever with sparse "Waiting…" lines, no estimate of how long or what's needed
6. Flatpak app not installed → caught in Step 1, good
7. `curl` / `numfmt` / `zip` / `python3` not found → caught in Step 1, good
8. GDAL version too old (missing `gdal raster tile`) → not checked; fails mid-pipeline with an opaque error

**During download (Step 4)**
9. Individual tile 404 / curl timeout after retries → logged as `ERROR <basename>`, no final count summary
10. All tiles fail → proceeds to mosaic step, then fails on empty tile list
11. Partial file left on disk (crash mid-download) → `.partial` cleanup handles per-tile; `. partial` from a prior killed run could block re-downloads (fixed in the download worker already, but not reported)
12. Disk fills during download → curl exits non-zero, tile logged as ERROR; root cause not surfaced

**During GDAL processing (Steps 6–8)**
13. `gdaldem` / `gdalwarp` / `gdal raster tile` / `gdal_translate` killed by SIGTERM/SIGKILL (OOM, systemd) → bash prints `Terminated` with no indication of which command or what step
14. `gdaldem` / `gdalwarp` crash (segfault, GDAL internal error) → non-zero exit captured by `set -e`, but no log of the exact invocation that failed
15. `gdalbuildvrt` produces empty VRT (all nodata, mismatched CRS) → GDAL continues; downstream tile step produces 0 tiles; no diagnostic
16. WGS84 reprojection produces fully-transparent raster → `--skip-blank` drops all tiles; `ensure_root_networklink` emits a WARN but no indication why all tiles were blank
17. Zoom computation fails (missing gdalinfo fields) → `compute_zoom_and_lookat` returns 1, the `|| true` swallows it; MAX_ZOOM is unset → unbound variable error or silent empty string
18. `inject_lookat` sed fails on malformed KML → silent; KML works but camera position wrong
19. COG reprojection disk-full → `gdalwarp` exits non-zero; intermediate tmp_reproj left on disk; exit trap cleans work dir but the cause isn't surfaced
20. KMZ zip fails (zip not found, disk full) → exits non-zero via `set -e`, no log of what was being zipped

**At exit**
21. SIGTERM received → `_on_project_signal TERM` converts to `exit 143`; `_on_project_exit` fires with rc=143; `events_emit_end` records exit code; but the log itself just ends at `Terminated` with no summary line explaining the signal
22. SIGKILL received → no trap fires; `events_emit_end` never runs; run stays as `⊘ crash` in the list (correct), but log ends at wherever GDAL was mid-output
23. `set -e` ERR trap fires (strict.sh) → exits; no summary line
24. Successful run with download failures → exit 0 but no final tally of failed tiles

---

## File map

| File | Action | What changes |
|------|--------|--------------|
| `lib/diag.sh` | **Create** | `diag_pre_run` (disk/RAM/tmpfs/GDAL version snapshot) and `diag_system_snapshot` (called at dispatcher level too) |
| `lib/gdal.sh` | **Modify** | Add `run_gdal` wrapper that logs the command array before exec; replace all bare GDAL invocations with `run_gdal` |
| `lib/download.sh` | **Modify** | Track failed-tile count; log summary at end of Step 4; respect `STRICT_DOWNLOADS` env var |
| `libexec/lidar-run` | **Modify** | Source `lib/diag.sh`; call `diag_pre_run` at start of `_run_one_project`; call `diag_system_snapshot` in the dispatcher before dispatch; add `--strict-downloads` flag; improve exit trap to log exit reason |
| `tests/test_cli.bats` | **Modify** | Add tests for `--strict-downloads` flag parsing and dry-run output |
| `tests/test_helpers.bats` | **Modify** | Add tests for `diag_pre_run` output (disk/RAM fields present), `run_gdal` logging |

---

## Task 1: Create `lib/diag.sh` with `diag_system_snapshot` and `diag_pre_run`

**Files:**
- Create: `lib/diag.sh`
- Test: `tests/test_helpers.bats`

- [ ] **Step 1: Write failing tests for `diag_system_snapshot`**

Add to `tests/test_helpers.bats`:

```bash
@test "diag_system_snapshot prints disk available" {
  source "${LIDAR_HOME}/lib/diag.sh"
  result=$(diag_system_snapshot "${BATS_TMPDIR}")
  [[ "${result}" == *"disk_avail"* ]]
}

@test "diag_system_snapshot prints ram_avail_mb" {
  source "${LIDAR_HOME}/lib/diag.sh"
  result=$(diag_system_snapshot "${BATS_TMPDIR}")
  [[ "${result}" == *"ram_avail_mb"* ]]
}

@test "diag_system_snapshot prints tmpfs_avail" {
  source "${LIDAR_HOME}/lib/diag.sh"
  result=$(diag_system_snapshot "${BATS_TMPDIR}")
  [[ "${result}" == *"tmpfs_avail"* ]]
}

@test "diag_pre_run prints GDAL_FLATPAK_APP" {
  source "${LIDAR_HOME}/lib/diag.sh"
  result=$(diag_pre_run "${BATS_TMPDIR}" 2>&1 || true)
  [[ "${result}" == *"${GDAL_FLATPAK_APP}"* ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
bats tests/test_helpers.bats --filter "diag"
```

Expected: FAIL — `lib/diag.sh: No such file or directory`

- [ ] **Step 3: Create `lib/diag.sh`**

```bash
#!/usr/bin/env bash
# Pre-run environment diagnostics: disk, RAM, tmpfs, GDAL version.
# Requires lib/common.sh (GDAL_FLATPAK_APP, GDAL array, human_bytes).

[[ -n "${_LIDAR_DIAG_LOADED:-}" ]] && return 0
_LIDAR_DIAG_LOADED=1

# Print a one-line environment snapshot to stdout.
# Args: <output_dir>  — the disk to measure free space on
# Output format:
#   disk_avail=12.3GB  ram_avail_mb=4096  tmpfs_avail=8.0GB  load=1.23
diag_system_snapshot() {
  local output_dir="${1:-/tmp}"
  local disk_kb ram_avail_mb tmpfs_kb load1
  disk_kb=$(df -k "${output_dir}" 2>/dev/null | awk 'NR==2{print $4}')
  ram_avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  tmpfs_kb=$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}')
  load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "?")
  printf 'disk_avail=%s  ram_avail_mb=%s  tmpfs_avail=%s  load=%s\n' \
    "$(human_bytes "${disk_kb}000" 2>/dev/null || echo "${disk_kb}KB")" \
    "${ram_avail_mb}" \
    "$(human_bytes "${tmpfs_kb}000" 2>/dev/null || echo "${tmpfs_kb}KB")" \
    "${load1}"
}

# Print a full pre-run environment block to stdout.
# Includes: flatpak app, GDAL version (if flatpak accessible), disk/RAM/tmpfs.
# Designed to be called inside the per-project log (exec > log already in place).
# Args: <output_dir>
diag_pre_run() {
  local output_dir="${1:-/tmp}"
  echo "=========================================="
  echo "ENVIRONMENT"
  echo "=========================================="
  echo "  Flatpak app : ${GDAL_FLATPAK_APP}"
  local gdal_ver
  gdal_ver=$(flatpak run --command=gdal "${GDAL_FLATPAK_APP}" --version 2>/dev/null || echo "unknown")
  echo "  GDAL version: ${gdal_ver}"
  echo "  $(diag_system_snapshot "${output_dir}")"
  local disk_kb
  disk_kb=$(df -k "${output_dir}" 2>/dev/null | awk 'NR==2{print $4}')
  # Warn if output disk has less than 20 GB free — a county-scale run with
  # hillshade + KML pyramid routinely needs 10–15 GB.
  if [[ -n "${disk_kb}" && "${disk_kb}" -lt $((20 * 1024 * 1024)) ]]; then
    echo "  WARNING: output disk has less than 20 GB free — large runs may fail with 'no space left on device'"
  fi
  local ram_avail_mb
  ram_avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 999999)
  if [[ "${ram_avail_mb}" -lt 2048 ]]; then
    echo "  WARNING: less than 2 GB RAM available — GDAL operations may be very slow or OOM-killed"
  fi
  echo "=========================================="
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
bats tests/test_helpers.bats --filter "diag"
```

Expected: all 4 PASS

- [ ] **Step 5: Commit**

```bash
git add lib/diag.sh tests/test_helpers.bats
git commit -m "feat(diag): add lib/diag.sh with diag_system_snapshot and diag_pre_run"
```

---

## Task 2: Add `run_gdal` wrapper to `lib/gdal.sh`

**Files:**
- Modify: `lib/gdal.sh`
- Test: `tests/test_helpers.bats`

`run_gdal` logs the full command array to the run log before executing it. This is the core fix for "log ended at `Terminated` with no indication of which command was running."

- [ ] **Step 1: Write failing test**

Add to `tests/test_helpers.bats`:

```bash
@test "run_gdal logs the command before running it" {
  source "${LIDAR_HOME}/lib/gdal.sh"
  # Use 'true' as a stand-in GDAL command — we're testing the logging, not GDAL
  result=$(run_gdal true --some-flag /input /output 2>&1)
  [[ "${result}" == *"true --some-flag /input /output"* ]]
}

@test "run_gdal executes the command" {
  source "${LIDAR_HOME}/lib/gdal.sh"
  run run_gdal true
  [ "${status}" -eq 0 ]
}

@test "run_gdal propagates non-zero exit" {
  source "${LIDAR_HOME}/lib/gdal.sh"
  run run_gdal false
  [ "${status}" -ne 0 ]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
bats tests/test_helpers.bats --filter "run_gdal"
```

Expected: FAIL — `run_gdal: command not found`

- [ ] **Step 3: Add `run_gdal` to `lib/gdal.sh`**

Add this block immediately after the `_LIDAR_GDAL_LOADED` guard at the top of `lib/gdal.sh` (before the `WCQ_TILE_DEG_Z0` line):

```bash
# run_gdal <cmd> [args...]: log the full invocation then exec.
# All GDAL calls go through this so the log always shows the exact command
# that was running when the process was interrupted or crashed.
run_gdal() {
  echo "  + $*" >&2
  "$@"
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
bats tests/test_helpers.bats --filter "run_gdal"
```

Expected: all 3 PASS

- [ ] **Step 5: Replace bare GDAL invocations in `lib/gdal.sh` with `run_gdal`**

In `derive_hillshade`, change:
```bash
  "${GDALDEM[@]}" "${args[@]}"
```
to:
```bash
  run_gdal "${GDALDEM[@]}" "${args[@]}"
```

In `derive_slopeshade`, change both `"${GDALDEM[@]}"` invocations:
```bash
  run_gdal "${GDALDEM[@]}" slope "${in}" "${slope_tif}" \
    -compute_edges -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES
```
```bash
  run_gdal "${GDALDEM[@]}" color-relief "${slope_tif}" "${ramp}" "${out}" \
    -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES
```

In `reproject_to_wgs84`, change:
```bash
  "${GDALWARP[@]}" -t_srs EPSG:4326 -r bilinear \
    -srcnodata 0 -dstalpha \
    -multi -wo NUM_THREADS=ALL_CPUS \
    -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES \
    "${in}" "${out}"
```
to:
```bash
  run_gdal "${GDALWARP[@]}" -t_srs EPSG:4326 -r bilinear \
    -srcnodata 0 -dstalpha \
    -multi -wo NUM_THREADS=ALL_CPUS \
    -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES \
    "${in}" "${out}"
```

In `build_dem_vrt`, change:
```bash
  "${GDALBUILDVRT[@]}" \
    -srcnodata "${DEM_NODATA}" -vrtnodata "${DEM_NODATA}" \
    -input_file_list "${list_file}" "${out_vrt}"
```
to:
```bash
  run_gdal "${GDALBUILDVRT[@]}" \
    -srcnodata "${DEM_NODATA}" -vrtnodata "${DEM_NODATA}" \
    -input_file_list "${list_file}" "${out_vrt}"
```

- [ ] **Step 6: Replace bare GDAL invocations in `lib/cog.sh` with `run_gdal`**

In `build_cog_dem`, change both GDAL invocations:
```bash
    run_gdal "${GDALWARP[@]}" -t_srs "${target}" \
      -srcnodata "${DEM_NODATA}" -dstnodata "${DEM_NODATA}" \
      -r bilinear -multi -wo NUM_THREADS=ALL_CPUS \
      -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES \
      "${in}" "${tmp_reproj}"
```
```bash
  run_gdal "${GDALTRANSLATE[@]}" -of COG \
    -co COMPRESS=ZSTD \
    -co PREDICTOR=FLOATING_POINT \
    -co BLOCKSIZE=512 \
    -co OVERVIEW_RESAMPLING=AVERAGE \
    "${src}" "${out}"
```

In `build_cog_shade`, change both GDAL invocations:
```bash
    run_gdal "${GDALWARP[@]}" -t_srs "${target}" \
      -srcnodata 0 -dstalpha \
      -r bilinear -multi -wo NUM_THREADS=ALL_CPUS \
      -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES \
      "${in}" "${tmp_reproj}"
```
```bash
  run_gdal "${GDALTRANSLATE[@]}" -of COG \
    -co COMPRESS=ZSTD \
    -co BLOCKSIZE=512 \
    -co OVERVIEW_RESAMPLING=NEAREST \
    "${src}" "${out}"
```

- [ ] **Step 7: Replace the bare GDAL invocation for `gdal raster tile` in `libexec/lidar-run`**

In `_run_one_project`, in Step 6, change:
```bash
        "${GDAL[@]}" raster tile \
          --tiling-scheme WorldCRS84Quad \
          --kml \
          --webviewer none \
          --min-zoom 0 \
          --max-zoom "${MAX_ZOOM}" \
          -r cubic \
          --overview-resampling cubic \
          --skip-blank \
          --title "${PROJECT}" \
          -j ALL_CPUS \
          "${WGS84_TIF}" "${PROJ_OUT}"
```
to:
```bash
        run_gdal "${GDAL[@]}" raster tile \
          --tiling-scheme WorldCRS84Quad \
          --kml \
          --webviewer none \
          --min-zoom 0 \
          --max-zoom "${MAX_ZOOM}" \
          -r cubic \
          --overview-resampling cubic \
          --skip-blank \
          --title "${PROJECT}" \
          -j ALL_CPUS \
          "${WGS84_TIF}" "${PROJ_OUT}"
```

- [ ] **Step 8: Verify the test suite still passes**

```bash
bats tests/
```

Expected: all tests PASS

- [ ] **Step 9: Commit**

```bash
git add lib/gdal.sh lib/cog.sh libexec/lidar-run tests/test_helpers.bats
git commit -m "feat(logging): add run_gdal wrapper; log GDAL invocation before each exec"
```

---

## Task 3: Improve download failure accounting in `lib/download.sh`

**Files:**
- Modify: `lib/download.sh`
- Test: `tests/test_helpers.bats`

Currently: individual tile errors print `ERROR <basename>` but there's no final count and `download_tiles` returns non-zero silently. We need: a failure counter, a clear end-of-step summary, and `STRICT_DOWNLOADS` support.

- [ ] **Step 1: Write failing tests**

Add to `tests/test_helpers.bats`:

```bash
@test "_lidar_download_one uses STRICT_DOWNLOADS env var" {
  # This tests the variable is read; actual download behavior is integration-only.
  # Verify the variable is exported and the function references it.
  source "${LIDAR_HOME}/lib/download.sh"
  # _lidar_download_one is exported; grep its definition for STRICT_DOWNLOADS
  declare -f _lidar_download_one | grep -q 'STRICT_DOWNLOADS'
}

@test "download_tiles summary mentions failed count on partial failure" {
  # We can't run real downloads in bats; test that the summary logic exists
  # by checking download_tiles' source references FAILED_DOWNLOADS.
  source "${LIDAR_HOME}/lib/download.sh"
  declare -f download_tiles | grep -q 'FAILED_DOWNLOADS'
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
bats tests/test_helpers.bats --filter "download"
```

Expected: FAIL

- [ ] **Step 3: Update `_lidar_download_one` in `lib/download.sh`**

The function is exported for `xargs -P` subshells. It needs to write failure counts to a shared temp file (the only race-safe approach without a named pipe). Add a `FAILED_TILE_LOG` env var pointing to a file; each failure appends a line.

Replace the `_lidar_download_one` function body with:

```bash
_lidar_download_one() {
  local url="$1"
  [[ -z "${url}" ]] && return 0
  local basename="${url##*/}"; basename="${basename%.tif}"
  local tile_tif="${DEM_DIR}/${basename}.tif"
  if [[ -f "${tile_tif}" ]]; then
    flock /dev/stderr -c "printf '  cached  %s\n' '${basename}'" 2>&1
    return 0
  fi
  local partial="${tile_tif}.$$.partial"
  if ! curl -L --retry 5 --retry-all-errors --retry-delay 5 \
            --fail-with-body --max-time 1800 -C - -sS \
            -o "${partial}" "${url}"; then
    flock /dev/stderr -c "printf '  ERROR   %s  (url: %s)\n' '${basename}' '${url}'" 2>&1
    rm -f "${partial}"
    # Record failure for the summary; FAILED_TILE_LOG is set by download_tiles.
    [[ -n "${FAILED_TILE_LOG:-}" ]] && flock "${FAILED_TILE_LOG}" -c "echo '${basename}' >> '${FAILED_TILE_LOG}'"
    return 1
  fi
  if [[ -f "${tile_tif}" ]]; then
    rm -f "${partial}"
  else
    mv -f "${partial}" "${tile_tif}"
  fi
  local sz
  sz=$(stat -c %s "${tile_tif}" 2>/dev/null || echo 0)
  flock /dev/stderr -c "printf '  done    %s  (%s)\n' '${basename}' '$(numfmt --to=iec --suffix=B --format=%.1f "${sz}")'" 2>&1
}
export -f _lidar_download_one
```

- [ ] **Step 4: Update `download_tiles` in `lib/download.sh`**

Replace the `download_tiles` function body with:

```bash
download_tiles() {
  local jobs="${LIDAR_DOWNLOAD_JOBS:-4}"
  echo "=========================================="
  echo "STEP 4: Downloading ${TOTAL_TILES} tiles  (parallel: ${jobs})"
  echo "=========================================="

  export DEM_DIR

  # Shared file for failure accounting across xargs worker subshells.
  local failed_log
  failed_log=$(mktemp "${WORK_DIR}/download_failures_XXXXXX.txt")
  export FAILED_TILE_LOG="${failed_log}"

  local rc=0
  grep -v '^[[:space:]]*$' "${FILTERED_LIST}" \
    | xargs -P "${jobs}" -n 1 bash -c '_lidar_download_one "$@"' _ \
    || rc=$?

  local n_failed=0
  [[ -f "${failed_log}" ]] && n_failed=$(wc -l < "${failed_log}")

  echo "=========================================="
  if [[ ${n_failed} -gt 0 ]]; then
    echo "STEP 4 complete — ${n_failed} tile(s) failed to download:"
    sed 's/^/    /' "${failed_log}"
    if [[ "${STRICT_DOWNLOADS:-0}" -eq 1 ]]; then
      echo "ERROR: --strict-downloads set; aborting run due to download failures"
      rm -f "${failed_log}"
      return 1
    else
      echo "  Proceeding with $(( TOTAL_TILES - n_failed )) of ${TOTAL_TILES} tiles."
      echo "  Re-run the same command to retry failed tiles (cached tiles are skipped)."
    fi
  else
    echo "STEP 4 complete — all ${TOTAL_TILES} tiles downloaded successfully"
  fi
  echo "=========================================="
  rm -f "${failed_log}"
  return ${rc}
}
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
bats tests/test_helpers.bats --filter "download"
```

Expected: all 2 PASS

- [ ] **Step 6: Commit**

```bash
git add lib/download.sh tests/test_helpers.bats
git commit -m "feat(download): track per-tile failures; summary at step end; STRICT_DOWNLOADS support"
```

---

## Task 4: Add `--strict-downloads` flag to `libexec/lidar-run` and improve exit trap

**Files:**
- Modify: `libexec/lidar-run`
- Test: `tests/test_cli.bats`

This task wires together: `--strict-downloads` flag → `STRICT_DOWNLOADS` env var; sources `lib/diag.sh`; calls `diag_pre_run` at start of `_run_one_project`; calls `diag_system_snapshot` in the dispatcher; improves `_on_project_exit` to log exit reason.

- [ ] **Step 1: Write failing tests**

Add to `tests/test_cli.bats`:

```bash
@test "lidar run --strict-downloads flag is accepted" {
  run bash -c "\"${LIDAR}\" run --strict-downloads --dry-run \"${FIXTURES}/one_tile.txt\" 2>&1 || true"
  [[ "${output}" != *"Unknown flag"* ]]
  [[ "${output}" != *"unknown flag"* ]]
}

@test "lidar run --strict-downloads appears in dry-run plan" {
  run bash -c "\"${LIDAR}\" run --strict-downloads --dry-run \"${FIXTURES}/one_tile.txt\" 2>&1 || true"
  [[ "${output}" == *"strict_downloads=1"* ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
bats tests/test_cli.bats --filter "strict-downloads"
```

Expected: FAIL — `Unknown flag: --strict-downloads`

- [ ] **Step 3: Add `--strict-downloads` flag parsing to `libexec/lidar-run`**

In the variable declaration block (after `DRY_RUN=0`), add:
```bash
STRICT_DOWNLOADS=0
```

In the `while [[ $# -gt 0 ]]` case block, add before the `-h|--help` case:
```bash
    --strict-downloads)    STRICT_DOWNLOADS=1; shift ;;
```

After the COG-modifier validation block and before the `--jobs` validation block, add:
```bash
export STRICT_DOWNLOADS
```

In the `--dry-run` output block, add after `echo "Outputs     : ${OUTPUTS_PLAN% }"`:
```bash
  echo "strict_downloads=${STRICT_DOWNLOADS}"
```

- [ ] **Step 4: Source `lib/diag.sh` in `libexec/lidar-run`**

In the lib-sourcing block (where `common.sh`, `events.sh`, etc. are sourced), add:
```bash
source "${LIDAR_HOME}/lib/diag.sh"
```

- [ ] **Step 5: Call `diag_system_snapshot` in the dispatcher**

In the dispatcher section, after the `echo "Dispatching ${_N_PROJECTS} run(s)..."` block and before the supervisor subshell `(`, add:
```bash
echo "  System: $(diag_system_snapshot "${GIS_DIR}")"
```

- [ ] **Step 6: Call `diag_pre_run` at start of `_run_one_project`**

Inside `_run_one_project`, after `exec > "${_log}" 2>&1` and `events_emit_start ...`, add:
```bash
  diag_pre_run "${PROJECTS_DIR}/${_project}"
```

- [ ] **Step 7: Improve `_on_project_exit` to log exit reason**

Replace the existing `_on_project_exit` function inside `_run_one_project` with:

```bash
  _on_project_exit() {
    local _rc=$?
    [[ ${_on_exit_done} -eq 1 ]] && return; _on_exit_done=1
    echo "=========================================="
    if [[ ${_rc} -eq 0 ]]; then
      : # normal exit; ALL DONE banner already printed above
    elif [[ ${_rc} -gt 128 ]]; then
      local _sig=$(( _rc - 128 ))
      local _signame; _signame=$(kill -l "${_sig}" 2>/dev/null || echo "${_sig}")
      echo "EXIT: killed by signal ${_signame} (exit ${_rc}) — likely OOM-kill or systemd timeout"
    else
      echo "EXIT: failed with exit code ${_rc}"
    fi
    echo "=========================================="
    events_emit_end "${_hex}" "${_rc}"
    rm -rf "${_proj_work}"
  }
```

- [ ] **Step 8: Run tests to confirm they pass**

```bash
bats tests/test_cli.bats --filter "strict-downloads"
```

Expected: all 2 PASS

- [ ] **Step 9: Run full test suite**

```bash
bats tests/
```

Expected: all tests PASS

- [ ] **Step 10: Commit**

```bash
git add libexec/lidar-run tests/test_cli.bats
git commit -m "feat(run): add --strict-downloads; call diag_pre_run in worker; improve exit trap signal reporting"
```

---

## Task 5: Add usage help for `--strict-downloads` to `libexec/lidar-run`

**Files:**
- Modify: `libexec/lidar-run`

The `usage()` function reads `sed -n '3,35p'` from the script's own header comment. This task updates that comment block so `lidar run --help` shows the new flag.

- [ ] **Step 1: Update the header comment in `libexec/lidar-run`**

Find the options comment block (lines ~3–35). Add after the `-d, --dry-run` line:
```
#   --strict-downloads       abort the run if any tile fails to download
#                            (default: proceed with successfully-downloaded tiles)
```

- [ ] **Step 2: Verify help output includes the new flag**

```bash
./lidar run --help | grep strict
```

Expected output: `  --strict-downloads       abort the run if any tile fails to download`

- [ ] **Step 3: Commit**

```bash
git add libexec/lidar-run
git commit -m "docs(run): add --strict-downloads to --help output"
```

---

## Self-review

**Spec coverage check:**

| Failure mode | Task that covers it |
|---|---|
| Output disk nearly full | Task 1 (`diag_pre_run` warns if <20 GB free) |
| tmpfs size | Task 1 (`diag_system_snapshot` reports tmpfs_avail) |
| RAM too low warning | Task 1 (`diag_pre_run` warns if <2 GB) |
| GDAL version | Task 1 (`diag_pre_run` logs `gdal --version`) |
| GDAL command logged before exec | Task 2 (`run_gdal` wrapper) |
| All GDAL calls go through `run_gdal` | Task 2 (Steps 5–7 cover gdal.sh, cog.sh, lidar-run) |
| Download failure count summary | Task 3 |
| `--strict-downloads` abort on failure | Task 3 + Task 4 |
| System snapshot in dispatcher output | Task 4 (Step 5) |
| System snapshot in run log | Task 4 (Step 6) |
| Exit trap logs signal name | Task 4 (Step 7) |
| `--strict-downloads` in --help | Task 5 |

**Placeholder scan:** None found.

**Type/name consistency:**
- `diag_system_snapshot` — defined in Task 1, called in Task 4 Step 5 ✓
- `diag_pre_run` — defined in Task 1, called in Task 4 Step 6 ✓
- `run_gdal` — defined in Task 2 Step 3, used in Task 2 Steps 5–7 ✓
- `STRICT_DOWNLOADS` — set in Task 4 Step 3, exported same step, read in Task 3 Step 4 ✓
- `FAILED_TILE_LOG` — set in Task 3 Step 4 (download_tiles), read in `_lidar_download_one` Step 3 ✓

**Edge cases not covered (intentional YAGNI):**
- SIGKILL (untrappable — correctly stays as `⊘ crash` in the run list, no log possible)
- `ensure_root_networklink` WARN message already present for blank-tile case; no change needed
- `compute_zoom_and_lookat` `|| true` behaviour: the outer `{ read ... } < <(...)` pattern with `|| true` means an empty MAX_ZOOM will cause an unbound-variable error from `set -u`. This is a pre-existing bug, not introduced here — leave for a separate fix.
