# Merge Gate & Pre-Merge Verification

> **This is the single authoritative definition of the merge gate.** All other rule files reference this file instead of duplicating it.
> **Always:** Verify merge gate before any merge. Verify CI. Verify AC checkboxes against code. Ask user before merging.
> **Ask first:** Merging — always ask the user.
> **Never:** Merge without meeting the gate. Merge with failing CI. Merge with unchecked AC boxes. Stop polling because "nothing is unresolved right now" — see "Polling exit criterion" below.

## Polling exit criterion

The ONLY valid reason to stop polling an open PR is: this file's merge gate has been met — specifically, one of:

1. **1 explicit clean CR approval on the current HEAD SHA** (CR-only path, Step 1 below).
2. **1 clean BugBot pass** on the current HEAD SHA (BugBot path, Step 1 below).
3. **Greptile severity gate passed** (sticky-Greptile path — clean review, or only P1/P2 fixed, or P0 fixed + re-review clean — Step 1 below).

"0 unresolved threads right now" is a transient snapshot, NOT an exit condition. After pushing a fix commit (whether by the loop directly or by `/fixpr`), the HEAD SHA changes and every reviewer re-runs — continue polling for the reviewer's response to the new SHA until one of the three conditions above holds.

## Step 1 — Confirm reviews are clean (merge gate)

The merge gate depends on which reviewer owns the PR:

**CR-only path** (neither BugBot nor Greptile was triggered for this PR):
- **1 clean CR approval on the current HEAD SHA satisfies the gate.** No extra verification round required. Two safeguards replace the old reliability check: SHA freshness (the approval must match the current HEAD) and explicit-approval-only (no inferring from acks or silence).
- **SHA freshness:** the approval's `commit_id` MUST equal the PR's current HEAD SHA. CR approvals stick to the PR after new pushes, so an approval from SHA `abc1234` does NOT validate SHA `def5678`. If the approval is on a stale SHA (any push happened after it), treat it as no approval: re-trigger `@coderabbitai full review` and keep polling. Verify every poll cycle — not just once.
- **Approval retraction on the same SHA.** If CR posts an `APPROVED` review and later posts a `CHANGES_REQUESTED` review on the same HEAD SHA (newer `submitted_at`), the approval is retracted and the gate is NOT met. Compare the newest `APPROVED` timestamp against the newest `CHANGES_REQUESTED` timestamp directly — a subsequent `COMMENTED` review must not paper over the retraction. Fix the findings, push (the SHA changes, so CR re-reviews from scratch), and wait for a fresh `APPROVED` on the new HEAD.
- **Explicit approval only.** A CR review with `state: "APPROVED"` on the current HEAD SHA counts — and only if it has not been retracted by a later `CHANGES_REQUESTED` on the same SHA (see above). Equivalently, a CR review with findings, all fixed + re-reviewed clean on the current HEAD SHA counts. The following are **NOT** approvals and MUST NOT exit polling:
  - The "Actions performed — Full review triggered" ack comment (review started, not finished).
  - "0 unresolved threads right now" without an APPROVED review on the current SHA.
  - Absence of findings in the first N minutes after triggering (CR can run slowly or time out).
  - CR check-run `status: "completed"` without an accompanying APPROVED review object on the current SHA.
- **Re-trigger policy:** if no approval on the current SHA within the 12-min timeout, re-trigger `@coderabbitai full review` once. Max 2 triggers per PR per hour. Rate-limit signals override the timeout — escalate immediately. After 2 failed re-triggers on the same SHA, fall back BugBot → Greptile → self-review.

**BugBot path** (CR failed, BugBot responded, Greptile was never triggered — sticky assignment, see `bugbot.md`):
- 1 clean BugBot review on the current HEAD SHA satisfies the gate (BugBot's completion signals are reliable).
- After fixing BugBot findings, BugBot auto-reviews the new push. If auto-review doesn't fire within 10 min, trigger manually via `@cursor review`.
- Stay on BugBot — do not switch back to CR. Ignore late CR reviews.

**Greptile path** (Greptile was triggered at any point — both CR and BugBot failed — sticky assignment, see `greptile.md`):
- Severity-gated: merge-ready when ANY of these hold:
  1. **Clean review:** no findings (thumbs-up with no inline comments).
  2. **No P0 findings:** only P1/P2 findings present — fix all of them, push, reply to threads; no re-review required.
  3. **P0 fixed + re-review clean:** P0 findings were present, fixed, and a re-triggered `@greptileai` review came back clean.
- Stay on Greptile — do not switch back to CR or BugBot. Ignore any late CR/BugBot reviews.
- Max 3 Greptile reviews per PR (initial + up to 2 P0 re-reviews). At 3 with persistent P0, self-review and report blocker.

**If CR, BugBot, and Greptile are all down** (CR rate-limited/timed out + BugBot 10-min timeout + Greptile 10-min timeout): perform a self-review for risk reduction. A clean self-review does NOT satisfy the merge gate — report the blocker to the user.

- **How to detect a clean CR approval:** After triggering `@coderabbitai full review`, watch for these signals in order:
  1. **Ack (review started):** CR posts an issue comment (on `issues/{N}/comments`) with "Actions performed — Full review triggered." This means CR **started** the review — it is NOT a completion signal and NOT an approval.
  2. **Completion (review finished):** The commit status check for CodeRabbit shows `status: "completed"` with `conclusion: "success"`. This is the completion signal — but completion alone does NOT satisfy the merge gate. An explicit `state: "APPROVED"` review object on the current HEAD SHA is still required.
  3. **Approval = APPROVED review on current HEAD:** Fetch `repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100`, filter to `.user.login == "coderabbitai[bot]"`, and find a review with `.state == "APPROVED"` AND `.commit_id == <current HEAD SHA>`. That review is the gate. If the latest APPROVED review's `commit_id` is stale, re-trigger and keep polling.
- Once the merge gate is met, proceed immediately to Step 1b (CI verification).

## Step 1b — CI Must Pass Before Merge (NON-NEGOTIABLE)

Before running `gh pr merge` on ANY PR, verify ALL CI check-runs are complete and passing. Use the shared helper `.claude/scripts/ci-status.sh <PR_NUMBER_OR_SHA> --format summary` — exit `0` is clean+complete, `1` is incomplete (WAIT), `3` is blocking failures (FIX). It implements the authoritative contract: (1) incomplete runs — `select(.status != "completed")`; (2) blocking conclusions — `select(.conclusion IN (failure, timed_out, action_required, startup_failure, stale))`. Full commands + inline fallback: `.claude/reference/cr-polling-commands.md`. `.claude/scripts/merge-gate.sh` already calls `ci-status.sh` internally as part of the gate.

**If query 1 returns ANY incomplete check-runs: DO NOT MERGE.** Wait for them to finish — a null conclusion means the check hasn't reported yet, not that it passed.

**If query 2 returns ANY blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`): DO NOT MERGE.** Instead:
1. Read the failure output and fix the issue
2. Commit, push, and wait for CI to re-run
3. Only merge after ALL checks are `status: "completed"` with non-blocking conclusions

This applies to ALL merge paths: manual `gh pr merge`, the `/merge` skill, the `/wrap` skill, and Phase C merge prep.

## Step 1c — All Review Threads Resolved (NON-NEGOTIABLE)

Every thread must be `isResolved: true` via GraphQL `reviewThreads` (REST misses cursor/copilot bots). `merge-gate.sh` enforces this — any unresolved thread blocks, regardless of author. **If any unresolved: DO NOT MERGE.** Reply + `resolveReviewThread`, then re-check.

## Step 2 — Verify every Test Plan checkbox (MANDATORY — do NOT skip)

> After Step 1c passes (`merge-gate.sh` enforces resolved threads), verify AC before merge.
>
> 1. Fetch the PR body via `gh pr view N --json body`
> 2. Parse **every** checkbox in the **Test plan** section of the PR description
> 3. For each item, read the relevant source file(s) and verify the criterion is met
> 4. Check off passing items by editing the PR body (replace `- [ ]` with `- [x]`)
> 5. If any item fails, fix the code first — do NOT offer to merge with unchecked boxes
> 6. Only after **ALL** boxes are checked, proceed to Step 3
>
> Re-run after every CR round. If additional code changes were made during the CR loop (e.g. fixes from CR rounds after the initial AC pass), you must re-verify ALL AC items against the final code. AC verification reflects the code **at merge time**, not the code at some earlier checkpoint.
>
> Skipping this step is a **blocking failure** — the user should never see unchecked AC boxes when asked about merge.

## Step 3 — Ask the user about merging

- Ask the user: "Reviews are clean, all AC verified and checked off. Want me to squash and merge, or do you want to review the diff yourself first?"
- Always use **squash and merge** (never regular merge or rebase)
