# Window Planning (increment 4/4)

This document covers the window-planning extension for `/pm` and the in-flight
overrun monitor for `/subagent`. It is the fourth and final increment of the
time-estimates theme.

## Concept

A planning window answers: "I have N hours — what can I confidently hand this
thread?" `/pm` accepts a window, fits a batch inside it, and tells you what's
in, what's out, and the projected finish.

Increment dependencies on main:
- Increment 1/4 — `estimate-resolve.sh`: per-issue estimate resolution
- Increment 2/4 — `estimate-log.sh`: actuals logging
- Increment 3/4 — `makespan.sh`: three-bound batch makespan
- **Increment 4/4 (this file)** — window planning + overrun alerts

## Window Parsing (`window-plan.sh`)

Accepts human-stated windows. Formats:

| Input | Parsed as |
|-------|-----------|
| `"until 5:00 PM"` | Minutes from now to 5:00 PM ET today |
| `"until 17:00"` | Same, 24-hour format |
| `"3 hours"` | 180 minutes |
| `"90m"` | 90 minutes |
| `"overnight"` | 720 min (12 h), unattended flag set |
| `"12-14 hours"` | 840 min (upper bound), unattended flag set |

### Stall Margin

Unattended runs (overnight, windows > 6 h) apply a **stall margin** — time
reserved for reviewer-escalation idle time when nobody is around to respond.

Default stall margin: **60 min** for unattended windows, **0 min** for attended.

Override via `STALL_MARGIN_MIN` in `pm-config.md` `## Budget` section:
```
## Budget
STALL_MARGIN_MIN: 30
```

Or via `--stall-margin N` argument to `window-plan.sh`.

`effective_window_min = window_minutes - stall_margin_min`

### Output

`window-plan.sh` emits a single line:
```
window_minutes=480 stall_margin_min=60 effective_window_min=420 deadline_epoch=1787709600
```

`/pm` persists this to `session-state.json`:
```json
".repos[\"owner/repo\"].window": {
  "deadline_epoch": 1787709600,
  "window_minutes": 480,
  "effective_window_min": 420,
  "set_at": "2026-08-25T18:00:00Z"
}
```

## Batch Fitting in `/pm`

When a window is active, `/pm` batch selection gates the makespan:

1. Resolve per-issue estimates via `estimate-resolve.sh`.
2. Compute candidate-batch makespan via `makespan.sh`.
3. If `makespan_hi > effective_window_min`: trim the batch by dropping lowest-
   priority issues (lowest-ranked first) until the batch fits. Each dropped
   issue is named in the exclusion report with the math:
   > `#N (90 min plan-bound) — excluded: batch would overshoot window by 45 min`
4. Report inclusions, exclusions, and projected finish:
   ```
   ## Window Plan (until 5:00 PM ET · effective 7 h)
   Batch: #42, #38, #55 — plan-bound makespan 4.5 h · finish ~4:30 PM ET ✓
   Excluded (window):
   - #61 (180 min plan) — adding it overshoots by 90 min
   ```

If no issue can be fit alone (smallest issue exceeds effective window), `/pm`
says so explicitly and suggests a narrower batch or a longer window.

## Overrun Monitor (`overrun-check.sh`)

Called once per poll cycle per active PR pipeline in `/subagent` Step 8.

### Inputs

- `--pr N` — PR number
- `--bound-min M` — planning bound in minutes (from the issue's `plan on M` line)
- `--started-at ISO8601` — when Phase A was launched (session-state
  `phase_a_started_at` or proxy: PR creation time)
- `--window-deadline EPOCH` — optional; the batch window end epoch
- `--window-issues "N1,N2"` — optional; other PRs in the batch (for cut suggestion)

### First-Breach-Only Semantics

On the first breach (elapsed > bound_min), `overrun-check.sh`:
1. Writes `.repos["owner/repo"].prs["N"].overrun.alerted_at` to `session-state.json`.
2. Emits the alert line to stdout (exit 1).
3. On all subsequent calls for the same PR: reads the marker, exits 2 (silent).

### Alert Format

```
⚠ PR #42 overrun: 2 h elapsed vs 90 min plan · revised finish ~5:45 PM ET
```

When window is blown:
```
⚠ PR #42 overrun: 2 h elapsed vs 90 min plan · revised finish ~5:45 PM ET · drop #42 to still land the rest by 5:00 PM ET
```

This is a **defined exception to silence-by-default**, bounded to one line per
pipeline. No repeated nagging. The alert suggests, never auto-drops.

### Session-State Schema

```json
".repos[\"owner/repo\"].prs[\"N\"].overrun": {
  "alerted_at": "2026-08-25T19:30:00Z",
  "bound_min": 90
}
```

## Testing

### Unit-test window-plan.sh

```bash
# "until HH:MM" and "N hours" resolve to same window logic
window-plan.sh --window "3 hours"           # → window_minutes=180
window-plan.sh --window "until 9:00 PM"     # → computed from now to 9 PM ET

# Unattended stall margin applied
window-plan.sh --window "overnight"         # → stall_margin_min=60, effective=660

# Explicit override
window-plan.sh --window "4 hours" --stall-margin 30  # → stall_margin_min=30
```

### Unit-test overrun-check.sh

```bash
# No breach: elapsed < bound
overrun-check.sh --pr 42 --bound-min 90 \
  --started-at "$(date -u -d '30 minutes ago' +%FT%TZ)"   # exit 0, no output

# First breach
overrun-check.sh --pr 42 --bound-min 90 \
  --started-at "$(date -u -d '120 minutes ago' +%FT%TZ)"  # exit 1, alert line

# Already alerted (marker written)
overrun-check.sh --pr 42 --bound-min 90 \
  --started-at "$(date -u -d '120 minutes ago' +%FT%TZ)"  # exit 2, silent

# Window blown: cut suggestion appears
overrun-check.sh --pr 42 --bound-min 90 \
  --started-at "$(date -u -d '120 minutes ago' +%FT%TZ)" \
  --window-deadline "$(date -d '+10 minutes' +%s)"         # exit 1, includes cut
```
