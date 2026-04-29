# Merge Gate & Pre-Merge Verification

> **This is the single authoritative definition of the merge gate.** All other rule files reference this file instead of duplicating it.
> **Always:** Verify merge gate before any merge. Verify CI. Verify AC checkboxes against code. Ask user before merging.
> **Ask first:** Merging — always ask the user.
> **Never:** Merge without meeting the gate. Merge with failing CI. Merge with unchecked AC boxes. Stop polling because "nothing is unresolved right now" — see "Polling exit criterion" below.

## Polling exit criterion

Stop polling ONLY when one current-HEAD review path below is satisfied:

1. **CR:** explicit clean `APPROVED` review on current HEAD.
2. **BugBot:** clean BugBot pass on current HEAD.
3. **Greptile:** severity gate passed.

"0 unresolved threads right now" is transient, not an exit condition. After any fix push, HEAD changes and reviewers re-run; keep polling for a current-HEAD gate.

## Step 1 — Confirm reviews are clean (merge gate)

The merge gate depends on which reviewer owns the PR:

**CR-only path** (neither BugBot nor Greptile was triggered):

- **Gate:** 1 CR review with `state: "APPROVED"` and `commit_id == current HEAD SHA`.
- **SHA freshness:** stale approvals do not count; re-trigger `@coderabbitai full review` subject to the rate cap and keep polling.
- **Retraction:** a newer same-SHA `CHANGES_REQUESTED` retracts an earlier `APPROVED` until findings are fixed, pushed, and re-approved.
- **Not approvals:**
  - The "Actions performed — Full review triggered" ack comment (review started, not finished).
  - "0 unresolved threads right now" without an APPROVED review on the current SHA.
  - Absence of findings in the first N minutes after triggering (CR can run slowly or time out).
  - CR check-run `status: "completed"` without an accompanying APPROVED review object on the current SHA.
- **Re-trigger policy:** after 12 min without approval, re-trigger `@coderabbitai full review` up to 2 times on the same SHA, capped at 2 explicit triggers/PR/hour. Rate-limit signals override the timeout. After 2 failed re-triggers on one SHA, fall back BugBot → Greptile → self-review.

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

**If CR, BugBot, and Greptile are all down:** self-review for risk reduction only. A clean self-review does NOT satisfy the gate; report the blocker.

**CR detection order:** ack means started; CodeRabbit check-run success means complete; only an APPROVED review object on current HEAD satisfies the gate. Once Step 1 passes, proceed immediately to Step 1b.

### Code-owner bots

Some repos list CR (`@coderabbitai`) or Greptile (`@greptile-apps`) in `CODEOWNERS`. When branch protection has `require_code_owner_reviews`, that bot's `APPROVED` review on the current HEAD SHA satisfies the code-owner approval requirement. Do not ask the PR author or repo owner to self-approve — GitHub does not allow author self-approval and the bot approval is the terminal unblock when fresh.

Because `CODEOWNERS` varies by repo, this is a runtime check. `.claude/scripts/merge-gate.sh` reads `CODEOWNERS`, `.github/CODEOWNERS`, or `docs/CODEOWNERS`; when CR or Greptile is a code owner it also requires GitHub `reviewDecision == "APPROVED"` on the current PR head. If branch protection is `BLOCKED` and a prior bot approval is stale/dismissed after a push, trigger that bot again (`@coderabbitai full review` for CR, `@greptileai` for Greptile) and keep polling. Human escalation is only for an actual human-authored `CHANGES_REQUESTED`, not stale bot approval.

## Step 1b — CI Must Pass Before Merge (NON-NEGOTIABLE)

Before running `gh pr merge` on ANY PR, verify ALL CI check-runs are complete and passing. Use `.claude/scripts/ci-status.sh <PR_NUMBER_OR_SHA> --format summary`: exit `0` clean+complete, `1` incomplete (WAIT), `3` blocking failures (FIX). `.claude/scripts/merge-gate.sh` calls it; fallback commands live in `.claude/reference/cr-polling-commands.md`.

**If any check-run is incomplete: DO NOT MERGE.** Wait; null conclusion means not reported, not passed.

**If any check-run has blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`): DO NOT MERGE.** Instead:
1. Read the failure output and fix the issue
2. Commit, push, and wait for CI to re-run
3. Only merge after ALL checks are `status: "completed"` with non-blocking conclusions

This applies to ALL merge paths: manual `gh pr merge`, the `/merge` skill, the `/wrap` skill, and Phase C verify-and-wrap.

## Step 1c — All Review Threads Resolved (NON-NEGOTIABLE)

Every thread must be `isResolved: true` via GraphQL `reviewThreads` (REST misses cursor/copilot bots). `merge-gate.sh` enforces this — any unresolved thread blocks, regardless of author. **If any unresolved: DO NOT MERGE.** Reply + `resolveReviewThread`, then re-check.

## Step 1d — `mergeStateStatus` and branch sync (NON-NEGOTIABLE)

**Do not infer “behind base” from `mergeStateStatus: "BLOCKED"` alone.** `BLOCKED` is overloaded (required checks, reviews, code owners, etc.). Always read **`mergeStateStatus` and `mergeable` explicitly** (e.g. `gh pr view <N> --json mergeStateStatus,mergeable,reviewDecision` — same fields `merge-gate.sh` uses).

| `mergeStateStatus` | Meaning | Action |
|--------------------|---------|--------|
| `CLEAN` | GitHub considers the branch mergeable with respect to the base | OK for merge once Steps 1–1c and 1b pass |
| `BEHIND` | Branch tip is behind the base branch | **Not merge-ready.** Invoke `/fixpr` (rebase onto the PR base per `.claude/skills/fixpr/SKILL.md` merge_state / `pr-state.sh` — do not reimplement). After `git fetch` + `git rebase` onto the correct base, **force-push only from a clean worktree** after `.claude/scripts/dirty-main-guard.sh --check` passes — force-push is destructive. Re-run reviews/CI on the new SHA; keep polling until Step 1d is satisfied |
| `BLOCKED` | Protection or merge requirements not met | Use `reviewDecision`, CI, and thread state — not a substitute for checking `BEHIND` |
| `UNSTABLE` | Required checks green but something non-merge-blocking is pending/failing | Treat as not merge-ready until CI/review gate is clearly satisfied; see Step 1b |
| `DIRTY` | Merge commit cannot be computed cleanly | Block merge; investigate (often needs rebase or conflict resolution via `/fixpr`) |
| `UNKNOWN` | GitHub still computing | Wait and re-check; do not merge |

**`mergeable == "CONFLICTING"`** (from the same JSON) means merge conflicts — `/fixpr` rebase path; do not merge until resolved.

**Polling / merge gate / Phase C:** When `mergeStateStatus == "BEHIND"`, the merge gate **must** fail until rebased (`merge-gate.sh` enforces this). Polling treats BEHIND as a **`/fixpr` trigger**, not a reason to stop polling or to treat the PR as “blocked by branch protection” without rebase.

## Step 2 — Verify every Test Plan checkbox (MANDATORY — do NOT skip)

> After Steps 1c and 1d pass (`merge-gate.sh` enforces resolved threads and merge metadata including `mergeStateStatus`), verify AC before merge.
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
