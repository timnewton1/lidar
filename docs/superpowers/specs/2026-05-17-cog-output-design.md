# COG output flag for `lidar run`

**Status**: approved
**Date**: 2026-05-17
**Branch**: `cog-output`

## Goal

Add an opt-in `-c|--cog` flag to `lidar run` that produces Cloud-Optimized
GeoTIFF mosaics (one DEM COG per project, one shade COG per shading×project)
alongside the existing KML pyramid output. The COGs are drop-in ready for
QGIS, ArcGIS, MapServer, or any tool that reads GeoTIFF — they are not
QGIS-specific.

## Why

The existing KML super-overlay output targets Google Earth, which renders
streamed raster tiles draped on Google's globe. For full-detail 3D terrain
analysis in QGIS or similar tools, a single self-contained raster file with
internal overviews loads faster and more reliably than a VRT pointing at
hundreds of source tiles (and QGIS 4.x has known VRT-as-3D-terrain bugs).

## Output

```
${LIDAR_DIR}/cog/${NAME}/
  ${PROJECT}_dem.tif              # float32 DEM, ZSTD+FLOATING_POINT predictor
  ${SHADING}__${PROJECT}.tif      # uint8+alpha shade, ZSTD
  README.md                       # setup notes + file inventory
```

Naming mirrors the existing KMZ convention (`${SHADING}__${PROJECT}.kmz`).
The directory sits parallel to `${LIDAR_DIR}/kml/` and `${LIDAR_DIR}/kmz/`.

## CLI

Output selection is a CSV via `--output`, replacing the previous boolean
`--kmz` / `--cog` flags. Default is `kml` (preserves prior behavior for
existing scripts that pass no output flags).

| Flag | Effect |
|------|--------|
| `-o`, `--output OUTPUTS` | Comma-separated outputs. Known: `kml`, `kmz`, `cog`. Default: `kml`. |
| `--cog-crs EPSG:NNNN` | Reproject COG output to this CRS (must match `^EPSG:[0-9]+$`) |
| `--cog-no-reproject` | Force native CRS for COG output even if geographic (with stderr warning) |

Output semantics:

- `kml` — Google Earth super-overlay tile pyramid (the expensive step)
- `kmz` — kml + zipped `.kmz` (auto-enables kml; you cannot zip a pyramid that wasn't built)
- `cog` — Cloud-Optimized GeoTIFFs into `${LIDAR_DIR}/cog/${NAME}/`

`--output cog` (without `kml`) is dramatically faster — skips the WGS84
reproject (Step 6b) and the `gdal raster tile` pyramid build (Step 6c),
which together dominate post-download wall time at high zoom levels.

Validation (runs before any heavy lifting):
- Each token must be in `{kml, kmz, cog}` (case-insensitive)
- Empty tokens rejected
- `--cog-crs` matches `^EPSG:[0-9]+$` if provided
- `--cog-crs` and `--cog-no-reproject` require `cog` in `--output`
- `--cog-crs` and `--cog-no-reproject` mutually exclusive

### CRS resolution

When `--cog` is set, target CRS is resolved per project:

1. `--cog-crs` set → use it
2. `--cog-no-reproject` set → use source CRS, emit warning if geographic
3. Source CRS is projected → use source CRS (no reproject)
4. Source CRS is geographic → auto-pick UTM zone from raster centroid
   - zone = `floor((center_lon + 180) / 6) + 1`
   - EPSG = `32600 + zone` (north hemisphere) or `32700 + zone` (south)

No hardcoded continent-specific default. UTM works globally and gives
projected meters suitable for QGIS 3D anywhere on Earth.

## Architecture

Mirrors the existing `lib/kml.sh` pattern: one focused lib file with a few
public functions, called from `libexec/lidar-run`.

### New file: `lib/cog.sh`

Public functions:

- `cog_resolve_crs <dem_vrt>` — echoes the target CRS for this project based
  on flag precedence; reads `COG_CRS`, `COG_NO_REPROJECT`. Emits a warning to
  stderr when `--cog-no-reproject` is used on geographic data.
- `build_cog_dem <in_vrt> <out_cog> <target_crs>` — reprojects (if target
  differs from source) then writes COG with float-friendly compression.
- `build_cog_shade <in_tif> <out_cog> <target_crs>` — reprojects (if needed)
  with `-srcnodata 0 -dstalpha` to avoid halos, then writes COG with uint8-
  friendly compression.
- `write_cog_readme <dir> <crs_summary>` — writes markdown notes.

Private helpers:

- `_cog_is_geographic <tif>` — gdalinfo -json + python3 WKT check; defaults
  to "not geographic" on parse error.
- `_cog_pick_utm <tif>` — gdalinfo + awk to compute UTM EPSG from centroid.

### Modified: `lib/common.sh`

Add:

```bash
GDALTRANSLATE=(flatpak run --command=gdal_translate "${GDAL_FLATPAK_APP}")
```

### Modified: `libexec/lidar-run`

1. Add usage doc for `-c|--cog`, `--cog-crs`, `--cog-no-reproject`
2. Parse the three new flags; init `PACKAGE_COG=0`, `COG_CRS=""`, `COG_NO_REPROJECT=0`
3. Validate after parse:
   - `--cog-crs` matches `^EPSG:[0-9]+$` if non-empty
   - `--cog-crs` and `--cog-no-reproject` mutually exclusive
   - `--cog-crs` / `--cog-no-reproject` require `--cog`
4. Source `lib/cog.sh`
5. Compute `COG_DIR="${LIDAR_DIR}/cog/${NAME}"`; reject if exists and `--cog`
6. Update dry-run output: `Package COG`, `COG CRS` (or `auto/native/<value>`)
7. **Step 6** cleanup: split `rm -f "${SHADE_TIF}" "${WGS84_TIF}"` so
   `SHADE_TIF` survives when `PACKAGE_COG=1`. WGS84_TIF still always removed.
8. **New Step 7** (before KMZ): if `PACKAGE_COG=1`:
   - `mkdir -p "${COG_DIR}"`
   - For each project: resolve CRS once via `cog_resolve_crs`, cache,
     call `build_cog_dem`
   - For each shading×project: call `build_cog_shade` with cached CRS
   - Call `write_cog_readme`
9. **KMZ becomes Step 8** (renumber comments only)
10. Final summary: print COG output paths when present

## Data type assumptions

| Input | Type | Compression |
|-------|------|-------------|
| USGS 3DEP DEM tiles | Float32 | `ZSTD` + `PREDICTOR=FLOATING_POINT` |
| `derive_hillshade` output | Byte (uint8) | `ZSTD`, no predictor |
| `derive_slopeshade` output | Byte (uint8) | `ZSTD`, no predictor |

If a non-3DEP integer DEM is ever passed in, `PREDICTOR=FLOATING_POINT` will
error out cleanly from gdal_translate. Not a supported case.

## Reprojection details

Reprojection only happens when target CRS differs from source CRS.

**DEM reproject** (when needed):
```
gdalwarp -t_srs <target> \
  -srcnodata -9999 -dstnodata -9999 \
  -r bilinear -multi -wo NUM_THREADS=ALL_CPUS \
  -co COMPRESS=DEFLATE -co TILED=YES
```

**Shade reproject** (when needed) — uses `-dstalpha` to avoid the halo bug
that `reproject_to_wgs84` already solves for the KML path:
```
gdalwarp -t_srs <target> \
  -srcnodata 0 -dstalpha \
  -r bilinear -multi -wo NUM_THREADS=ALL_CPUS \
  -co COMPRESS=DEFLATE -co TILED=YES
```

**COG output (DEM)**:
```
gdal_translate -of COG \
  -co COMPRESS=ZSTD \
  -co PREDICTOR=FLOATING_POINT \
  -co BLOCKSIZE=512 \
  -co OVERVIEW_RESAMPLING=BILINEAR
```

**COG output (shade)**:
```
gdal_translate -of COG \
  -co COMPRESS=ZSTD \
  -co BLOCKSIZE=512 \
  -co OVERVIEW_RESAMPLING=BILINEAR
```

`BILINEAR` overview resampling is correct for DEMs (preserves elevation
continuity) and acceptable for hillshade (smooths overview tiles without
the false-ridge artifacts that `AVERAGE` would create at tile boundaries).

## Tests

bats cases in `tests/test_cli.bats`:

- `--cog` accepted, dry-run plan shows `Package COG : 1`
- `-c` equivalent to `--cog`
- `--cog-crs FOO` rejected with clear error
- `--cog-crs EPSG:32614` accepted
- `--cog-crs X --cog-no-reproject` rejected as contradictory
- `--cog-crs X` without `--cog` rejected
- `--cog-no-reproject` without `--cog` rejected

No integration tests for the actual COG production (needs flatpak GDAL +
real tiles; same gap that exists for the KMZ path).

## Out of scope

- A `lidar cog` subcommand that post-processes an existing run. Not needed
  for V1; the `--cog` flag during the run covers the use case.
- Auto-generated `.qgs/.qgz` project files. Requires PyQGIS; manual QGIS 3D
  setup is ~30 seconds. README.md documents the steps.
- COG-of-COG mosaicking across projects (single COG covering all projects).
  Per-project COGs are easier to manage and match the per-project KMZ pattern.
- Color ramps / `.qml` style sidecars. User-specific; out of scope.

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Reprojected shade halo from nodata blending | `-srcnodata 0 -dstalpha` mirrors existing `reproject_to_wgs84` fix |
| `PREDICTOR=FLOATING_POINT` errors on non-float DEMs | Acceptable; USGS 3DEP is always Float32, error is clear |
| Disk usage doubles (DEM tiles + COG mosaic) | User opts in via `--cog`; warned in README |
| `gdalinfo -json` parse failure | `_cog_is_geographic` defaults to "no" — safer not to reproject than to fail |
| Source UTM detection wrong for cross-zone data | If centroid falls in zone X but data spans X-1 and X, the wrong zone is picked. User can override with `--cog-crs`. Acceptable. |
