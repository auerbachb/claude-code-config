# BugBot (Cursor) — Second-Tier Reviewer

> **Always:** Poll for BugBot reviews alongside CR after every push. Process findings same as CR/Greptile. Use BugBot as the first fallback when CR fails — before Greptile.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile before checking if BugBot already posted a review. Include `@cursor` in reply comments (may trigger a re-review). Ignore BugBot findings.

BugBot (Cursor, per-seat) is the **second-tier** reviewer in the escalation chain (`cr-github-review.md` §Three-Tier).

**Always-trigger:** CI posts `@cursor review` on every PR open/push (`cursor-review-pr-comment.yml`); GitHub auto-trigger is unreliable — see `feedback_bugbot_auto_trigger_unreliable.md`.

**Escalation authority:** The numbered gate + STOP conditions live in `cr-github-review.md` ("Reviewer escalation gate"). Use `.claude/scripts/escalate-review.sh <PR_NUMBER>` for the per-cycle `STATUS=` verdict; this file only defines BugBot behavior after `STATUS=switch_bugbot`.

## BugBot Basics

- **Bot username:** `cursor[bot]`
- **Trigger:** `@cursor review` comment (auto-posted by CI + `/fixpr` per the Always-trigger note above; duplicates OK).
- **Cost:** Per-seat — safe to always-trigger.
- **Review time:** ~1–3 min. **No CLI** (GitHub-only).

## Polling for BugBot Reviews

Poll alongside CR per the shared cadence/endpoints (`cr-github-review.md` §Polling); filter `.user.login == "cursor[bot]"`.

**Fallback timing:** Do not maintain a separate CR-owned BugBot timeout here — the escalation gate owns that decision (`cr-github-review.md`). Once BugBot owns the PR, keep 60 s cadence and use the `Cursor Bugbot` completion signal below.

**Completion signal:** BugBot creates a CI check-run named `Cursor Bugbot` that transitions to `status: "completed"` when the review finishes. The `conclusion` field is `neutral` when BugBot posted findings (still counts as a completed review — `neutral` is not a failure). Completion can also be detected via BugBot review comments appearing on any of the three endpoints.

**BugBot failure detection (issue #552):** a usage/spend-limit failure produces the *same* completed/`neutral` tuple as a clean pass. `escalate-review.sh` scans `cursor[bot]` comment bodies (and the check-run title) for failure phrases (`couldn't run`, `usage limit`, …) and treats a match as a failure — a completed check-run is a genuine clean pass only when no failure phrase is present.

## When BugBot Becomes the Active Reviewer

BugBot becomes the active reviewer (`reviewer: bugbot`) when:
1. The escalation gate returns `STATUS=switch_bugbot`, and
2. The caller persists sticky ownership with `.claude/scripts/reviewer-of.sh <PR_NUMBER> --sticky bugbot`.

**Sticky assignment:** canonical in `cr-github-review.md` (Timeout & Fallback).

## Processing BugBot Findings

Verify all findings against actual code. Fix all valid findings in one commit, push once, reply to every thread, resolve via GraphQL.

**Reply format:** Use plain text only in replies — do NOT include `@cursor` in reply comments (may trigger a re-review). This matches Greptile's reply behavior.

**Thread resolution:** `resolve-review-threads.sh <PR> --thread-ids <id1,id2>` (retries + `minimizeComment` fallback).

## Merge Gate

**A clean BugBot review on current HEAD satisfies the merge gate alone** (`cr-merge-gate.md` Step 1).

## Re-Reviews

After a fix push, CI already posted `@cursor review` on the new HEAD; if stale after polling, post it again (duplicates OK).
