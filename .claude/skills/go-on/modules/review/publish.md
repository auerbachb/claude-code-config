<!-- go-on-routing:begin -->
Route `review:publish`.

**Trigger:** the lane reaches Step 2.

**Prerequisites:** the `token-exhaustion` or `unplanned` kind module routed the lane here, and the lane preflight resolved every review module. `review:prepare` ran: its helpers are resolved and Steps 0b, 1 and 1b are done.

**Next:** `review:respond` after Step 4.
<!-- go-on-routing:end -->

## Step 2: Run local CR review

Find the `coderabbit` CLI:
```bash
CR_BIN=$(which coderabbit 2>/dev/null || echo ~/.local/bin/coderabbit)
test -x "$CR_BIN" && echo "Found: $CR_BIN" || echo "Not found"
```

If available, run the local review loop:
```bash
$CR_BIN review --agent
```

- If findings are returned: `[ACTION]` — Fix all valid findings. Run `$CR_BIN review --agent` again after fixing.
- **Exit on 1 clean pass** (no findings returned) — `[DONE]` Local CR review passed.
- **Max 5 total iterations.** If you hit 5 runs without a clean pass, stop and report: `[BLOCKED]` — CR review not converging after 5 iterations.
- If CR CLI is not available or errors out: `[SKIP]` — CR CLI unavailable, performing self-review instead:
  ```bash
  BASE=$(gh pr view --json baseRefName --jq '.baseRefName' 2>/dev/null || echo main)
  git diff "$BASE"...HEAD
  ```
- **After the local review loop completes**, classify and print coverage: `[COVERAGE] <level> — <reason>` (per `cr-local-review.md` "Coverage classification": `both | cr-only | codeant-only | none`). This flow reaches at most `cr-only` or `none`. For `none`, the line is mandatory before any push.

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
PR_NUM=$(printf '%s' "$PR_JSON" | jq -r '.number // empty')
```

Pipe with `printf '%s'`, never `echo` — zsh's builtin `echo` interprets the escape sequences in the PR body and corrupts the JSON, so `jq` errors and `PR_NUM` comes back empty, which reads as "no PR exists" (issue #574).

- If a PR exists and is open: `[DONE]` — PR #$PR_NUM exists. Additionally, always update the `**Local review coverage:**` line in the PR body: if coverage is `both`, remove any existing label (clearing stale degraded markers from prior runs); if coverage is degraded, replace the line if present or append it if missing. Fetch the PR body, apply the change, then `gh pr edit "$PR_NUM" --body "$UPDATED_BODY"`. In the same edit, derive the issue number from the branch name (`ISSUE_NUM=$(echo "$BRANCH" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+')`; it is not set yet on this path), and when it is non-empty and this thread recovered its claim holder from its receipt, replace any existing `<!-- claim-holder: ... -->` line in the body with the output of `pr-claim-line.sh "$ISSUE_NUM" --holder "<recovered holder>"` (resolved as in the creation step below), or append it when missing, so a resumed PR never keeps a missing or stale claim-holder line.
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
  - Create the PR with `gh pr create` and a proper body (including `Closes #N` if issue was found) and a Test plan section. When `ISSUE_NUM` is set and this thread recovered its claim holder from its receipt, also put the output of `pr-claim-line.sh "$ISSUE_NUM" --holder "<recovered holder>"` (resolve it to the first executable of `$HOME/.claude/skills-worktree/.claude/scripts/pr-claim-line.sh`, `$HOME/.claude/scripts/pr-claim-line.sh`, `.claude/scripts/pr-claim-line.sh` (skip the installed candidates when `HOME` is unset or empty)) on its own line of the body, also when the PR is opened through the REST API (`gh api repos/{owner}/{repo}/pulls`); with no issue or no recovered holder, omit the line. Include a `**Local review coverage:** <level>` labeled line when coverage is anything other than `both` (mandatory for `none` and single-CLI cases). After creation, capture the PR number:
    ```bash
    PR_NUM=$(gh pr view --json number --jq '.number')
    ```
- If the PR is merged: `[DONE]` — PR is already merged. Nothing to continue.
- If the PR is closed but not merged: `[BLOCKED]` — PR was closed without merging. It may need to be reopened or a new PR created.
