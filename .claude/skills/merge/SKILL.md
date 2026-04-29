---
name: merge
description: Squash merge the current PR, delete the branch, and clean up. Verifies merge gate and acceptance criteria before merging.
---

Squash merge the current PR. This is the "we're done here" command.

## When to use /merge vs /wrap

- Use **/merge** for a quick mid-session merge when you'll continue working in the same session. It handles AC verification, CI check, and squash-merge — nothing else.
- Use **/wrap** for end-of-session cleanup. /wrap is a superset: runs the same merge flow PLUS detects follow-up issues, extracts session lessons, and cleans up the worktree.
- If you're done for the session, use /wrap. If you're merging and immediately starting the next issue, use /merge.
- Note: /merge aborts if invoked from inside a worktree (see Step 1) — use /wrap in that case since it removes the worktree before deleting the branch.

## Steps

### Step 1: Identify the PR

```bash
gh pr view --json number,title,headRefName,body,state --jq '{number, title, headRefName, body, state}'
```

If no PR exists on the current branch, stop and tell the user: "No PR found for the current branch. Push and create a PR first."

If the PR is already merged or closed, stop and tell the user.

**Worktree check:** If running inside a git worktree where the feature branch is checked out, `git branch -D` will fail even after checking out away — git refuses to delete a branch checked out in any worktree. Detect this and abort early:

```bash
if [ "$(git rev-parse --git-common-dir)" != "$(git rev-parse --git-dir)" ]; then
  echo "Running inside a worktree. Use /wrap instead — it handles worktree removal before branch cleanup."
  exit 1
fi
```

If running in a worktree, stop here and tell the user: "This PR was developed in a worktree. Use `/wrap` instead of `/merge` — it removes the worktree first, then deletes the branch in the correct order."

### Step 2: Verify the merge gate

Run the shared merge-gate verifier, which implements the authoritative gate from `.claude/rules/cr-merge-gate.md` (CR 1 explicit APPROVED review on current HEAD / BugBot 1-clean / Greptile severity, plus CI and BEHIND checks):

```bash
PR_NUM=$(gh pr view --json number --jq .number)
GATE_JSON=$(.claude/scripts/merge-gate.sh "$PR_NUM")
GATE_EXIT=$?
```

- Exit `0` → gate met, proceed.
- Exit `1` → gate NOT met. Stop and report the `missing` array from the JSON output verbatim (e.g., "need 1 explicit CR APPROVED review on HEAD", "Greptile has P0 finding", "branch is BEHIND base").
- Exit `3` → PR not found (already merged/closed). Stop.
- Exit `2`/`4` → script or gh error; surface the stderr message to the user.

If `missing` says branch protection `reviewDecision` is not `APPROVED` and `.code_owner_bots` lists `coderabbitai[bot]` or `greptile-apps[bot]`, do not ask the PR author to approve. Trigger the matching bot re-review (`@coderabbitai full review` or `@greptileai`) and wait for a fresh current-HEAD approval.

Reviewer assignment is resolved automatically from `~/.claude/session-state.json` and live history. Pass `--reviewer cr|bugbot|greptile` to override.

### Step 3: Verify acceptance criteria

Use the shared `ac-checkboxes.sh` helper to parse and tick Test Plan items. All Test Plan checkboxes must be checked off before proceeding. If any fail verification, stop and report — do NOT merge with unchecked boxes.

```bash
# 1. Extract items (JSON array of {index, checked, text})
ITEMS=$(.claude/scripts/ac-checkboxes.sh "$PR_NUM" --extract)
AC_EXIT=$?
```

Exit codes from `--extract`:
- `0` → `$ITEMS` is a JSON array. Verify each unchecked item against the code, then tick the ones that pass.
- `1` → no Test Plan section. Stop and tell the user: "PR has no Test Plan section — cannot verify acceptance criteria."
- `3` → PR not found. Stop.
- `2` → internal script error. Surface stderr (`[script-error]`) and stop.

After verification, tick passing items — and **capture the tick exit code**:

```bash
.claude/scripts/ac-checkboxes.sh "$PR_NUM" --tick "0,2,3"  # or --all-pass
TICK_EXIT=$?
```

Exit codes from `--tick`/`--all-pass`:
- `0` → body updated (or noop — nothing to tick). Proceed.
- `4` → `gh pr edit` failed. Surface stderr (`[gh-error]`) and stop — do NOT merge.
- `2` / other non-zero → internal script error. Surface stderr and stop.

If any item fails verification, do NOT tick it — stop and report the failure. Do NOT merge with any unchecked AC.

### Step 4: CI verification (handled by Step 2)

`.claude/scripts/merge-gate.sh` already verifies CI as part of the gate — a gate-passing PR has all check-runs complete with no blocking conclusions. If Step 2 exited `0`, CI is green and you can proceed to merge.

If Step 2 reported `missing` entries about CI ("CI has N failing check-run(s): ..." or "CI has N incomplete check-run(s): ..."), **do NOT merge**. Instead:

1. Inspect the CI split: `.claude/scripts/ci-status.sh "$PR_NUM" --format summary` (exit `3` = blocking failures, exit `1` = incomplete). For the JSON with failing check-run IDs, drop `--format summary`.
2. Read a specific failure's output: `gh api "repos/{owner}/{repo}/check-runs/{CHECK_RUN_ID}" --jq '.output.summary'`
3. Fix the issue (lint errors, type errors, test failures, etc.)
4. Commit, push, and wait for CI to re-run
5. Re-run `.claude/scripts/merge-gate.sh` to confirm CI is green before proceeding

**Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, or any suppression comment to work around CI.** Fix the actual code.

### Step 5: Squash merge

```bash
gh pr merge --squash
```

Do NOT use `--delete-branch`. That flag attempts local branch deletion immediately, which fails when run from a worktree (the branch is still checked out). Handle branch cleanup in Step 5a below.

### Step 5a: Delete the branches

```bash
BRANCH_NAME=$(gh pr view --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view --json baseRefName --jq '.baseRefName')
```

**Local branch** — must use `-D` (force), not `-d`. Squash merges rewrite history so the branch commits are not reachable from `main` and `-d` always fails post-squash.

If currently on the feature branch, check out the base branch first (can't delete the branch you're on):

```bash
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" = "$BRANCH_NAME" ]; then
  git checkout "$BASE_BRANCH"
fi
git branch -D "$BRANCH_NAME" || echo "Warning: local branch deletion failed (may already be deleted) — skipping"
```

**Remote branch** — treat failure as non-fatal (branch may already be deleted by GitHub's auto-delete-on-merge, by `/wrap` if run previously, or due to permissions/network):

```bash
git push origin --delete "$BRANCH_NAME" || echo "Warning: remote branch deletion failed (may already be deleted) — skipping"
```

### Step 5b: Sync local main

After merging, update the local `main` so subsequent sessions branch from the latest code. **Capture the result for the completion report in Step 6.**

```bash
# .claude/scripts/main-sync.sh writes the status line to stdout and exits
# 0 OK / 1 skipped (uncommitted) / 2 failed (checkout/pull). All three
# outcomes are captured here for the completion report — a non-zero exit
# is not a hard error for /merge, just a report-worthy condition.
MAIN_SYNC_STATUS=$(bash .claude/scripts/main-sync.sh 2>&1 || true)
echo "Main sync: $MAIN_SYNC_STATUS"
```

Note: `/merge` only runs outside worktrees (Step 1 aborts in worktrees), so we should be on `main` after Step 5a's checkout. The helper's internal checkout-main guard handles edge cases. The `post-merge-pull.sh` hook also fires as a safety net, but this explicit step captures the result for reporting. See `.claude/scripts/main-sync.sh --help` for the full contract.

### Step 6: Report completion

Tell the user:
- PR number and title
- Merge SHA
- Main branch {MAIN_SYNC_STATUS from Step 5b — e.g. "updated abc1234 → def5678", "up to date (abc1234)", or "failed: ..."}
- Branch deleted
