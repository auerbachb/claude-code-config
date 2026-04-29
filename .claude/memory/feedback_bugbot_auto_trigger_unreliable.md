---
name: BugBot auto-trigger unreliable
description: Why we always post @cursor review on every PR push via CI and /fixpr
type: feedback
---

BugBot’s GitHub “auto-trigger on push” is unreliable on later pushes even when settings suggest it should run every time. Agents used to post `@cursor review` only when no BugBot activity appeared on the new SHA after a wait; that detection frequently missed real gaps.

**Current behavior (issue #361):** The workflow `.github/workflows/cursor-review-pr-comment.yml` posts `@cursor review` on every PR open, reopen, and synchronize (every push). `/fixpr` also always appends `@cursor review` after its conditional triggers for the other bots. Duplicates are acceptable.

**Cost:** BugBot (Cursor) is included per seat — there are no per-review or per-comment charges for spamming the trigger. Prefer reliability over skipping.

**Why:** Per-seat billing → safe to always-trigger; conditional detection cost more agent confusion than it saved.
