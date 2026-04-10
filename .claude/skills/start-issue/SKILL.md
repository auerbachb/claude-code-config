---
name: start-issue
description: End-to-end issue-to-coding workflow. Accepts an issue number or description, handles CR plan polling, merges plans into issue body, creates worktree and branch, outputs ready-to-code summary. Use to start work on an issue without manually walking through the issue-planning flow.
triggers:
  - start issue
  - start work
  - kick off issue
  - begin coding
argument-hint: "<issue-number | 'description of new issue'>"
---

Automate the full issue-to-coding flow: create issue (if needed) → wait for CR plan → merge plans → create worktree + branch → output ready-to-code summary. Replaces 5-10 minutes of manual setup per issue.

## Step 1: Parse arguments

Parse `$ARGUMENTS`:

- **Numeric** (`42` or `#42`): treat as an existing issue number. Strip any leading `#`. Set `ISSUE_NUMBER=$ARGUMENTS` and skip to Step 2.
- **Non-empty string** (e.g. `"Add dark mode toggle"`): this is a new issue to create. Go to Step 1a.
- **Empty**: stop and ask the user: "What issue should I start? Provide an issue number (e.g. `/start-issue 42`) or a description (e.g. `/start-issue \"Add dark mode toggle\"`)."

### Step 1a: Draft and create new issue

Only when a description was provided.

1. **Draft locally** (do NOT post yet):
   - Title: concise version of the description (≤70 chars)
   - Body: one paragraph of context plus an `## Acceptance Criteria` section with placeholder checkbox items derived from the description
2. **Create the issue:**
   ```bash
   ISSUE_URL=$(gh issue create --title "<title>" --body "<body>")
   ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
   ```
3. The repo's `cr-plan-on-issue.yml` workflow will auto-post `@coderabbitai plan` within ~30s. Record `ISSUE_CREATED_AT=$(date -u +%s)` so Step 3 knows to use the "< 10 min" polling path.

## Step 2: Read the issue

```bash
gh issue view "$ISSUE_NUMBER" --json number,title,body,state,createdAt --comments
```

- If `state != "OPEN"`: stop and report "Issue #$ISSUE_NUMBER is $state — cannot start work on a closed issue."
- Capture `TITLE`, `BODY`, and `createdAt` for downstream steps.
- Compute issue age in seconds from `createdAt`. Use a portable approach (Python or `gdate` on macOS if available; otherwise derive from the recorded `ISSUE_CREATED_AT` when the issue was just created by this skill).

## Step 3: Handle CR implementation plan

CR's plan is identified by a comment from `coderabbitai` (no `[bot]` suffix — issue comments use the bare name).

### Path A: Fresh issue (age < 10 minutes)

CR may still be generating the plan. Poll every 60s until the issue is 10 minutes old (from `createdAt`):

```bash
while true; do
  PLAN=$(gh issue view "$ISSUE_NUMBER" --json comments \
    --jq '[.comments[] | select(.author.login == "coderabbitai") | .body] | first // empty')
  if [ -n "$PLAN" ]; then break; fi
  # Stop polling once issue age exceeds 10 minutes
  AGE_NOW=$(python3 -c "import datetime,sys; print(int((datetime.datetime.utcnow() - datetime.datetime.strptime('$CREATED_AT','%Y-%m-%dT%H:%M:%SZ')).total_seconds()))")
  if [ "$AGE_NOW" -ge 600 ]; then break; fi
  sleep 60
done
```

- If a plan arrives, capture it and proceed to Step 4.
- If timeout is reached with no plan, proceed to Step 4 without it.

### Path B: Older issue (age >= 10 minutes)

Check for an existing CR plan comment:

```bash
PLAN=$(gh issue view "$ISSUE_NUMBER" --json comments \
  --jq '[.comments[] | select(.author.login == "coderabbitai") | .body] | first // empty')
```

- **If plan exists:** capture and proceed to Step 4.
- **If no plan:** post `@coderabbitai plan` and poll every 60s for up to 5 minutes:
  ```bash
  gh issue comment "$ISSUE_NUMBER" --body "@coderabbitai plan"
  for i in $(seq 1 5); do
    sleep 60
    PLAN=$(gh issue view "$ISSUE_NUMBER" --json comments \
      --jq '[.comments[] | select(.author.login == "coderabbitai") | .body] | first // empty')
    if [ -n "$PLAN" ]; then break; fi
  done
  ```
- If still no plan after 5 minutes, proceed to Step 4 without it. Note it in the final summary.

> **Note:** Use `coderabbitai` (no `[bot]` suffix) for issue comments. PR reviews use `coderabbitai[bot]`.

## Step 4: Build Claude's implementation plan

- Read the issue body (and CR plan, if available).
- Explore the codebase enough to understand scope — list files that will be touched, identify existing patterns to follow, note edge cases.
- Draft a plan internally with:
  - **Files to create / modify** (with absolute paths)
  - **Implementation steps** (numbered, concrete)
  - **Risks / edge cases**
  - **Verification** (how to confirm each AC item)

Do NOT post this plan yet — it gets merged in Step 5.

## Step 5: Merge plans into the issue body

This creates **one canonical planning document** the coding agent can work from.

1. **Compare plans** (if CR posted one): incorporate anything CR identified that Claude missed (additional files, edge cases, architectural considerations). Goal is the most robust plan.
2. **Fetch current body and append:**
   ```bash
   current_body=$(gh issue view "$ISSUE_NUMBER" --json body --jq .body)
   gh issue edit "$ISSUE_NUMBER" --body "${current_body}

   ## Implementation Plan

   <merged plan — files, steps, risks, verification>"
   ```
   `gh issue edit --body` replaces the entire body, so the fetch-concatenate-write pattern is required to preserve the original description.
3. **Post a confirmation comment:**
   ```bash
   if [ -n "$PLAN" ]; then
     gh issue comment "$ISSUE_NUMBER" --body "Implementation plan merged into issue body (Claude's analysis + CodeRabbit's recommendations). Ready for work."
   else
     gh issue comment "$ISSUE_NUMBER" --body "Implementation plan added to issue body (Claude's analysis only — CodeRabbit plan was not available). Ready for work."
   fi
   ```

## Step 6: Create worktree and branch

1. **Derive a short slug** from the issue title: lowercase, strip punctuation, replace spaces with hyphens, keep the first 3-5 meaningful words. Example: `"Add dark mode toggle"` → `add-dark-mode-toggle`.
2. **Branch name:** `issue-$ISSUE_NUMBER-$SLUG`
3. **Check for existing worktree first:**
   ```bash
   if git worktree list | grep -q "issue-$ISSUE_NUMBER-"; then
     echo "A worktree already exists for issue #$ISSUE_NUMBER:"
     git worktree list | grep "issue-$ISSUE_NUMBER-"
     exit 0
   fi
   ```
4. **Pull main and create worktree:**
   ```bash
   ROOT_REPO=$(git worktree list | head -1 | awk '{print $1}')
   git -C "$ROOT_REPO" pull origin main --ff-only
   WORKTREE_PATH="$ROOT_REPO/.claude/worktrees/issue-$ISSUE_NUMBER-$SLUG"
   git -C "$ROOT_REPO" worktree add "$WORKTREE_PATH" -b "issue-$ISSUE_NUMBER-$SLUG"
   cd "$WORKTREE_PATH"
   ```
   If `pull` fails (diverged history), stop and report to the user — do not force-pull.
5. **Verify:** confirm the worktree directory exists and the branch is checked out before proceeding.

## Step 7: Output ready-to-code summary

Print a compact summary to the user:

```
## Ready to code — Issue #{N}

**Title:** {TITLE}
**Branch:** issue-{N}-{slug}
**Worktree:** {WORKTREE_PATH}
**CR plan:** {included | not available}

### Implementation Plan
{top-level bullets from the merged plan — files, key steps, risks}

### Acceptance Criteria
{unchecked checkbox items from the issue body}

---
Ready to code. Start with step 1 of the plan above. Run local CR review (`coderabbit review --prompt-only`) before pushing.
```

Stop after printing the summary. Do NOT start coding automatically — the user may want to review the plan first.

## Edge cases

- **Issue already has a branch / worktree:** if `git worktree list` shows an existing worktree for `issue-$ISSUE_NUMBER-*`, stop and report the path instead of creating a duplicate (see Step 6).
- **Issue is closed:** stop in Step 2.
- **CR plan is an "Actions performed" ack only** (no actual plan content): treat as "no plan" and proceed.
- **New issue description matches an existing open issue** (e.g. duplicate title): the skill will still create a new issue. It does not dedupe — that is the user's responsibility.
- **Empty argument:** stop and ask the user for input.
- **`gh` not authenticated or repo lookup fails:** stop and report the underlying `gh` error to the user.

## Usage examples

- `/start-issue 42` — start on existing issue #42: read issue, get CR plan, merge plans, create worktree, ready to code.
- `/start-issue "Add dark mode toggle"` — draft and create a new issue, wait for CR plan, merge plans, create worktree, ready to code.
- `/start-issue` — prompts for input when no argument is supplied.
