# User-Facing Decision Points — AskUserQuestion

> **Always:** Present enumerable decisions as clickable menus via AskUserQuestion. Put the recommended option first, labeled `"<text> (Recommended)"`. Use `multiSelect: true` for non-exclusive choices.
> **Ask first:** Never — this file governs the vehicle, not the timing; each pause point's own rule controls when to pause.
> **Never:** Call AskUserQuestion as filler between monitor ticks or while background work is running with no genuine decision at hand. Typed-reply prose is the fallback, never the default.

## Default behavior

At a decision point — pick an option, confirm a destructive action, resolve an ambiguity — present it via **`AskUserQuestion`**, not a `(y/N)` prose line.

**Exceptions** (fall back to prose):
- Non-interactive / headless session (tool unavailable)
- Answers genuinely cannot be enumerated (no plausible option list)

## Conventions

| Convention | Rule |
|------------|------|
| Recommended option | Listed first; label ends with `" (Recommended)"` |
| `multiSelect` | Set `true` for independent choices; `Skip`/`Skip all` is always skip-wins |
| >4 options | List the 3 most plausible + rely on the built-in "Other" free-text escape |
| No filler | Never call AskUserQuestion with placeholder content while waiting on background work |

## Named pause points

These sites use AskUserQuestion when available; prose fallback in headless runs:

- `/issue-maker` Step 4 — dedup strong-match: options `"Skip — looks like a duplicate (Recommended)"`, `"File anyway"`
- `/issue-maker` Step 8 — chain cap: options `"Re-cut to ≤5 increments (Recommended)"`, `"File all N increments"`
- `/issue-maker` Step 12 — retract chain: options `"Retract whole chain (Recommended)"`, `"Re-cut remainder"`
- `repo-bootstrap.md` — branch-protection ask: options `"Add required checks (Recommended)"`, `"Skip for now"`
- `/pm-clean` Step 4.1 — issue closures: `multiSelect` across closure categories + `"Skip all"` (skip-wins)
- `/pm-clean` Step 4.2 — workspace cleanup: options `"Apply cleanup (Recommended)"`, `"Skip"`
- `/memory-clean` Step 3 — prune confirmation: `multiSelect` across finding types + `"Skip"` (skip-wins)
- Blocker surface ending in a question — options derived from the blocker's resolution paths
