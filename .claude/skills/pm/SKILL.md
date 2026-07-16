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

## Step 0: Identify the current gh user

Before any mode-specific logic, detect the active GitHub user so downstream filtering can target "your work" vs. "all work".

```bash
GH_USER=$(gh api user --jq .login 2>/dev/null)
if [ -z "$GH_USER" ]; then
  echo "WARNING: gh api user failed — falling back to unfiltered views"
else
  echo "Active gh user: $GH_USER"
fi
```

Store `$GH_USER` for the rest of the session. Use it everywhere filtering matters:

- **Your active PRs** — `gh pr list --state open --search "author:$GH_USER"`
- **PRs awaiting your review** — `gh pr list --state open --search "review-requested:$GH_USER"`
- **Your recent merged work** — `gh pr list --state merged --search "author:$GH_USER" --limit 20`
- **Issues assigned to you** — `gh issue list --state open --assignee "$GH_USER"`

When the user asks "what should I work on?", prioritize in this order:
1. **Your own open PRs with unresolved review findings** — highest priority (you own them and they're blocked on you)
2. **PRs where you're the requested reviewer** — others are blocked on you
3. **Open issues assigned to you** — committed work
4. **Unassigned issues you could claim** — backlog pickup

If `gh api user` fails (no auth, network error), degrade gracefully: skip the user-scoped filters and fall back to the repo-wide views below. Note the fallback in the output so the user knows filtering is unavailable.

---

## Step 1A: Resume mode

Read existing orchestration state to continue where a previous PM thread left off.

### 1A.1: Load pm-config.md

```bash
# Probe the config file via the shared parser. IMPORTANT: run the probe as a
# direct call first, not via `mapfile < <(...)`. With mapfile, `$?` captures
# mapfile's exit code (always 0 on success) — NOT the script's — so a probe
# like `mapfile ...; LIST_RC=$?` would silently never see the rc=2
# (config-missing) signal.
.claude/scripts/pm-config-get.sh --list >/dev/null 2>&1
LIST_RC=$?
```

- If `LIST_RC == 2`: tell the user to run `/pm-handoff` first to bootstrap the config, then stop.
- Otherwise: enumerate sections and iterate for bodies:

  ```bash
  mapfile -t SECTIONS < <(.claude/scripts/pm-config-get.sh --list 2>/dev/null)
  for name in "${SECTIONS[@]}"; do
    body="$(.claude/scripts/pm-config-get.sh --section "$name" 2>/dev/null)"
    # store (name, body) — same loop as `/pm-handoff` Step 3
  done
  ```

### 1A.2: Load in-flight state

```bash
# Session-wide orchestration state
.claude/scripts/session-state.sh --get . 2>/dev/null || echo "NO_SESSION_STATE"

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

State files may be stale. Cross-reference with live data. When `$GH_USER` is set (Step 0), also fetch the user-scoped views so resumed state can be annotated with "yours" vs. "others":

```bash
gh pr list --state open --json number,title,headRefName,author,updatedAt
gh pr list --state merged --limit 10 --json number,title,mergedAt
gh issue list --state open --json number,title,labels,assignees --limit 500

# User-scoped views (only if $GH_USER is set)
if [ -n "$GH_USER" ]; then
  gh pr list --state open --search "author:$GH_USER" --json number,title,updatedAt
  gh pr list --state open --search "review-requested:$GH_USER" --json number,title,author,updatedAt
  gh issue list --state open --assignee "$GH_USER" --json number,title,labels
fi
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

Then proceed to **Step 2: Active Monitoring Setup** (resume mode restores passive tracking — see Step 2).

---

## Step 1B: Cold start (default)

No prior state — scan GitHub and suggest what to work on.

### 1B.1: Load or bootstrap pm-config.md

```bash
# Probe for the config file via the shared parser. rc=2 means the file is missing.
.claude/scripts/pm-config-get.sh --list >/dev/null 2>&1
LIST_RC=$?
```

- If `LIST_RC == 2` (**BOOTSTRAP**): run the same bootstrap logic as `/pm-handoff` Step 2 (detect infrastructure, map architecture, generate pm-config.md). Then continue.
- Otherwise (**CONFIG_EXISTS**): parse sections via `--list` + per-section `--section <name>` as in 1A.1.

Extract the `## OKRs` section via `.claude/scripts/pm-config-get.sh --section OKRs`. If `rc=0` **and** the body does not start with "No OKRs set", set `OKR_MODE=true`.

### 1B.2: Fetch GitHub state

```bash
# Recent merged PRs — understand momentum and direction
gh pr list --state merged --limit 20 --json number,title,mergedAt,author,body

# Open issues — the backlog
gh issue list --state open --json number,title,labels,assignees,createdAt,updatedAt --limit 500

# Open PRs — detect in-flight work
gh pr list --state open --json number,title,headRefName,author,updatedAt,additions,deletions

# User-scoped views (only if $GH_USER is set from Step 0)
if [ -n "$GH_USER" ]; then
  # Your own open PRs — highest priority when asking "what's next"
  gh pr list --state open --search "author:$GH_USER" --json number,title,updatedAt,headRefName

  # PRs awaiting your review — others are blocked on you
  gh pr list --state open --search "review-requested:$GH_USER" --json number,title,author,updatedAt

  # Issues assigned to you — committed work
  gh issue list --state open --assignee "$GH_USER" --json number,title,labels,updatedAt
fi
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

When `$GH_USER` is set, lead the output with user-scoped sections before the general backlog ranking. These always take precedence over backlog pickup — they represent work already on the user's plate.

```
## Your Open PRs
{List of open PRs authored by $GH_USER with last update time — or "none" if empty}

## PRs Awaiting Your Review
{List of open PRs where $GH_USER is a requested reviewer — or "none" if empty}

## Issues Assigned to You
{List of open issues assigned to $GH_USER — or "none" if empty}
```

Then output the top 3-5 backlog issues (unassigned / up for pickup) as a ranked list:

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

Then proceed to **Step 2: Active Monitoring Setup**.

---

## Step 2: Active Monitoring Setup

After Step 1 presents assignments/suggestions, detect whether any **active cloud threads** exist and configure on-demand tracking. `/pm` is a strictly on-demand orchestrator — it does **not** propose or arm any recurring poll (`CronCreate`, `/loop`, or hand-rolled wake chains). PR fleet monitoring between messages is owned by `/pr-monitor-and-manage`.

Resume mode passes through this step too — restore passive tracking state; do **not** re-arm a poll.

For explicit user-initiated "poll every N" requests that are not PR-fleet-specific, `/loop` remains the canonical primitive per `.claude/rules/scheduling-reliability.md`. `/pm` itself never sets one up.

### 2.1: Detect active threads

An active cloud thread is an open issue (assigned to `$GH_USER` if set, otherwise any) where ANY of:
- A feature branch referencing the issue exists on the remote
- A local worktree exists for the issue
- An open PR has `Closes #N` / `Fixes #N` referencing the issue

Cross-reference the open-issue list (already fetched in Step 1) against open PRs and `git branch -r` / `git worktree list`. Count the result as `ACTIVE_COUNT`.

### 2.2: Fleet monitoring redirect (≥3 active threads)

When `ACTIVE_COUNT ≥ 3`, surface a one-line redirect (do NOT offer `CronCreate` or `/loop`):

> "You have {N} active cloud threads. Run `/pr-monitor-and-manage` to auto-dispatch fixes and merges across the fleet with per-PR state tracking."

For 0–2 active threads, emit no polling offer — proceed with the assignments table and status only.

### 2.3: Passive tracking (default)

`/pm` tracks orchestration state on demand. When the user asks "status", "what's next?", or similar, Step 3 fetches live GitHub state and updates the assignments table. The user may explicitly say "passive" or "just track state" at any time — honor that.

Update `~/.claude/session-state.json` to reflect passive tracking. Preserve unknown fields and record at least:

- `monitoring_active` — true when `/pm` is tracking in-flight work (not a recurring poll)
- `monitoring_mode`: `passive` for `/pm`-owned monitoring
- tracked `prs` and `active_agents` where known

**Do not create, modify, or clear `polling_jobs[]` on `/pm`'s behalf.** That field remains valid for other skills (`/pr-monitor-and-manage`, `/babysit-pr`, etc.); leave entries `/pm` did not create intact.

If orchestration state is stale after context turnover, recover using `.claude/rules/monitor-mode.md` "PM Monitoring Recovery".

### 2.4: Backwards compatibility

Any `/pm`-created `CronCreate` jobs from before this change persist until the 7-day auto-expiry or explicit `CronDelete`. New `/pm` sessions do not create replacement polls.

After setup, proceed to **Step 3: Orchestration Loop**.

---

## Step 3: Orchestration Loop

This is the core PM behavior. Once the user confirms which issues to work on, enter the orchestration loop.

### 3.1: Generate coding thread prompts

For each selected issue, generate a self-contained prompt. The prompt content below is the same in both delivery modes — only how it reaches the user differs.

**First, check chip availability** per `.claude/reference/chip-launching.md`, then branch:

- **Chip mode** (`mcp__ccd_session__spawn_task` present): call `spawn_task` once per selected issue with `title` / `prompt` / `tldr` / `cwd`, where `prompt` is the full self-contained prompt below, unchanged. Print **only** the short summary per issue (issue, title, `**Model:**` line, one-line rationale) — see the reference for the exact format. Record each returned `task_id` in the Active Work table (3.2) and set that issue's status to `Chip offered`.
- **Fallback mode** (tool absent): emit the full prompt blocks for every selected issue exactly as before — same fences, same content.

**Spawn outcomes are tracked per issue.** A failed `spawn_task` falls back for **that issue alone** — print its full block and leave it at `Prompt generated`. Issues whose spawns succeeded keep their chip, their `task_id`, and their `Chip offered` status; never re-print their block as well, or the same issue is offered twice. Every selected issue ends with exactly one of: a chip, or a printed block.

Chips carry no model preset, so the `**Model:**` line must appear both in the visible summary and inside the chip's prompt text. Get the model recommendation from `/prompt`'s tier classification when it ran; otherwise infer it from the issue's signals using the same Heavy/Standard/Light mapping.

If the user asks to "print the full prompt for #N" while in chip mode, re-emit that issue's complete block verbatim — the chip stays offered.

Each prompt must include:

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
5. Run the local dual-CLI review per `cr-local-review.md` (`coderabbit review --agent` + `codeant review --all --headless`) — fix all findings
6. One clean pass on each available CLI (dropped-CLI and outage fallbacks per `cr-local-review.md`), then commit and push
7. Create a PR with `Closes #{N}` in the body
8. Include a Test Plan section with checkboxes for acceptance criteria
9. Enter the review polling loop and fix any findings

## Constraints
- Do NOT work on main — use a worktree or feature branch
- Do NOT modify .env files
- Squash and merge when reviews are clean
```

Offer or present every prompt — never execute one. Do NOT spawn subagents or run the prompts: in chip mode the user's click is the only launch path, and in fallback mode the user pastes the block into a thread. Only spawn agents if the user explicitly asks (e.g., "go ahead and run those", "spin up agents for those").

### 3.2: Track assignments

Maintain a state table in the conversation. Update it as work progresses:

```
## Active Work

| Issue | Thread | Task ID | PR | Status | Last Update |
|-------|--------|---------|----|--------|-------------|
| #42 | Chip offered | `task_abc123` | — | Awaiting thread start | {timestamp} |
| #61 | Prompt generated | — | — | Awaiting thread start | {timestamp} |
| #38 | Active | — | PR #88 | In review | {timestamp} |
| #55 | Active | — | PR #90 | Merged | {timestamp} |
```

**Thread column values:**

- `Chip offered` — a chip was spawned for this issue and is waiting on a click (chip mode).
- `Prompt generated` — a full prompt block was printed for the user to paste (fallback mode, or a failed spawn).
- `Active` — a thread is running for this issue.

**Task ID column:** every `Chip offered` row MUST carry the `task_id` returned by its `spawn_task` call — it is the only handle for dismissing that chip later, and a chip whose `task_id` was not recorded cannot be withdrawn. `Prompt generated` and `Active` rows leave it empty (`—`).

`Chip offered` and `Prompt generated` are the same state from the pipeline's view — offered, not yet started — and both pair with the `Awaiting thread start` status. Both are excluded from re-offering: `/prompt`'s Path B scan treats an offered-but-unstarted chip exactly as it treats `Prompt generated`, so a re-run never double-offers the same issue.

### 3.3: Progress detection

When the user asks "status", "what's next", or "update" — or periodically when it makes sense:

```bash
# Check for new/merged PRs
gh pr list --state open --json number,title,headRefName,body
gh pr list --state merged --limit 10 --json number,title,mergedAt,body

# Check for closed issues
gh issue list --state closed --limit 20 --json number,title,closedAt

# User-scoped re-check (only if $GH_USER is set from Step 0)
if [ -n "$GH_USER" ]; then
  gh pr list --state open --search "author:$GH_USER" --json number,title,updatedAt
  gh pr list --state open --search "review-requested:$GH_USER" --json number,title,author,updatedAt
fi
```

When answering "what's next", always check the user-scoped results first (your open PRs with unresolved findings, then review requests against you) before suggesting new backlog pickup.

Cross-reference with the assignments table:
- Detect PRs that reference tracked issues (search PR body for `Closes #N`, `Fixes #N`)
- Mark issues as "PR open" or "Merged" accordingly
- Flag stale threads: if an issue was assigned > 30 minutes ago with no PR, note it
- **Dismiss stale chips:** any issue sitting at `Chip offered` that now has an open PR is being worked already — withdraw its chip via `dismiss_task` (see `.claude/reference/chip-launching.md`). Reuse the open-PR result already fetched above and the same closing-keyword predicate — no extra API call. Only clear the tracked `task_id` after the dismiss succeeds.

Also accept user input: "thread for #42 is done", "PR #88 merged", "#55 is blocked".

### 3.4: Suggest next batch

When one or more threads finish (PRs merged, issues closed):

1. **Dismiss the chips of finished issues, then remove their rows.** Order matters: a row carries its chip's `task_id`, and once the row is gone the chip can no longer be withdrawn. So for every completed issue still at `Chip offered`, `dismiss_task` first — its work is done, the offer is dead — and only then drop it from the assignments table.
2. Re-scan open issues (reuse 1B.2-1B.4 logic but lighter — only fetch new/changed issues)
3. Suggest 1-3 new issues to fill the pipeline
4. Generate prompts for the user's selected issues (Step 3.1 — chip or fallback)
5. **Dismiss superseded and re-planned chips.** Beyond the finished issues handled in step 1, withdraw a `Chip offered` chip only when its offer is genuinely dead:
   - **Superseded** — the issue was explicitly replaced by a newer suggestion.
   - **Re-planned** — the issue's scope or plan changed, so the chip's prompt is stale.

   An offered chip that simply isn't in the new batch is **not** superseded — a suggestion the user hasn't acted on yet stays valid and keeps its chip. Only dismiss on an explicit signal.

   Re-planning is spawn-then-dismiss: create the replacement chip first, then dismiss the old one. If the dismiss fails, the issue now has two chips — withdraw the replacement to restore a single offer, and if that also fails, leave both tracked and tell the user which `task_id` is stale rather than silently dropping either. Update the Active Work table only after a dismiss succeeds.

### 3.5: Handoff awareness

When the conversation is getting long (many back-and-forth cycles, multiple batches of work completed), proactively suggest:

> "This PM session has been running for a while. To preserve context for a fresh thread, run `/pm-handoff` — it will capture the current state, memory, and in-flight work into a prompt you can paste into a new PM session."

---

## Execution Boundary (CRITICAL)

**This skill does NOT write code, create PRs, or spawn subagents.**

The PM orchestrator's job is to:
- Analyze the backlog and recommend what to work on
- Generate self-contained prompts for coding threads, and offer them as chips when available
- Track progress across threads
- Suggest next work when threads finish

The **user** decides when and where to start work — by clicking a chip in chip mode, or by pasting a prompt in fallback mode. The user starts the coding threads. The PM tracks and coordinates.

**Offering a chip is not launching a thread.** `spawn_task` puts a chip in front of the user; only their click starts a session. The PM never clicks for them, and never runs a coding thread's work itself — via the Agent tool or otherwise — in place of a chip the user hasn't clicked. This governs coding threads only; the read-only `pm-worker` data-gathering spawns described under "Model selection for spawned subagents" below remain allowed and are unaffected.

**Exception:** If the user explicitly says "go ahead and run those", "spin up agents", or "execute those prompts" — then and only then may you spawn subagents via the Agent tool to execute the coding thread prompts.

**Model selection for spawned subagents:**

- **Coding subagents** (Phase A/B executing a selected issue): prefer the `/subagent` skill, which already enforces per-phase model selection (`opus` for Phase A/B, `sonnet` for Phase C; these aliases currently resolve to Opus 4.8 and Sonnet 5). See `.claude/rules/subagent-orchestration.md` "Model Selection".
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
