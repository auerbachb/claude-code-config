# Greptile — Last-Resort Fallback Reviewer

> **Always:** Poll for response after triggering. Reply to every thread. Fix all valid findings. Classify by severity (P0/P1/P2). Only re-review for P0. Stay on G once triggered for a PR.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile before both CR AND BugBot have failed. Ignore Greptile findings. Switch a PR back to CR/BugBot after Greptile has been triggered. Include `@greptileai` in reply comments (triggers a paid re-review with no learning benefit).

Greptile is the **last-resort paid** AI code reviewer — only triggered when both CR and BugBot (Cursor) have failed. Review chain: **CR → BugBot → Greptile → self-review.** Verify all findings against code.

**Escalation gate:** `cr-github-review.md` owns triggers/STOP conditions. This file only defines Greptile behavior after `escalate-review.sh` returns `STATUS=trigger_greptile`.

## Greptile Basics

Bot username: `greptile-apps[bot]`. Trigger: PR comment `@greptileai` (no suffix). Auto-trigger is OFF. Review time is usually 1-3 minutes. Signals: 👀 analyzing, 👍 complete, 😕 failed. Config/setup details: `.claude/reference/greptile-setup.md`.

## Daily Budget

Default budget: 40 reviews/day. `~/.claude/session-state.json` tracks `greptile_daily.{reviews_used,date,budget}` (ET date). `.claude/scripts/greptile-budget.sh` is authoritative; every `@greptileai` trigger point MUST run `greptile-budget.sh --consume` first. Exit 0 = consumed; exit 1 = exhausted. Use `--check` for snapshots and `--reset` only for intentional counter resets.

If exhausted, perform self-review, report `"Greptile budget exhausted (used/budget, e.g. 40/40). PR #N falling back to self-review — merge blocked until manual review or budget resets tomorrow."` using actual numeric counters. Self-review does NOT satisfy the merge gate.

## Before EVERY `@greptileai` Re-Trigger (MANDATORY — after initial trigger)

Applies to 2nd/3rd triggers only; initial trigger requires only the budget check (no severity classification).

1. **Classify all findings from the previous review** (P0/P1/P2).
2. **If NO P0:** STOP — do NOT trigger `@greptileai`. Proceed to Phase B completion (merge gate check).
3. **If P0 present:** perform budget check (see "Daily Budget" above) → trigger `@greptileai`.
4. **Log severity counts in handoff `notes`.**

## When to Trigger Greptile

**Last-resort only:** trigger Greptile only after the mandatory escalation gate in `cr-github-review.md` returns `STATUS=trigger_greptile`. The gate checks CR failure/silence, BugBot response/install/cache state, and STOP conditions before Greptile is considered.

Always rely on `.claude/scripts/escalate-review.sh <PR_NUMBER>` for the current per-cycle verdict; it checks all three endpoints for `cursor[bot]` before returning `STATUS=trigger_greptile`.

### Sticky Assignment

**Once Greptile is triggered for a PR, it stays on Greptile permanently.** Do not switch back to CR or BugBot. After fixing findings, only re-trigger `@greptileai` for P0 findings. Ignore late CR/BugBot reviews. Merge gate is severity-dependent — see `cr-merge-gate.md` (Step 1) for the authoritative definition.

## Polling for Greptile Response

Poll every 60 seconds on all three endpoints (same pattern as CR — `pulls/{N}/reviews`, `pulls/{N}/comments`, `issues/{N}/comments` with `per_page=100`). Filter by `greptile-apps[bot]`.

**Timeout:** 10 minutes. Cadence stays 60 s. **Completion:** 👍 or review comments = done (exit immediately). 😕 = failed. No signal after 10 min = timeout.

## Processing Greptile Findings

Classify by severity (P0/P1/P2 — use Greptile badges only), verify against code, fix all valid findings in one commit, push once, reply to every thread, resolve via GraphQL. Use 👍/👎 reactions for feedback (this is Greptile's only learning mechanism).

> **CRITICAL: Do NOT include `@greptileai` in reply comments.** Every `@greptileai` mention — even in a reply — triggers a new paid review ($0.50-$1.00). Greptile does not learn from text replies. Use plain text only in replies — `@greptileai` is ONLY for intentionally requesting a new review.

Reply commands and CR-vs-Greptile comparison: `.claude/reference/greptile-reply-format.md`.

**Severity-gated re-review:** See the "Before EVERY `@greptileai` Re-Trigger" checklist above.

## Merge Gate

**Canonical definition:** See `cr-merge-gate.md` (Step 1). That file is the single authoritative source for the CR 1-explicit-APPROVED-on-current-HEAD path, the BugBot 1-clean-pass path, and the Greptile severity-gated path (including the 3-review-per-PR cap and the self-review fallback when all three reviewers are down).
