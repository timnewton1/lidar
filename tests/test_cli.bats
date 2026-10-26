#!/usr/bin/env bats

setup() {
  export GIS_DIR="${BATS_TMPDIR}/gis"
  mkdir -p "${GIS_DIR}/lidar/logs"
  export LIDAR_HOME
  LIDAR_HOME=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  # The in-container entrypoint; the host wrapper only adds podman/systemd.
  LIDAR="${LIDAR_HOME}/libexec/lidar-dispatch"
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

@test "lidar run --output with unknown token rejected" {
  run "${LIDAR}" run --output xml "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--output unknown"* ]]
}

@test "lidar run --cog-crs with bad value errors before deps check" {
  run "${LIDAR}" run --output cog --cog-crs FOO "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--cog-crs must match"* ]]
}

@test "lidar run --cog-crs without cog in --output rejected" {
  run "${LIDAR}" run --output kml --cog-crs EPSG:32614 "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"require --output to include cog"* ]]
}

@test "lidar run --cog-no-reproject without cog in --output rejected" {
  run "${LIDAR}" run --output kml --cog-no-reproject "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"require --output to include cog"* ]]
}

@test "lidar run --cog-crs and --cog-no-reproject are mutually exclusive" {
  run "${LIDAR}" run --output cog --cog-crs EPSG:32614 --cog-no-reproject "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"mutually exclusive"* ]]
}

@test "lidar run --output cog --cog-crs EPSG:32614 accepted (validation passes)" {
  # Validation happens before job specs are written; downstream may fail,
  # but the EPSG check itself must pass — i.e. no "--cog-crs must match" error.
  run bash -c "\"${LIDAR}\" run --output cog --cog-crs EPSG:32614 \"${FIXTURES}/one_tile.txt\" 2>&1 || true"
  [[ "${output}" != *"--cog-crs must match"* ]]
  [[ "${output}" != *"mutually exclusive"* ]]
}

@test "lidar run -o is equivalent to --output (flag parses)" {
  run bash -c "\"${LIDAR}\" run -o cog --cog-crs FOO \"${FIXTURES}/one_tile.txt\" 2>&1 || true"
  # -o must trigger OUTPUT_COG=1 so --cog-crs FOO reaches the EPSG validator.
  [[ "${output}" == *"--cog-crs must match"* ]]
}

@test "lidar run --output kml,cog accepted" {
  run bash -c "\"${LIDAR}\" run --output kml,cog \"${FIXTURES}/one_tile.txt\" 2>&1 || true"
  # Should not fail at flag parsing; downstream errors are fine.
  [[ "${output}" != *"--output unknown"* ]]
  [[ "${output}" != *"empty token"* ]]
}

@test "lidar run usage includes --output and cog modifiers" {
  run "${LIDAR}" run --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--output"* ]]
  [[ "${output}" == *"--cog-crs"* ]]
  [[ "${output}" == *"--cog-no-reproject"* ]]
}

@test "lidar run --dry-run prints plan header" {
  run bash -c "
    export GIS_DIR=\"${GIS_DIR}\"
    export LIDAR_HOME=\"${LIDAR_HOME}\"
    mkdir -p \"\${GIS_DIR}/lidar\"
    \"${LIDAR}\" run --dry-run \"${FIXTURES}/one_tile.txt\" 2>&1 || true
  "
  # --name is gone; we just check the flag doesn't trip an "Unknown flag" error.
  [[ "${output}" != *"Unknown flag: --name"* ]]
}

@test "lidar run --dry-run passes with one_tile.txt and writes no job" {
  rm -rf "${GIS_DIR}/lidar/jobs"
  run "${LIDAR}" run --dry-run "${FIXTURES}/one_tile.txt"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY RUN PLAN"* ]]
  [[ "${output}" != *"@job "* ]]
  [ ! -d "${GIS_DIR}/lidar/jobs" ]
}

@test "lidar run writes a job spec and emits @job for each project" {
  rm -rf "${GIS_DIR}/lidar/jobs"
  run "${LIDAR}" run -s hillshade,slopeshade -o cog "${FIXTURES}/one_tile.txt"
  [ "${status}" -eq 0 ]
  local hex; hex=$(grep '^@job ' <<< "${output}" | head -1 | cut -d' ' -f2)
  [[ "${hex}" =~ ^[0-9a-f]{6}$ ]]
  [ -s "${GIS_DIR}/lidar/jobs/${hex}.urls" ]
  # The spec must round-trip the resolved flags for the worker.
  run bash -c "source '${GIS_DIR}/lidar/jobs/${hex}.env'; echo \"\${SHADINGS[*]}|\${OUTPUT_COG}|\${OUTPUT_KML}|\${JOB_PROJECT}\""
  [[ "${output}" == "hillshade slopeshade|1|0|"?* ]]
  # The dispatcher's own scratch is gone once specs are written.
  [ -z "$(compgen -G "${GIS_DIR}/lidar/.work_*")" ]
}

@test "lidar resolve prints the full id for a prefix" {
  mkdir -p "${GIS_DIR}/lidar/logs"
  printf '{"id":"abc123","event":"start","ts":"2026-01-01T00:00:00Z","log":"","project":"p","urls":[]}\n' \
    > "${GIS_DIR}/lidar/logs/runs.jsonl"
  run "${LIDAR}" resolve abc
  [ "${status}" -eq 0 ]
  [ "${output}" = "abc123" ]
  run "${LIDAR}" resolve zzz
  [ "${status}" -ne 0 ]
}

@test "lidar kill and restart are host-only (not in the container)" {
  run "${LIDAR}" kill
  [ "${status}" -eq 2 ]
  run "${LIDAR}" restart
  [ "${status}" -eq 2 ]
}

@test "events_emit_start writes project field and urls key" {
  source "${LIDAR_HOME}/lib/common.sh"
  source "${LIDAR_HOME}/lib/events.sh"
  events_emit_start "aabbcc" "" "TestProject" "a.txt" "b.txt"
  local row
  row=$(tail -1 "${GIS_DIR}/lidar/logs/runs.jsonl")
  [[ "${row}" == *'"project":"TestProject"'* ]]
  [[ "${row}" == *'"urls":'* ]]
  [[ "${row}" != *'"args":'* ]]
}

@test "Bug A: _on_project_exit captures \$? before re-entrancy guard" {
  # Verify the fix is in place: local _rc=\$? must appear before the [[ check.
  local src="${LIDAR_HOME}/libexec/lidar-worker"
  local rc_line guard_line
  rc_line=$(grep -n 'local _rc=\$?' "${src}" | head -1 | cut -d: -f1)
  guard_line=$(grep -n '\[\[ \${_on_exit_done}' "${src}" | head -1 | cut -d: -f1)
  (( rc_line < guard_line ))
}

@test "events: start is emitted only by the worker, never the dispatcher" {
  # The dispatcher only writes job specs; a start event there would show a
  # run as alive before its unit exists.
  ! grep -q 'events_emit_start' "${LIDAR_HOME}/libexec/lidar-run"
  grep -q 'events_emit_start' "${LIDAR_HOME}/libexec/lidar-worker"
}

# ─── Fan-out flags ────────────────────────────────────────────────────────────

@test "lidar run --background flag rejected" {
  run "${LIDAR}" run --background "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unknown flag"* ]]
}

@test "lidar run --name flag rejected" {
  run "${LIDAR}" run --name foo "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unknown flag"* ]]
}

@test "lidar run --jobs 0 rejected" {
  run "${LIDAR}" run --jobs 0 "${FIXTURES}/one_tile.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--jobs must be a positive integer"* ]]
}

@test "lidar run --jobs 2 accepted (reaches downstream)" {
  run bash -c "\"${LIDAR}\" run --jobs 2 --dry-run \"${FIXTURES}/one_tile.txt\" 2>&1 || true"
  [[ "${output}" != *"Unknown flag"* ]]
  [[ "${output}" != *"--jobs must be"* ]]
}

@test "lidar run accepts two positional files" {
  run bash -c "\"${LIDAR}\" run \"${FIXTURES}/one_tile.txt\" \"${FIXTURES}/one_tile.txt\" --dry-run 2>&1 || true"
  [[ "${output}" != *"Unknown flag"* ]]
  [[ "${output}" != *"Too many"* ]]
}

# ─── list subcommand ─────────────────────────────────────────────────────────

@test "lidar list with no args exits 0" {
  run "${LIDAR}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"STATUS"* || "${output}" == *"no runs yet"* ]]
}

@test "lidar list --help exits 0" {
  run "${LIDAR}" list --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"lidar list"* ]]
}

@test "lidar list marks a run with no end event as crashed unless active" {
  printf '{"id":"abc123","event":"start","ts":"2026-01-01T00:00:00Z","log":"","project":"p","urls":[]}\n' \
    > "${GIS_DIR}/lidar/logs/runs.jsonl"
  run env LIDAR_ACTIVE="" "${LIDAR}" list
  [[ "${output}" == *"crash"*"abc123"* ]]
  run env LIDAR_ACTIVE="ffffff abc123" "${LIDAR}" list
  [[ "${output}" == *"run"*"abc123"* ]]
}

@test "lidar list uses the latest start after a restart" {
  {
    printf '{"id":"abc123","event":"start","ts":"2026-01-01T00:00:00Z","log":"","project":"p","urls":[]}\n'
    printf '{"id":"abc123","event":"end","ts":"2026-01-01T00:01:00Z","exit":1}\n'
    printf '{"id":"abc123","event":"start","ts":"2026-02-02T00:00:00Z","log":"","project":"p","urls":[]}\n'
  } > "${GIS_DIR}/lidar/logs/runs.jsonl"
  run env LIDAR_ACTIVE="abc123" "${LIDAR}" list
  [[ "${output}" == *"2026-02-02"* ]]
  [[ "${output}" != *"2026-01-01"* ]]
}

# ─── Removed subcommands ─────────────────────────────────────────────────────

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

# ─── Disk-discipline guard ───────────────────────────────────────────────────
# /tmp is tmpfs on Bazzite/Fedora (16 GB RAM). Reprojected county-scale
# rasters routinely exceed that — see run a3f4a8. Every mktemp invocation
# in the run pipeline must explicitly pick a base on the output disk via
# -p or -d <basedir>. A bare `mktemp` or `mktemp --suffix=...` lands in
# $TMPDIR (default /tmp) and is a silent OOM trap.
@test "lidar run --strict-downloads flag is accepted" {
  run bash -c "\"${LIDAR}\" run --strict-downloads --dry-run \"${FIXTURES}/one_tile.txt\" 2>&1 || true"
  [[ "${output}" != *"Unknown flag"* ]]
  [[ "${output}" != *"unknown flag"* ]]
}

@test "lidar run --strict-downloads appears in dry-run plan" {
  run bash -c "\"${LIDAR}\" run --strict-downloads --dry-run \"${FIXTURES}/one_tile.txt\" 2>&1 || true"
  [[ "${output}" == *"strict_downloads=1"* ]]
}

@test "no mktemp in run pipeline targets default TMPDIR" {
  # Every mktemp invocation must reference one of the output-disk path
  # variables (LIDAR_DIR, WORK_DIR, _proj_work) — either via -p/-d or in
  # the template positional. A bare mktemp lands in /tmp = tmpfs.
  run grep -nE 'mktemp(\s|$)' "${LIDAR_HOME}/libexec/lidar-run" "${LIDAR_HOME}/libexec/lidar-worker" "${LIDAR_HOME}/lib"/*.sh
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" == *'LIDAR_DIR'* \
       || "${line}" == *'_proj_work'* \
       || "${line}" == *'WORK_DIR'* ]]; then
      continue
    fi
    echo "FORBIDDEN: ${line}" >&2
    return 1
  done <<< "${output}"
}


@test "worker EXIT trap only reads globals (it fires after the function returns)" {
  # Regression: the trap used function locals and died with "unbound
  # variable" after a successful run, so no end event was written.
  local src="${LIDAR_HOME}/libexec/lidar-worker"
  ! grep -qE 'local _on_exit_done|local _proj_work' "${src}"
  local body
  body=$(sed -n '/_on_project_exit() {/,/^  }/p' "${src}")
  [[ "${body}" == *'"${HEX}"'* ]]
  [[ "${body}" != *'_hex'* ]]
}
