---
name: wrap
description: End-of-session command — verify no unresolved findings, squash merge, detect follow-ups, extract lessons, sync work-log, and clean up the worktree.
---

Wrap up the current PR and session. This is the "we're done here" command that handles everything from final verification through worktree cleanup.

## Phase 1: Pre-Merge Verification — Check for Unresolved Findings

Before merging, verify that all reviewer feedback has been addressed.

### Step 1.1: Identify the PR

```bash
gh pr view --json number,title,headRefName,body,state --jq '{number, title, headRefName, body, state}'
```

If no PR exists on the current branch, stop: "No PR found for the current branch."
If the PR is already merged or closed, skip to Phase 3 (follow-up detection).

### Step 1.2: Scan for unresolved review findings

Fetch all review comments from all three endpoints:

```bash
gh api "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100"
gh api "repos/{owner}/{repo}/pulls/{N}/comments?per_page=100"
gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100"
```

Filter for comments from `coderabbitai[bot]` and `greptile-apps[bot]`. For each finding:

1. Check if there is a reply confirming the fix
2. Check if the code at the referenced location has been updated since the comment
3. Check if the thread is resolved/outdated

**If unresolved findings exist:** Report them to the user and stop. List each unresolved finding with its location and what it says. Do NOT proceed to merge.

**If all findings are addressed:** Continue to Phase 2.

## Phase 2: Merge

### Step 2.1: Verify the merge gate

Determine which reviewer owns this PR:

1. Check `~/.claude/session-state.json` for a `reviewer` field for this PR number (`"g"` = Greptile, `"cr"` = CodeRabbit).
2. If no session-state entry, check the PR's review history — if `greptile-apps[bot]` has posted reviews/comments, this PR is on Greptile. Otherwise CR.

Also extract and store the feature branch name for use in Phase 5 cleanup:

```bash
BRANCH_NAME=$(gh pr view --json headRefName --jq '.headRefName')
```

**Merge gate check:**
- **CR-only PR:** Need 2 clean CR reviews. Check the last 2 review objects from `coderabbitai[bot]` — both must have no actionable findings. Also verify the CodeRabbit check-run on the HEAD commit:
  ```bash
  gh api "repos/{owner}/{repo}/commits/{HEAD_SHA}/check-runs" \
    --jq '.check_runs[] | select(.name == "CodeRabbit") | {status, conclusion}'
  ```
  Gate on BOTH `status == "completed"` AND `conclusion == "success"`. If check-runs is empty, fall back to commit statuses:
  ```bash
  gh api "repos/{owner}/{repo}/commits/{HEAD_SHA}/statuses" \
    --jq '.[] | select(.context | test("CodeRabbit"; "i")) | {state}'
  ```
- **Greptile PR:** Need severity-gated clean — no unresolved P0 findings. Check the last review from `greptile-apps[bot]`.

If the merge gate is NOT met, stop and report exactly what's missing.

### Step 2.2: Verify acceptance criteria

Extract the PR body's **Test plan** section. For each checkbox:

1. Read the criterion
2. Identify and read the relevant source files
3. Confirm the criterion is satisfied by the current code
4. Check off passing items by editing the PR body (replace `- [ ]` with `- [x]`)

If any item fails, stop and report — do NOT merge with unchecked boxes.

### Step 2.3: Pre-merge safety check

Before merging, verify the PR has not been rebased or force-pushed since the last clean review:

1. Compare the HEAD SHA that passed the merge gate with the current PR head:
   ```bash
   gh pr view N --json commits --jq '.commits[-1].oid'
   ```
2. If the SHA differs from what the merge gate was verified against, a rebase/force-push happened — **do NOT merge.** Wait for a fresh CR review on the new SHA before proceeding.

### Step 2.4: Verify CI passes (NON-NEGOTIABLE)

Before merging, check ALL CI check-runs on the HEAD commit:

```bash
SHA=$(gh pr view <PR_NUMBER> --json commits --jq '.commits[-1].oid')
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required") | {name, conclusion}'
```

**If ANY check-run has a blocking conclusion: DO NOT MERGE.** Instead:
1. Read the failure output: `gh api "repos/{owner}/{repo}/check-runs/{CHECK_RUN_ID}" --jq '.output.summary'`
2. Fix the issue (lint errors, type errors, test failures, etc.)
3. Commit, push, and wait for CI to re-run
4. Re-verify all checks pass before proceeding

**Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, or any suppression comment to work around CI.** Fix the actual code.

### Step 2.5: Squash merge

```bash
gh pr merge --squash
```

Do NOT use `--delete-branch` here. That flag attempts local branch deletion while the worktree is still active, which fails because git refuses to delete a branch checked out in any worktree. Branch cleanup is handled explicitly in Phase 5 after the worktree is removed.

### Step 2.6: Sync root repo main

After merging, update the root repo's local `main` so subsequent sessions branch from the latest code.

First check that the root repo is clean before switching branches:

```bash
ROOT_REPO=$(git worktree list | head -1 | awk '{print $1}')
if [ -z "$ROOT_REPO" ] || [ ! -d "$ROOT_REPO" ]; then
  echo "Warning: could not determine root repo path — skipping main sync"
elif [ -z "$(git -C "$ROOT_REPO" status --porcelain)" ]; then
  git -C "$ROOT_REPO" checkout main
  git -C "$ROOT_REPO" pull origin main --ff-only
else
  echo "Warning: root repo has uncommitted changes — skipping main sync. Run manually: git -C \"$ROOT_REPO\" checkout main && git -C \"$ROOT_REPO\" pull origin main --ff-only"
fi
```

### Step 2.7: Log to work-log

If a work-log directory was detected at session start:

1. Reconstruct the cycle count from PR history:
   ```bash
   gh api "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" \
     --jq '[.[] | select(.user.login == "coderabbitai[bot]" or .user.login == "greptile-apps[bot]") | {state, submitted_at}]'
   gh api "repos/{owner}/{repo}/pulls/{N}/commits?per_page=100" \
     --jq '[.[] | {sha: .sha, date: .commit.committer.date}]'
   ```
   Count each review-with-findings followed by a fix commit as 1 cycle.

2. Append to today's session log:
   ```
   - {time} ET — PR #{N} merged (Issue #{M}): {1-line summary} [opened: {open_time}, merged: {merge_time}, cycles: {count}]
   ```

## Phase 3: Follow-Up Detection

Check if there is related work that needs attention for feature completeness.

### Step 3.1: Check related issues

1. Extract the linked issue number from the PR body (`Closes #N` pattern)
2. If a parent issue exists (check for "parent" or "epic" references in the issue body), fetch sibling issues:
   ```bash
   gh issue view {parent_N} --json body --jq .body
   ```
   Look for task lists or child issue references. Check which are still open.

3. Check for related issues mentioned in the PR or issue thread:
   ```bash
   gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" --jq '.[].body'
   ```
   Scan for issue references (`#NNN`), "follow-up", "TODO", "next step", "migration", "deploy" mentions.

4. Check if the issue itself has sub-tasks (task list checkboxes) that are unchecked.

### Step 3.2: Report follow-ups

If follow-up items were found, present them:

```
## Follow-ups Detected
- Issue #X: {title} — still open, related to this work
- Migration needed: {description from thread}
- ...
```

If nothing found: "No follow-up items detected."

## Phase 4: Lessons Learned (Depth-Adaptive)

Determine the session depth to decide how thoroughly to reflect.

### Step 4.1: Assess session complexity

Calculate a complexity signal:
- **Cycle count** from Phase 2 (review-then-fix rounds)
- **Thread length** — count the number of user + assistant messages in the current session. "Short" = fewer than 15 total messages.
- **PR size** — number of files changed (`gh pr view N --json files --jq '.files | length'`)

**Trivial threshold:** cycle count = 0 AND conversation is short (you've been in this session for <15 messages) AND <5 files changed.

### Step 4.2: Run lessons (or skip)

**If trivial:** Output "Clean session — no lessons to capture." and skip to Phase 5.

**If non-trivial:** Reflect on the session:

1. What was the task? What was accomplished?
2. What went wrong or was harder than expected?
3. What patterns emerged (good or bad)?
4. Any surprises — tools behaving unexpectedly, edge cases, workflow friction?
5. Any workarounds that should be codified?

For each actionable, novel lesson:
- Check `MEMORY.md` for duplicates — update existing memories rather than creating new ones
- Write memory files with proper frontmatter (`feedback`, `project`, or `user` type)
- Add pointers to `MEMORY.md`

Present the summary:
```
## Session Lessons

### Saved to memory:
1. **<title>** — <summary> (saved as <type>)

### Observations (not saved):
- <things noted but not actionable>
```

## Phase 5: Worktree Cleanup

### Step 5.1: Sync work-log to root repo

If a work-log was updated in Phase 2, sync it before removing the worktree:

```bash
ROOT_REPO=$(git worktree list | head -1 | awk '{print $1}')
WORKTREE=$(pwd)
# Compare and append any missing entries to root repo copy
diff "$WORKTREE/$WORK_LOG_PATH/session-log-YYYY-MM-DD.md" "$ROOT_REPO/$WORK_LOG_PATH/session-log-YYYY-MM-DD.md"
```

If the root repo's copy is missing entries, append them (do not overwrite the entire file).

### Step 5.2: Remove the worktree

Use `ExitWorktree` with `action: "remove"` to delete the worktree directory. This must happen **before** local branch deletion — git refuses to delete a branch that is currently checked out in any worktree.

If `ExitWorktree` reports uncommitted changes, discard them — by this point all meaningful work has been merged.

### Step 5.3: Delete the local branch

After the worktree is removed, the branch is no longer checked out anywhere and can be safely deleted. Run on the root repo:

```bash
git -C "$ROOT_REPO" branch -D "$BRANCH_NAME"
```

Use `-D` (force) rather than `-d` — squash merges rewrite history so the branch commits are not reachable from `main`, and `-d` will always fail post-squash.

If this fails (branch already deleted or never existed locally), treat as non-fatal.

The remote branch is deleted by GitHub's auto-delete-on-merge setting. If that is not enabled, delete it manually — treat failure as non-fatal (branch may already be deleted, or permissions/network may prevent it):

```bash
git push origin --delete "$BRANCH_NAME" || echo "Warning: remote branch deletion failed (may already be deleted) — skipping"
```

### Step 5.4: Final report

```
## Wrap-Up Complete

- **PR #{N}** merged ({title})
- **Branch** deleted
- **Work-log** updated (if applicable)
- **Follow-ups:** {summary or "none"}
- **Lessons:** {summary or "clean session"}
- **Worktree** removed
```
