---
name: pm
description: Active PM orchestrator — manages issue pipeline, tracks coding threads, suggests next work. Cold-starts from GitHub state or resumes from a /pm-handoff prompt. Triggers on "pm", "project manager", "orchestrate", "what should I work on".
triggers:
  - project manager
  - orchestrate
  - what should I work on
  - manage issues
argument-hint: "[resume] (optional — 'resume' reads in-flight state from session files to continue a previous PM session)"
---

Active PM orchestrator. Manages which issues are being worked on across coding threads, tracks progress, and suggests next work.

**Two modes:**
- **Cold start (default):** Scan GitHub state, suggest next 3-5 issues, enter orchestration loop.
- **Resume:** Read in-flight state from session files and continue where the previous PM left off.

Parse `$ARGUMENTS`:
- If `$ARGUMENTS` contains "resume" or "handoff": enter Resume mode (Step 1A).
- Otherwise: enter Cold Start mode (Step 1B).

---

## Step 1A: Resume mode

Read existing orchestration state to continue where a previous PM thread left off.

### 1A.1: Load pm-config.md

```bash
test -f .claude/pm-config.md && echo "CONFIG_EXISTS" || echo "NO_CONFIG"
```

If config exists, parse it using line-anchored `^## ` headers (same logic as `/pm-handoff` Step 3). If missing, tell the user to run `/pm-handoff` first to bootstrap the config.

### 1A.2: Load in-flight state

```bash
# Session-wide orchestration state
test -f ~/.claude/session-state.json && cat ~/.claude/session-state.json || echo "NO_SESSION_STATE"

# Per-PR handoff files (iterate to emit valid JSON per file)
found_handoffs=false
for f in ~/.claude/handoffs/pr-*-handoff.json; do
  [ -f "$f" ] || continue
  found_handoffs=true
  echo "--- $f ---"
  cat "$f"
done
$found_handoffs || echo "NO_HANDOFF_FILES"
```

Parse any found state into an assignments table:

| PR | Issue | Phase | Reviewer | Last SHA | Notes |
|----|-------|-------|----------|----------|-------|

### 1A.3: Verify against live GitHub

State files may be stale. Cross-reference with live data:

```bash
gh pr list --state open --json number,title,headRefName,author,updatedAt
gh pr list --state merged --limit 10 --json number,title,mergedAt
gh issue list --state open --json number,title,labels,assignees --limit 500
```

**Truncation check:** If the returned issue count equals 500, warn: "Showing 500 issues — repo may have more. Results may be incomplete."

- PRs that have merged since the handoff: mark as complete, remove from assignments.
- Issues that have been closed: remove from backlog.
- New PRs not in the state file: note them as untracked.

### 1A.4: Present recovered state

Show the user:
1. Verified assignments table (corrected for merges/closures since handoff)
2. Any issues that were in-progress but whose PRs are now missing or stale
3. Remaining open issues not yet assigned

Proceed with current assignments by default. State: "Continuing with current assignments. Say 're-prioritize' to change strategy."

Then proceed to **Step 3: Orchestration Loop**.

---

## Step 1B: Cold start (default)

No prior state — scan GitHub and suggest what to work on.

### 1B.1: Load or bootstrap pm-config.md

```bash
test -f .claude/pm-config.md && echo "CONFIG_EXISTS" || echo "BOOTSTRAP"
```

- If **BOOTSTRAP**: Run the same bootstrap logic as `/pm-handoff` Step 2 (detect infrastructure, map architecture, generate pm-config.md). Then continue.
- If **CONFIG_EXISTS**: Parse it using line-anchored `^## ` headers.

Extract the `## OKRs` section if present and non-placeholder. Set `OKR_MODE=true` if OKRs exist.

### 1B.2: Fetch GitHub state

```bash
# Recent merged PRs — understand momentum and direction
gh pr list --state merged --limit 20 --json number,title,mergedAt,author,body

# Open issues — the backlog
gh issue list --state open --json number,title,labels,assignees,createdAt,updatedAt --limit 500

# Open PRs — detect in-flight work
gh pr list --state open --json number,title,headRefName,author,updatedAt,additions,deletions
```

**Truncation check:** If the returned issue count equals 500, warn: "Showing 500 issues — repo may have more. Results may be incomplete."

### 1B.3: Read issue bodies for top candidates

Reading all issue bodies is expensive. Use a two-pass approach:

**Pass 1 — Quick scan:** From the issue list, identify the top ~20 candidates using fast signals:
- Labels containing `bug`, `critical`, `P0`, `P1`, `urgent`, `blocked`
- Issues with no assignee (available for pickup)
- Issues not already covered by an open PR (cross-reference PR branch names and bodies for `#N` references)
- Most recently updated (active discussion = likely important)
- Oldest unassigned (may be neglected but important)

**Pass 2 — Deep read:** For the top ~20 candidates, fetch full bodies:

```bash
# For each candidate issue number:
gh issue view $NUMBER --json body,title,labels,comments,assignees
```

Extract from each:
- Scope and intent (what the issue actually asks for)
- Dependency references: `blocked by #N`, `depends on #N`, `unblocks #N`
- Complexity signals: number of acceptance criteria, files mentioned
- Whether a PR is already in flight for this issue

### 1B.4: Score and rank issues

For each candidate, assess:

1. **Priority signals (primary):**
   - Labels: `P0`/`critical` > `P1`/`bug` > `P2`/`enhancement` > unlabeled
   - Dependency leverage: issues that unblock 2+ other issues rank higher
   - Age + activity: old unassigned issues with recent comments = neglected priority

2. **OKR alignment (when `OKR_MODE=true`):**
   - Issues that directly advance an incomplete key result get a one-tier boost
   - Issues aligned with an objective broadly get a tiebreaker advantage
   - Record which OKR(s) each issue aligns with

3. **Recent momentum:**
   - What areas of the codebase have recent merged PRs? Issues in the same area benefit from warm context.
   - What themes appear in recent merges? Issues continuing that theme are cheaper to pick up.

4. **Exclusions:**
   - Skip issues that already have an open PR (someone is working on it)
   - Skip issues assigned to someone else (unless stale > 14 days)
   - Skip issues labeled `blocked`, `on-hold`, `wontfix`, `duplicate`

### 1B.5: Present recommendations

Output the top 3-5 issues as a ranked list:

```
## Suggested Next Issues

Based on {N} open issues, {M} recent merges, and {OKR status}:

1. **#42 — {Title}** — {1-line rationale connecting to business value or OKR}
   - Labels: {labels} | Age: {days} days | Unblocks: #50, #53

2. **#38 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days | Blocked by: #35

3. **#55 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days

4. **#61 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days

5. **#47 — {Title}** — {rationale}
   - Labels: {labels} | Age: {days} days

### Already In-Flight
{List open PRs with their linked issues — these don't need new threads}

### Dependency Note
{If any suggested issues have dependency chains, note the order}
```

Select the top-ranked batch by default and generate prompts immediately. State: "Generating prompts for the top issues below. Say 'adjust' to change the selection before pasting into threads."

Then proceed to **Step 3: Orchestration Loop**.

---

## Step 2: (Reserved — both modes skip to Step 3)

---

## Step 3: Orchestration Loop

This is the core PM behavior. Once the user confirms which issues to work on, enter the orchestration loop.

### 3.1: Generate coding thread prompts

For each selected issue, generate a self-contained prompt that can be pasted into a new Claude Code thread (web or CLI). Each prompt must include:

```
You are a coding agent working on {repo URL}.

## Task
Fix/implement issue #{N}: {title}
{Full issue URL}

## Issue Details
{Issue body — paste the full body so the thread has context}

## Relevant Codebase Context
{Based on the issue body and recent PRs, describe:}
- Key files likely involved (from issue body references, labels, or educated guess from architecture)
- Patterns to reuse (from pm-config Architecture section)
- Dependencies that are already met

## Workflow
1. Create a worktree for isolated work
2. Read the issue body — this is the canonical implementation plan (includes merged CodeRabbit recommendations when available)
3. Check issue comments only to detect any plan content not yet merged into the body — if found, merge it first
4. Implement the changes
5. Run local CodeRabbit review (`coderabbit review --prompt-only`) — fix all findings
6. Two clean passes, then commit and push
7. Create a PR with `Closes #{N}` in the body
8. Include a Test Plan section with checkboxes for acceptance criteria
9. Enter the review polling loop and fix any findings

## Constraints
- Do NOT work on main — use a worktree or feature branch
- Do NOT modify .env files
- Squash and merge when reviews are clean
```

Present all prompts to the user. Do NOT spawn subagents or execute the prompts — present them for the user to paste into coding threads. Only spawn agents if the user explicitly asks (e.g., "go ahead and run those", "spin up agents for those").

### 3.2: Track assignments

Maintain a state table in the conversation. Update it as work progresses:

```
## Active Work

| Issue | Thread | PR | Status | Last Update |
|-------|--------|----|--------|-------------|
| #42 | Prompt generated | — | Awaiting thread start | {timestamp} |
| #38 | Active | PR #88 | In review | {timestamp} |
| #55 | Active | PR #90 | Merged | {timestamp} |
```

### 3.3: Progress detection

When the user asks "status", "what's next", or "update" — or periodically when it makes sense:

```bash
# Check for new/merged PRs
gh pr list --state open --json number,title,headRefName,body
gh pr list --state merged --limit 10 --json number,title,mergedAt,body

# Check for closed issues
gh issue list --state closed --limit 20 --json number,title,closedAt
```

Cross-reference with the assignments table:
- Detect PRs that reference tracked issues (search PR body for `Closes #N`, `Fixes #N`)
- Mark issues as "PR open" or "Merged" accordingly
- Flag stale threads: if an issue was assigned > 30 minutes ago with no PR, note it

Also accept user input: "thread for #42 is done", "PR #88 merged", "#55 is blocked".

### 3.4: Suggest next batch

When one or more threads finish (PRs merged, issues closed):

1. Remove completed items from the assignments table
2. Re-scan open issues (reuse 1B.2-1B.4 logic but lighter — only fetch new/changed issues)
3. Suggest 1-3 new issues to fill the pipeline
4. Generate prompts for the user's selected issues

### 3.5: Handoff awareness

When the conversation is getting long (many back-and-forth cycles, multiple batches of work completed), proactively suggest:

> "This PM session has been running for a while. To preserve context for a fresh thread, run `/pm-handoff` — it will capture the current state, memory, and in-flight work into a prompt you can paste into a new PM session."

---

## Execution Boundary (CRITICAL)

**This skill does NOT write code, create PRs, or spawn subagents.**

The PM orchestrator's job is to:
- Analyze the backlog and recommend what to work on
- Generate self-contained prompts for coding threads
- Track progress across threads
- Suggest next work when threads finish

The **user** decides when and where to paste the prompts. The user starts the coding threads. The PM tracks and coordinates.

**Exception:** If the user explicitly says "go ahead and run those", "spin up agents", or "execute those prompts" — then and only then may you spawn subagents via the Agent tool to execute the coding thread prompts.

**Model selection for spawned subagents:**

- **Coding subagents** (Phase A/B executing a selected issue): prefer the `/subagent` skill, which already enforces per-phase model selection (`opus` for Phase A/B, `sonnet` for Phase C). See `.claude/rules/subagent-orchestration.md` "Model Selection".
- **Read-only PM data-gathering subagents** (e.g., scanning GitHub for backlog context, summarizing recent PR activity, reviewing progress on in-flight threads): spawn with `subagent_type: "pm-worker"`, `mode: "bypassPermissions"`, and `model: "sonnet"`. These tasks are template-driven data collection — Sonnet is the right cost tier and the frontmatter default on `pm-worker` matches.
- **Never omit `model`** at the call site. Explicit model selection keeps cost decisions visible at every spawn point and prevents silent Opus usage for lightweight work.

---

## Writing Rules

- **Rationales must connect to business value.** "This is a bug" is not a rationale. "This bug blocks the checkout flow that drives 60% of revenue" is.
- **1-2 lines per issue** in the suggestions list. Save detail for the coding thread prompts.
- **Flag dependencies inline** with the issues they affect.
- **Total suggestions should be scannable in under 1 minute.**
- **Coding thread prompts should be complete and self-contained.** The receiving thread has zero prior context — give it everything it needs.
- **Do not list every issue.** If 80 of 100 issues are low-priority, say "75 additional issues deferred" rather than listing them.
