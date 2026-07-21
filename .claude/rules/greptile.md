# Greptile — Last-Resort Fallback Reviewer

> **Always:** Poll for response after triggering. Reply to every thread. Fix all valid findings. Classify by severity (P0/P1/P2). Only re-review for P0. Stay on G once triggered for a PR.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile before both CR AND BugBot have failed. Ignore Greptile findings. Switch a PR back to CR/BugBot after Greptile has been triggered. Include `@greptileai` in reply comments (triggers a paid re-review with no learning benefit).

Greptile is the **last-resort paid** reviewer — only after both CR and BugBot fail (chain + supplemental CodeAnt/Graphite: `cr-github-review.md` §Three-Tier).

**Escalation gate:** `cr-github-review.md` owns triggers/STOP conditions. This file only defines Greptile behavior after `escalate-review.sh` returns `STATUS=trigger_greptile`.

## Greptile Basics

Bot username: `greptile-apps[bot]`. Trigger: PR comment `@greptileai` (no suffix). Auto-trigger is OFF. Review time is usually 1-3 minutes. Signals: 👀 analyzing, 👍 complete, 😕 failed. Config/setup details: `.claude/reference/greptile-setup.md`.

## Daily Budget

Default budget: 40 reviews/day. `~/.claude/session-state.json` tracks `greptile_daily.{reviews_used,date,budget}` (ET date). `.claude/scripts/greptile-budget.sh` is authoritative; every `@greptileai` trigger point MUST run `greptile-budget.sh --consume` first. Exit 0 = consumed; exit 1 = exhausted.

If exhausted: self-review (never satisfies the gate) and report the actual counters.

## Before EVERY `@greptileai` Re-Trigger (MANDATORY — after initial trigger)

Applies to 2nd/3rd triggers only; initial trigger requires only the budget check.

1. **Classify all findings from the previous review** (P0/P1/P2).
2. **If NO P0:** STOP — do NOT trigger `@greptileai`. Proceed to Phase B completion (merge gate check).
3. **If P0 present:** budget check → trigger `@greptileai`.
4. **Log severity counts in handoff `notes`.**

## When to Trigger Greptile

**Last-resort only:** trigger only after the escalation gate in `cr-github-review.md` returns `STATUS=trigger_greptile`. Always rely on `.claude/scripts/escalate-review.sh <PR_NUMBER>` for the per-cycle verdict.

"BugBot also fails" includes a classified BugBot failure; see `bugbot.md`'s "BugBot failure detection" section. In that case, `escalate-review.sh` routes directly to `trigger_greptile` without waiting out the BugBot grace window.

### Sticky Assignment

Sticky per `cr-github-review.md`: once triggered, Greptile owns the PR permanently. Re-trigger `@greptileai` only for P0 findings. Merge gate is severity-dependent — see **Merge Gate** below.

## Polling for Greptile Response

Poll per the shared cadence/endpoints (`cr-github-review.md` §Polling); filter `greptile-apps[bot]`. **Completion:** 👍 or review comments = done; 😕 = failed; no signal after **10 min** = timeout.

## Processing Greptile Findings

Classify by severity (P0/P1/P2 — use Greptile badges only), verify against code, fix all valid findings in one commit, push once, reply to every thread, resolve via `.claude/scripts/resolve-review-threads.sh` (never inline GraphQL). Use 👍/👎 reactions for feedback (Greptile's only learning mechanism).

> **CRITICAL: plain text only in replies** — every `@greptileai` mention triggers a new paid review.

Reply commands and CR-vs-Greptile comparison: `.claude/reference/greptile-reply-format.md`.

## Merge Gate

**Canonical definition:** See `cr-merge-gate.md` (Step 1) and `.claude/reference/merge-gate-reviewer-paths.md` (Greptile path).
