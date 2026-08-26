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

Each pause point's own rule or skill step is canonical for its options and wording — `/issue-maker` Steps 4, 8, 12; `/pm-clean` Steps 4.1, 4.2; `/memory-clean` Step 3; `repo-bootstrap.md`'s branch-protection ask. All use AskUserQuestion when available, prose fallback in headless runs.

One site has no other home: a **blocker surface ending in a question** derives its options from the blocker's own resolution paths.
