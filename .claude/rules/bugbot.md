# BugBot (Cursor) — Paid Reviewer, Owner Approval Only

> **Always:** Treat every BugBot review as paid. Poll and process findings on a PR BugBot already owns, same as CR/Greptile.
> **Ask first:** Every BugBot review needs the owner's explicit approval in chat (`safety.md` §Paid AI Reviews); without it, follow `no_reviewer`.
> **Never:** Post `@cursor review` without that approval. Include `@cursor` in reply comments (may trigger a re-review). Ignore BugBot findings. Re-nudge after a usage-limit refusal postdating HEAD.

Not an automatic fallback since issue #1897 — gated paths: `.claude/reference/review-policy.md` §Paid review authorization.

## BugBot Basics

- **Bot username:** `cursor[bot]`. **Trigger:** `@cursor review` — owner-approved only.
- **Cost:** Highest per review in the stack. One nudge per HEAD; after a usage-limit refusal, `bugbot-refused-head.sh` suppresses further nudges until the next push.
- **Review time:** ~1–3 min. **No CLI**.

## Polling for BugBot Reviews

Poll alongside CR per the shared cadence/endpoints (`cr-github-review.md` §Polling); filter `.user.login == "cursor[bot]"`.

**Completion signal:** a `Cursor Bugbot` check-run reaching `status: "completed"`. `conclusion: "success"` = no findings, no review object (silent pass — §Merge Gate). `conclusion: "neutral"` = findings posted (review object required) or a refusal (below). Completion also detected via review comments on any endpoint.

**BugBot failure detection:** a spend-limit failure produces a `neutral` check-run alongside a failure-phrase cursor[bot] comment (`couldn't run`, `usage limit`, …; PR #1349). `merge-gate.sh` blocks the `success` silent-pass path whenever such a comment postdates HEAD. Cap and levers: `.claude/reference/pricing-matrix.md` §Cursor BugBot.

## When BugBot Owns a PR

Only a PR already sticky on BugBot (`.claude/scripts/reviewer-of.sh <PR_NUMBER> --sticky bugbot`), or one whose BugBot review the owner approved. Never on `STATUS=tier_gate` (`review-policy.md`).

## Processing BugBot Findings

Verify all findings against actual code. Fix all valid findings in one commit, push once, reply to every thread with the same verdict flags (`cr-github-review.md` §Processing CR Feedback step 3), then resolve via `resolve-review-threads.sh <PR> --thread-ids <id1,id2>`.

**Reply format:** plain text only, no `@cursor`.

## Merge Gate

**A clean BugBot pass on current HEAD satisfies the merge gate alone** (`cr-merge-gate.md` Step 1). Full conditions and accepted shapes: `.claude/reference/merge-gate-reviewer-paths.md` §BugBot path.

## Re-Reviews

BugBot doesn't auto-review pushes, and nothing re-invites it: a re-review is a new paid review, posted only on the owner's approval in chat, via `paid-review-grant.sh --trigger`.
