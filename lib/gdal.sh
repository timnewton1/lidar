#!/usr/bin/env bash
# GDAL operations: shading derivation, reprojection, VRT mosaicking.
# Requires lib/common.sh (GDAL/GDALDEM/GDALWARP/GDALBUILDVRT arrays,
# HS_* and DEM_NODATA variables).

[[ -n "${_LIDAR_GDAL_LOADED:-}" ]] && return 0
_LIDAR_GDAL_LOADED=1

# ─── WorldCRS84Quad geometry (OGC TileMatrixSet 2D spec) ─────────────────────
# At zoom 0 the world is tiled 2×1; each tile spans 180° square. At zoom z
# there are 2^(z+1) × 2^z tiles, each 180/2^z degrees on a side. Tiles are
# 256-pixel squares, so one tile pixel covers 180 / (256 * 2^z) degrees.
WCQ_TILE_DEG_Z0=180   # tile span in degrees at zoom 0
WCQ_TILE_PX=256       # tile dimension in pixels

# ─── Zoom-range tuning ───────────────────────────────────────────────────────
# Hard ceiling on max zoom — guards against pathological inputs (sub-cm
# pixels) creating thousands of tiles. WorldCRS84Quad z=22 ≈ 2.6 cm/pixel.
ZOOM_MAX_CAP=22

# ─── Derivation: shading algorithms ──────────────────────────────────────────
# Each takes a DEM raster (native or WGS84) and writes a single-band byte
# GeoTIFF ready to tile. Compute in the source projection — gdaldem handles
# units when given a degree-spaced grid via -s; for projected (meter) grids
# the default scale works.

derive_hillshade() {
  local in="$1" out="$2"
  local args=(hillshade "${in}" "${out}"
    -z "${HS_Z_FACTOR}"
    -alg "${HS_ALGORITHM}"
    -compute_edges
    -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES)
  if [[ ${HS_MULTIDIRECTIONAL} -eq 1 ]]; then
    args+=(-multidirectional)
  else
    args+=(-az "${HS_AZIMUTH}" -alt "${HS_ALTITUDE}" -combined)
  fi
  "${GDALDEM[@]}" "${args[@]}"
}

# Slopeshade: slope in degrees → grayscale via color-relief
# (steep = dark, flat = white). Two-step; uses a tmp slope raster.
derive_slopeshade() {
  local in="$1" out="$2"
  local slope_tif="${out%.tif}_slope.tif"
  local ramp="${out%.tif}_ramp.txt"
  "${GDALDEM[@]}" slope "${in}" "${slope_tif}" \
    -compute_edges -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES
  cat > "${ramp}" <<'RAMP'
0   255 255 255
90    0   0   0
RAMP
  "${GDALDEM[@]}" color-relief "${slope_tif}" "${ramp}" "${out}" \
    -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES
  rm -f "${slope_tif}" "${ramp}"
}

derive_shading() {
  local shading="$1" in="$2" out="$3"
  case "${shading}" in
    hillshade)  derive_hillshade  "${in}" "${out}" ;;
    slopeshade) derive_slopeshade "${in}" "${out}" ;;
    *) echo "ERROR: unknown shading: ${shading}" >&2; return 1 ;;
  esac
}

# Read Size + Pixel Size from gdalinfo. Sets SIZE_X SIZE_Y PIXEL_SIZE in caller.
# Returns 1 if any field is missing.
_read_raster_dims() {
  local tif="$1" info
  info=$("${GDALINFO[@]}" "${tif}" 2>/dev/null) || return 1
  # `|| true` keeps pipefail-under-set-e from killing us if grep misses; the
  # explicit empty-string checks below handle the failure path.
  SIZE_X=$(echo "${info}" | { grep -oP '^Size is \K[0-9]+'           || true; })
  SIZE_Y=$(echo "${info}" | { grep -oP '^Size is [0-9]+, \K[0-9]+'   || true; })
  PIXEL_SIZE=$(echo "${info}" | { grep -oP 'Pixel Size = \(\K[0-9.eE+-]+' || true; })
  [[ -n "${SIZE_X}" && -n "${SIZE_Y}" && -n "${PIXEL_SIZE}" ]]
}

# compute_max_zoom: lowest zoom where a tile pixel is no larger than a source
# pixel — i.e. the source's native resolution with no information loss.
# Solving (180 / (256 * 2^z)) ≤ px  →  z ≥ log2(180 / (256*px)). Uses ceil so
# we land at-or-above native, never below. Clamped by ZOOM_MAX_CAP.
# Usage: max_zoom=$(compute_max_zoom path/to/wgs84.tif)
compute_max_zoom() {
  local tif="$1" SIZE_X SIZE_Y PIXEL_SIZE
  _read_raster_dims "${tif}" || { echo "ERROR: could not read raster dims from ${tif}" >&2; return 1; }
  awk -v px="${PIXEL_SIZE}" -v wdeg="${WCQ_TILE_DEG_Z0}" -v tpx="${WCQ_TILE_PX}" -v cap="${ZOOM_MAX_CAP}" 'BEGIN {
    raw = log(wdeg / (tpx * px)) / log(2)
    z = int(raw); if (raw > z) z++   # ceil
    if (z > cap) z = cap
    if (z < 1)   z = 1
    print z
  }'
}

# ─── Reproject helper ────────────────────────────────────────────────────────
# -srcnodata 0: gdaldem writes 0 for nodata pixels (single-band byte).
# -dstalpha: bilinear can blend nodata=0 into real pixels near edges, leaving
# a dark halo around the data. Generating an explicit alpha band from source
# coverage means transparency is decoupled from grayscale values.
reproject_to_wgs84() {
  local in="$1" out="$2"
  "${GDALWARP[@]}" -t_srs EPSG:4326 -r bilinear \
    -srcnodata 0 -dstalpha \
    -multi -wo NUM_THREADS=ALL_CPUS \
    -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES \
    "${in}" "${out}"
}

# ─── VRT mosaic ──────────────────────────────────────────────────────────────
# Build a per-project DEM mosaic VRT from a file-of-paths.
# Pins nodata explicitly: adjacent USGS projects sometimes ship different
# NoData defaults, causing bright/dark seam artifacts at boundaries.
build_dem_vrt() {
  local list_file="$1" out_vrt="$2"
  "${GDALBUILDVRT[@]}" \
    -srcnodata "${DEM_NODATA}" -vrtnodata "${DEM_NODATA}" \
    -input_file_list "${list_file}" "${out_vrt}"
}
