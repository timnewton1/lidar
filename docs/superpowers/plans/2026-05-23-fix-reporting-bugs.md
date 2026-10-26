# Fix Reporting Bugs (exit-code clobber + wrong PID) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two bugs that together made `lidar list` show "crashed" for the entire run duration then flip to "success" on exit regardless of actual outcome.

**Architecture:** Bug A is a one-line reorder in `_on_project_exit` (capture `$?` before the re-entrancy guard clobbers it). Bug B is a two-part change: swap `$$` → `$BASHPID` in `events_emit_start`, and move the emit call from the pre-fork dispatch loop into `_run_one_project` so the recorded PID belongs to the long-lived worker subshell, not the dispatcher.

**Tech Stack:** bash, bats (tests)

---

### Task 1: Fix Bug A — capture `$?` before re-entrancy guard

**Files:**
- Modify: `libexec/lidar-run:269-274`

The re-entrancy guard `[[ ${_on_exit_done} -eq 1 ]] && return` runs before `local _rc=$?`. The `[[` compound command always exits 0, so `_rc` is always 0 when eventually captured. Fix: move `local _rc=$?` to the very first line.

- [ ] **Step 1: Write the failing test**

In `tests/test_cli.bats`, add after the existing `events_emit_start` test (around line 141):

```bash
@test "_on_project_exit captures non-zero exit before re-entrancy guard" {
  # Simulate the trap pattern: define a minimal _on_project_exit that mirrors
  # the real one, and verify it passes the real exit code to events_emit_end.
  local _captured_rc=""
  events_emit_end() { _captured_rc="$2"; }
  events_emit_start() { :; }

  local _on_exit_done=0 _hex="test" _proj_work
  _proj_work=$(mktemp -d)

  _on_project_exit() {
    [[ ${_on_exit_done} -eq 1 ]] && return; _on_exit_done=1
    local _rc=$?
    events_emit_end "${_hex}" "${_rc}"
    rm -rf "${_proj_work}"
  }
  trap _on_project_exit EXIT

  # Exit the subshell with a non-zero status; the trap fires on the exit.
  ( trap _on_project_exit EXIT; exit 42 ) || true

  # Re-run the trap manually to capture (the subshell trap doesn't affect outer scope)
  _on_exit_done=0
  (
    _captured_rc_inner=""
    events_emit_end_inner() { _captured_rc_inner="$2"; }
    _on_project_exit_inner() {
      [[ ${_on_exit_done} -eq 1 ]] && return; _on_exit_done=1
      local _rc=$?
      _captured_rc_inner="${_rc}"
    }
    trap _on_project_exit_inner EXIT
    exit 42
  ) || true
  # The above is hard to assert across subshell boundary; use the grep approach instead.
  # This test is intentionally replaced by a static grep in Step 2.
  true
}
```

Actually, the cross-subshell variable capture makes a behavioral test awkward. Use a **static grep** test instead (simpler and just as effective as a regression guard):

```bash
@test "Bug A: _on_project_exit captures \$? before re-entrancy guard" {
  # Verify the fix is in place: local _rc=\$? must appear before the [[ check.
  local src="${LIDAR_HOME}/libexec/lidar-run"
  # Extract the function body and confirm line order.
  local rc_line guard_line
  rc_line=$(grep -n 'local _rc=\$?' "${src}" | grep -A0 '' | head -1 | cut -d: -f1)
  guard_line=$(grep -n '_on_exit_done' "${src}" | head -1 | cut -d: -f1)
  (( rc_line < guard_line ))
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bats tests/test_cli.bats --filter "Bug A"
```

Expected: FAIL — `rc_line` is currently *after* `guard_line` (line 271 vs line 270).

- [ ] **Step 3: Apply the fix**

In `libexec/lidar-run`, change the function body from:

```bash
  _on_project_exit() {
    [[ ${_on_exit_done} -eq 1 ]] && return; _on_exit_done=1
    local _rc=$?
    events_emit_end "${_hex}" "${_rc}"
    rm -rf "${_proj_work}"
  }
```

to:

```bash
  _on_project_exit() {
    local _rc=$?
    [[ ${_on_exit_done} -eq 1 ]] && return; _on_exit_done=1
    events_emit_end "${_hex}" "${_rc}"
    rm -rf "${_proj_work}"
  }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bats tests/test_cli.bats --filter "Bug A"
```

Expected: PASS.

- [ ] **Step 5: Run full suite to confirm no regressions**

```bash
bats tests/
```

Expected: all existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add libexec/lidar-run tests/test_cli.bats
git commit -m "fix(events): capture \$? before re-entrancy guard in _on_project_exit

The [[ \${_on_exit_done} -eq 1 ]] compound always exits 0, clobbering \$?
before local _rc=\$? captured it — so events_emit_end always recorded exit 0.
Move local _rc=\$? to the first statement of the trap."
```

---

### Task 2: Fix Bug B — emit start event with the worker's own PID

**Files:**
- Modify: `lib/events.sh:25-26` — `$$` → `$BASHPID`
- Modify: `libexec/lidar-run:524-530` — remove pre-fork emit loop
- Modify: `libexec/lidar-run:247-253` — add emit call inside `_run_one_project` after log redirect

**Context:** `_run_one_project` is called as `_run_one_project ... &` inside the supervisor subshell (line 544). Each `&` fork gets its own `$BASHPID`. The pre-fork loop records `$$` (the dispatcher PID), which exits within seconds of disown — causing `lidar list` to report "⊘ crashed" for the entire actual run duration.

- [ ] **Step 1: Write the static-grep regression tests**

In `tests/test_cli.bats`, add after the Bug A test:

```bash
@test "Bug B: events_emit_start uses BASHPID not \$\$" {
  grep -q '\$BASHPID' "${LIDAR_HOME}/lib/events.sh"
  ! grep -q '"pid":%d.*\$\$' "${LIDAR_HOME}/lib/events.sh" || false
}

@test "Bug B: events_emit_start not called outside _run_one_project in lidar-run" {
  local src="${LIDAR_HOME}/libexec/lidar-run"
  # Collect line numbers of all events_emit_start calls
  local call_lines func_start func_end
  call_lines=$(grep -n 'events_emit_start' "${src}" | cut -d: -f1)
  # _run_one_project starts at the 'local _project=' line; find its range
  func_start=$(grep -n '_run_one_project()' "${src}" | head -1 | cut -d: -f1)
  # The function ends at the closing '}' after a blank line — use the
  # trap registration block as a proxy: all emit calls must be > func_start
  # and before the supervisor subshell (the '(' that follows the dispatch echo).
  supervisor_line=$(grep -n '^# Supervisor subshell' "${src}" | head -1 | cut -d: -f1)
  for ln in ${call_lines}; do
    (( ln > func_start && ln < supervisor_line ))
  done
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bats tests/test_cli.bats --filter "Bug B"
```

Expected: both FAIL — `events.sh` still uses `$$`; emit is still outside `_run_one_project`.

- [ ] **Step 3: Fix `lib/events.sh` — swap `$$` for `$BASHPID`**

Change line 25-26 of `lib/events.sh` from:

```bash
  printf '{"id":"%s","event":"start","ts":"%s","pid":%d,"log":"%s","project":"%s","urls":%s}\n' \
    "$(json_escape "${id}")" "${ts}" "$$" "$(json_escape "${log}")" \
```

to:

```bash
  printf '{"id":"%s","event":"start","ts":"%s","pid":%d,"log":"%s","project":"%s","urls":%s}\n' \
    "$(json_escape "${id}")" "${ts}" "${BASHPID}" "$(json_escape "${log}")" \
```

- [ ] **Step 4: Move `events_emit_start` into `_run_one_project`**

In `libexec/lidar-run`, remove the pre-fork emit loop (lines 524-530):

```bash
declare -a _HEXES=()
for (( _i=0; _i<_N_PROJECTS; _i++ )); do
  _hex=$(gen_hex_id)
  _HEXES+=("${_hex}")
  events_emit_start "${_hex}" "${LIDAR_DIR}/logs/${_hex}.log" \
    "${_FANOUT_PROJECTS[_i]}" "${INPUTS[@]}"
done
```

Replace with (hex generation only, no emit):

```bash
declare -a _HEXES=()
for (( _i=0; _i<_N_PROJECTS; _i++ )); do
  _hex=$(gen_hex_id)
  _HEXES+=("${_hex}")
done
```

Then inside `_run_one_project`, add the emit immediately after the `exec > "${_log}" 2>&1` line (currently line 253). The function signature passes `_hex` as `$2` and `_project` as `$1`; `INPUTS` is inherited from the outer scope. Change from:

```bash
  exec > "${_log}" 2>&1

  local _proj_work; _proj_work=$(mktemp -d "${LIDAR_DIR}/.work_XXXXXX")
```

to:

```bash
  exec > "${_log}" 2>&1
  events_emit_start "${_hex}" "${_log}" "${_project}" "${INPUTS[@]}"

  local _proj_work; _proj_work=$(mktemp -d "${LIDAR_DIR}/.work_XXXXXX")
```

- [ ] **Step 5: Run the regression tests to verify they pass**

```bash
bats tests/test_cli.bats --filter "Bug B"
```

Expected: both PASS.

- [ ] **Step 6: Run full test suite**

```bash
bats tests/
```

Expected: all tests pass (including the existing `events_emit_start writes project field and urls key` test at line 132).

- [ ] **Step 7: Commit**

```bash
git add lib/events.sh libexec/lidar-run tests/test_cli.bats
git commit -m "fix(events): record worker PID, not dispatcher PID, in start event

The pre-fork loop called events_emit_start with \$\$ — the dispatcher PID.
The dispatcher exits within seconds of disowning the supervisor subshell, so
lidar list saw kill -0 fail and reported 'crashed' for the entire run duration.

Fix: change events_emit_start to use \$BASHPID (correct in any context, and
gives the real subshell PID when called from a fork). Move the emit into
_run_one_project so it fires from the worker's own fork.

Trade-off: projects now appear in 'lidar list' when their worker starts (a
few ms after dispatch), not before. This is unobservable in practice since
all workers fork within the same scheduling quantum."
```

---

## Verification

1. **Unit tests:** `bats tests/` — all existing + 4 new tests should pass.

2. **Dry-run smoke check:** confirm flag parsing still works end-to-end:
   ```bash
   lidar run --dry-run tests/fixtures/one_tile.txt
   ```
   Expected: plan printed, no errors.

3. **Live happy path** (manual, requires `GIS_DIR`):
   - Start: `lidar run tests/fixtures/one_tile.txt`
   - While running: `lidar list` should show status `running` (not `crashed`)
   - After completion: `lidar list` should show `✓ ok` (or `✗ fail` if it failed)

4. **Crash negative case** (manual):
   - Start a run, note its hex ID from `lidar list`
   - `kill <worker-pid>` (PID shown by `lidar list`)
   - `lidar list` should show `⊘ crashed` (PID gone, no end event written)

5. **Failed-run negative case** (manual — introduce a deliberate failure or use a bad tile list):
   - Confirm `lidar list` shows `✗ fail` with a non-zero exit code, not `✓ ok`.
