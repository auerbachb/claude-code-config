---
name: merge
description: Squash merge the current PR, delete the branch, log to work-log, and clean up. Verifies merge gate and acceptance criteria before merging.
disable-model-invocation: true
---

Squash merge the current PR. This is the "we're done here" command.

## Steps

### Step 1: Identify the PR

```bash
gh pr view --json number,title,headRefName,body,state --jq '{number, title, headRefName, body, state}'
```

If no PR exists on the current branch, stop and tell the user: "No PR found for the current branch. Push and create a PR first."

If the PR is already merged or closed, stop and tell the user.

### Step 2: Verify the merge gate

Determine which reviewer owns this PR:

1. **Check session-state** — read `~/.claude/session-state.json` and check the `reviewer` field for this PR number. If it says `"g"`, this PR is on Greptile.
2. **If no session-state entry**, check the PR's review history to determine ownership:
   ```bash
   gh api "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" --jq '.[].user.login'
   gh api "repos/{owner}/{repo}/pulls/{N}/comments?per_page=100" --jq '.[].user.login'
   gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" --jq '.[].user.login'
   ```
   - If `greptile-apps[bot]` has posted reviews/comments, this PR is on Greptile.
   - Otherwise, it's on CR.

**Merge gate check:**

- **CR-only PR:** Need 2 clean CR reviews. Check the last 2 review objects from `coderabbitai[bot]` — both must have no actionable findings. Also verify the CodeRabbit check-run shows `conclusion: "success"`.
- **Greptile PR:** Need 1 clean Greptile review. Check the last review from `greptile-apps[bot]` has no actionable findings.

If the merge gate is NOT met, stop and tell the user exactly what's missing (e.g., "PR needs 1 more clean CR review" or "Greptile has unresolved findings").

### Step 3: Verify acceptance criteria

Before merging, run the acceptance criteria check inline:

1. Fetch the PR body via `gh pr view N --json body`
2. Parse every checkbox in the **Test plan** section
3. For each item, read the relevant source files and verify the criterion is met
4. Check off passing items by editing the PR body (replace `- [ ]` with `- [x]`)
5. If ANY item fails, stop and tell the user which items failed and why. Do NOT merge with unchecked boxes.

### Step 4: Squash merge

```bash
gh pr merge --squash --delete-branch
```

### Step 5: Log to work-log

If a work-log directory exists (detected at session start per work-log.md rules):

1. Determine the cycle count by reconstructing from PR history:
   - Fetch all reviews on `pulls/{N}/reviews` and all commits on `pulls/{N}/commits`
   - Count each review with actionable findings followed by a fix commit = 1 cycle
2. Append a merge entry to today's session log:
   ```
   - {time} ET — PR #{N} merged (Issue #{M}): {1-line summary} [opened: {open_time}, merged: {merge_time}, cycles: {count}]
   ```
3. Get the linked issue number from the PR body (`Closes #N` pattern)

### Step 6: Report completion

Tell the user:
- PR number and title
- Merge SHA
- Branch deleted
- Work-log updated (if applicable)
