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
- Capture `TITLE`, `BODY`, and `CREATED_AT` (from the `createdAt` JSON field) for downstream steps.
- Compute issue age in seconds from `CREATED_AT`. Use a portable approach (Python or `gdate` on macOS if available; otherwise derive from the recorded `ISSUE_CREATED_AT` when the issue was just created by this skill).

## Step 3: Handle CR implementation plan

CR's plan is identified by a comment from `coderabbitai` (no `[bot]` suffix — issue comments use the bare name). Use `.claude/scripts/cr-plan.sh` for detection — it encapsulates the canonical jq filter (skip "actions performed" ack lines, require length > 200) and the 60s polling loop.

Exit codes: `0` plan found (printed to stdout), `1` no plan, `3` issue not found/closed, `4` gh error. Run `.claude/scripts/cr-plan.sh --help` for full usage.

### Path A: Fresh issue (age < 10 minutes)

CR may still be generating the plan. Poll for up to 10 minutes, stopping early once the issue ages past 10 minutes from `createdAt`:

```bash
if PLAN=$(.claude/scripts/cr-plan.sh "$ISSUE_NUMBER" --poll 10 --max-age-minutes 10); then
  : # plan captured
else
  case $? in
    1) PLAN="" ;;  # timeout — no plan
    *) PLAN=""; echo "cr-plan.sh failed" >&2 ;;
  esac
fi
```

- If a plan arrives, capture it and proceed to Step 4.
- If timeout is reached with no plan, proceed to Step 4 without it.

### Path B: Older issue (age >= 10 minutes)

Do a single check for an existing CR plan comment:

```bash
PLAN=$(.claude/scripts/cr-plan.sh "$ISSUE_NUMBER" || true)
```

- **If plan exists:** capture and proceed to Step 4.
- **If no plan:** the auto-trigger workflow (`.github/workflows/cr-plan-on-issue.yml`) should have already posted `@coderabbitai plan` when the issue was opened. Do NOT manually trigger it unless you have confirmed the workflow failed **for this specific issue**. Filter runs to the `issues` event and match by displayed title so a failure on an unrelated issue doesn't cause a false manual-trigger here:
  ```bash
  gh run list --workflow=cr-plan-on-issue.yml --event issues --limit 20 \
    --json databaseId,displayTitle,status,conclusion,createdAt,event \
    --jq ".[] | select(.displayTitle | test(\"#${ISSUE_NUMBER}\\\\b\"))"
  ```
  If that query returns nothing (no matching run), consider it a "missing" case. When evaluating a matching run, **always check `status` before `conclusion`** — a run with `status: "queued"` or `status: "in_progress"` has no final conclusion yet and must not be treated as success or failure:
  - **`status != "completed"` (queued / in_progress):** the workflow is still running. Wait up to 5 minutes, re-querying every 60s. If it completes during the wait, re-evaluate. If still not completed after 5 minutes, treat it as stalled and fall through to the manual trigger branch below.
  - **`status == "completed"` and `conclusion == "success"`:** the workflow succeeded. Skip the manual trigger and proceed to Step 4 without a plan — CR simply produced no plan comment.
  - **`status == "completed"` and `conclusion` in the blocking set (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`):** the workflow ran but failed — fall through to the manual trigger branch.
  - **`status == "completed"` and `conclusion` is non-blocking (`cancelled`, `neutral`, `skipped`):** do not assume failure. Skip the manual trigger and proceed to Step 4 without a plan. The workflow was intentionally aborted or bypassed; manually re-posting `@coderabbitai plan` would be unjustified.
  - **If the workflow run for this issue hit a blocking conclusion, is missing entirely, or stalled past the 5-minute wait**: post `@coderabbitai plan` and poll every 60s for up to 5 minutes:
    ```bash
    gh issue comment "$ISSUE_NUMBER" --body "@coderabbitai plan"
    PLAN=$(.claude/scripts/cr-plan.sh "$ISSUE_NUMBER" --poll 5 || true)
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
2. **Fetch current body and upsert the Implementation Plan section:**
   ```bash
   current_body=$(gh issue view "$ISSUE_NUMBER" --json body --jq .body)
   merged_plan="<merged plan — files, steps, risks, verification>"

   # Export CURRENT_BODY BEFORE the python heredoc so the subshell inherits it.
   export CURRENT_BODY="$current_body"

   # Strip any existing "## Implementation Plan" section (everything from the
   # header to EOF or to the next top-level heading) so re-runs of /start-issue
   # don't create duplicate plan sections.
   stripped_body=$(python3 - <<'PY'
   import os, re, sys
   body = os.environ["CURRENT_BODY"]
   # Remove "## Implementation Plan" through EOF or the next "## " heading.
   body = re.sub(r"\n*##[ \t]+Implementation Plan\b.*?(?=\n##[ \t]|\Z)", "", body, flags=re.DOTALL)
   sys.stdout.write(body.rstrip() + "\n")
   PY
   )

   new_body="${stripped_body}

   ## Implementation Plan

   ${merged_plan}"

   gh issue edit "$ISSUE_NUMBER" --body "$new_body"
   ```
   `gh issue edit --body` replaces the entire body, so the fetch-strip-rewrite pattern is required to preserve the original description AND prevent duplicate `## Implementation Plan` sections when `/start-issue` is re-run on the same issue.
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
   ROOT_REPO=$(.claude/scripts/repo-root.sh 2>/dev/null || true)
   if [ -z "$ROOT_REPO" ] || [ ! -d "$ROOT_REPO" ]; then
     echo "ERROR: could not resolve root repo path" >&2
     exit 1
   fi
   # Defensive guard: only pull main if the root repo is actually on main.
   # Mirrors the pattern used by wrap/merge skills.
   CURRENT_BRANCH=$(git -C "$ROOT_REPO" branch --show-current)
   if [ "$CURRENT_BRANCH" != "main" ]; then
     git -C "$ROOT_REPO" checkout main
   fi
   git -C "$ROOT_REPO" pull origin main --ff-only
   WORKTREE_PATH="$ROOT_REPO/.claude/worktrees/issue-$ISSUE_NUMBER-$SLUG"
   git -C "$ROOT_REPO" worktree add "$WORKTREE_PATH" -b "issue-$ISSUE_NUMBER-$SLUG"
   cd "$WORKTREE_PATH"
   ```
   If `pull` fails (diverged history), stop and report to the user — do not force-pull. If `checkout main` fails (uncommitted changes in the root repo), stop and report — do not stash or discard changes.
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
