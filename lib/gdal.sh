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
    -co COMPRESS=DEFLATE -co TILED=YES)
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
    -compute_edges -co COMPRESS=DEFLATE -co TILED=YES
  cat > "${ramp}" <<'RAMP'
0   255 255 255
90    0   0   0
RAMP
  "${GDALDEM[@]}" color-relief "${slope_tif}" "${ramp}" "${out}" \
    -co COMPRESS=DEFLATE -co TILED=YES
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

# ─── Reproject helper ────────────────────────────────────────────────────────
reproject_to_wgs84() {
  local in="$1" out="$2"
  "${GDALWARP[@]}" -t_srs EPSG:4326 -r bilinear \
    -multi -wo NUM_THREADS=ALL_CPUS \
    -co COMPRESS=DEFLATE -co TILED=YES \
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
