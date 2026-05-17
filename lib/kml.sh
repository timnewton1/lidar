#!/usr/bin/env bash
# KML/KMZ output: per-shading index, root NetworkLink doc, and KMZ packaging.

[[ -n "${_LIDAR_KML_LOADED:-}" ]] && return 0
_LIDAR_KML_LOADED=1

# Write per-shading intermediate doc.kml: one NetworkLink per project.
# Args: <kml_path> <shading_name> <project_names...>
write_shading_kml() {
  local kml_path="$1" shading="$2"; shift 2
  local projects=("$@")
  {
    cat <<HEAD
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>${shading}</name>
  <open>1</open>
HEAD
    for p in "${projects[@]}"; do
      cat <<NL
  <NetworkLink>
    <name>${p}</name>
    <visibility>1</visibility>
    <Link><href>${p}/doc.kml</href></Link>
  </NetworkLink>
NL
    done
    cat <<'TAIL'
</Document>
</kml>
TAIL
  } > "${kml_path}"
}

# Write root doc.kml: one NetworkLink per shading.
# Args: <kml_path> <name> <shading_names...>
write_root_kml() {
  local kml_path="$1" name="$2"; shift 2
  local shadings=("$@")
  {
    cat <<HEAD
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>${name}</name>
  <open>1</open>
HEAD
    for s in "${shadings[@]}"; do
      cat <<NL
  <NetworkLink>
    <name>${s}</name>
    <visibility>1</visibility>
    <Link><href>${s}/doc.kml</href></Link>
  </NetworkLink>
NL
    done
    cat <<'TAIL'
</Document>
</kml>
TAIL
  } > "${kml_path}"
}

# Package an output directory into a .kmz file.
# Args: <kmz_out_path> <out_dir> <kmz_parent_dir>
package_kmz() {
  local kmz_out="$1" out_dir="$2" kmz_dir="$3"
  mkdir -p "${kmz_dir}"
  ( cd "${out_dir}" && zip -rq "${kmz_out}" . -x '*.aux.xml' )
}
