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

# Resolve the target CRS for a raster based on flag precedence.
# Echoes "EPSG:NNNN" (or other CRS spec). Always succeeds.
# Args: <raster>
#
# A single gdalinfo -json call extracts both the WKT (to detect geographic CRS)
# and cornerCoordinates.center (for UTM auto-pick). This avoids two Flatpak
# spawns when the source is geographic — Flatpak bwrap overhead is 100-400 ms.
#
# Why not a substring check on the WKT: PROJCRS WKT contains BASEGEOGCRS as a
# child, so naive "GEOGCRS in wkt" produces false positives on projected rasters.
cog_resolve_crs() {
  local tif="$1"
  if [[ -n "${COG_CRS:-}" ]]; then
    echo "${COG_CRS}"
    return 0
  fi
  local json
  json=$("${GDALINFO[@]}" -json "${tif}" 2>/dev/null) || { echo "native"; return 0; }
  python3 - "${json}" "${COG_NO_REPROJECT:-0}" <<'PY'
import sys, json, re
try:
    d = json.loads(sys.argv[1])
    no_reproject = sys.argv[2] == "1"

    # Detect geographic CRS from WKT root keyword. Handles WKT1 (GEOGCS),
    # WKT2 (GEOGCRS), and compound CRS where only the horizontal axis matters.
    wkt = d.get("coordinateSystem", {}).get("wkt", "").lstrip()
    m = re.match(r'([A-Z_]+)\s*\[', wkt, re.IGNORECASE)
    root = m.group(1).upper() if m else ""
    is_geo = root in ("GEOGCRS", "GEOGCS")
    if not is_geo and root in ("COMPD_CS", "COMPOUNDCRS"):
        child = re.search(r',\s*([A-Z_]+)\s*\[', wkt, re.IGNORECASE)
        is_geo = bool(child and child.group(1).upper() in ("GEOGCRS", "GEOGCS"))

    if not is_geo:
        print("native")
        sys.exit(0)

    if no_reproject:
        print("WARN: source CRS is geographic; QGIS 3D Map View may not render correctly without a projected CRS.", file=sys.stderr)
        print("native")
        sys.exit(0)

    # Auto-pick UTM from WGS84 centroid embedded in gdalinfo -json output.
    # cornerCoordinates.center is always in WGS84 regardless of source CRS.
    center = d.get("cornerCoordinates", {}).get("center", [])
    if len(center) < 2:
        print("native")
        sys.exit(0)
    lon, lat = center[0], center[1]
    zone = int((lon + 180) / 6) + 1
    zone = max(1, min(60, zone))
    base = 32600 if lat >= 0 else 32700
    print(f"EPSG:{base + zone}")
except Exception:
    print("native")
PY
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

  # AVERAGE preserves mean elevation across overview levels; BILINEAR is for
  # upsampling and can create NoData holes at coarser zoom levels.
  "${GDALTRANSLATE[@]}" -of COG \
    -co COMPRESS=ZSTD \
    -co PREDICTOR=FLOATING_POINT \
    -co BLOCKSIZE=512 \
    -co OVERVIEW_RESAMPLING=AVERAGE \
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

  # NEAREST avoids interpolation artifacts in uint8 visual rasters (hillshade,
  # slopeshade). BILINEAR/AVERAGE can blend transparent edges into real pixels.
  "${GDALTRANSLATE[@]}" -of COG \
    -co COMPRESS=ZSTD \
    -co BLOCKSIZE=512 \
    -co OVERVIEW_RESAMPLING=NEAREST \
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
