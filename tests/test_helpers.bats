#!/usr/bin/env bats

setup() {
  export GIS_DIR="${BATS_TMPDIR}/gis"
  mkdir -p "${GIS_DIR}/lidar/logs"
  LIDAR_HOME=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  export LIDAR_HOME
  source "${LIDAR_HOME}/lib/strict.sh"
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

@test "is_known_shading accepts hillshade" {
  is_known_shading hillshade
}

@test "is_known_shading accepts slopeshade" {
  is_known_shading slopeshade
}

@test "is_known_shading rejects gibberish" {
  run is_known_shading gibberish
  [ "${status}" -ne 0 ]
}

@test "gen_hex_id returns 6 lowercase hex chars" {
  result=$(gen_hex_id)
  [[ "${result}" =~ ^[0-9a-f]{6}$ ]]
}

@test "gen_hex_id returns different values on repeated calls" {
  a=$(gen_hex_id); b=$(gen_hex_id); c=$(gen_hex_id)
  [[ "${a}" != "${b}" || "${b}" != "${c}" ]]
}

@test "fanout_by_project groups by USGS project" {
  WORK_DIR=$(mktemp -d); trap 'rm -rf "${WORK_DIR}"' EXIT
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
  WORK_DIR=$(mktemp -d); trap 'rm -rf "${WORK_DIR}"' EXIT
  result=$(printf '%s\n' \
    "https://example.com/no/projects/tile.tif" \
    | fanout_by_project "_myfallback")
  project=$(echo "${result}" | cut -f1)
  [ "${project}" = "_myfallback" ]
}

@test "fanout_by_project drops non-project URLs when fallback is empty" {
  WORK_DIR=$(mktemp -d); trap 'rm -rf "${WORK_DIR}"' EXIT
  result=$(printf '%s\n' \
    "https://example.com/no/projects/tile.tif" \
    | fanout_by_project "")
  [ -z "${result}" ]
}

@test "fanout_by_project splits two projects into separate entries" {
  WORK_DIR=$(mktemp -d); trap 'rm -rf "${WORK_DIR}"' EXIT
  result=$(printf '%s\n%s\n' \
    "https://s3/Foo/Projects/Alpha_2020/TIFF/a.tif" \
    "https://s3/Foo/Projects/Beta_2021/TIFF/b.tif" \
    | fanout_by_project "")
  count=$(echo "${result}" | wc -l)
  [ "${count}" -eq 2 ]
  [[ "${result}" == *"Alpha_2020"* ]]
  [[ "${result}" == *"Beta_2021"* ]]
}

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

@test "signal_exit_reason explains SIGINT" {
  source "${LIDAR_HOME}/lib/diag.sh"
  result=$(signal_exit_reason INT)
  [[ "${result}" == *"SIGINT"* ]]
}

@test "signal_exit_reason explains SIGHUP" {
  source "${LIDAR_HOME}/lib/diag.sh"
  result=$(signal_exit_reason HUP)
  [[ "${result}" == *"SIGHUP"* ]]
}

@test "signal_exit_reason for SIGTERM names the signal and never guesses OOM" {
  # OOM-kills use SIGKILL (untrappable) and can't reach the exit trap, so the
  # reason for a caught TERM must not claim OOM. On a normally-running test
  # host the system is not "stopping", so this exercises the generic branch.
  source "${LIDAR_HOME}/lib/diag.sh"
  result=$(signal_exit_reason TERM)
  [[ "${result}" == *"SIGTERM"* ]]
  [[ "${result}" != *"OOM"* ]]
}

@test "signal_exit_reason falls back for an unnamed signal" {
  source "${LIDAR_HOME}/lib/diag.sh"
  result=$(signal_exit_reason USR1)
  [[ "${result}" == *"USR1"* ]]
}

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

@test "download_tiles respects STRICT_DOWNLOADS on failure" {
  # STRICT_DOWNLOADS is checked in download_tiles (not in _lidar_download_one).
  # Worker failures are recorded in FAILED_TILE_LOG; download_tiles decides
  # whether to abort (STRICT=1) or continue (STRICT=0) based on the count.
  source "${LIDAR_HOME}/lib/download.sh"
  declare -f download_tiles | grep -q 'STRICT_DOWNLOADS'
}

@test "download_tiles summary mentions failed tile log" {
  # We can't run real downloads in bats; test that the summary logic exists
  # by checking download_tiles' source references FAILED_TILE_LOG.
  source "${LIDAR_HOME}/lib/download.sh"
  declare -f download_tiles | grep -q 'FAILED_TILE_LOG'
}
