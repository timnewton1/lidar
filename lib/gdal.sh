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

# compute_zoom_and_lookat: single gdalinfo call that emits both the max zoom
# level and the LookAt "lon lat range" on two lines.
# Combines what compute_max_zoom + compute_lookat used to do in two separate
# Flatpak spawns — saves one bwrap invocation per (shading × project) pair.
#
# Output (two lines on stdout):
#   <max_zoom>
#   <lon> <lat> <range_m>
#
# Returns 1 if gdalinfo fails or any required field is missing.
# Usage: { read -r MAX_ZOOM; read -r LK_LON LK_LAT LK_RANGE; } < <(compute_zoom_and_lookat tif)
compute_zoom_and_lookat() {
  local tif="$1" SIZE_X SIZE_Y PIXEL_SIZE
  _read_raster_dims "${tif}" || { echo "ERROR: could not read raster dims from ${tif}" >&2; return 1; }
  # _read_raster_dims captures PIXEL_SIZE from the same gdalinfo run we need for
  # lookat, but it only retains the scalar pixel size. For lookat we need corners
  # too, so we run gdalinfo once more — but only once total for both outputs.
  local info
  info=$("${GDALINFO[@]}" "${tif}" 2>/dev/null) || return 1
  local cx cy ulx uly lrx lry
  cx=$(echo "${info}"  | { grep -oP '^Center\s*\(\s*\K-?[0-9.]+'                    || true; })
  cy=$(echo "${info}"  | { grep -oP '^Center\s*\(\s*-?[0-9.]+,\s*\K-?[0-9.]+'       || true; })
  ulx=$(echo "${info}" | { grep -oP '^Upper Left\s*\(\s*\K-?[0-9.]+'                || true; })
  uly=$(echo "${info}" | { grep -oP '^Upper Left\s*\(\s*-?[0-9.]+,\s*\K-?[0-9.]+'   || true; })
  lrx=$(echo "${info}" | { grep -oP '^Lower Right\s*\(\s*\K-?[0-9.]+'               || true; })
  lry=$(echo "${info}" | { grep -oP '^Lower Right\s*\(\s*-?[0-9.]+,\s*\K-?[0-9.]+' || true; })
  [[ -n "${cx}" && -n "${cy}" && -n "${ulx}" && -n "${uly}" && -n "${lrx}" && -n "${lry}" ]] \
    || { echo "ERROR: could not parse corner coords from ${tif}" >&2; return 1; }
  awk -v px="${PIXEL_SIZE}" \
      -v wdeg="${WCQ_TILE_DEG_Z0}" -v tpx="${WCQ_TILE_PX}" -v cap="${ZOOM_MAX_CAP}" \
      -v cx="${cx}" -v cy="${cy}" \
      -v ulx="${ulx}" -v uly="${uly}" -v lrx="${lrx}" -v lry="${lry}" 'BEGIN {
    # max zoom: lowest zoom where tile pixel ≤ source pixel
    raw = log(wdeg / (tpx * px)) / log(2)
    z = int(raw); if (raw > z) z++
    if (z > cap) z = cap
    if (z < 1)   z = 1
    print z
    # lookat range: ~111 km/deg, 1.5× padding, 5 km floor
    w = lrx - ulx; if (w < 0) w = -w
    h = uly - lry; if (h < 0) h = -h
    ext_deg = (w > h ? w : h)
    range = ext_deg * 111000 * 1.5
    if (range < 5000) range = 5000
    printf "%s %s %d\n", cx, cy, range
  }'
}

# Inject a <LookAt> element into a KML Document so Google Earth focuses on
# the data (not on the geographic union of world-spanning overview tiles).
# Args: <doc_kml_path> <lon> <lat> <range_m>
inject_lookat() {
  local kml="$1" lon="$2" lat="$3" range="$4"
  local lookat="<LookAt><longitude>${lon}</longitude><latitude>${lat}</latitude><altitude>0</altitude><range>${range}</range><tilt>0</tilt><heading>0</heading><altitudeMode>relativeToGround</altitudeMode></LookAt>"
  # Replace the FIRST <Document> open tag only. 0,/pat/{} confines the
  # substitution to the range up to and including the first match.
  sed -i "0,/<Document>/{s|<Document>|<Document>${lookat}|}" "${kml}"
}

# ensure_root_networklink: gdal raster tile emits a root doc.kml with no
# <NetworkLink> when --skip-blank suppresses every min-zoom tile (happens
# when the data extent is much smaller than a z=0 WorldCRS84Quad tile —
# the data resamples to fully-transparent pixels and the tile is dropped,
# so the KML emitter has nothing to link to). Google Earth then opens an
# empty Document. Fix: link the root to the lowest-zoom tile KML that
# actually exists on disk. Idempotent — no-op if a NetworkLink is already
# present.
# Args: <doc_kml_path> <tile_dir>
ensure_root_networklink() {
  local kml="$1" dir="$2"
  grep -q '<NetworkLink' "${kml}" && return 0
  # Tile-KML layout is <dir>/<z>/<x>/<y>.kml. sort -V orders numerically
  # across z, x, y so head picks the lowest zoom (and within it, the
  # lowest x/y) — a child tile whose own <Region> is well-formed.
  local child
  child=$(find "${dir}" -mindepth 3 -maxdepth 3 \
            -regextype posix-extended -regex '.*/[0-9]+/[0-9]+/[0-9]+\.kml' \
          | sort -V | head -n1) || true
  [[ -z "${child}" ]] && { echo "  WARN: no child KML under ${dir}; doc.kml left without NetworkLink" >&2; return 0; }
  local rel="${child#${dir}/}"
  # Copy the child's first <LatLonAltBox> (its own Region) so the root
  # Region matches the tile it links to. The child also contains nested
  # <LatLonAltBox> elements for its own NetworkLinks — stop at the first.
  local box
  box=$(awk '/<LatLonAltBox>/{flag=1} flag{print} /<\/LatLonAltBox>/{exit}' "${child}")
  [[ -z "${box}" ]] && { echo "  WARN: no <LatLonAltBox> in ${child}; doc.kml left without NetworkLink" >&2; return 0; }
  local nl="    <NetworkLink>
      <name>${rel}</name>
      <Region>
${box}
        <Lod>
          <minLodPixels>128</minLodPixels>
          <maxLodPixels>-1</maxLodPixels>
        </Lod>
      </Region>
      <Link>
        <href>${rel}</href>
        <viewRefreshMode>onRegion</viewRefreshMode>
      </Link>
    </NetworkLink>"
  # Insert before </Document>. Use python for a multi-line, regex-safe
  # replace — sed multi-line escaping in shell is fragile.
  python3 -c '
import sys
p, nl = sys.argv[1], sys.argv[2]
with open(p) as f: t = f.read()
with open(p, "w") as f: f.write(t.replace("</Document>", nl + "\n</Document>", 1))
' "${kml}" "${nl}"
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
