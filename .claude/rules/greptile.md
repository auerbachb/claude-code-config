# Greptile — Paid Reviewer, Owner Approval Only

> **Always:** Treat every Greptile review as paid. On a PR Greptile owns: poll for its response, reply to every thread, fix all valid findings, classify by severity (P0/P1/P2), stay on G.
> **Ask first:** Every `@greptileai` trigger — first or P0 re-trigger — needs the owner's explicit approval in chat (`safety.md` §Paid AI Reviews); without it, follow `no_reviewer`.
> **Never:** Trigger Greptile without that approval. Ignore Greptile findings. Switch a PR back to CR/BugBot after Greptile has been triggered. Include `@greptileai` in reply comments (triggers a re-review with no learning benefit). Treat `budget_exhausted`, 😕, or a 10-min timeout as routine — each drops the PR to self-review, which never satisfies the gate, so surface the blocker.

Not an automatic fallback since issue #1897. Role + cost: `.claude/reference/ai-review-chain-roles-decision.md`; gated paths: `.claude/reference/review-policy.md` §Paid review authorization.

## Greptile Basics

Bot: `greptile-apps[bot]`. Trigger: `@greptileai` PR comment. Auto-trigger OFF. Signals — reactions on the **trigger** comment, not the bot's: 👀 analyzing, 👍 complete, 😕 failed. Setup: `greptile-setup.md`.

## Approved Triggers

An approved trigger still runs `greptile-budget.sh --consume` first (exit 1 = exhausted → self-review). Re-trigger only for P0: with no P0, reply to every finding naming the current HEAD, resolve the threads, and go to the merge gate — that provenance permits zero-P0 round reuse (issue #1000). Log severity counts in handoff `notes`. Budget, timeout, and re-trigger mechanics: `.claude/reference/review-policy.md` §Paid review authorization; gate paths: `merge-gate-reviewer-paths.md` §Greptile path.

## Sticky Assignment

Once triggered, Greptile owns the PR permanently (`cr-github-review.md`) — sticky on *history*. The **merge gate** reads no reaction: its clean pass is the summary comment's `Last reviewed commit` footer naming HEAD (`cr-merge-gate.md`).

## Polling and Processing

Poll per the shared cadence/endpoints (`cr-github-review.md` §Polling); filter `greptile-apps[bot]`. **Completion:** 👍 or review comments = done; 😕 = failed; no signal after **10 min** = timeout. Classify by severity (Greptile badges only), verify against code, fix all valid findings in one commit, push once, reply to every thread naming the current HEAD, resolve via `resolve-review-threads.sh` (never inline GraphQL). 👍/👎 reactions are Greptile's only learning channel.

> **CRITICAL: plain text only in replies** — every `@greptileai` mention triggers a new review.

Reply commands and CR-vs-Greptile comparison: `greptile-reply-format.md`.
