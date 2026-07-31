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

**Completion signal:** BugBot creates a CI check-run named `Cursor Bugbot` that transitions to `status: "completed"` when the review finishes. Two shapes to distinguish:

- `conclusion: "success"` — BugBot found nothing and posted **no review object** (silent pass). `merge-gate.sh` accepts this as a clean BugBot pass when freshness checks pass and no failure-phrase `cursor[bot]` comment is present (issue #844).
- `conclusion: "neutral"` — BugBot posted findings (review object and/or inline comments). Gate is satisfied only when the latest review object on current HEAD has no `CHANGES_REQUESTED` and no inline findings.

Completion can also be detected via BugBot review comments appearing on any of the three endpoints.

**BugBot failure detection:** a spend-limit failure can produce a `conclusion: "success"` check-run alongside a failure-phrase comment (`couldn't run`, `usage limit`, …). `escalate-review.sh` scans for failure phrases; `merge-gate.sh` also blocks the silent-pass path when a failure-phrase `cursor[bot]` comment exists — a clean pass requires no failure phrase on either endpoint.

## When BugBot Becomes the Active Reviewer

BugBot becomes the active reviewer when:
1. The escalation gate returns `STATUS=switch_bugbot`, and
2. The caller persists sticky ownership with `.claude/scripts/reviewer-of.sh <PR_NUMBER> --sticky bugbot`.

## Processing BugBot Findings

Verify all findings against actual code. Fix all valid findings in one commit, push once, reply to every thread, resolve via GraphQL.

**Reply format:** Use plain text only in replies — do NOT include `@cursor` in reply comments (may trigger a re-review). This matches Greptile's reply behavior.

**Thread resolution:** `resolve-review-threads.sh <PR> --thread-ids <id1,id2>`.

## Merge Gate

**A clean BugBot pass on current HEAD satisfies the merge gate alone** (`cr-merge-gate.md` Step 1). Two accepted shapes:

1. A `cursor[bot]` review object on current HEAD with no `CHANGES_REQUESTED` and no inline findings.
2. A completed `Cursor Bugbot` check-run with `conclusion: "success"` on HEAD, no failure-phrase `cursor[bot]` comment, and timestamp postdating the HEAD commit (issue #844 — the silent-pass shape).

## Re-Reviews

After a fix push, CI already posted `@cursor review` on the new HEAD; if stale after polling, post it again (duplicates OK).
