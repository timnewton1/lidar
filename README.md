# lidar

A bash pipeline that turns USGS 3DEP lidar tile lists into Google Earth
super-overlays (KML/KMZ) and/or Cloud-Optimized GeoTIFFs (COG) for QGIS,
ArcGIS, and anything else that reads GeoTIFF.

Pick tiles on [The National Map](https://apps.nationalmap.gov/downloader/),
download the resulting `.txt` link list, point `lidar run` at it.

## Requirements

- Podman 5+ and a systemd user session (rootless quadlets)
- That's it on the host. GDAL 3.13.3, curl, jq, zip, python3 and bats all
  live in the container image (see [`Containerfile`](Containerfile)).

## Install

```bash
git clone https://github.com/timnewton1/lidar.git
cd lidar
./lidar install --gis-dir /path/to/your/gis   # or export GIS_DIR first
```

`install` writes `~/.config/lidar/lidar.env` (repo path + GIS dir), symlinks
`quadlet/lidar@.container` into `~/.config/containers/systemd/` and `lidar`
into `~/.local/bin/`, reloads systemd, and builds `localhost/lidar:latest`
if it doesn't exist. Re-run it if you move the repo or the GIS dir.

## How it runs

```
lidar run list.txt
  │ copies list.txt onto the data disk (inputs/)
  ├─ podman run --rm lidar run …      plan: validate, fan out by project,
  │                                   write jobs/<hex>.env + <hex>.urls
  └─ systemctl --user start lidar@<hex>.service   (one per project)
        └─ container lidar-<hex>: worker <hex> → the pipeline
```

The repo is bind-mounted read-only into every container, so code edits take
effect on the next run. Rebuild (`lidar build`) only when the Containerfile
changes. Each run is an ordinary systemd unit:
`systemctl --user status lidar@<hex>`, `journalctl --user -u lidar@<hex>`.

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

When a tile list spans multiple USGS projects, `lidar run` dispatches one
independent run per project and returns immediately. Each run gets its own
hex ID, log file, and output directory. Use `--jobs N` to cap concurrency.

Outputs land under `${GIS_DIR}/lidar/`:

```
${GIS_DIR}/lidar/
  tiles/dem/                        # downloaded source tiles (cached, shared across runs)
  projects/<project>/<hex>/kml/     # Google Earth super-overlay pyramid
  projects/<project>/<hex>/kmz/     # zipped .kmz files (one per shading×project)
  projects/<project>/<hex>/cog/     # Cloud-Optimized GeoTIFFs + README.md
  logs/<hex>.log                    # per-run log file
  logs/runs.jsonl                   # events index
  jobs/<hex>.env, <hex>.urls        # job spec each lidar@<hex> unit runs (kept for restart)
  inputs/<stamp>/                   # copies of the local tile lists you passed to `run`
```

## Subcommands

| Command | What it does |
|---|---|
| `lidar run` | Download tiles, mosaic, derive shading, build outputs |
| `lidar list [<hex>]` | Run table, or follow/page one run's log |
| `lidar size <list\|hex>` | Estimate download size for a tile list or run |
| `lidar kill <hex>…` / `--all` | Stop running pipeline(s) (`systemctl stop`) |
| `lidar restart <hex>…` | Re-run in place: same hex, same flags; replaces that run's output |
| `lidar install` | One-time setup (config, quadlet, PATH link, image) |
| `lidar build` | Rebuild the container image |
| `lidar test` | Run the bats suite inside the image |
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
lidar                    # host wrapper (podman + systemctl); what you run
Containerfile            # runtime image: GDAL + tools, no code
quadlet/lidar@.container # one unit per run
libexec/lidar-dispatch   # in-container entrypoint → libexec/lidar-<sub>
libexec/lidar-*          # run (plan), worker (pipeline), list, size, resolve
lib/*.sh                 # shared helpers (gdal, kml, cog, download, events, jobs)
tests/                   # bats tests + fixtures
docs/superpowers/        # design specs and implementation plans
```

## Testing

```bash
lidar test
```

Tests run offline inside the image (flag parsing, dry-run, job specs,
helpers). The full pipeline needs real tile downloads; verify it with
`lidar run tests/fixtures/one_tile.txt`.

## License

No license declared yet.
