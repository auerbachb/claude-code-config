---
name: continue
description: Resume an interrupted or stalled review workflow. Detects where the agent left off — local CR review, push, PR creation, review polling, CR/Greptile feedback processing, thread resolution, merge gate verification, or acceptance criteria — and continues from the next incomplete step automatically.
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
- If CR CLI is not available or errors out: `[SKIP]` — CR CLI unavailable, performing self-review instead:
  ```bash
  BASE=$(gh pr view --json baseRefName --jq '.baseRefName' 2>/dev/null || echo main)
  git diff "$BASE"...HEAD
  ```

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
- If the PR is merged: `[DONE]` — PR is already merged. Nothing to continue.
- If the PR is closed but not merged: `[BLOCKED]` — PR was closed without merging. It may need to be reopened or a new PR created.

---

## Step 5: Determine reviewer ownership

Resolve reviewer ownership via the shared helper (reads `.prs["<N>"].reviewer` from `~/.claude/session-state.json` first, falls back to a paginated live-history scan on all three comment endpoints):

```bash
REVIEWER=$(.claude/scripts/reviewer-of.sh "$PR_NUM")
REVIEWER_EXIT=$?
```

Branch on exit code:
- `0` → `$REVIEWER` is one of `cr` / `bugbot` / `greptile`. Use it for Step 6.
- `1` → `unknown` printed; no bot has reviewed yet. Treat as **CR** (the default primary reviewer) and proceed to Step 6 to wait for the first review.
- `2` → `[BLOCKED]` — script/gh error; surface stderr.
- `3` → `[BLOCKED]` — PR #$PR_NUM not found (closed, merged, or invalid).
- `5` → `[BLOCKED]` — `~/.claude/session-state.json` is malformed, wrong shape, or the helper hit a runtime failure (e.g. a racing read between the validation guard and the jq lookup). Surface the helper's stderr, stop polling, and repair or remove the state file before retrying `/continue`. Do **not** fall through to a live-history scan — sticky reviewer assignments live in session-state, and bypassing them risks mis-routing an already-escalated PR back to CR.

Output: `Reviewer: CR` / `Reviewer: BugBot` / `Reviewer: Greptile`.

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
- `[ACTION]` — CR is rate-limited. Check BugBot (second-tier reviewer) before falling through to Greptile — BugBot auto-triggers on every push, so it may already have responded while CR was blocked:
  ```bash
  gh api "repos/{owner}/{repo}/pulls/$PR_NUM/reviews?per_page=100" \
    --jq '[.[] | select(.user.login == "cursor[bot]" and .commit_id == "'"$SHA"'")]'
  ```
  - BugBot has posted on `$SHA` → PR is now on **BugBot** (sticky). Persist and go to the BugBot section:
    ```bash
    .claude/scripts/reviewer-of.sh "$PR_NUM" --sticky bugbot
    ```
  - BugBot has NOT posted AND <5 min since push → `[ACTION]` — Waiting up to 5 min for BugBot's auto-review. Poll every 60 s.
  - BugBot has NOT posted AND ≥5 min since push → BugBot timed out. Fall through to Greptile:
    ```bash
    gh pr comment "$PR_NUM" --body "@greptileai"
    .claude/scripts/reviewer-of.sh "$PR_NUM" --sticky greptile
    ```
    Go to the Greptile section below.

**Review completion:** If check-run shows `status: "completed"` with `conclusion: "success"`:
- CR has finished reviewing. Check for findings (Step 7).

**Review pending:** If no completion signal and no rate-limit signal:
- `[ACTION]` — CR review is still pending. Polling every 60 seconds (7-minute timeout).
- Poll all 3 endpoints each cycle for new comments from `coderabbitai[bot]`.
- Check for rate-limit signals on every poll cycle.
- After 7 minutes with no review content and no rate-limit signal: `[ACTION]` — CR timed out. Check BugBot (same query as rate-limit path above). If BugBot has posted a review, persist `--sticky bugbot` and go to the BugBot section. If BugBot has also timed out (≥5 min since push), fall through to Greptile.

### If PR is on BugBot:

BugBot (`cursor[bot]`) is the second-tier free reviewer. Auto-triggers on every push; merge gate requires **1 clean BugBot review** on the current HEAD SHA (no confirmation pass — BugBot's completion signals are reliable).

Check for BugBot reviews on the current HEAD:
```bash
gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUM/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]" and .commit_id == "'"$SHA"'")]'
gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUM/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]")]'
gh api --paginate "repos/{owner}/{repo}/issues/$PR_NUM/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]")]'
```

Also check the BugBot check-run for the completion signal:
```bash
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "Cursor Bugbot") | {status, conclusion}'
```

- BugBot has posted findings on `$SHA` → `[DONE]` — BugBot review received. Process findings (Step 7). After fixes are pushed, BugBot auto-reviews the new push; return to this section on the new SHA.
- BugBot has posted a clean review (check-run `completed` with no finding comments) on `$SHA` → `[DONE]` — merge gate met (1 clean pass is sufficient for the BugBot path). Proceed to merge verification.
- No BugBot response AND <5 min since push → `[ACTION]` — Polling for BugBot (5-min timeout from push). Poll every 60 s.
- No BugBot response AND ≥5 min since push → BugBot timed out. Trigger manual re-review once; if still silent after another 5 min, fall through to Greptile:
  ```bash
  gh pr comment "$PR_NUM" --body "@cursor review"
  ```
- Stay on BugBot — do not switch back to CR. Ignore late CR reviews. Only escalate to Greptile if BugBot also fails.

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
- Filter for threads where any comment is from `coderabbitai[bot]`, `greptile-apps[bot]`, or `cursor[bot]`
- Only count threads where `isResolved == false`

Also check for issue-level review comments that may not have threads. Use the shared `pr-state.sh` helper — it fetches all three endpoints in one call, filters to `coderabbitai[bot]` / `greptile-apps[bot]` / `cursor[bot]` (BugBot), and pre-classifies each comment with `classification.class` (`finding` vs `acknowledgment`). The classifier only runs when `--since <iso>` is passed — pass the PR's `createdAt` to include every bot comment on the PR. The helper writes the JSON bundle to a tempfile and prints its **path** on stdout — capture the path, then read with `jq < "$BUNDLE"`:

```bash
PR_CREATED=$(gh pr view "$PR_NUM" --json createdAt --jq '.createdAt')
BUNDLE=$(.claude/scripts/pr-state.sh --pr "$PR_NUM" --since "$PR_CREATED")
jq '.new_since_baseline.conversation | map(select(.classification.class == "finding"))' < "$BUNDLE"
```

- If there are unresolved findings: `[ACTION]` — Processing N unresolved findings.
  1. Read each finding carefully
  2. Verify against actual code before fixing
  3. Fix ALL valid findings in a single commit
  4. Push once
  5. Reply to every thread confirming the fix. Use the shared helper — it tries the inline `/replies` endpoint first, falls back to a PR-level comment on 404, and applies reviewer-specific `@mention` rules (prepends `@coderabbitai` for CR; strips `@cursor`/`@greptileai` for BugBot/Greptile):

     ```bash
     # $REVIEWER: cr | bugbot | greptile (determined from the finding's author)
     .claude/scripts/reply-thread.sh <comment_id> --reviewer "$REVIEWER" \
       --body "Fixed in \`$SHA\`: <what changed>" --pr N
     ```

     Exit codes: `0` inline reply posted; `1` fallback PR-level reply posted (still success). Both outcomes are successful replies. See `.claude/scripts/reply-thread.sh --help` for the full contract, including 404-without-`--pr` or both-endpoints-404 (exit 3) and inline-404-then-fallback-non-404 (exit 4).

  6. Resolve all bot threads with the shared helper (paginated, filtered to `coderabbitai`/`cursor`/`greptile-apps`, falls back to `minimizeComment` on failure):

     ```bash
     bash .claude/scripts/resolve-review-threads.sh $PR_NUM
     ```

     Exit 1 means at least one thread failed both mutations — surface to the user and stop. Do not proceed with a non-zero exit.

  7. After fixing, go back to **Step 6** to wait for the next review.
- If no unresolved findings: `[DONE]` — No unresolved findings.

---

## Step 8: Check merge gate

Run the shared merge-gate verifier (implements CR 2-clean / BugBot 1-clean / Greptile severity + CI + BEHIND checks):

```bash
GATE_JSON=$(.claude/scripts/merge-gate.sh "$PR_NUM")
GATE_EXIT=$?
```

Branch on the exit code:

- `0` → `[DONE]` — Merge gate satisfied. Proceed to Step 9 (AC verification).
- `1` → `[ACTION]` — Gate not met. Parse `missing` from the JSON output and act accordingly:
  - CR path with **"need 2 clean CR reviews on HEAD (have 1)"**: post `@coderabbitai full review` to trigger the confirmation pass, then return to **Step 6**.
  - CR path with **"CodeRabbit check-run not green on HEAD"** or **"latest CR review on HEAD requests changes"**: CR has findings; return to **Step 7** to process them.
  - BugBot path with **"no BugBot review on HEAD"**: BugBot hasn't reviewed the current HEAD yet; return to **Step 6** to poll for the review.
  - BugBot path with **"latest BugBot review on HEAD has findings"**: return to **Step 7** to process findings.
  - Greptile path with **"unresolved Greptile thread(s)"**: return to **Step 7** to process; if P0 remains after fix, re-trigger `@greptileai` (subject to the 3-review cap per `.claude/rules/greptile.md`).
  - **"branch is BEHIND base"**: `[ACTION]` — rebase onto base, force-push, wait for a fresh review, then re-run the gate.
  - **"CI has N failing check-run(s)"** or **"CI has N incomplete check-run(s)"**: fix CI or wait for incomplete runs, then re-run the gate.
- `3` → `[BLOCKED]` — PR not found (closed or merged).
- `2`/`4` → `[BLOCKED]` — script or gh error; surface the message to the user.

---

## Step 9: Verify acceptance criteria

Run the acceptance criteria check via the shared helper:

```bash
ITEMS=$(.claude/scripts/ac-checkboxes.sh "$PR_NUM" --extract)
AC_EXIT=$?
```

Branch on exit code:
- `0` → `$ITEMS` is a JSON array of `{index, checked, text}`. For each item with `checked == false`, read the relevant source files and verify the criterion. Tick passing items by index: `.claude/scripts/ac-checkboxes.sh "$PR_NUM" --tick "0,2,3"` (or `--all-pass` if every unchecked item passed).
- `1` → `[BLOCKED]` — PR body is missing a Test Plan section. Every PR must include one (per CLAUDE.md). The PR is NOT merge-ready until the body is fixed — report this to the user and do not continue to the merge decision.
- `3` → `[BLOCKED]` — PR not found.
- `2`/`4` → `[BLOCKED]` — script or gh error; surface stderr to user.

- If all items pass after ticking: `[DONE]` — All acceptance criteria verified and checked off.
- If any item fails: `[ACTION]` — Fix the failing criteria, then re-verify.

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
