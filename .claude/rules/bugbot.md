# BugBot (Cursor) — Second-Tier Reviewer

> **Always:** Poll for BugBot reviews alongside CR after every push. Process findings same as CR/Greptile. Use BugBot as the first fallback when CR fails — before Greptile.
> **Ask first:** Never — fix findings autonomously.
> **Never:** Trigger Greptile before checking if BugBot already posted a review. Include `@cursor` in reply comments (may trigger a re-review). Ignore BugBot findings. Re-nudge `@cursor review` after a usage-limit refusal postdating HEAD.

BugBot (Cursor) is the **second-tier** reviewer in the escalation chain (`cr-github-review.md` §Three-Tier).

**Trigger on push:** CI posts `@cursor review` via `CURSOR_REVIEW_PAT` PAT (`cursor-review-pr-comment.yml`); BugBot ignores bot-authored triggers; absent secret → no post, warns — see `feedback_bugbot_auto_trigger_unreliable.md`.

**Escalation authority:** The numbered gate + STOP conditions live in `cr-github-review.md` ("Reviewer escalation gate"). Use `.claude/scripts/escalate-review.sh <PR_NUMBER>` for the per-cycle `STATUS=` verdict; this file only defines BugBot behavior after `STATUS=switch_bugbot`.

## BugBot Basics

- **Bot username:** `cursor[bot]`
- **Trigger:** `@cursor review` comment (`/fixpr` or CI when `CURSOR_REVIEW_PAT` set — duplicates OK, but see §Re-Reviews).
- **Cost:** **The stack's largest line** — ~$1.58/review on-demand, cap-exhausted, refusing 64% of PRs (#1204). One nudge per HEAD; after a usage-limit refusal there, `maybe-trigger-ai-review.sh` suppresses further nudges until the next push.
- **Review time:** ~1–3 min. **No CLI** (GitHub-only).

## Polling for BugBot Reviews

Poll alongside CR per the shared cadence/endpoints (`cr-github-review.md` §Polling); filter `.user.login == "cursor[bot]"`.

**Fallback timing:** the escalation gate owns it — never a separate BugBot timeout here. Once BugBot owns the PR, keep 60 s cadence and use the `Cursor Bugbot` completion signal below.

**Completion signal:** BugBot creates a CI check-run named `Cursor Bugbot` that transitions to `status: "completed"` when the review finishes. `conclusion: "success"` = no findings, no review object (silent pass — gate conditions at §Merge Gate). `conclusion: "neutral"` = findings posted; review object required. Completion also detected via review comments on any endpoint.

**BugBot failure detection:** a spend-limit failure produces a `conclusion: "success"` check-run alongside a failure-phrase cursor[bot] comment (`couldn't run`, `usage limit`, …); `merge-gate.sh` blocks the silent-pass path when any such comment postdates the HEAD commit. Cap and levers: `.claude/reference/pricing-matrix.md` §Cursor BugBot.

## When BugBot Becomes the Active Reviewer

On `STATUS=switch_bugbot`, **and** once the caller persists sticky ownership with `.claude/scripts/reviewer-of.sh <PR_NUMBER> --sticky bugbot`.

## Processing BugBot Findings

Verify all findings against actual code. Fix all valid findings in one commit, push once, reply to every thread, resolve via GraphQL.

**Reply format:** Use plain text only in replies — do NOT include `@cursor` in reply comments (may trigger a re-review).

**Thread resolution:** `resolve-review-threads.sh <PR> --thread-ids <id1,id2>`.

## Merge Gate

**A clean BugBot pass on current HEAD satisfies the merge gate alone** (`cr-merge-gate.md` Step 1). Full conditions and accepted shapes: `.claude/reference/merge-gate-reviewer-paths.md` §BugBot path.

## Re-Reviews

After a fix push, CI posts `@cursor review` when `CURSOR_REVIEW_PAT` is set (BugBot doesn't auto-review pushes); if absent, post it manually — subject to the one-nudge-per-HEAD rule above.
