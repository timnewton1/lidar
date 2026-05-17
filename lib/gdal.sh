#!/usr/bin/env bash
# GDAL operations: shading derivation, reprojection, VRT mosaicking.
# Requires lib/common.sh (GDAL/GDALDEM/GDALWARP/GDALBUILDVRT arrays,
# HS_* and DEM_NODATA variables).

[[ -n "${_LIDAR_GDAL_LOADED:-}" ]] && return 0
_LIDAR_GDAL_LOADED=1

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

# Compute the WorldCRS84Quad max zoom that matches a raster's native resolution.
# Reads pixel size from gdalinfo, applies round(log2(360/(256*px))), caps at 22.
# Usage: max_zoom=$(compute_max_zoom path/to/wgs84.tif)
compute_max_zoom() {
  local tif="$1"
  local pixel_size
  # `|| true` keeps pipefail from killing us under set -e if grep finds nothing;
  # the empty-string check below handles the failure cleanly.
  pixel_size=$("${GDALINFO[@]}" "${tif}" 2>/dev/null \
    | { grep -oP 'Pixel Size = \(\K[0-9.eE+-]+' || true; })
  [[ -z "${pixel_size}" ]] && { echo "ERROR: could not read pixel size from ${tif}" >&2; return 1; }
  awk -v px="${pixel_size}" 'BEGIN {
    z = log(360 / (256 * px)) / log(2)
    z = int(z + 0.5)  # round to nearest: preserves native res without upsampling
    print (z > 22) ? 22 : (z < 1) ? 1 : z
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
