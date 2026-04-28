# BugBot (Cursor) — Second-Tier Reviewer

> **Always:** Poll for BugBot reviews alongside CR after every push. Process findings same as CR/Greptile. Use BugBot as the first fallback when CR fails — before Greptile.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile before checking if BugBot already posted a review. Include `@cursor` in reply comments (may trigger a re-review). Ignore BugBot findings.

BugBot is the **second-tier** AI code reviewer — free, auto-triggers on every push/PR open, and sits between CR (primary) and Greptile (last resort). The full review chain: **CR → BugBot → Greptile → self-review.**

## BugBot Basics

- **Bot username:** `cursor[bot]`
- **Auto-trigger:** ON — runs on every push and every PR open (both "Only Run When Mentioned" and "Only Run Once Automatically" are OFF)
- **Manual trigger:** Comment `@cursor review` on any PR (for re-reviews or when auto-trigger didn't fire)
- **Cost:** Free (included with Cursor)
- **Review time:** Typically fast (~1-3 minutes)
- **No CLI** — local review loop uses CR CLI only; BugBot is GitHub-only

## Polling for BugBot Reviews

Poll alongside CR every 60 seconds on all three endpoints (same pattern — `pulls/{N}/reviews`, `pulls/{N}/comments`, `issues/{N}/comments` with `per_page=100`). Filter by `.user.login == "cursor[bot]"`.

**Timeout:** 10 minutes **from push time** (not from CR failure detection). BugBot auto-triggers at push, so its timeout runs concurrently with CR's 12-minute window (BugBot's 10 fits inside CR's 12). Cadence stays 60 s; `Cursor Bugbot` `status: "completed"` short-circuits the wait. If CR's 12-min timeout fires and BugBot hasn't posted, BugBot's 10-min window has already expired — trigger Greptile immediately (see `greptile.md`). Do NOT wait another 10 min.

**Completion signal:** BugBot creates a CI check-run named `Cursor Bugbot` that transitions to `status: "completed"` when the review finishes. The `conclusion` field is `neutral` when BugBot posted findings (still counts as a completed review — `neutral` is not a failure). Completion can also be detected via BugBot review comments appearing on any of the three endpoints.

## When BugBot Becomes the Active Reviewer

BugBot becomes the active reviewer (`reviewer: bugbot`) when:
1. **CR fails** (rate-limited or 12-min timeout) AND BugBot has already posted a review, OR
2. **CR fails** AND BugBot posts a review within its 10-minute window

**Sticky assignment:** Once a PR is assigned to BugBot (CR failed, BugBot responded), it stays on BugBot unless BugBot also fails — then Greptile takes over permanently.

## Processing BugBot Findings

Verify all findings against actual code. Fix all valid findings in one commit, push once, reply to every thread, resolve via GraphQL.

**Reply format:** Use plain text only in replies — do NOT include `@cursor` in reply comments (may trigger a re-review). This matches Greptile's reply behavior.

**Thread resolution:** Same GraphQL mutations as CR/Greptile — `resolveReviewThread(threadId)` or `minimizeComment(subjectId, classifier: RESOLVED)`.

## Merge Gate

**A clean BugBot review independently satisfies the merge gate.** BugBot requires 1 clean pass on the current HEAD, while CR requires an explicit review with `state: "APPROVED"` whose `commit_id` matches the current HEAD SHA (SHA freshness enforced; a later `CHANGES_REQUESTED` on the same SHA retracts the approval). See `cr-merge-gate.md` Step 1 for the canonical CR-path definition.

**Canonical definition:** See `cr-merge-gate.md` (Step 1) for the authoritative merge gate including the BugBot path.

## Re-Reviews

After fixing BugBot findings, BugBot auto-reviews the new push (since auto-trigger is ON). No need to manually trigger `@cursor review` unless the auto-review didn't fire within 10 minutes — then post `@cursor review` as a manual trigger.
