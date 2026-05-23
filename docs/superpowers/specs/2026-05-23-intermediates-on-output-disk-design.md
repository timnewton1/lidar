# Intermediates on the output disk

## Problem

Run `a3f4a8` (AZ Pima County 2021 B21, 9406 tiles, 109 GB DEM source) appeared
to run for 28h 30m and report success. It actually failed:

- `gdalwarp` reprojected the hillshade to a 354,810 × 267,575 × 2-band WGS84
  TIFF (~190 GB uncompressed).
- The output file was `mktemp --suffix=_wgs84.tif`, which lands in `$TMPDIR`,
  which defaults to `/tmp`. On Bazzite (and any modern Fedora) `/tmp` is
  **tmpfs** — RAM-backed, 16 GB on this box.
- libtiff hit `_tiffWriteProc: No space left on device` around scanline
  265k. `gdalwarp` doesn't abort on write errors, so it logged the failure
  for ~28 hours before exiting 1.

Two reporting bugs masked the failure (the EXIT trap clobbers `$?` before
capture, and `events_emit_start` records the parent PID which exits within
seconds of dispatch). Those are out of scope here — file separately.

## Rule

DEM source tiles in `${GIS_DIR}/lidar/tiles/dem/` persist across runs.
**Everything else** the pipeline writes is intermediate and must be
deleted, and must be written onto the output disk — never tmpfs.

## Audit

| Artifact | Today | Aligned? |
|---|---|---|
| DEM source tile cache | `${GIS_DIR}/lidar/tiles/dem/` | ✅ |
| Per-project DEM VRT | `_proj_work` (under `${LIDAR_DIR}`) | ✅ |
| Shading TIF (native CRS) | `_proj_work` | ✅ |
| WGS84 reproject TIF | **`/tmp` (tmpfs)** | ❌ |
| COG reproject TIF | next to final COG | ✅ |
| KML tile pyramid (un-zipped) | `${OUT_DIR}/...` | ⚠️ intermediate when only KMZ requested |
| Final KML / KMZ / COG | `${PROJECTS_DIR}/<project>/<hex>/{kml,kmz,cog}/` | ✅ deliverable |

## Fixes

1. **WGS84 intermediate onto output disk.** `libexec/lidar-run:375`:
   `mktemp --suffix=_wgs84.tif` → `mktemp -p "${_proj_work}" wgs84_XXXXXX.tif`.
   The existing EXIT trap reclaims `_proj_work`; the explicit `rm -f` after
   the pyramid stays so multi-project fan-out doesn't carry the WGS84
   working set forward.

2. **Pin GDAL scratch.** Export `TMPDIR` and `CPL_TMPDIR` to `_proj_work`
   inside `_run_one_project`, before any GDAL invocation. Belt-and-
   suspenders against future GDAL features spilling to tmpfs.

3. **KML tree is intermediate when only KMZ requested.** Drop the
   line-85 implication `[[ ${OUTPUT_KMZ} -eq 1 ]] && OUTPUT_KML=1`.
   When `OUTPUT_KMZ=1 && OUTPUT_KML=0`, build the pyramid under
   `_proj_work/kml_stage/<shading>/<project>/`, package to KMZ, let the
   EXIT trap reclaim. When `OUTPUT_KML=1`, build under `${OUT_DIR}/...`
   as today (it's a deliverable). KMZ packaging reads from whichever
   path the pyramid was built into.

4. **Comment.** One-line comment at the new mktemp explaining why we
   don't use tmpfs (cites a3f4a8).

5. **Test.** `tests/test_cli.bats`: static grep over `libexec/lidar-run`
   asserting every `mktemp` call uses `-p` or `-d` with a base path
   under `${LIDAR_DIR}` / `${_proj_work}` / `${WORK_DIR}`. The actual
   190 GB scenario isn't unit-testable; this catches regressions.

## Out of scope (file separately)

- EXIT-trap exit-code clobber in `_on_project_exit` (the "said it worked"
  half of the a3f4a8 fiasco).
- `events_emit_start` recording the soon-dead parent PID (the "crashed
  status the whole run" half).
