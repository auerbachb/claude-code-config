# Greptile — Last-Resort Fallback Reviewer

> **Always:** Poll for response after triggering. Reply to every thread. Fix all valid findings. Classify by severity (P0/P1/P2). Only re-review for P0. Stay on G once triggered for a PR.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile before both CR AND BugBot have failed. Ignore Greptile findings. Switch a PR back to CR/BugBot after Greptile has been triggered. Include `@greptileai` in reply comments (triggers a paid re-review with no learning benefit).

Greptile is the **last-resort paid** reviewer — only after both CR and BugBot fail (chain + supplemental CodeAnt/Graphite: `cr-github-review.md` §Three-Tier).

**Escalation gate:** `cr-github-review.md` owns triggers/STOP conditions. This file only defines Greptile behavior after `escalate-review.sh` returns `STATUS=trigger_greptile`.

## Greptile Basics

Bot: `greptile-apps[bot]`. Trigger: `@greptileai` PR comment. Auto-trigger OFF. Signals: 👀 analyzing, 👍 complete, 😕 failed. Setup: `.claude/reference/greptile-setup.md`.

## Daily Budget

Default budget: 40 reviews/day (tracked in `session-state.json`). Every `@greptileai` trigger MUST run `greptile-budget.sh --consume` first (exit 0 = consumed, exit 1 = exhausted). If exhausted: self-review (never satisfies gate).

## Before EVERY `@greptileai` Re-Trigger (MANDATORY — after initial trigger)

Applies to 2nd/3rd triggers only; initial trigger requires only the budget check.

1. **Classify all findings from the previous review** (P0/P1/P2).
2. **If NO P0:** STOP — do NOT trigger `@greptileai`. Proceed to Phase B completion (merge gate check). After a fix-only push, `merge-gate.sh` reuses the latest completed zero-P0 round (issue #1000; boundary rules in `.claude/reference/merge-gate-reviewer-paths.md`).
3. **If P0 present:** budget check → trigger `@greptileai`.
4. **Log severity counts in handoff `notes`.**

## Sticky Assignment

Once triggered, Greptile owns the PR permanently (`cr-github-review.md`). Re-trigger `@greptileai` only for P0 findings; a latest round containing P0 requires a later triggered clean round, while a completed zero-P0 round remains reusable after fix-only pushes. The merge gate is severity-dependent — canonical definition in `cr-merge-gate.md` Step 1, Greptile path expanded in `.claude/reference/merge-gate-reviewer-paths.md`. A classified BugBot failure (`bugbot.md`) routes `escalate-review.sh` straight to `trigger_greptile`.

## Polling for Greptile Response

Poll per the shared cadence/endpoints (`cr-github-review.md` §Polling); filter `greptile-apps[bot]`. **Completion:** 👍 or review comments = done; 😕 = failed; no signal after **10 min** = timeout.

## Processing Greptile Findings

Classify by severity (P0/P1/P2 — use Greptile badges only), verify against code, fix all valid findings in one commit, push once, reply to every thread, resolve via `.claude/scripts/resolve-review-threads.sh` (never inline GraphQL). Use 👍/👎 reactions for feedback (Greptile's only learning mechanism).

> **CRITICAL: plain text only in replies** — every `@greptileai` mention triggers a new paid review.

Reply commands and CR-vs-Greptile comparison: `.claude/reference/greptile-reply-format.md`.
