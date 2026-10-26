#!/usr/bin/env bash
# Job specs: the hand-off from `lidar run` (dispatcher) to `lidar worker`.
#
# The dispatcher runs in a short-lived container and the worker in its own
# lidar@<hex> unit, so nothing is inherited by fork. Everything the worker
# needs is serialized to ${JOBS_DIR}/<hex>.env (bash `declare -p` output,
# sourced at top level by the worker) plus <hex>.urls (that project's tiles).
# The spec is kept after the run so `lidar restart` can replay it exactly.
# Requires lib/common.sh (LIDAR_DIR).

[[ -n "${_LIDAR_JOBS_LOADED:-}" ]] && return 0
_LIDAR_JOBS_LOADED=1

JOBS_DIR="${LIDAR_DIR}/jobs"
SLOTS_DIR="${JOBS_DIR}/.slots"

# Variables the worker reads. Keep in sync with what lidar-run resolves.
JOB_VARS=(
  JOB_PROJECT JOB_BATCH JOBS INPUTS SHADINGS
  OUTPUT_KML OUTPUT_KMZ OUTPUT_COG NEED_PYRAMID
  COG_CRS COG_NO_REPROJECT
  HS_ALGORITHM HS_MULTIDIRECTIONAL
  STRICT_DOWNLOADS extra_deps
)

# job_write <hex> <project> <batch> <url_file>
job_write() {
  local hex="$1" JOB_PROJECT="$2" JOB_BATCH="$3" url_file="$4"
  mkdir -p "${JOBS_DIR}"
  cp "${url_file}" "${JOBS_DIR}/${hex}.urls"
  # The worker sources this at top level, where plain `declare` lines create
  # globals. Sourcing it from inside a function would make them locals.
  declare -p "${JOB_VARS[@]}" > "${JOBS_DIR}/${hex}.env.partial"
  mv -f "${JOBS_DIR}/${hex}.env.partial" "${JOBS_DIR}/${hex}.env"
}

job_env()  { echo "${JOBS_DIR}/$1.env"; }
job_urls() { echo "${JOBS_DIR}/$1.urls"; }

# Block until one of JOBS slots for this batch is free, then hold it for the
# life of the process. Enforces --jobs across independent lidar@ units, which
# systemd would otherwise start all at once. The lock fd is inherited by GDAL
# children, so the slot frees only when the whole run is gone.
job_acquire_slot() {
  local batch="$1" n="$2" i fd
  mkdir -p "${SLOTS_DIR}"
  while true; do
    for (( i = 1; i <= n; i++ )); do
      exec {fd}>"${SLOTS_DIR}/${batch}.${i}"
      if flock -n "${fd}"; then
        echo "  Job slot: ${i}/${n} (batch ${batch})"
        return 0
      fi
      exec {fd}>&-
    done
    echo "Waiting for a job slot (batch ${batch}, jobs=${n})..."
    sleep 10
  done
}

# Slot lock files are empty and only meaningful while their batch runs.
cleanup_old_slots() {
  local days="${1:-30}"
  [[ -d "${SLOTS_DIR}" ]] || return 0
  find "${SLOTS_DIR}" -maxdepth 1 -type f -mtime "+${days}" -delete 2>/dev/null || true
}
