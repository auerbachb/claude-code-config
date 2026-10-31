# BugBot (Cursor) — Second-Tier Reviewer

> **Always:** Poll for BugBot reviews alongside CR after every push. Process findings same as CR/Greptile. Use BugBot as the first fallback when CR fails — before Greptile.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile before checking if BugBot already posted a review. Include `@cursor` in reply comments (may trigger a re-review). Ignore BugBot findings. Re-nudge `@cursor review` after a usage-limit refusal postdating HEAD.

BugBot (Cursor) is the **second-tier** reviewer in the escalation chain (`cr-github-review.md` §Three-Tier).

**Trigger on push:** CI posts `@cursor review` via `CURSOR_REVIEW_PAT` (`cursor-review-pr-comment.yml`; no-policy repos only); BugBot ignores bot-authored triggers; absent secret → no post, warns.

**Escalation authority:** The numbered gate + STOP conditions live in `cr-github-review.md`. Use `.claude/scripts/escalate-review.sh <PR_NUMBER>` for the per-cycle `STATUS=` verdict; this file only defines BugBot behavior after `STATUS=switch_bugbot`.

## BugBot Basics

- **Bot username:** `cursor[bot]`
- **Trigger:** `@cursor review` comment (`/fixpr`, `pr-preflight.sh`, or CI; duplicates OK only without a review policy — §Re-Reviews).
- **Cost:** Highest per review in the stack. One nudge per HEAD; after a usage-limit refusal all three trigger paths — `maybe-trigger-ai-review.sh`, `/fixpr` Step 3b, CI — suppress further nudges until the next push, via the shared fail-open `bugbot-refused-head.sh`.
- **Review time:** ~1–3 min. **No CLI**.

## Polling for BugBot Reviews

Poll alongside CR per the shared cadence/endpoints (`cr-github-review.md` §Polling); filter `.user.login == "cursor[bot]"`.

**Fallback timing:** the escalation gate owns it — never a separate BugBot timeout. Once BugBot owns the PR, keep 60 s cadence and use the completion signal below.

**Completion signal:** BugBot creates a CI check-run named `Cursor Bugbot` that transitions to `status: "completed"` when the review finishes. `conclusion: "success"` = no findings, no review object (silent pass — gate conditions at §Merge Gate). `conclusion: "neutral"` = findings posted (review object required) or a refusal (below). Completion also detected via review comments on any endpoint.

**BugBot failure detection:** a spend-limit failure produces a non-passing `conclusion: "neutral"` check-run alongside a failure-phrase cursor[bot] comment (`couldn't run`, `usage limit`, …; PR #1349). `merge-gate.sh` still blocks the `success` silent-pass path whenever such a comment postdates HEAD. Cap and levers: `.claude/reference/pricing-matrix.md` §Cursor BugBot.

## When BugBot Becomes the Active Reviewer

On `STATUS=switch_bugbot`, **and** once the caller persists sticky ownership with `.claude/scripts/reviewer-of.sh <PR_NUMBER> --sticky bugbot`. Never on `STATUS=tier_gate` (review tier excludes BugBot — `review-policy.md`).

## Processing BugBot Findings

Verify all findings against actual code. Fix all valid findings in one commit, push once, reply to every thread with the same verdict flags (`cr-github-review.md` §Processing CR Feedback step 3), then resolve via `resolve-review-threads.sh <PR> --thread-ids <id1,id2>`.

**Reply format:** plain text only, no `@cursor`.

## Merge Gate

**A clean BugBot pass on current HEAD satisfies the merge gate alone** (`cr-merge-gate.md` Step 1). Full conditions and accepted shapes: `.claude/reference/merge-gate-reviewer-paths.md` §BugBot path.

## Re-Reviews

BugBot doesn't auto-review pushes. With no `## Review policy`, after a fix push CI posts `@cursor review` when `CURSOR_REVIEW_PAT` is set — necessary, not sufficient: a refusal on that HEAD still suppresses; otherwise post manually — one nudge per HEAD. With one, post only once `review-triggers-allowed.sh <PR> --claim cursor` exits 0.
