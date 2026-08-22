# Greptile — Second Fallback Reviewer

> **Always:** Poll for response after triggering. Reply to every thread. Fix all valid findings. Classify by severity (P0/P1/P2). Only re-review for P0. Stay on G once triggered for a PR.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile before both CR AND BugBot have failed. Ignore Greptile findings. Switch a PR back to CR/BugBot after Greptile has been triggered. Include `@greptileai` in reply comments (triggers a re-review with no learning benefit). Treat `budget_exhausted`, 😕, or a 10-min timeout as a routine fallback — each drops the PR to self-review, which never satisfies the gate, so surface the blocker.

Greptile is the second fallback — only after both CR and BugBot fail (chain + supplemental CodeAnt/Graphite: `cr-github-review.md` §Three-Tier). Role + cost: `.claude/reference/ai-review-chain-roles-decision.md`.

**Escalation gate:** `cr-github-review.md` owns triggers/STOP conditions; this file covers behavior after `escalate-review.sh` returns `STATUS=trigger_greptile`.

## Greptile Basics

Bot: `greptile-apps[bot]`. Trigger: `@greptileai` PR comment. Auto-trigger OFF. Signals: 👀 analyzing, 👍 complete, 😕 failed. Setup: `greptile-setup.md`.

## Daily Budget

Default: **40/day** (`session-state.json`) — a runaway-*loop* bound, **not** a spend cap; the real cap is vendor-side (`.claude/reference/pricing-matrix.md` §Greptile). Every `@greptileai` trigger MUST run `greptile-budget.sh --consume` first (exit 0 = consumed, exit 1 = exhausted). If exhausted: self-review, which never satisfies the gate.

## Before EVERY Re-Trigger (MANDATORY)

2nd/3rd triggers only; the initial trigger needs just the budget check.

1. **Classify the previous review's findings** (P0/P1/P2).
2. **No P0:** STOP — do NOT trigger. Reply to every finding naming the current HEAD, resolve the threads, then go to the merge gate; that provenance permits zero-P0 round reuse (issue #1000; boundaries in `.claude/reference/merge-gate-reviewer-paths.md`).
3. **P0 present:** budget check → trigger `@greptileai`.
4. **Log severity counts in handoff `notes`.**

## Sticky Assignment

Once triggered, Greptile owns the PR permanently (`cr-github-review.md`) — sticky on *history*. Re-trigger only for P0. Severity-gate conditions and zero-P0 round reuse: `.claude/reference/merge-gate-reviewer-paths.md` (canonical: `cr-merge-gate.md` Step 1). A classified BugBot failure (`bugbot.md`) routes `escalate-review.sh` straight here.

## Polling for Greptile Response

Poll per the shared cadence/endpoints (`cr-github-review.md` §Polling); filter `greptile-apps[bot]`. **Completion:** 👍 or review comments = done; 😕 = failed; no signal after **10 min** = timeout.

## Processing Greptile Findings

Classify by severity (Greptile badges only), verify against code, fix all valid findings in one commit, push once, reply to every thread naming the current HEAD, resolve via `resolve-review-threads.sh` (never inline GraphQL). 👍/👎 reactions are Greptile's only learning channel.

> **CRITICAL: plain text only in replies** — every `@greptileai` mention triggers a new review.

Reply commands and CR-vs-Greptile comparison: `greptile-reply-format.md`.
