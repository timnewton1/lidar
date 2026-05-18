# CLAUDE.md — notes for AI assistants working in this repo

## What this is

A bash CLI that turns USGS 3DEP lidar tile lists into Google Earth
super-overlays (KML/KMZ) and/or Cloud-Optimized GeoTIFFs (COG). The user
runs it on Bazzite (immutable Fedora), so all GDAL operations go through
the Flatpak `org.qgis.qgis` app.

See [`README.md`](README.md) for the user-facing overview.

## Layout

```
lidar                  # dispatcher; sets LIDAR_HOME, execs libexec/lidar-<sub>
libexec/lidar-<sub>    # one file per subcommand (run, list, log, size, kill, ...)
lib/<name>.sh          # sourced libraries:
  strict.sh              set -Eeuo pipefail + ERR trap; sourced first
  common.sh              GDAL_* arrays, paths, KNOWN_SHADINGS, helpers
  download.sh            tile download pipeline (check_deps, prescan, download)
  gdal.sh                shading derivation, reprojection, VRT mosaic
  kml.sh                 KMZ zip packaging
  cog.sh                 COG output (DEM + shading), CRS detection, UTM auto-pick
  events.sh              runs.jsonl events index used by `lidar list`
systemd/lidar@.service # template for `lidar service install`
tests/test_*.bats      # bats tests + fixtures/
docs/superpowers/      # design specs and implementation plans
```

## Conventions to preserve

- **`set -Eeuo pipefail`** — every executable in `libexec/` sources
  `lib/strict.sh` first. Don't skip.
- **Library files** start with `[[ -n "${_LIDAR_<NAME>_LOADED:-}" ]] && return 0`
  guards. Follow the pattern.
- **GDAL is in Flatpak** — invoke via the `GDAL`, `GDALDEM`, `GDALINFO`,
  `GDALWARP`, `GDALBUILDVRT`, `GDALTRANSLATE` arrays in `lib/common.sh`.
  Never call `gdal_*` directly.
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
bats tests/
```

Tests run offline. Flag parsing, validation, dry-run output, and pure-bash
helpers are testable. The end-to-end pipeline (downloads + Flatpak GDAL +
real tiles) is not — verify those by running `lidar run` manually with a
small fixture like `tests/fixtures/one_tile.txt`.

When adding CLI surface, add bats coverage in `tests/test_cli.bats`. Match
the existing patterns (the test that drives `-c is equivalent to --cog` was
the prior shape; `-o is equivalent to --output` is the current one).

## Environment

- **OS**: Bazzite (immutable Fedora). Don't suggest `dnf install`; use
  Flatpak or distrobox.
- **Required env**: `GIS_DIR` must be set (or passed via `--gis-dir`). All
  run outputs land under `${GIS_DIR}/lidar/`.
- **`LIDAR_HOME`**: exported by the `lidar` entrypoint. Subcommands and
  libs assume it's set.

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
