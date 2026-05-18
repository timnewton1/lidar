# lidar

A bash pipeline that turns USGS 3DEP lidar tile lists into Google Earth
super-overlays (KML/KMZ) and/or Cloud-Optimized GeoTIFFs (COG) for QGIS,
ArcGIS, and anything else that reads GeoTIFF.

Pick tiles on [The National Map](https://apps.nationalmap.gov/downloader/),
download the resulting `.txt` link list, point `lidar run` at it.

## Requirements

- Bash 4+, `curl`, `numfmt` (coreutils), `python3`
- Flatpak with the `org.qgis.qgis` app installed (provides GDAL)
- `zip` (only if you ask for `kmz` output)
- [`bats-core`](https://github.com/bats-core/bats-core) (only for running tests)

## Install

```bash
git clone https://github.com/timnewton1/lidar.git
cd lidar
ln -s "$PWD/lidar" ~/.local/bin/lidar      # or put it on your PATH another way
export GIS_DIR=/path/to/your/gis           # where runs live
```

## Quick start

```bash
# 1. Pick tiles on https://apps.nationalmap.gov/downloader/ and download the
#    "downloadlist.txt" of tile URLs.

# 2. Build a Google Earth super-overlay (default behavior):
lidar run ~/Downloads/downloadlist.txt

# 3. ...or COG for QGIS — significantly faster, skips the KML pyramid:
lidar run --output cog ~/Downloads/downloadlist.txt

# 4. ...or both:
lidar run --output kml,cog ~/Downloads/downloadlist.txt
```

Outputs land under `${GIS_DIR}/lidar/`:

```
${GIS_DIR}/lidar/
  tiles/dem/           # downloaded source tiles (cached, shared across runs)
  kml/<name>/          # Google Earth super-overlay pyramid
  kmz/<name>/          # zipped pyramid (.kmz files, one per shading×project)
  cog/<name>/          # Cloud-Optimized GeoTIFFs (DEM + shadings) + README.md
  logs/                # per-run log files + events index
```

## Subcommands

| Command | What it does |
|---|---|
| `lidar run` | Download tiles, mosaic, derive shading, build outputs |
| `lidar list` | Recent runs from the events index |
| `lidar log <name\|hex>` | Stream (running) or page (done) a run's log |
| `lidar size <name\|hex>` | Disk usage breakdown for a run's output |
| `lidar kill <name\|hex\|PID>` | Stop a running pipeline (or `--all`) |
| `lidar service install <name>` | Wrap a run as a systemd `--user` service |
| `lidar service uninstall <name>` | Remove a service |
| `lidar help` | This help |

Run `lidar <subcommand> --help` for per-subcommand flags.

## Output formats

| Format | When to pick it |
|---|---|
| **kml** | Google Earth — best for casual 3D browsing, draped on Google's globe |
| **kmz** | Same as kml, packaged as portable `.kmz` files (auto-enables kml) |
| **cog** | QGIS / ArcGIS / any GeoTIFF reader. Drop-in raster for 3D terrain analysis. Cog-only runs are 60-90% faster — they skip the WGS84 reproject and tile pyramid steps. |

COG output auto-detects CRS: uses the source CRS if projected, or auto-picks
a UTM zone from the data centroid if geographic. Override with
`--cog-crs EPSG:NNNN` or force native with `--cog-no-reproject`.

## Layout

```
lidar                  # entrypoint dispatcher
libexec/lidar-*        # subcommand implementations
lib/*.sh               # shared helpers (gdal, kml, cog, download, events)
systemd/               # systemd unit template for `lidar service`
tests/                 # bats tests + fixtures
docs/superpowers/      # design specs and implementation plans
```

## Testing

```bash
bats tests/
```

Most tests run offline (flag parsing, dry-run). The full pipeline needs
Flatpak GDAL + real tile downloads; those are not in the test suite.

## License

No license declared yet.
