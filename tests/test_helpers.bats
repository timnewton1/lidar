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
