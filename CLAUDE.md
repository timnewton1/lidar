# CLAUDE.md — notes for AI assistants working in this repo

## What this is

A bash CLI that turns USGS 3DEP lidar tile lists into Google Earth
super-overlays (KML/KMZ) and/or Cloud-Optimized GeoTIFFs (COG). The user
runs it on Bazzite (immutable Fedora). The pipeline runs only inside the
`localhost/lidar` Podman image (GDAL 3.13.3 from `ghcr.io/osgeo/gdal`);
each run is a rootless quadlet unit `lidar@<hex>.service`. The QGIS Flatpak
is no longer used (dropped 2026-10-25 — it blocked systemd hardening and
escaped unit cgroups).

See [`README.md`](README.md) for the user-facing overview.

## Layout

```
lidar                    # HOST wrapper: stages inputs, podman run, systemctl.
                         #   Only host-side logic lives here (install, build,
                         #   test, kill, restart, unit start). Needs only podman.
Containerfile            # image = GDAL + tools; NO code (repo is bind-mounted ro)
.containerignore         # `*` — build context is intentionally empty
quadlet/lidar@.container # one unit per run; symlinked into ~/.config/containers/systemd
libexec/lidar-dispatch   # in-container ENTRYPOINT; execs libexec/lidar-<sub>
libexec/lidar-<sub>      # in-container subcommands:
  run                      plan only: validate, fan out, write job specs, print `@job <hex>`
  worker                   Exec of lidar@<hex>: PID-1 supervisor + the pipeline
  list, size               reporting
  resolve                  hex prefix → full id (used by host kill/restart)
lib/<name>.sh            # sourced libraries:
  strict.sh                set -Eeuo pipefail + ERR trap; sourced first
  common.sh                GDAL_* arrays, paths, KNOWN_SHADINGS, helpers
  download.sh              tile download pipeline (check_deps, prescan, download)
  gdal.sh                  shading derivation, reprojection, VRT mosaic
  kml.sh                   KMZ zip packaging
  cog.sh                   COG output (DEM + shading), CRS detection, UTM auto-pick
  events.sh                runs.jsonl events index, liveness, run-id resolver
  jobs.sh                  job spec write/load, --jobs slot semaphore
  diag.sh                  pre-run environment banner, signal exit reasons
tests/test_*.bats        # bats tests + fixtures/
docs/superpowers/        # design specs and implementation plans
```

## Conventions to preserve

- **`set -Eeuo pipefail`** — every executable in `libexec/` sources
  `lib/strict.sh` first. Don't skip.
- **Library files** start with `[[ -n "${_LIDAR_<NAME>_LOADED:-}" ]] && return 0`
  guards. Follow the pattern.
- **GDAL comes from the image** — invoke via the `GDAL`, `GDALDEM`,
  `GDALINFO`, `GDALWARP`, `GDALBUILDVRT`, `GDALTRANSLATE` arrays in
  `lib/common.sh` (one indirection point; `run_gdal` logs them). Never call
  `gdal_*` directly.
- **Host vs container split.** Anything needing GDAL, jq, or the data layout
  runs in the container. Anything needing systemd (unit start/stop, liveness)
  runs in the host wrapper. The container learns which runs are alive only
  via `LIDAR_ACTIVE` (space-separated ids) — PIDs mean nothing across
  containers, so never reintroduce pid-based liveness.
- **Dispatcher → worker hand-off is the job spec** (`lib/jobs.sh`). A new
  flag the worker needs must be added to `JOB_VARS`, or the worker silently
  uses defaults.
- **Worker EXIT-trap state must be global.** The trap fires after
  `_run_one_project` returns; locals are gone by then (regression test in
  `test_cli.bats`).
- **No backwards-compat aliases.** When the user asks to rename or replace
  a flag, the old form is removed cleanly (see the `--kmz`/`--cog` →
  `--output` refactor).
- **Comments explain WHY, not WHAT.** The codebase has substantial
  `# explanation` blocks for non-obvious GDAL flags, KML quirks, etc. Match
  that style. Don't add docstrings narrating obvious operations.

## User preferences (durable)

- **Prefer generalized format/concept names over platform-specific names.**
  e.g., `--output cog` not `--output qgis`; `lib/cog.sh` not `lib/qgis.sh`.
- **Avoid hardcoded defaults**, especially region- or platform-specific
  ones. Prefer auto-detection plus explicit overrides. The user calls this
  "great optionality." Example: `--cog-crs` defaults to auto-UTM-from-
  centroid, not `EPSG:5070` (CONUS-only).
- **One concern per lib file.** New functionality typically gets a new
  `lib/<name>.sh` rather than being bolted into an existing lib.

## Working on a feature

1. **Brainstorm + spec** — write to `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`
2. **Feature branch** named after the change (e.g. `cog-output`, `output-csv`)
3. **Implement** — one focused commit per logical unit; bats test for any
   CLI surface change
4. **Merge** with `git merge --no-ff <branch>` to preserve branch history

## Testing

```bash
lidar test        # bats inside the image (host has no GDAL)
```

Tests run offline. Flag parsing, validation, dry-run output, job specs, and
pure-bash helpers are testable; tests call `libexec/lidar-dispatch`, not the
host wrapper. The end-to-end pipeline (downloads + GDAL + real tiles) is not
— verify by running `lidar run tests/fixtures/one_tile.txt` and checking
`lidar list`. That fixture is a small live AZ_PimaCounty tile; USGS does
retire tiles (the previous AK fixture 404s), so re-check it if it fails in
STEP 4.

When adding CLI surface, add bats coverage in `tests/test_cli.bats`. Match
the existing patterns (the test that drives `-c is equivalent to --cog` was
the prior shape; `-o is equivalent to --output` is the current one).

## Environment

- **OS**: Bazzite (immutable Fedora). Don't suggest `dnf install`; new tools
  go in the Containerfile.
- **Config**: `~/.config/lidar/lidar.env` (`LIDAR_REPO`, `GIS_DIR`), written
  by `lidar install`, read by the wrapper and by the quadlet (systemd expands
  `${GIS_DIR}` / `${LIDAR_REPO}` in the generated ExecStart). There is no
  per-command `--gis-dir`: the quadlet's mounts are fixed per install.
- **Mounts**: repo → `/opt/lidar` (ro,z — it's under `$HOME`); `GIS_DIR` →
  the same path in the container, so log/event paths are valid on the host.
  The data disk is already `container_file_t`; don't add `:Z` to it.
- **`LIDAR_HOME`**: `/opt/lidar` in the image (`ENV`). Subcommands and libs
  assume it's set.

## Tile cache

Downloaded source tiles live in `${GIS_DIR}/lidar/tiles/dem/` and are
shared across runs — multiple `lidar run` invocations targeting overlapping
tile lists won't re-download. Don't add per-run subdirectories under
`tiles/dem/`; that breaks the cache.

## Common pitfalls

- **GDAL nodata bleed** when reprojecting: use `-srcnodata <val> -dstalpha`
  for shading rasters (uint8) to avoid halos. The pattern is in
  `reproject_to_wgs84` (gdal.sh) and `build_cog_shade` (cog.sh).
- **GDAL_TRANSLATE float predictor**: `PREDICTOR=FLOATING_POINT` is only
  valid for float data (DEMs). Don't apply it to uint8 shading rasters.
- **KML super-overlay LOD threshold**: forcing `--min-zoom 0` matters;
  see the long comment in `lidar-run` Step 6 for the rationale.
- **VRT for QGIS 3D**: QGIS 3D Map View has known VRT bugs ([#63612](https://github.com/qgis/QGIS/issues/63612)). Prefer COG output over VRT for terrain.

## Reference

- USGS 3DEP downloader: <https://apps.nationalmap.gov/downloader/>
- 3D Tiles spec: <https://www.ogc.org/standards/3dtiles/>
- QGIS 3D docs: <https://docs.qgis.org/3.44/en/docs/user_manual/map_views/3d_map_view.html>
