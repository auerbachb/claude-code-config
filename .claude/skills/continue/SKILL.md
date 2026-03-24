---
name: continue
description: Detect where the review workflow left off and resume from the next incomplete step. Handles local CR review, PR creation, review polling, feedback processing, and merge readiness.
disable-model-invocation: true
---

Detect and resume the interrupted review workflow for the current branch.

Walk through the full review lifecycle checklist in order. At each step, check if it's already been completed. Stop at the first incomplete step and execute it, then continue to the next step. Keep going until the workflow is complete or a blocking condition is hit.

**Output a status line at each step** so the user can follow along:
- `[DONE]` — step already completed, moving on
- `[ACTION]` — step incomplete, executing now
- `[BLOCKED]` — step cannot proceed, reporting why
- `[SKIP]` — step not applicable

---

## Step 0: Identify context

```bash
BRANCH=$(git branch --show-current)
echo "Branch: $BRANCH"
```

If on `main`, stop: "Not on a feature branch. Nothing to continue."

Check if a PR exists:
```bash
gh pr view --json number,title,headRefName,state 2>/dev/null
```

Determine the {owner}/{repo} from git remote:
```bash
gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"'
```

---

## Step 1: Check for uncommitted changes

```bash
git status --porcelain
```

- If there are uncommitted changes: `[ACTION]` — Stage and commit changes. Ask the user for a commit message if the changes are ambiguous, otherwise use a descriptive message based on the diff.
- If clean: `[DONE]` — No uncommitted changes.

---

## Step 2: Run local CR review

Check if `coderabbit` CLI is available:
```bash
which coderabbit 2>/dev/null || which ~/.local/bin/coderabbit 2>/dev/null
```

If available, run the local review loop:
```bash
~/.local/bin/coderabbit review --prompt-only
```

- If findings are returned: `[ACTION]` — Fix all valid findings. Run `coderabbit review --prompt-only` again after fixing. Repeat until clean (max 5 iterations to avoid infinite loops).
- If clean (no findings): `[DONE]` — Local CR review passed.
- If CR CLI is not available or errors out: `[SKIP]` — CR CLI unavailable, performing self-review of `git diff main...HEAD` instead.
- **Two consecutive clean passes required** before marking as done.

---

## Step 3: Push to remote

```bash
git log --oneline origin/$BRANCH..$BRANCH 2>/dev/null | wc -l
```

- If there are unpushed commits: `[ACTION]` — Pushing.
  ```bash
  git push origin $BRANCH
  ```
- If already up to date: `[DONE]` — Branch is pushed.
- If the remote branch doesn't exist yet: `[ACTION]` — Pushing with `-u`:
  ```bash
  git push -u origin $BRANCH
  ```

---

## Step 4: Ensure PR exists

```bash
PR_JSON=$(gh pr view --json number,title,body,state 2>/dev/null)
```

- If a PR exists and is open: `[DONE]` — PR #{number} exists.
- If no PR exists: `[ACTION]` — Create one.
  - Look for an issue number from the branch name (pattern: `issue-N-*`):
    ```bash
    ISSUE_NUM=$(echo "$BRANCH" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+')
    ```
  - Read the issue body for context:
    ```bash
    gh issue view $ISSUE_NUM --json title,body 2>/dev/null
    ```
  - Create the PR with a proper body including `Closes #N` and a Test plan section.
- If the PR is merged/closed: `[DONE]` — PR is already merged. Nothing to continue.

---

## Step 5: Trigger Greptile alongside CR

After pushing (Step 3) or creating a PR (Step 4), check if Greptile has already been triggered:

```bash
gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" \
  --jq '[.[] | select(.body | test("@greptileai"))] | length'
```

- If `@greptileai` has NOT been triggered yet on the current HEAD SHA: `[ACTION]` — Trigger Greptile:
  ```bash
  gh pr comment $PR_NUM --body "@greptileai"
  ```
- If already triggered: `[DONE]` — Greptile already triggered.

---

## Step 6: Determine reviewer ownership

Check which reviewer owns this PR:

```bash
# Check session-state first
cat ~/.claude/session-state.json 2>/dev/null | jq -r ".prs.\"$PR_NUM\".reviewer // empty"

# If no session-state, check review history
gh api "repos/{owner}/{repo}/pulls/{N}/comments?per_page=100" --jq '[.[] | .user.login] | unique'
gh api "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" --jq '[.[] | .user.login] | unique'
gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" --jq '[.[] | .user.login] | unique'
```

- If `greptile-apps[bot]` has posted reviews: PR is on **Greptile** (sticky assignment).
- Otherwise: PR is on **CR**.

Output: `Reviewer: CR` or `Reviewer: Greptile`

---

## Step 7: Check for review response

### If PR is on CR:

Check the commit status for CodeRabbit:
```bash
SHA=$(gh pr view $PR_NUM --json commits --jq '.commits[-1].oid')
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "CodeRabbit") | {status: .status, conclusion: .conclusion, title: .output.title}'
```

Also check the statuses endpoint as fallback:
```bash
gh api "repos/{owner}/{repo}/commits/$SHA/statuses" \
  --jq '.[] | select(.context | test("CodeRabbit"; "i")) | {state: .state, description: .description}'
```

**Rate limit fast-path:** If check-run shows `conclusion: "failure"` with title containing "rate limit" (case-insensitive), OR status shows `state: "failure"`/`state: "error"` with description containing "rate limit":
- `[ACTION]` — CR is rate-limited. Switching to Greptile.
- Trigger `@greptileai` on the PR if not already done.
- This PR is now on Greptile permanently (sticky assignment).
- Go to the Greptile section below.

**Review completion:** If check-run shows `status: "completed"` with `conclusion: "success"`:
- CR has finished reviewing. Check for findings (Step 8).

**Review pending:** If no completion signal:
- `[ACTION]` — CR review is still pending. Polling every 60 seconds (7-minute timeout, then Greptile fallback).
- Poll all 3 endpoints each cycle for new comments from `coderabbitai[bot]`.
- After 7 minutes with no review content: trigger Greptile (sticky assignment).

### If PR is on Greptile:

Check for Greptile comments:
```bash
gh api "repos/{owner}/{repo}/pulls/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
gh api "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
```

- If Greptile has posted findings: `[DONE]` — Greptile review received. Process findings (Step 8).
- If no Greptile response: `[ACTION]` — Polling for Greptile (5-minute timeout).
  - If no response after 5 minutes: `[BLOCKED]` — Greptile timed out. Performing self-review as fallback. Note: self-review does NOT satisfy merge gate.

---

## Step 8: Check for unresolved findings

Fetch unresolved review threads:
```bash
gh api graphql -f query='query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {N}) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 5) {
            nodes {
              body
              author { login }
              createdAt
            }
          }
        }
      }
    }
  }
}'
```

Count unresolved threads from reviewers:
- Filter for threads where any comment is from `coderabbitai[bot]` or `greptile-apps[bot]`
- Only count threads where `isResolved == false`

Also check for issue-level review comments that may not have threads:
```bash
gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "coderabbitai[bot]" or .user.login == "greptile-apps[bot]") | select(.body | test("suggestion|finding|issue|bug|error|warning"; "i"))]'
```

- If there are unresolved findings: `[ACTION]` — Processing N unresolved findings.
  1. Read each finding carefully
  2. Verify against actual code before fixing
  3. Fix ALL valid findings in a single commit
  4. Push once
  5. Reply to every thread confirming the fix:
     ```bash
     gh api "repos/{owner}/{repo}/pulls/comments/{id}/replies" -f body="Fixed in \`$SHA\`: <what changed>"
     ```
  6. Resolve each thread via GraphQL:
     ```bash
     gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "{thread_id}"}) { thread { isResolved } } }'
     ```
  7. After fixing, go back to **Step 7** to wait for the next review.
- If no unresolved findings: `[DONE]` — No unresolved findings.

---

## Step 9: Check merge gate

### If PR is on CR (Greptile never triggered):

Need **2 clean CR reviews**. Check:
```bash
gh api "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "coderabbitai[bot]") | {state: .state, submitted_at: .submitted_at}] | sort_by(.submitted_at) | reverse | .[0:2]'
```

Also verify the CodeRabbit check-run is green on the current HEAD:
```bash
SHA=$(gh pr view $PR_NUM --json commits --jq '.commits[-1].oid')
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "CodeRabbit") | {status, conclusion}'
```

- If 2 clean CR reviews exist on recent SHAs with no findings: `[DONE]` — Merge gate satisfied (2 clean CR reviews).
- If 1 clean review: `[ACTION]` — Triggering confirmation pass:
  ```bash
  gh pr comment $PR_NUM --body "@coderabbitai full review"
  ```
  Go back to **Step 7** to poll for the confirmation review.
- If 0 clean reviews or latest review had findings: `[ACTION]` — Merge gate not met. Go back to **Step 7**.

### If PR is on Greptile:

Severity-gated merge gate:
- **No findings at all** on last Greptile review: `[DONE]` — Merge gate satisfied (clean Greptile pass).
- **Only P1/P2 findings** (no P0) on last review, all fixed: `[DONE]` — Merge gate satisfied (P1/P2 fixed, no re-review needed).
- **P0 findings were present**: Need re-review to confirm P0 resolution.
  - Check if re-review has been done (max 3 Greptile reviews per PR).
  - If re-review needed and budget allows: `[ACTION]` — Triggering Greptile re-review:
    ```bash
    gh pr comment $PR_NUM --body "@greptileai"
    ```
    Go back to **Step 7**.
  - If 3 reviews already consumed: `[BLOCKED]` — Greptile review budget exhausted. Performing self-review. Report blocker to user.

---

## Step 10: Verify acceptance criteria

Run the acceptance criteria check (same logic as `/check-acceptance-criteria`):

1. Fetch PR body: `gh pr view $PR_NUM --json body --jq .body`
2. Parse every checkbox in the **Test plan** section
3. For each item, read the relevant source files and verify the criterion is met
4. Check off passing items by editing the PR body (replace `- [ ]` with `- [x]`)

- If all items pass: `[DONE]` — All acceptance criteria verified and checked off.
- If any item fails: `[ACTION]` — Fix the failing criteria, then re-verify.
- If no Test Plan section: `[SKIP]` — No acceptance criteria to verify.

---

## Step 11: Report completion

Output a summary:

```
=== /continue complete ===

Branch: $BRANCH
PR: #$PR_NUM
Reviewer: CR / Greptile
Merge gate: MET / NOT MET
Acceptance criteria: ALL PASSED / N FAILED
Status: Ready to merge — want me to squash and merge?
```

If the merge gate is met and all AC pass, ask:
"Reviews clean, all AC verified and checked off. Want me to squash and merge and delete the branch, or do you want to review the diff yourself first?"
