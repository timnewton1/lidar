#!/usr/bin/env bash
# Cloud-Optimized GeoTIFF output: per-project DEM + per-shading-per-project
# shade rasters, written as self-contained COG files with internal overviews.
# Drop-in for QGIS / ArcGIS / MapServer or anything that reads GeoTIFF.
#
# Requires lib/common.sh (GDAL*, DEM_NODATA) and reads:
#   COG_CRS            — explicit user override (EPSG:NNNN or empty)
#   COG_NO_REPROJECT   — 1 to keep native CRS even if geographic
#
# CRS resolution precedence (per project):
#   1. COG_CRS set                 → use it
#   2. COG_NO_REPROJECT=1          → use source CRS (warn if geographic)
#   3. source CRS projected        → use source CRS
#   4. source CRS geographic       → auto-pick UTM zone from centroid

[[ -n "${_LIDAR_COG_LOADED:-}" ]] && return 0
_LIDAR_COG_LOADED=1

# Returns 0 if the raster has a geographic (degree-based) horizontal CRS.
# Parses the WKT root keyword via gdalinfo -json + python3. Handles WKT1
# (GEOGCS), WKT2 (GEOGCRS), and compound CRS (COMPD_CS/COMPOUNDCRS) where
# only the horizontal axis matters. Defaults to "not geographic" on parse
# error — safer not to reproject than to fail mid-run.
#
# Why not a substring check: PROJCRS WKT contains BASEGEOGCRS as a child,
# so naive "GEOGCRS in wkt" produces false positives on projected rasters.
_cog_is_geographic() {
  local tif="$1" json
  json=$("${GDALINFO[@]}" -json "${tif}" 2>/dev/null) || return 1
  python3 - "$json" <<'PY' >/dev/null 2>&1
import sys, json, re
try:
    d = json.loads(sys.argv[1])
    wkt = d.get("coordinateSystem", {}).get("wkt", "").lstrip()
    m = re.match(r'([A-Z_]+)\s*\[', wkt, re.IGNORECASE)
    if not m:
        sys.exit(1)
    root = m.group(1).upper()
    if root in ("GEOGCRS", "GEOGCS"):
        sys.exit(0)
    if root in ("COMPD_CS", "COMPOUNDCRS"):
        # Compound: find the first child after the compound's own name string.
        # The horizontal child immediately follows the quoted name + comma.
        child = re.search(r',\s*([A-Z_]+)\s*\[', wkt, re.IGNORECASE)
        if child and child.group(1).upper() in ("GEOGCRS", "GEOGCS"):
            sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
PY
}

# Pick a UTM EPSG code from the raster centroid.
# zone = floor((lon + 180) / 6) + 1
# EPSG = 32600 + zone (north) or 32700 + zone (south)
# Echoes "EPSG:NNNNN" on success, returns 1 on parse failure.
_cog_pick_utm() {
  local tif="$1" info cx cy
  info=$("${GDALINFO[@]}" "${tif}" 2>/dev/null) || return 1
  cx=$(echo "${info}" | { grep -oP '^Center\s*\(\s*\K-?[0-9.]+'              || true; })
  cy=$(echo "${info}" | { grep -oP '^Center\s*\(\s*-?[0-9.]+,\s*\K-?[0-9.]+' || true; })
  [[ -n "${cx}" && -n "${cy}" ]] || return 1
  awk -v lon="${cx}" -v lat="${cy}" 'BEGIN {
    zone = int((lon + 180) / 6) + 1
    if (zone < 1)  zone = 1
    if (zone > 60) zone = 60
    base = (lat >= 0) ? 32600 : 32700
    printf "EPSG:%d\n", base + zone
  }'
}

# Resolve the target CRS for a raster based on flag precedence.
# Echoes "EPSG:NNNN" (or other CRS spec). Always succeeds.
# Args: <raster>
cog_resolve_crs() {
  local tif="$1"
  if [[ -n "${COG_CRS:-}" ]]; then
    echo "${COG_CRS}"
    return 0
  fi
  if _cog_is_geographic "${tif}"; then
    if [[ "${COG_NO_REPROJECT:-0}" -eq 1 ]]; then
      echo "WARN: source CRS is geographic; QGIS 3D Map View may not render correctly without a projected CRS." >&2
      echo "native"
      return 0
    fi
    local utm
    utm=$(_cog_pick_utm "${tif}") || {
      echo "WARN: could not auto-pick UTM zone for ${tif}; using native CRS" >&2
      echo "native"
      return 0
    }
    echo "${utm}"
    return 0
  fi
  echo "native"
}

# Build a COG from a DEM source (float32 elevation).
# When target_crs is "native", no reprojection. Otherwise gdalwarp first.
# Args: <in_vrt_or_tif> <out_cog> <target_crs>
build_cog_dem() {
  local in="$1" out="$2" target="$3"
  local src="${in}"
  local tmp_reproj="${out%.tif}__reproj.tif"

  if [[ "${target}" != "native" ]]; then
    "${GDALWARP[@]}" -t_srs "${target}" \
      -srcnodata "${DEM_NODATA}" -dstnodata "${DEM_NODATA}" \
      -r bilinear -multi -wo NUM_THREADS=ALL_CPUS \
      -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES \
      "${in}" "${tmp_reproj}"
    src="${tmp_reproj}"
  fi

  "${GDALTRANSLATE[@]}" -of COG \
    -co COMPRESS=ZSTD \
    -co PREDICTOR=FLOATING_POINT \
    -co BLOCKSIZE=512 \
    -co OVERVIEW_RESAMPLING=BILINEAR \
    "${src}" "${out}"

  [[ "${src}" != "${in}" ]] && rm -f "${tmp_reproj}"
  return 0
}

# Build a COG from a single-band byte shading raster.
# Uses -srcnodata 0 -dstalpha during reproject to avoid halo bleed (same
# pattern as reproject_to_wgs84 in gdal.sh).
# Args: <in_tif> <out_cog> <target_crs>
build_cog_shade() {
  local in="$1" out="$2" target="$3"
  local src="${in}"
  local tmp_reproj="${out%.tif}__reproj.tif"

  if [[ "${target}" != "native" ]]; then
    "${GDALWARP[@]}" -t_srs "${target}" \
      -srcnodata 0 -dstalpha \
      -r bilinear -multi -wo NUM_THREADS=ALL_CPUS \
      -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES \
      "${in}" "${tmp_reproj}"
    src="${tmp_reproj}"
  fi

  "${GDALTRANSLATE[@]}" -of COG \
    -co COMPRESS=ZSTD \
    -co BLOCKSIZE=512 \
    -co OVERVIEW_RESAMPLING=BILINEAR \
    "${src}" "${out}"

  [[ "${src}" != "${in}" ]] && rm -f "${tmp_reproj}"
  return 0
}

# Write a README.md to the COG output directory documenting setup steps
# for QGIS 3D and listing the files in the package.
# Args: <dir> <crs_summary>
write_cog_readme() {
  local dir="$1" crs="$2"
  local files
  files=$(cd "${dir}" && ls -1 *.tif 2>/dev/null | sort | sed 's/^/  - /')
  cat > "${dir}/README.md" <<EOF
# COG terrain package

Cloud-Optimized GeoTIFFs generated by \`lidar run --cog\`. Drop into any GIS
tool that reads GeoTIFF (QGIS, ArcGIS, MapServer, etc.).

**Target CRS:** ${crs}

## Files

${files}

\`*_dem.tif\` files are float32 elevation rasters (the terrain source).
\`*__*.tif\` files are uint8 shading overlays (hillshade / slopeshade) keyed
as \`<shading>__<project>.tif\`.

## QGIS 4.x 3D Map View

1. Drag the \`.tif\` files into QGIS.
2. Set the project CRS to match the target CRS above (Project → Properties → CRS).
3. View → 3D Map Views → New 3D Map View.
4. Click **Configure** → **Elevation** tab.
5. Set **Terrain type** to *DEM (Raster Layer)* and select the \`_dem.tif\` layer.
6. Suggested settings:
   - Tile resolution: 32–64 px
   - Vertical scale: 1.5–2.5 (terrain-dependent)
   - Skirt height: raise if you see seams at tile boundaries

The shading rasters render usefully as 2D overlays draped over the terrain.

## Other tools

The COG format is broadly supported: open the \`.tif\` files directly in
ArcGIS Pro, QGIS 3.x/4.x, MapServer, GDAL-based pipelines, or Mapbox/Cesium
tooling. Internal overviews and tiling are stored inside each file — no
sidecars needed.
EOF
}
