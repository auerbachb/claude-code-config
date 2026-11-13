# User-Facing Decision Points — AskUserQuestion

> **Always:** Present enumerable decisions as clickable menus via AskUserQuestion. Put the recommended option first, labeled `"<text> (Recommended)"`. Use `multiSelect: true` for non-exclusive choices.
> **Ask first:** Never — this file governs the vehicle, not the timing; each pause point's own rule controls when to pause.
> **Never:** Call AskUserQuestion as filler between monitor ticks or while background work runs with no genuine decision at hand. Open one while unattended (`human-queue.md`).

Typed-reply prose is a fallback only when the tool is unavailable (headless) or the answers cannot be enumerated. Over 4 options: the 3 most plausible plus the built-in "Other". A **blocker surface ending in a question** takes its options from the blocker's own resolution paths. Named pause points (each owns its options and wording): `.claude/reference/ask-menu-pause-points.md`.
