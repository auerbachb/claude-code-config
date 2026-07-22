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

CR's plan is identified by a comment from `coderabbitai` (no `[bot]` suffix — issue comments use the bare name). Use `.claude/scripts/cr-plan.sh` for detection — it encapsulates the canonical substantive-plan filter (`cr-plan-filter.py`: reject the issue-enrichment/Issue-Planner boilerplate and "actions performed" ack lines, then require >200 chars of stripped content plus a heading or numbered step — issue #541) and the 60s polling loop.

Exit codes: `0` plan found (printed to stdout), `1` no plan, `3` issue not found/closed, `4` gh/env error (network, missing `python3`, or filter failure). Run `.claude/scripts/cr-plan.sh --help` for full usage.

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

## Step 7: Deliver the ready-to-code handoff

**PM-context inline gate (before the chip).** Apply the gate from `.claude/reference/chip-launching.md` "PM-context inline gate". `/start-issue` creates no `## Active Work` table of its own, but when it is invoked *inside* a PM thread that has one — with a free inline slot and a subagent-fit issue — **prefer recommending the issue run inline via `/subagent #N` in that PM thread** over spawning a chip that opens yet another thread (#613); the worktree prepared in Step 6 stays ready if the user would rather code it here instead. In the common case — `/start-issue` as the front door to a fresh coding thread, no PM context — there is no inline pipeline to use, so the chip/handoff below is the right delivery and Step 7 proceeds unchanged. Recommending inline is not launching it (Execution boundary).

**First, check chip availability** per `.claude/reference/chip-launching.md`, then branch. The handoff content is the same in both delivery modes — only how it reaches the user differs:

- **Chip mode** (`mcp__ccd_session__spawn_task` present): call `spawn_task` once for this issue with `title` / `prompt` / `tldr` / `cwd` (shape under "Chip construction" below). Print **only** the short summary — issue, title, `**Model:**` line, one-line rationale — in the reference's exact format. Do **not** also print the fallback block, or the same work is offered twice.
- **Fallback mode** (tool absent): print the summary block below, unchanged.

**A failed `spawn_task` is treated as unavailable** (per the reference): print the full fallback block instead. Do not retry the spawn. The handoff always ends with exactly one of: a chip, a printed block, or — when the PM-context inline gate above routed it — an inline `/subagent` recommendation; never neither.

### Fallback mode output

Print a compact summary to the user. Per `chip-launching.md`, the content **inside** this block (not the fence delimiters themselves) is now **byte-identical to the chip `prompt`** (model-guard preamble included) rather than byte-for-byte identical to pre-chip behavior — see `chip-model-guard-decision.md` for the trade-off. One consequence: the `**Model:**` line, previously a chip-only addition here, is now baked into the base block below, so the guard has a recommendation to compare against in fallback mode too:

```
**Model:** {MODEL} — {REASON}
{Model-guard preamble — insert verbatim from `chip-launching.md` "Model-guard preamble", immediately after this line, no blank line between}

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
Ready to code. Start with step 1 of the plan above. Run the dual-CLI local review per `cr-local-review.md`, fix all valid findings, and rerun until the required clean gate is reached before pushing.
```

### Chip construction (chip mode)

`.claude/reference/chip-launching.md` is authoritative for chip semantics — this table only maps the skill's existing variables onto its params:

| Param | Value |
|-------|-------|
| `title` | Verb-first, ≤60 chars, includes the issue number — built from `ISSUE_NUMBER` + `TITLE` (e.g. `Fix #42 stale worktree warning`) |
| `prompt` | The complete self-contained coding-thread prompt: the **content inside** the fallback fence above (not the fence delimiters themselves), reproduced **verbatim** — Model line and model-guard preamble included. No further additions are made for chip mode; the block content above is already the full chip payload |
| `tldr` | 1–2 plain-English sentences from `TITLE` / the merged plan: what the session will do and why. No file paths, no jargon |
| `cwd` | `WORKTREE_PATH` — the worktree created in Step 6 |

> **`cwd` deliberately differs from `/pm` and `/prompt`,** which pass the repo root. By Step 7, `/start-issue` has already created an issue-specific worktree, so the launched thread must start *there* — repo root would land it in the wrong checkout, on the wrong branch. This is an intentional divergence, not an inconsistency with the shared contract.

**The `**Model:** {MODEL} — {REASON}` line and its guard live in the base block, not as a chip-only addition** — chips cannot preset the model picker, so both a fallback-mode reader and a chip-mode spawned session need the recommendation and the guard in the text itself. The visible short summary in chip mode still repeats just the `**Model:**` line (not the guard) so the user can set the picker before clicking.

**Record the returned `task_id` immediately,** before any dependent step — an unrecorded chip cannot be withdrawn. `/start-issue` has no Active Work table, so track it **session-locally**, keyed by issue number, and say so in the summary; the chip stays dismissable for this session only. If the issue already has a live chip recorded in this session, skip the spawn rather than offering it twice. `dismiss_task` hygiene and print-on-demand replay ("print the full prompt for #N" re-emits that chip's `prompt` verbatim — Model line, guard preamble, and block — in the fenced form fallback would have printed; the chip stays offered) follow the reference — do not restate its rules here.

### Model recommendation

Every handoff — chip or fallback — needs a `{MODEL}` and a `{REASON}`. Use this lightweight, role-based rule over the canonical roster (**Fable 5, Opus 4.8, Sonnet 5, Haiku 4.5** — see `.claude/rules/subagent-orchestration.md` "Model Selection"):

- **Default: Sonnet 5** — ordinary single-issue coding work.
- **Step up to Opus 4.8** when the issue touches rules, `CLAUDE.md`, skills, or orchestration — instruction-adherence work where literal-following models misfire.

`{REASON}` is a short phrase naming the dominant driver (e.g. `rules + skill wiring`, `single-file code change`). Do **NOT** replicate `/prompt`'s Heavy/Standard/Light multi-signal pipeline — `/start-issue` is single-issue and has no model concept beyond this rule. When `/prompt` already produced a recommendation for the issue, prefer it.

### Execution boundary

Stop after delivering the handoff. Do NOT start coding automatically — the user may want to review the plan first. **Offering a chip is not launching a thread:** `spawn_task` only puts a chip in front of the user, and their click is the only launch path. Never click for them, and never do the coding thread's work yourself — via the Agent tool or otherwise — in place of a chip they haven't clicked.

## Edge cases

- **Issue already has a branch / worktree:** if `git worktree list` shows an existing worktree for `issue-$ISSUE_NUMBER-*`, stop and report the path instead of creating a duplicate (see Step 6).
- **Issue is closed:** stop in Step 2.
- **CR plan is an "Actions performed" ack only** (no actual plan content): treat as "no plan" and proceed.
- **New issue description matches an existing open issue** (e.g. duplicate title): the skill will still create a new issue. It does not dedupe — that is the user's responsibility.
- **Empty argument:** stop and ask the user for input.
- **`gh` not authenticated or repo lookup fails:** stop and report the underlying `gh` error to the user.
- **Launched thread's running model mismatches its `**Model:**` line:** guard rules live in `chip-launching.md`, not here — the launched thread stops on any mismatch as its first action and waits for the user, per the model-guard preamble. `/start-issue` only has to ensure the preamble is present in the block; it does not itself detect or resolve mismatches.

## Usage examples

- `/start-issue 42` — start on existing issue #42: read issue, get CR plan, merge plans, create worktree, ready to code.
- `/start-issue "Add dark mode toggle"` — draft and create a new issue, wait for CR plan, merge plans, create worktree, ready to code.
- `/start-issue` — prompts for input when no argument is supplied.
