---
name: continue
description: Resume an interrupted or stalled review workflow. Detects where the agent left off — local CR review, push, PR creation, review polling, CR/Greptile feedback processing, thread resolution, merge gate verification, or acceptance criteria — and continues from the next incomplete step automatically.
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

Find the `coderabbit` CLI:
```bash
CR_BIN=$(which coderabbit 2>/dev/null || echo ~/.local/bin/coderabbit)
test -x "$CR_BIN" && echo "Found: $CR_BIN" || echo "Not found"
```

If available, run the local review loop:
```bash
$CR_BIN review --prompt-only
```

- If findings are returned: `[ACTION]` — Fix all valid findings. Run `$CR_BIN review --prompt-only` again after fixing.
- Track a **consecutive-clean counter** (starts at 0). Each clean pass increments it by 1. Any pass with findings resets it to 0.
- **Exit when consecutive-clean == 2** (two back-to-back clean passes) — `[DONE]` Local CR review passed.
- **Max 5 total iterations.** If you hit 5 runs without achieving 2 consecutive clean passes, stop and report: `[BLOCKED]` — CR review not converging after 5 iterations.
- If CR CLI is not available or errors out: `[SKIP]` — CR CLI unavailable, performing self-review of `git diff main...HEAD` instead.

---

## Step 3: Push to remote

First refresh remote refs and check if the remote branch exists:
```bash
git fetch origin "$BRANCH" --quiet 2>/dev/null || true
git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1
```

- If the remote branch **does not exist**: `[ACTION]` — Pushing new branch:
  ```bash
  git push -u origin $BRANCH
  ```
- If the remote branch **exists**, check for unpushed commits:
  ```bash
  UNPUSHED=$(git log --oneline origin/$BRANCH..$BRANCH | wc -l | tr -d ' ')
  ```
  - If `UNPUSHED > 0`: `[ACTION]` — Pushing $UNPUSHED commits.
    ```bash
    git push origin $BRANCH
    ```
  - If `UNPUSHED == 0`: `[DONE]` — Branch is up to date with remote.

---

## Step 4: Ensure PR exists

```bash
PR_JSON=$(gh pr view --json number,title,body,state 2>/dev/null)
PR_NUM=$(echo "$PR_JSON" | jq -r '.number // empty')
```

- If a PR exists and is open: `[DONE]` — PR #$PR_NUM exists.
- If no PR exists: `[ACTION]` — Create one.
  - Look for an issue number from the branch name (pattern: `issue-N-*`):
    ```bash
    ISSUE_NUM=$(echo "$BRANCH" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+')
    ```
  - If `ISSUE_NUM` is empty (branch doesn't follow `issue-N-*` pattern): create the PR without a `Closes #N` footer. Note to user: "No linked issue detected from branch name."
  - If `ISSUE_NUM` is set: read the issue body for context:
    ```bash
    gh issue view $ISSUE_NUM --json title,body 2>/dev/null
    ```
  - Create the PR with a proper body (including `Closes #N` if issue was found) and a Test plan section. After creation, capture the PR number:
    ```bash
    PR_NUM=$(gh pr view --json number --jq '.number')
    ```
- If the PR is merged/closed: `[DONE]` — PR is already merged. Nothing to continue.

---

## Step 5: Determine reviewer ownership

Check which reviewer owns this PR:

```bash
# Check session-state first
cat ~/.claude/session-state.json 2>/dev/null | jq -r ".prs.\"$PR_NUM\".reviewer // empty"

# If no session-state, check review history (paginate to catch all activity)
gh api --paginate "repos/{owner}/{repo}/pulls/{N}/comments?per_page=100" --jq '.[].user.login' | sort -u
gh api --paginate "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" --jq '.[].user.login' | sort -u
gh api --paginate "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" --jq '.[].user.login' | sort -u
```

- If `greptile-apps[bot]` has posted reviews: PR is on **Greptile** (sticky assignment).
- Otherwise: PR is on **CR**.

Output: `Reviewer: CR` or `Reviewer: Greptile`

---

## Step 6: Check for review response

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

**Rate limit detection:** If check-run shows `conclusion: "failure"` with title containing "rate limit" (case-insensitive), OR status shows `state: "failure"`/`state: "error"` with description containing "rate limit":
- `[ACTION]` — CR is rate-limited. Switching to Greptile.
- Trigger `@greptileai` on the PR if not already done.
- This PR is now on Greptile permanently (sticky assignment).
- Go to the Greptile section below.

**Review completion:** If check-run shows `status: "completed"` with `conclusion: "success"`:
- CR has finished reviewing. Check for findings (Step 7).

**Review pending:** If no completion signal and no rate-limit signal:
- `[ACTION]` — CR review is still pending. Polling every 60 seconds (7-minute timeout).
- Poll all 3 endpoints each cycle for new comments from `coderabbitai[bot]`.
- Check for rate-limit signals on every poll cycle.
- After 7 minutes with no review content and no rate-limit signal: `[BLOCKED]` — CR has not responded. Tell the user and ask whether to wait longer or trigger Greptile manually.
- **Only switch to Greptile on a clear rate-limit signal.** Do not auto-trigger Greptile on timeout alone.

### If PR is on Greptile:

Check for Greptile comments:
```bash
gh api --paginate "repos/{owner}/{repo}/pulls/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
gh api --paginate "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
gh api --paginate "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
```

- If Greptile has posted findings: `[DONE]` — Greptile review received. Process findings (Step 7).
- If no Greptile response: `[ACTION]` — Polling for Greptile (5-minute timeout).
  - If no response after 5 minutes: `[BLOCKED]` — Greptile timed out. Performing self-review as fallback. Note: self-review does NOT satisfy merge gate.

---

## Step 7: Check for unresolved findings

Fetch unresolved review threads (first 100 — sufficient for most PRs; if a PR has >100 threads, paginate using `pageInfo.endCursor`):
```bash
gh api graphql -f query='query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {N}) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 100) {
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
gh api --paginate "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" \
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
  7. After fixing, go back to **Step 6** to wait for the next review.
- If no unresolved findings: `[DONE]` — No unresolved findings.

---

## Step 8: Check merge gate

### If PR is on CR (Greptile never triggered):

Need **2 consecutive clean CR passes**. A pass is clean only when ALL of:
1. CodeRabbit check-run on current HEAD shows `status: "completed"` + `conclusion: "success"`
2. Step 7 reports zero unresolved CR findings
3. No new CR review comments appeared after the check-run completed

Track a `cr_clean_streak` counter:
- Increment by 1 after a verified clean pass
- Reset to 0 when findings are present or a new commit is pushed
- Merge gate met when `cr_clean_streak >= 2`

Check latest CR signals:
```bash
SHA=$(gh pr view $PR_NUM --json commits --jq '.commits[-1].oid')

# Check-run must be green on current HEAD
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "CodeRabbit") | {status, conclusion}'

# Verify no unresolved findings from CR (fetch all comments per thread to catch CR anywhere in thread)
gh api graphql -f query='query { repository(owner: "{owner}", name: "{repo}") { pullRequest(number: {N}) { reviewThreads(first: 100) { nodes { isResolved comments(first: 100) { nodes { author { login } } } } } } } }' \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[]
         | select(.isResolved == false)
         | select(any(.comments.nodes[]; .author.login == "coderabbitai[bot]"))] | length'
```

- If check-run is green AND zero unresolved CR findings: this is a clean pass. Increment `cr_clean_streak`.
- If `cr_clean_streak >= 2`: `[DONE]` — Merge gate satisfied (2 consecutive clean CR passes).
- If `cr_clean_streak == 1`: `[ACTION]` — One clean pass confirmed. Triggering confirmation review:
  ```bash
  gh pr comment $PR_NUM --body "@coderabbitai full review"
  ```
  Go back to **Step 6** to poll for the confirmation review.
- If check-run has findings or is not green: `[ACTION]` — Merge gate not met. Reset streak. Go back to **Step 6**.

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
    Go back to **Step 6**.
  - If 3 reviews already consumed: `[BLOCKED]` — Greptile review budget exhausted. Performing self-review. Report blocker to user.

---

## Step 9: Verify acceptance criteria

Run the acceptance criteria check (same logic as `/check-acceptance-criteria`):

1. Fetch PR body: `gh pr view $PR_NUM --json body --jq .body`
2. Parse every checkbox in the **Test plan** section
3. For each item, read the relevant source files and verify the criterion is met
4. Check off passing items by editing the PR body (replace `- [ ]` with `- [x]`)

- If all items pass: `[DONE]` — All acceptance criteria verified and checked off.
- If any item fails: `[ACTION]` — Fix the failing criteria, then re-verify.
- If no Test Plan section: `[SKIP]` — No acceptance criteria to verify.

---

## Step 10: Report completion

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
"Reviews clean, all AC verified and checked off. Want me to squash and merge (`gh pr merge --squash --delete-branch`) and delete the branch, or do you want to review the diff yourself first?"
