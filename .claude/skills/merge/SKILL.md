---
name: merge
description: Squash merge the current PR, delete the branch, log to work-log, and clean up. Verifies merge gate and acceptance criteria before merging.
---

Squash merge the current PR. This is the "we're done here" command.

## When to use /merge vs /wrap

- Use **/merge** for a quick mid-session merge when you'll continue working in the same session. It handles AC verification, CI check, and squash-merge — nothing else.
- Use **/wrap** for end-of-session cleanup. /wrap is a superset: runs the same merge flow PLUS detects follow-up issues, extracts session lessons, syncs the work log, and cleans up the worktree.
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

Run the shared PR-state helper once and read every downstream check from the resulting JSON bundle (eliminates overlapping `gh api` round trips). `/merge` runs outside worktrees (Step 1 aborts inside one), so the current branch is the PR's feature branch and no `--pr` override is needed.

> **`$STATE` is a file path, not JSON.** `pr-state.sh` writes `/tmp/pr-state-<PR>-<epoch>.json` and prints that path on stdout. Every `jq` below passes `"$STATE"` as the file argument. The script exits non-zero on failure (gh/network error, closed PR, detached HEAD) — under `set -e` the skill aborts automatically; in an ad-hoc shell, check `$?` before using `$STATE`.

```bash
STATE=$(.claude/scripts/pr-state.sh)
PR_NUMBER=$(jq -r '.pr.number' "$STATE")
HEAD_SHA=$(jq -r '.pr.head_sha' "$STATE")
```

Determine which reviewer owns this PR:

1. **Check session-state** — read `~/.claude/session-state.json` and check the `reviewer` field for this PR number. If it says `"g"`, this PR is on Greptile.
2. **If no session-state entry**, check the PR's review history from the bundle:
   ```bash
   jq -r '[.comments.reviews[], .comments.inline[], .comments.conversation[]] | .[].user.login' "$STATE" | sort -u
   ```
   - If `greptile-apps[bot]` has posted reviews/comments, this PR is on Greptile.
   - Otherwise, it's on CR.

**Merge gate check:**

- **CR-only PR:** Need 2 clean CR reviews. Check the last 2 review objects from `coderabbitai[bot]` — both must have no actionable findings. Also verify the CodeRabbit check-run **with fallback to the legacy commit-status API** — some repos still surface CR via `statuses` instead of `check-runs`, and without the fallback the merge gate silently misses rate-limit and pending signals:
  ```bash
  # Preferred: check-run on the current HEAD
  CR_CHECK=$(jq '.check_runs.all[] | select(.name == "CodeRabbit")' "$STATE")

  # Fallback: commit-status rollup already captured by pr-state.sh
  if [ -z "$CR_CHECK" ] || [ "$CR_CHECK" = "null" ]; then
    jq '.bot_statuses.CodeRabbit' "$STATE"
    # A clean pass in the fallback path requires .state == "success"
  else
    echo "$CR_CHECK" | jq '{status, conclusion}'
    # A clean pass in the check-runs path requires status == "completed" AND conclusion == "success"
  fi
  ```
- **Greptile PR:** Need 1 clean Greptile review. Check the last review from `greptile-apps[bot]` has no actionable findings.

If the merge gate is NOT met, stop and tell the user exactly what's missing (e.g., "PR needs 1 more clean CR review" or "Greptile has unresolved findings").

### Step 3: Verify acceptance criteria

Run the `/check-acceptance-criteria` skill logic for this PR. All Test Plan checkboxes must be checked off before proceeding. If any fail, stop and report — do NOT merge with unchecked boxes.

### Step 4: Verify CI passes (NON-NEGOTIABLE)

Before merging, inspect the check-runs from `$STATE` (already fetched in Step 2 for the current HEAD SHA). If you reach this step directly without Step 2, re-run `STATE=$(.claude/scripts/pr-state.sh)` first.

Look for any incomplete or blocking check-runs:

```bash
# Incomplete (still running or queued)
jq '.check_runs.in_progress_runs' "$STATE"

# Blocking conclusions (failure, timed_out, action_required, startup_failure, stale)
jq '.check_runs.failing_runs' "$STATE"
```

**If `in_progress_runs` is non-empty:** wait — do NOT merge. A null/pending conclusion is not a pass.

**If `failing_runs` has ANY entry: DO NOT MERGE.** Instead:
1. Read the failure output: `gh api "repos/{owner}/{repo}/check-runs/{CHECK_RUN_ID}" --jq '.output.summary'` (each entry in `failing_runs` already includes the `id` and `title`).
2. Fix the issue (lint errors, type errors, test failures, etc.)
3. Commit, push, and wait for CI to re-run
4. Refresh `$STATE` and re-verify every check before proceeding:
   ```bash
   STATE=$(.claude/scripts/pr-state.sh)
   jq '.check_runs.in_progress_runs, .check_runs.failing_runs' "$STATE"
   ```
   Both arrays must be empty before the merge gate is clear.

**Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, or any suppression comment to work around CI.** Fix the actual code.

If all checks pass, proceed to merge.

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

After merging, update the local `main` so subsequent sessions branch from the latest code. **Capture the result for the completion report in Step 7.**

```bash
MAIN_SYNC_STATUS=""

# Guard: tracked files with uncommitted changes would block checkout
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  MAIN_SYNC_STATUS="skipped: tracked files have uncommitted changes — run manually: git checkout main && git pull origin main --ff-only"
fi

# Ensure we're on main before pulling
CURRENT_BRANCH=$(git branch --show-current)
if [ -z "$MAIN_SYNC_STATUS" ] && [ "$CURRENT_BRANCH" != "main" ]; then
  if ! CHECKOUT_OUTPUT=$(git checkout main 2>&1); then
    MAIN_SYNC_STATUS="failed: could not checkout main — $CHECKOUT_OUTPUT"
  fi
fi

if [ -z "$MAIN_SYNC_STATUS" ]; then
  BEFORE_SHA=$(git rev-parse HEAD 2>/dev/null)
  if PULL_OUTPUT=$(git pull origin main --ff-only 2>&1); then
    AFTER_SHA=$(git rev-parse HEAD 2>/dev/null)
    if [ "$BEFORE_SHA" = "$AFTER_SHA" ]; then
      MAIN_SYNC_STATUS="up to date (${AFTER_SHA:0:7})"
    else
      MAIN_SYNC_STATUS="updated ${BEFORE_SHA:0:7} → ${AFTER_SHA:0:7}"
    fi
  else
    MAIN_SYNC_STATUS="failed: $PULL_OUTPUT"
  fi
fi

echo "Main sync: $MAIN_SYNC_STATUS"
```

Note: `/merge` only runs outside worktrees (Step 1 aborts in worktrees), so we should be on `main` after Step 5a's checkout. The explicit checkout-main guard handles edge cases. The `post-merge-pull.sh` hook also fires as a safety net, but this explicit step captures the result for reporting.

### Step 6: Log to work-log

If a work-log directory exists (detected at session start per work-log.md rules):

1. Determine the cycle count by reconstructing from PR history:
   ```bash
   CYCLES=$(.claude/scripts/cycle-count.sh "$PR_NUM")
   ```
   The script counts one cycle per review followed by at least one commit before the next review (or merge). Clean passes and confirmation reviews do not count. Default mode includes all reviewers (CR, Greptile, cursor, humans); pass `--exclude-bots` only if you need human-only cycles (not used here). See `.claude/scripts/cycle-count.sh --help` for the full contract.
2. Append a merge entry to today's session log:
   ```
   - {time} ET — PR #{N} merged (Issue #{M}): {1-line summary} [opened: {open_time}, merged: {merge_time}, cycles: {count}]
   ```
3. Get the linked issue number from the PR body (`Closes #N` pattern)

### Step 7: Report completion

Tell the user:
- PR number and title
- Merge SHA
- Main branch {MAIN_SYNC_STATUS from Step 5b — e.g. "updated abc1234 → def5678", "up to date (abc1234)", or "failed: ..."}
- Branch deleted
- Work-log updated (if applicable)
