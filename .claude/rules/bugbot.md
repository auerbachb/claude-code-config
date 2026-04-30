# BugBot (Cursor) — Second-Tier Reviewer

> **Always:** Poll for BugBot reviews alongside CR after every push. Process findings same as CR/Greptile. Use BugBot as the first fallback when CR fails — before Greptile.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile before checking if BugBot already posted a review. Include `@cursor` in reply comments (may trigger a re-review). Ignore BugBot findings.

BugBot is the **second-tier** reviewer (Cursor, per-seat) between CR and Greptile: **CR → BugBot → Greptile → self-review.** Parallel CodeAnt/Graphite: `codeant-graphite.md`.

**Always-trigger:** CI posts `@cursor review` on every PR open/push (`cursor-review-pr-comment.yml`); GitHub auto-trigger is unreliable — see `feedback_bugbot_auto_trigger_unreliable.md`.

**Escalation authority:** The numbered gate + STOP conditions live in `cr-github-review.md` ("Reviewer escalation gate"). Use `.claude/scripts/escalate-review.sh <PR_NUMBER>` for the per-cycle `STATUS=` verdict; this file only defines BugBot behavior after `STATUS=switch_bugbot`.

## BugBot Basics

- **Bot username:** `cursor[bot]`
- **Triggers:** GitHub auto-trigger is best-effort only. This repo: CI + agents always post `@cursor review` on open/push (`cursor-review-pr-comment.yml`, `/fixpr`); duplicates OK. Manual: same comment if needed.
- **Cost:** Per-seat — safe to always-trigger.
- **Review time:** ~1–3 min. **No CLI** (GitHub-only).

## Polling for BugBot Reviews

Poll alongside CR every 60 seconds on all three endpoints (same pattern — `pulls/{N}/reviews`, `pulls/{N}/comments`, `issues/{N}/comments` with `per_page=100`). Filter by `.user.login == "cursor[bot]"`.

**Fallback timing:** Do not maintain a separate CR-owned BugBot timeout here. The escalation gate decides whether to keep polling, switch to BugBot, trigger Greptile, or self-review. Once BugBot owns the PR, keep 60 s cadence and use the `Cursor Bugbot` completion signal below.

**Completion signal:** BugBot creates a CI check-run named `Cursor Bugbot` that transitions to `status: "completed"` when the review finishes. The `conclusion` field is `neutral` when BugBot posted findings (still counts as a completed review — `neutral` is not a failure). Completion can also be detected via BugBot review comments appearing on any of the three endpoints.

## When BugBot Becomes the Active Reviewer

BugBot becomes the active reviewer (`reviewer: bugbot`) when:
1. The escalation gate returns `STATUS=switch_bugbot`, and
2. The caller persists sticky ownership with `.claude/scripts/reviewer-of.sh <PR_NUMBER> --sticky bugbot`.

**Sticky assignment:** Once a PR is assigned to BugBot (CR failed, BugBot responded), it stays on BugBot unless BugBot also fails — then Greptile takes over permanently.

## Processing BugBot Findings

Verify all findings against actual code. Fix all valid findings in one commit, push once, reply to every thread, resolve via GraphQL.

**Reply format:** Use plain text only in replies — do NOT include `@cursor` in reply comments (may trigger a re-review). This matches Greptile's reply behavior.

**Thread resolution:** Same GraphQL mutations as CR/Greptile — `resolveReviewThread(threadId)` or `minimizeComment(subjectId, classifier: RESOLVED)`.

## Merge Gate

**A clean BugBot review satisfies the merge gate alone.** CR path needs an explicit `APPROVED` on current HEAD (see `cr-merge-gate.md` Step 1).

## Re-Reviews

After fixing BugBot findings and pushing, expect a new BugBot pass on the new HEAD: CI already posted `@cursor review` on that push. If anything still looks stale after polling, post `@cursor review` again — duplicates are acceptable.
