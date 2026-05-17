# Tile pyramid refactor — best-practice KML SuperOverlay

**Date:** 2026-05-17
**Branch:** refactor-lidar-subcommands
**Status:** approved, pending implementation plan

## Motivation

Successive zoom-related fixes (commits 71c6d96 → 89319e4) layered bandaids
on top of the tile-pyramid step instead of addressing root causes. Symptoms
in Google Earth Pro: overlay invisible when zoomed out, render artifacts as
you zoom in.

Research (web, 2025-2026) identified two real root causes:

1. **Our handwritten wrapper KMLs (`lib/kml.sh::write_shading_kml` and
   `write_root_kml`) contain no `<Region>` elements.** `gdal raster tile`
   produces a proper per-tile `<Region><Lod>` super-overlay in each
   project's `doc.kml`, but our wrapper bundles them inside bare
   `<NetworkLink>` containers with no LOD gate. Google Earth has no
   directive for when to start streaming a pyramid.

2. **`-r average` + `--overview-resampling average` blend alpha-edge
   pixels** with neighbors across overview levels, producing visible
   halos and tile-seam artifacts.

A third issue is structural: `compute_min_zoom` (commit 89319e4) tried
to fix an oversized `doc.kml` bounding box by truncating tile levels.
That's the wrong layer — the bounding box belongs to a `<Region>` in
the wrapper, not to the pyramid depth.

## Decision

Stop hand-writing KML wrappers. Let `gdal raster tile` produce one
self-contained KML super-overlay per `(shading, project)`. No root
`doc.kml`, no per-shading `doc.kml`.

## Output structure

```
${KML_DIR}/${NAME}/
  hillshade/
    ${PROJECT_A}/doc.kml      ← gdal-generated super-overlay
    ${PROJECT_A}/<tile dirs>/
    ${PROJECT_B}/doc.kml
    ${PROJECT_B}/<tile dirs>/
  slopeshade/
    ${PROJECT_A}/doc.kml
    ...
```

To view: `File → Open` whichever per-project super-overlay(s) the user
wants. Each is a standalone, spec-correct KML super-overlay with proper
Region/LOD per tile. Multi-shading is two `File → Open` actions.

## Code changes

### `lib/gdal.sh`

- Delete `compute_min_zoom`.
- Delete constants `ZOOM_MIN_TILES_PER_SIDE` and `ZOOM_MIN_OVERVIEW_LEVELS`.
- Keep `compute_max_zoom` and `WCQ_TILE_DEG_Z0` / `WCQ_TILE_PX` / `ZOOM_MAX_CAP`.
  Auto-detect in `gdal raster tile` rounds down by one for sub-meter data
  (OSGeo/gdal #2799, #3460), so an explicit max stays. Min-zoom is
  unaffected and gdal's auto-pick is fine.
- Keep `_read_raster_dims` (used by `compute_max_zoom`).
- Keep `reproject_to_wgs84` (`-srcnodata 0 -dstalpha` is the practitioner-
  idiomatic pattern; halo fix confirmed correct).

### `libexec/lidar-run`

- In Step 6, change the `gdal raster tile` invocation:
  - `-r average` → `-r cubic`
  - `--overview-resampling average` → `cubic`
  - Drop `--min-zoom "${MIN_ZOOM}"` (let auto-pick handle it).
  - Keep `--max-zoom "${MAX_ZOOM}"`.
  - Keep all other flags: `--tiling-scheme WorldCRS84Quad --kml
    --webviewer none --skip-blank --title "${PROJECT}" -j ALL_CPUS`.
- Delete Step 7 ("Writing KML index") entirely.
- Update the "ALL DONE" summary: enumerate every generated `doc.kml`
  path, group by shading. Remove the `Root KML : ${ROOT_KML}` line.
- Remove `ROOT_KML` variable.

### `lib/kml.sh`

- Delete `write_shading_kml` and `write_root_kml` (now unused).
- Keep `package_kmz` — repurposed (see KMZ section below).

### KMZ packaging (`--kmz`)

A KMZ archive expects exactly one `doc.kml` at its root. With no
unified root, we shift to **one KMZ per (shading, project)** super-
overlay. Each KMZ is independently openable and portable.

Layout under `${LIDAR_DIR}/kmz/${NAME}/`:
```
hillshade__${PROJECT_A}.kmz
hillshade__${PROJECT_B}.kmz
slopeshade__${PROJECT_A}.kmz
...
```

`package_kmz` stays as a generic "zip a directory containing doc.kml
into a kmz" helper, called once per (shading, project) when `--kmz`
is set.

### Parallelism

Each (shading, project) tile job is now fully independent. But
`gdal raster tile -j ALL_CPUS` already saturates the CPU per job.
Running multiple jobs concurrently would thrash, not speed up. **Keep
the outer loop sequential**; the existing parallelism inside each
gdal invocation is sufficient and unchanged.

### Logging

- `events_emit_start` / `events_emit_end` — unchanged. One event pair
  per `lidar run` invocation. (User has only one run in flight.)
- Step 6 per-job headers (`${SHADING} / ${PROJECT}`) — unchanged.
- New trailing summary lists each emitted super-overlay path so the
  user can copy-paste into Google Earth's File→Open dialog. KMZ paths
  printed too when `--kmz` is set.

### Tests (`bats`)

- Existing tests that check wrapper KML structure must be removed or
  rewritten. Specifically anything referencing `write_root_kml` /
  `write_shading_kml` / the root `doc.kml`.
- Add: smoke test that `gdal raster tile` invocation produces a
  `doc.kml` per project containing a `<Region>` element. Skipped if
  GDAL not installed.

## Non-goals

- No change to download/prescan/VRT-build steps. Per-project mosaics
  stay (different USGS projects ship at different native resolutions;
  merging would force the coarsest project to tile at the finest
  resolution, wasting tiles).
- No change to the events index, runs.jsonl, or `lidar list` / `lidar
  log` / `lidar size` subcommands. `lidar size` still walks the
  pyramid tree by directory depth.
- No change to backup or migration of existing output directories.
  Existing runs are unaffected; new runs use the new layout.

## Backout

Single commit. Revert restores the old wrapper KML behavior.

## Risk

- Users who scripted around the single-root `doc.kml` path will need to
  open per-shading-project files instead. The script's documented
  output is `Pyramid : ${OUT_DIR}/`; the root KML was emitted but not
  the documented interface.
- The `cubic` resampling slightly increases per-tile build time vs
  `average`. Expected to be within noise on real datasets.
- `gdal raster tile` is provisional in GDAL 3.11+ (subject to flag
  changes until a future PSC vote). Acceptable: we already depend on
  it, and it's the official successor to gdal2tiles.py (removed in
  3.15).
