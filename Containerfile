# lidar runtime image: GDAL plus the shell tools the pipeline calls.
#
# Code is NOT baked in. The repo is bind-mounted read-only at /opt/lidar by
# both the host `lidar` wrapper and the lidar@.container quadlet, so edits
# take effect on the next run without a rebuild. Rebuild only when this file
# changes: `lidar build`.
#
# Pinned to the GDAL release the pipeline was validated against. Bump the tag
# deliberately; `gdal raster tile` (3.11+) and its flags are load-bearing.
FROM ghcr.io/osgeo/gdal:ubuntu-small-3.13.3

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq zip less bats ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV LIDAR_HOME=/opt/lidar
ENTRYPOINT ["/opt/lidar/libexec/lidar-dispatch"]
