# Named pause points — AskUserQuestion

Moved out of `.claude/rules/ask-menu.md` to keep the auto-loaded rule corpus inside its word budget (issue #2283). Each pause point's own rule or skill step is canonical for its options and wording; all use AskUserQuestion when available; with no question tool (headless, sub-agent) the agent takes the default or parks and records it in the handoff or exit report, never asks in prose (`human-queue.md`); and none opens a menu while unattended (`human-queue.md` §Unattended).

1. `/issue-maker` Steps 4, 8, 12.
2. `/pm-clean` Steps 4.1, 4.2.
3. `/memory-clean` Step 3.
4. `repo-bootstrap.md`'s branch-protection ask.
5. `chip-launching.md`'s model-guard mismatch.

## Conventions (from the former rule table)

| Convention | Rule |
|------------|------|
| Recommended option | Listed first; label ends with `" (Recommended)"` |
| `multiSelect` | `true` for independent choices; `Skip`/`Skip all` is always skip-wins |
| >4 options | The 3 most plausible + the built-in "Other" escape |
| No filler | Never call AskUserQuestion with placeholder content while background work runs |
