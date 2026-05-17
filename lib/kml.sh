#!/usr/bin/env bash
# KMZ packaging. Each (shading, project) super-overlay is its own KMZ —
# gdal raster tile emits a self-contained doc.kml + tile tree per project,
# and we zip that directory directly. No handwritten wrapper KML: Google
# Earth's Region/Lod streaming relies on the per-tile <Region> elements
# gdal raster tile produces, which our old NetworkLink-only wrappers
# bypassed.

[[ -n "${_LIDAR_KML_LOADED:-}" ]] && return 0
_LIDAR_KML_LOADED=1

# Package an output directory (containing doc.kml at its root) into a .kmz.
# out_kmz must be an absolute path; caller is responsible for mkdir -p.
# Args: <out_dir> <out_kmz>
package_kmz() {
  local out_dir="$1" out_kmz="$2"
  ( cd "${out_dir}" && zip -rq "${out_kmz}" . -x '*.aux.xml' )
}
