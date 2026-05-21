# Run identity + list/restart cleanup

**Status:** draft / 2026-05-20

## What changes

Three small things.

### 1. Names come from the tile list, not from a flag

Every USGS tile list URL has the project in the path:

    https://prd-tnm.s3.amazonaws.com/.../Projects/AZ_CochiseCounty_2020_B20/.../*.tif
                                                  ^^^^^^^^^^^^^^^^^^^^^^^^
                                                  this is the name

`lidar run <list>` extracts the project segment(s) from the URLs in the list and
uses that as the run's name. No `--name` flag interaction needed; the data already
knows what it's about.

- One project in the list → use it (`AZ_CochiseCounty_2020_B20`)
- Multiple projects → join the top two with `+`, truncate (`AZ_Cochise+AZ_Brawley`)
- No `Projects/` segment matches → fall back to the input file's basename minus extension

`--name <x>` becomes an override flag (kept for the rare case the user wants one),
not the primary mechanism.

### 2. Hex is the run id

Today the run id is `<name>_<hex>` and the hex is treated as a disambiguator. Flip it:
the **hex is the id**; the project name is a human-readable tag attached to it. Same
storage on disk (we keep `<name>_<hex>` as the directory/log basename for grep-ability),
but every command accepts the bare hex first and shows it first.

`lidar list` output leads with the hex; the project name comes after. `lidar list <hex>`,
`lidar kill <hex>`, `lidar restart <hex>` are the canonical forms. Name-or-hex resolution
in `resolve_run_id` already exists and stays.

### 3. Rename `lidar log` → `lidar list`, `lidar rerun` → `lidar restart`

`lidar list` (no arg): prints the run table. No fzf, no tmux, no exec — just print.
`lidar list <hex>`: tails or pages the log, same logic as today.
`lidar restart <hex>`: same as today's `lidar rerun`.

Old names removed. No aliases.

## Why this is the simple version

- The JSONL events file at `$LIDAR_DIR/logs/runs.jsonl` is already machine-readable.
  Claude Code or any script reads it directly with `jq`. No `--output json` flag needed
  on any subcommand. (Documenting the file path in `lidar --help` is enough.)
- No fzf chooser, no tmux multi-pane viewer. If the user wants those, they're one
  shell pipeline away (`jq -r .id runs.jsonl | fzf | xargs lidar list`).
- No systemd-run. Verified earlier that Flatpak GDAL escapes the unit cgroup, so the
  current pgrp-TERM kill is actually the correct primitive for this stack.

## Files touched

- `lib/common.sh` — new helper: `derive_run_name <tile_list_path_or_url>` (one regex
  pass over the file, count project segments, pick the dominant one(s)). ~15 lines.
- `libexec/lidar-run` — calls `derive_run_name` when `--name` not given. ~3 lines.
- `libexec/lidar-log` → `libexec/lidar-list`. Strip the fzf chooser + tmux pane code.
- `libexec/lidar-rerun` → `libexec/lidar-restart`. Rename only.
- `lib/events.sh` `list_runs` — reorder columns to lead with hex.
- `libexec/lidar-help` / dispatcher — update command listings.
- `tests/test_cli.bats` — coverage for `derive_run_name` and the renames.

## Risks

- **Empty tile-list files** (a few of those exist in ~/Downloads). `derive_run_name`
  falls back to the basename, same as today's `--name`-not-given path.
- **Hex collisions**: 6-hex (16M) is plenty for personal scale; if a collision ever
  shows up, `resolve_run_id` already errors as ambiguous.
