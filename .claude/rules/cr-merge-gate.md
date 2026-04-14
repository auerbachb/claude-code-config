# Merge Gate & Pre-Merge Verification

> **This is the single authoritative definition of the merge gate.** All other rule files reference this file instead of duplicating it.
> **Always:** Verify merge gate before any merge. Verify CI. Verify AC checkboxes against code. Ask user before merging.
> **Ask first:** Merging — always ask the user.
> **Never:** Merge without meeting the gate. Merge with failing CI. Merge with unchecked AC boxes.

## Step 1 — Confirm reviews are clean (merge gate)

The merge gate depends on which reviewer owns the PR:

**CR-only path** (neither BugBot nor Greptile was triggered for this PR):
- 2 clean CR reviews required. The second is a confirmation pass — CR's completion signal is unreliable (it may mark the check as "completed" but post findings minutes later), so a second clean pass is needed.
- If CR responds with no findings after a round of fixes, post `@coderabbitai full review` one more time to confirm.
- **After 2 failed re-triggers on the same SHA**, stop and tell the user. Do not loop forever.

**BugBot path** (CR failed, BugBot responded, Greptile was never triggered — sticky assignment, see `bugbot.md`):
- 1 clean BugBot review satisfies the gate — no confirmation pass needed (BugBot's completion signals are reliable).
- After fixing BugBot findings, BugBot auto-reviews the new push. If auto-review doesn't fire within 5 min, trigger manually via `@cursor review`.
- Stay on BugBot — do not switch back to CR. Ignore late CR reviews.

**Greptile path** (Greptile was triggered at any point — both CR and BugBot failed — sticky assignment, see `greptile.md`):
- Severity-gated: merge-ready when ANY of these hold:
  1. **Clean review:** no findings (thumbs-up with no inline comments).
  2. **No P0 findings:** only P1/P2 findings present — fix all of them, push, reply to threads; no re-review required.
  3. **P0 fixed + re-review clean:** P0 findings were present, fixed, and a re-triggered `@greptileai` review came back clean.
- Stay on Greptile — do not switch back to CR or BugBot. Ignore any late CR/BugBot reviews.
- Max 3 Greptile reviews per PR (initial + up to 2 P0 re-reviews). At 3 with persistent P0, self-review and report blocker.

**If CR, BugBot, and Greptile are all down** (CR rate-limited/timed out + BugBot 5-min timeout + Greptile 5-min timeout): perform a self-review for risk reduction. A clean self-review does NOT satisfy the merge gate — report the blocker to the user.

- **How to detect a clean CR pass:** After triggering `@coderabbitai full review`, watch for these signals in order:
  1. **Ack (review started):** CR posts an issue comment (on `issues/{N}/comments`) with "Actions performed — Full review triggered." This means CR **started** the review — it is NOT a completion signal.
  2. **Completion (review finished):** The commit status check for CodeRabbit shows `status: "completed"` with `conclusion: "success"` (visible as "CodeRabbit — Review completed" in the PR's CI checks). This is the **definitive completion signal**.
  3. **Clean = completed + no new findings:** Once the CI check shows completed, check all three comment endpoints for any new findings posted after the ack. If there are none, the review is a clean pass. You do NOT need to keep polling to the 7-minute timeout once the CI check is green and no findings appeared.
- Once the merge gate is met, proceed immediately to Step 1b (CI verification).

## Step 1b — CI Must Pass Before Merge (NON-NEGOTIABLE)

Before running `gh pr merge` on ANY PR, verify ALL CI check-runs are complete and passing. Run two queries against `repos/{owner}/{repo}/commits/$SHA/check-runs?per_page=100`: (1) incomplete runs — `select(.status != "completed")`; (2) blocking conclusions — `select(.conclusion IN (failure, timed_out, action_required, startup_failure, stale))`. Full commands: `.claude/reference/cr-polling-commands.md`.

**If query 1 returns ANY incomplete check-runs: DO NOT MERGE.** Wait for them to finish — a null conclusion means the check hasn't reported yet, not that it passed.

**If query 2 returns ANY blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`): DO NOT MERGE.** Instead:
1. Read the failure output and fix the issue
2. Commit, push, and wait for CI to re-run
3. Only merge after ALL checks are `status: "completed"` with non-blocking conclusions

This applies to ALL merge paths: manual `gh pr merge`, the `/merge` skill, the `/wrap` skill, and Phase C merge prep.

## Step 2 — Verify every Test Plan checkbox (MANDATORY — do NOT skip)

> This is the **immediate next step** after CI passes (Step 1b). Do not ask the user about merging until this is done.
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
