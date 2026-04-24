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

Then proceed to **Step 2: Active Monitoring Setup** (resume mode must re-establish polling — see Step 2).

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

After Step 1 presents assignments/suggestions, detect whether any **active cloud threads** exist and offer (do NOT auto-start) a polling loop. The PM agent can't autonomously poll GitHub between user messages without a timer — this step wires one up so state changes (new PRs, CR findings, merges, CI failures) get surfaced without the user having to ping.

Resume mode passes through this step too — polling needs to be re-established after context turnover.

**Primitive selection (MANDATORY):** For any user-initiated "poll every N" request, `/loop` is **mandatory** — not just recommended. `CronCreate` is reserved for PM-initiated autonomous monitoring across ≥3 concurrent threads or cross-session durability. Hand-rolled one-shot `ScheduleWakeup` chains are forbidden for recurring polls — they drop silently when the model forgets to re-schedule. For the full decision tree and the pre-exit checklist that every polling turn must run, see `.claude/rules/scheduling-reliability.md`.

### 2.1: Detect active threads

An active cloud thread is an open issue (assigned to `$GH_USER` if set, otherwise any) where ANY of:
- A feature branch referencing the issue exists on the remote
- A local worktree exists for the issue
- An open PR has `Closes #N` / `Fixes #N` referencing the issue

Cross-reference the open-issue list (already fetched in Step 1) against open PRs and `git branch -r` / `git worktree list`. Count the result as `ACTIVE_COUNT`.

### 2.2: Offer a polling option (do NOT auto-start)

Based on `ACTIVE_COUNT`, recommend one of three options:

| Threads | Recommended | Rationale |
|---------|-------------|-----------|
| ≥3 active | **(a) Recurring `CronCreate` poll** — set-and-forget, fires even when REPL is idle between user messages | Too many threads to track manually |
| 1-2 active | **(b) `/loop 5m /status`** — dynamic, tied to this session, dies on session exit | Lightweight; self-paced |
| 0 active | **(c) Passive** — user pings the PM thread when PRs need attention | Nothing to monitor |

Only offer option (c) proactively when there are zero active threads. If the user explicitly requests passive mode at any count, honor it.

**In the same message that proposes the option, state the cancel command.** The user should never have to spelunk to escape a poll:

- Option (a): `CronDelete {jobId}` — emit the job ID as soon as `CronCreate` returns it.
- Option (b): interrupt the loop (Ctrl+C in CLI, stop in web), or say "stop polling".
- Option (c): N/A.

Template message:

> "Detected {N} active cloud threads. Recommend **{option}** — {schedule/command}. To stop: **{cancel command}**. Say 'yes' to start, 'passive' to skip, or pick a different option."

### 2.3: Off-peak minute selection (option a only)

When creating a `CronCreate` job, pick a minute that is NOT 0, 5, 30, or 55 — these are fleet pile-up minutes where every agent's schedule collides on the API. Use `.claude/scripts/off-peak-minute.sh` so the same repo always lands on the same minute (predictability) but different repos spread across the hour (no collision):

```bash
MINUTE=$(.claude/scripts/off-peak-minute.sh)
echo "Off-peak minute for $(gh repo view --json nameWithOwner --jq .nameWithOwner): $MINUTE"
```

The script hashes the current repo's `owner/name` with `cksum`, reduces mod 60, and nudges off the pile-up minutes (0, 5, 30, 55). Pass `--repo <owner/name>` to target a different repo; pass `--every-n-min N` to also emit a cron-friendly step-range (see below).

**CronCreate defaults for `/pm` polling:**
- `cron`: `"$MINUTE * * * *"` for hourly (most common). For tighter cadence like every 10 min, invoke the script with `--every-n-min 10` — it returns two lines (chosen minute on line 1, range string like `7-59/10` on line 2), and handles the ones-digit reduction + re-nudge so the step range doesn't truncate (cron's `A-59/10` form fires only at :A and :A+10 when `A > 9`, e.g., `47-59/10` silently collapses to :47 and :57). Example: `{ read -r M; read -r RANGE; } < <(.claude/scripts/off-peak-minute.sh --every-n-min 10); CRON="$RANGE * * * *"`.
- `recurring`: `true` (default).
- `durable`: `false` — session-only. Only set `durable: true` when the user explicitly asks the poll to survive across sessions.
- `prompt`: `/status` (or a PM-specific scan command) — the cron fires it in a fresh invocation, so the prompt must be self-contained.
- Tell the user about the 7-day auto-expiry.

### 2.4: Heartbeat etiquette

Every poll cycle should produce **at most ~3 lines** of status unless action is required. Long silence between cycles is the goal — the user shouldn't feel spammed.

This cadence is independent of the 5-minute user-heartbeat rule in `.claude/rules/monitor-mode.md` (which applies only while actively monitoring subagents). PM polling is a slower tempo — hourly is normal, 5-10 min when PRs are actively merging.

Good heartbeat:
```
{time} ET — 3 active PRs: #88 clean, #90 CR reviewing, #92 CI failing. No action needed.
```

Bad heartbeat (too verbose):
```
{time} ET — Polled GitHub. PR #88 has 0 new comments, last review clean, CI green, waiting for merge gate. PR #90 ...
```

After setup (or if the user picks passive mode), proceed to **Step 3: Orchestration Loop**.

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
