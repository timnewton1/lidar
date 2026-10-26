# Containerize lidar (Podman image + quadlet template)

## Why

GDAL came from the QGIS Flatpak since the first commit. There was no record
of a reason beyond "Bazzite has no `dnf install gdal`", and it caused real
friction:

- systemd hardening had to skip `RestrictNamespaces=`, `ProtectSystem=strict`
  and `MemoryDenyWriteExecute=` because they break bwrap;
- Flatpak GDAL escaped the unit cgroup, so `lidar kill` had to signal process
  groups and the `lidar@.service` template was abandoned;
- runs were bare detached processes tracked by PID.

Every other service on scrubjay is a rootless Podman quadlet. lidar now is too.

## Shape

CLI-only for now (no always-on service). Room for a web UI later: it would be
one more `.container` quadlet on the same image, reading the same `jobs/`,
`logs/` and `runs.jsonl`, and starting `lidar@<hex>` units the same way.

```
host: lidar (wrapper)            container: localhost/lidar (GDAL 3.13.3)
  run  → stage inputs ─────────→ lidar run      plan + write jobs/<hex>.{env,urls}
       ← "@job <hex>" lines ────
       → systemctl start lidar@<hex> ──→ lidar worker <hex>   (pipeline)
  list/size ───────────────────→ lidar list / size  (LIDAR_ACTIVE from systemd)
  kill/restart → lidar resolve → systemctl stop / restart lidar@<hex>
```

## Decisions

- **Image** `ghcr.io/osgeo/gdal:ubuntu-small-3.13.3` — same GDAL as the
  Flatpak at switch-over, so output is unchanged. Adds curl, jq, zip, less,
  bats. No code in the image: the repo is bind-mounted ro at `/opt/lidar`
  (same pattern as parrot/pepla), so edits need no rebuild.
- **One unit per run** (`lidar@<hex>`), not one container for the batch. Gives
  per-run `systemctl stop`, journald, and a clean cgroup. `--jobs` is enforced
  with a flock slot semaphore per batch (`jobs/.slots/`), since systemd starts
  every unit at once.
- **PID 1 supervisor** in `lidar-worker`: podman signals only PID 1, and bash
  defers traps while a foreground GDAL child runs. PID 1 runs the pipeline in
  its own session and relays TERM to the whole group, so the EXIT banner and
  end event are always written on stop.
- **Liveness from systemd**, passed in as `LIDAR_ACTIVE`. The `pid` field is
  gone from start events.
- **Restart in place**: same hex, replays the stored job spec (flags
  included, which the old URL-replay restart lost), appends to the log,
  clears the previous output dir. Pre-container runs have no spec and are
  refused with a hint to `lidar run` again.
- **No `--gis-dir` per command** — the quadlet mounts are fixed per install
  (`~/.config/lidar/lidar.env`). `lidar install --gis-dir` changes it.
- **Removed**: `lidar-kill`, `lidar-restart` (now host-side), `lib/process.sh`,
  `libexec/lidar-help` (help lives in the host wrapper), kill-by-PID.

## Verification

- `lidar test` — 78 bats tests inside the image.
- End-to-end on `tests/fixtures/one_tile.txt` with `-o kml,kmz,cog -s
  hillshade,slopeshade`, compared against the Flatpak pipeline on `main` for
  the same tile.
