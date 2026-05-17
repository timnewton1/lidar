# Lidar pipeline refactor — design spec

**Date:** 2026-05-16
**Status:** Approved (brainstorming complete; implementation pending)
**Scope:** Restructure `lidar_hillshade.sh` + `lidar_common.sh` into a git-style subcommand layout, add modern bash hardening, expand systemd unit hardening, parallelize tile downloads, add bats smoke tests. Behaviour-preserving except for the parallel-download speedup and added error diagnostics.

## Motivation

The current scripts are well-written but the entry filename (`lidar_hillshade.sh`) misnames a pipeline that already produces multiple shadings (hillshade and slopeshade). Research into 2026 bash/GIS practice (see Research findings) confirmed bash is the right tool at this scale, but identified concrete improvements: ERR-trap diagnostics, systemd hardening directives compatible with flatpak GDAL, parallel downloads, and a correction to an incorrect PIPE_BUF claim in the events code.

## Research findings (summary)

Four parallel research agents covered current-state, modern bash + GDAL, systemd/security, and atomicity/observability. Full findings live in the session transcript; the load-bearing conclusions:

- **Bash is still appropriate** for a ~1100-line single-host GIS pipeline in 2026. PEP 723 + `uv run` is the only credible Python alternative; no compelling case to migrate.
- **`gdal raster tile` (GDAL 3.11+)** — already in use — is the consensus replacement for the deprecated `gdal2tiles.py`. Keep.
- **`gdalbuildvrt`** for mosaicking is still standard up to ~100k tiles. Keep.
- **KML/KMZ output** is legacy in the broader GIS world but is the explicit use case here (Google Earth Pro). Keep.
- **systemd hardening** has a safe sweet spot when wrapping flatpak: `ProtectSystem=full`, `ProtectHome=tmpfs`, `LockPersonality`, `ReadWritePaths`, `SystemCallFilter` (denylist form), and `RestrictAddressFamilies`. Avoid `RestrictNamespaces=` and `MemoryDenyWriteExecute=` — both break flatpak's bwrap sandbox.
- **PIPE_BUF myth**: the events-file comment claiming "<4KB writes are atomic with O_APPEND" is wrong. `PIPE_BUF` (4096 bytes on Linux) constrains atomic pipe writes between processes — not regular files. `O_APPEND` writes to regular files are atomic at any size on Linux. Correct the comment.
- **Parallelism**: `xargs -P` is the 2026 consensus for parallel download loops.
- **Observability**: journald structured logging is "good enough"; OpenTelemetry is overkill for single-host. Stick with JSONL + jq.

## File layout

```
lidar/
├── lidar                       # dispatcher (~30 LOC, exec only)
├── libexec/
│   ├── lidar-run               # pipeline entry: download → mosaic → derive → tile → KML
│   ├── lidar-list              # JSONL events query (was --list-runs)
│   ├── lidar-kill              # kill specific PIDs or --all (was --kill-all)
│   ├── lidar-service-install   # was --install-service
│   ├── lidar-service-uninstall # was --uninstall-service
│   └── lidar-help              # subcommand help printer
├── lib/
│   ├── strict.sh               # set -Eeuo pipefail + ERR trap; sourced first
│   ├── common.sh               # GIS_DIR check, GDAL flatpak handles, defaults, color codes
│   ├── events.sh               # JSONL: emit_start, emit_end, list_runs, cleanup_old_logs
│   ├── download.sh             # check_deps_and_input, prescan, download_tiles
│   ├── gdal.sh                 # derive_hillshade/slopeshade/shading, reproject, build_dem_vrt
│   └── kml.sh                  # write_shading_kml, write_root_kml, package_kmz
├── tests/
│   ├── test_helpers.bats       # pure-function unit tests
│   └── test_cli.bats           # dispatcher + per-subcommand --dry-run + --help
├── systemd/
│   └── lidar@.service          # renamed; hardened
└── docs/superpowers/specs/
    └── 2026-05-16-lidar-refactor-design.md   # this file
```

Each `lib/*.sh` declares an idempotent load guard so multiple sub-binaries can source the same lib without re-execution side effects. `lib/common.sh` is sourced first by every sub-binary (it depends only on `lib/strict.sh`).

## Dispatcher

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
export LIDAR_HOME="${HERE}"
export PATH="${HERE}/libexec:${PATH}"
sub="${1:-help}"; [[ $# -gt 0 ]] && shift
case "${sub}" in
  help|-h|--help) exec "${HERE}/libexec/lidar-help" "$@" ;;
  service)
    sub2="${1:-}"; [[ -n "${sub2}" ]] || { echo "service requires install|uninstall" >&2; exit 2; }
    shift
    exec "${HERE}/libexec/lidar-service-${sub2}" "$@" ;;
  *)
    [[ -x "${HERE}/libexec/lidar-${sub}" ]] || { echo "unknown subcommand: ${sub}" >&2; exit 2; }
    exec "${HERE}/libexec/lidar-${sub}" "$@" ;;
esac
```

`exec` replaces the dispatcher in place (no extra fork). `LIDAR_HOME` lets sub-binaries source `${LIDAR_HOME}/lib/*.sh` regardless of cwd.

## CLI surface

| Old | New |
|---|---|
| `lidar_hillshade.sh URL` | `lidar run URL` |
| `lidar_hillshade.sh --list-runs --status running` | `lidar list --status running` |
| `lidar_hillshade.sh --list-running` | `lidar list --running` (short alias) |
| `lidar_hillshade.sh --kill-all` | `lidar kill --all` |
| (none) | `lidar kill <PID> [<PID>...]` — kill specific tracked PIDs |
| `lidar_hillshade.sh --install-service N` | `lidar service install N` |
| `lidar_hillshade.sh --uninstall-service N` | `lidar service uninstall N` |
| `--background` | `lidar run --background` |
| (none) | `lidar run --dry-run` — print resolved plan, exit 0 without side effects |

Per-subcommand `--help` is rendered by each sub-binary. `lidar help` lists subcommands.

### `lidar kill` safety

- `lidar kill <PID> [<PID>...]` — for each PID, look it up in `runs.jsonl` (must appear as `event=start` with no matching `event=end`, and `kill -0` must succeed). If a PID isn't tracked, refuse and exit 1 — prevents `lidar kill 1`.
- `lidar kill --all` — kills (a) all PIDs the events index reports as running, (b) all `lidar@*.service` systemd user units, (c) stray `pgrep -f 'libexec/lidar-run'` matches not covered above (excluding self/PPID/pgrep itself). Same logic as today's `--kill-all`.
- `lidar kill` with no args and no `--all` — print usage, exit 2.

## Modern bash hardening (`lib/strict.sh`)

```bash
[[ -n "${_LIDAR_STRICT_LOADED:-}" ]] && return 0
_LIDAR_STRICT_LOADED=1
set -Eeuo pipefail
trap 'rc=$?; printf "\nERROR rc=%d at %s:%d in %s\n" "$rc" \
  "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" "${FUNCNAME[1]:-main}" >&2' ERR
```

The `E` flag propagates ERR traps into functions and subshells. Sourced first by every sub-binary and every bats test. Expected non-fatal exits (a failed download in the middle of a loop) are handled with explicit `|| { ... }` blocks and do not trip the trap.

## Correctness fixes

- **`lib/events.sh`**: replace the misleading "<4KB writes are atomic with O_APPEND on Linux" comment with: "On Linux, write(2) with O_APPEND atomically advances the file offset and writes; concurrent appenders never interleave or clobber regardless of write size. (PIPE_BUF — 4096 on Linux — constrains atomic writes to *pipes*, not regular files.)"
- **`lib/download.sh`**: replace the serial download loop with `xargs -P`:
  - Per-URL helper function is exported via `export -f` and invoked by `xargs -P "${LIDAR_DOWNLOAD_JOBS:-4}" -n1`.
  - Cache-hit short-circuit preserved (helper exits 0 if final file exists).
  - PID-suffixed partials preserved (helper uses `$$` of the xargs subshell, which is unique per concurrent invocation).
  - Progress output serialized to stderr via `flock /dev/stderr` inside the helper so lines don't interleave.
  - The EWMA download-rate ETA is recomputed in the parent after each batch of N completions (where N = `LIDAR_DOWNLOAD_JOBS`), not per-tile, since per-tile rate is meaningless under parallelism.

## Systemd hardening (`systemd/lidar@.service`)

ExecStart becomes:
```ini
ExecStart=/bin/bash -c '%h/scripts/gis/lidar/lidar run --name %i ${EXTRA_ARGS} "${DOWNLOAD_LIST}"'
```

Hardening additions (from research; only directives that are compatible with flatpak's bwrap sandbox):

```ini
ProtectSystem=full
ProtectHome=tmpfs
ProtectKernelTunables=yes
ProtectKernelModules=yes
LockPersonality=yes
PrivateDevices=yes
SystemCallArchitectures=native
SystemCallFilter=~@clock @debug @module @obsolete @privileged @raw-io @reboot @swap
RestrictRealtime=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

# Intentionally omitted — break flatpak bwrap or GDAL JIT codecs:
#   RestrictNamespaces=     (flatpak requires user namespace creation)
#   MemoryDenyWriteExecute= (GDAL DEFLATE/LZW JIT segfaults)
#   ProtectSystem=strict    (flatpak ExecStart cannot reach /tmp sandbox resources)
```

`ReadWritePaths` is not in the static unit file. Instead, `lidar service install` writes a drop-in at `~/.config/systemd/user/lidar@<name>.service.d/paths.conf` containing:
```ini
[Service]
ReadWritePaths=${GIS_DIR}
```
This keeps the unit template portable across machines with different `GIS_DIR` values.

## What does NOT change

- JSONL events file path (`$LIDAR_DIR/logs/runs.jsonl`) and event schema. Pre-refactor logs remain readable.
- Output directory layout (`kml/<name>/<shading>/<project>/doc.kml`).
- Flatpak GDAL choice (`org.qgis.qgis`). No pivot to titiler/COG-on-the-fly.
- Hillshade and slopeshade math: algorithms, az/alt/z-factor, `-multidirectional`, nodata pinning.
- `gdalbuildvrt` per-project mosaicking and `gdal raster tile` with `WorldCRS84Quad` + KML output.
- 30-day log retention.
- Flock-based single-instance locking per `--name`.

## Test plan

### `tests/test_helpers.bats` (~15 cases)

Pure-function unit tests sourcing the relevant `lib/*.sh` directly. No GDAL, no network, no filesystem beyond `BATS_TMPDIR`.

Coverage:
- `json_escape`: backslash, double-quote, newline, tab, CR escapes; idempotent on safe strings
- `human_duration`: 0s, 59s, 60s, 3599s, 3600s, multi-hour
- `human_bytes`: round-trip via `numfmt`
- `parse_duration`: `30s`, `5m`, `2h`, `7d`; rejects `7y`, empty, negative
- `project_from_url`: standard USGS URL → project; URL without `/Projects/` → empty
- `is_known_shading`: hillshade, slopeshade → 0; gibberish → 1

### `tests/test_cli.bats` (~10 cases)

Invokes the real `lidar` binary with `--dry-run` / `--help` and asserts on stdout/stderr/exit code. No GDAL invocation reached.

Coverage:
- `lidar` (no args) → help, exit 0
- `lidar bogus` → "unknown subcommand", exit 2
- `lidar run --dry-run --shading hillshade ./test/fixtures/empty.txt` → exit 1, mentions "no .tif URLs"
- `lidar run --dry-run --shading bogus URL` → exit 1, mentions known shadings
- `lidar run --dry-run --algorithm Foo URL` → exit 1, "Horn or ZevenbergenThorne"
- `lidar list --json` on empty events file → `[]`
- `lidar list --since 7y` → exit 1, "bad duration"
- `lidar kill` (no args, no --all) → usage, exit 2
- `lidar kill 1` (untracked PID) → refuses, exit 1
- `lidar service install` (no name) → usage, exit 2

### Manual smoke test

After all commits land, run one small real job against a 5-tile USGS list. Diff the resulting `kml/<name>/` tree (excluding timestamps in KML files) against a reference produced from the pre-refactor `master`. Byte-identical (modulo timestamps) is the acceptance gate.

## Migration

The user has no installed systemd services at refactor time (verified: only the unit *template* is symlinked; no instance units or env files exist). Therefore:

- No migration helper subcommand.
- The old `systemd/lidar-hillshade@.service` symlink at `~/.config/systemd/user/` is removed (or left orphaned — it's a dead symlink after commit 5 deletes the source).
- Fresh `lidar service install N` invocations after the refactor lands set up the new `lidar@N.service` instances.

The old entry point `lidar_hillshade.sh` is **deleted** in commit 3 — no deprecation symlink. Clean break.

## Commit plan

Five commits, each independently revertable. Each commit ends in a green test run (or, for commits 1-2 where tests don't exist yet, a successful `lidar_hillshade.sh --help`).

1. **Add `lib/strict.sh` + extract pure helpers to `lib/common.sh`.** Original `lidar_hillshade.sh` and `lidar_common.sh` still in place and functional; both updated to source `lib/strict.sh` and `lib/common.sh`. No behaviour change.
2. **Split pipeline functions into `lib/{events,download,gdal,kml}.sh`.** Original `lidar_common.sh` becomes a thin shim that sources the new lib files (for one commit). `lidar_hillshade.sh` unchanged. No behaviour change.
3. **Add dispatcher `lidar` + `libexec/lidar-*` sub-binaries.** Delete `lidar_hillshade.sh` and the now-empty `lidar_common.sh` shim. The dispatcher is the new entry point. Behaviour preserved.
4. **Add bats tests + `--dry-run` plumbing in `lidar-run`.** First commit that adds new behaviour: `--dry-run` mode prints the resolved plan and exits 0 without side effects.
5. **Rename systemd unit; add hardening directives; parallelize downloads via `xargs -P`.** Two real behaviour changes (parallelism, unit name); spec acceptance gate is the manual smoke test above.

## Open questions

None at spec-write time. The two real behaviour changes (parallel downloads, unit rename) are scoped to commit 5; everything before is mechanical restructure.

## Acceptance criteria

- All bats tests pass.
- Manual smoke test produces byte-identical output (modulo timestamps) to a pre-refactor reference run.
- `shellcheck` is clean across all `*.sh` and `libexec/*` files (no new warnings vs. pre-refactor baseline).
- `lidar service install testrun` against a small URL creates a working `lidar@testrun.service` that completes successfully under journalctl.
