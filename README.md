# Claude Code Configuration

A reusable `CLAUDE.md` configuration that teaches [Claude Code](https://docs.anthropic.com/en/docs/claude-code) to collaborate with [CodeRabbit](https://coderabbit.ai) and [Greptile](https://greptile.com) for automated PR planning, code review, and merge workflows — all driven from your terminal. Includes a full PM skill family for project orchestration across threads.

## Table of Contents

- [What You Get](#what-you-get)
- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
- [Slash Commands](#slash-commands)
  - [PM Skill Family](#pm-skill-family)
  - [Workflow Commands](#workflow-commands)
- [Rule Files](#rule-files)
- [Hook Scripts](#hook-scripts)
- [Config Files](#config-files)
- [GitHub Actions](#github-actions)
- [Architecture](#architecture)
- [How the Review Loop Works](#how-the-review-loop-works)
- [Key Design Decisions](#key-design-decisions)
- [Per-Project Override](#per-project-override-optional)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [Customizing](#customizing)
- [Contributing](#contributing)
- [License](#license)

---

## What you get

After setup, Claude Code will automatically:

- **Plan before coding** — Kicks off `@coderabbitai plan` on new issues, builds its own plan in parallel, then merges both into one implementation spec.
- **Review locally first** — Runs CodeRabbit reviews via CLI before pushing. No PR noise, instant feedback.
- **GitHub review as safety net** — After pushing, CodeRabbit auto-reviews on GitHub. Claude polls for findings and resolves them. If CodeRabbit is rate-limited or unresponsive, Greptile is triggered as a fallback (budget permitting).
- **Handle rate limits** — Batches fixes into single commits, respects CodeRabbit's hourly limits, falls back to Greptile or self-review when throttled.
- **Verify acceptance criteria** — Before merging, reads every Test Plan checkbox, verifies each against the code, and checks them off.
- **Squash and merge** — Clean PRs get squash-merged with branch cleanup after merge gates pass.
- **Orchestrate multi-agent work** — Decomposes large tasks into phases (fix, review, merge) with health monitoring, handoff files, and heartbeat enforcement.
- **Project management** — A full PM skill family (`/pm`, `/pm-sprint-plan`, `/pm-okr`, etc.) for backlog prioritization, sprint planning, team metrics, and cross-thread orchestration.

---

## Getting Started

Follow these steps after cloning the repo. All commands assume macOS/Linux.

### Step 1: Clone the repo

```bash
git clone https://github.com/auerbachb/claude-code-config.git
cd claude-code-config
```

Pick a permanent location — the symlinks you create below will point here. If you move the repo later, you'll need to recreate them.

### Step 2: Create the `~/.claude` directory structure

```bash
mkdir -p ~/.claude/skills
```

### Step 3: Symlink `CLAUDE.md` (global instructions)

```bash
ln -sfn "$(pwd)/CLAUDE.md" ~/.claude/CLAUDE.md
```

This gives Claude Code its core instructions in every project. The symlink means pulling updates to this repo automatically updates your config.

### Step 4: Symlink the rule files

```bash
ln -sfn "$(pwd)/.claude/rules" ~/.claude/rules
```

Rule files in `.claude/rules/` auto-load alongside `CLAUDE.md`. They contain the detailed review, planning, safety, and orchestration workflows.

### Step 5: Install global settings (hooks + permissions)

```bash
cp global-settings.json ~/.claude/settings.json
```

> **Why copy instead of symlink?** Unlike the other files, `settings.json` contains absolute paths that must be customized per machine. A symlink would point everyone to the same placeholder paths.

**Then replace all placeholder paths** with the absolute path to your clone:

```bash
# macOS:
sed -i '' 's|/path/to/claude-code-config|'"$(pwd)"'|g' ~/.claude/settings.json

# Linux:
sed -i 's|/path/to/claude-code-config|'"$(pwd)"'|g' ~/.claude/settings.json
```

This file configures:
- **Permissions** — Broad allow rules so Claude operates autonomously without prompting for every tool call.
- **Hooks** — Shell scripts that run automatically during sessions (see [Hook Scripts](#hook-scripts)).
- **Environment variables** — Model preferences and experimental flags.

> **Important:** All hook paths in `settings.json` must be absolute. Do not use `~/` or relative paths — they are unreliable. If you move the repo, re-run the `sed` command above.

### Step 6: Set up skills worktree

The skills worktree ensures skills are always available regardless of what branch the root repo is on:

```bash
# Run from inside the repo
./setup-skills-worktree.sh
```

This creates a dedicated worktree at `~/.claude/skills-worktree/` pinned to `main` and symlinks all skills to `~/.claude/skills/`. The `post-merge-pull.sh` hook keeps it in sync automatically. If skills ever break, re-run this script.

### Prerequisites

These tools are required for the full workflow:

| Tool | Install | Purpose |
|------|---------|---------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | `npm install -g @anthropic-ai/claude-code` | The CLI / desktop app itself |
| [GitHub CLI (`gh`)](https://cli.github.com/) | `brew install gh && gh auth login` | Issue/PR creation, API calls |
| [CodeRabbit](https://coderabbit.ai) | Install the GitHub App on your repos | AI code review on PRs |
| [CodeRabbit CLI](https://docs.coderabbit.ai/cli) | See below | Local pre-push reviews |

**CodeRabbit CLI install:**

```bash
curl -fsSL https://cli.coderabbit.ai/install.sh | sh
coderabbit auth login
```

The CLI installs to `~/.local/bin/coderabbit`. If it's not in your PATH, the config falls back to the full path.

**Optional: Greptile** — An AI code reviewer used as a fallback when CodeRabbit is rate-limited or unresponsive. Install the [Greptile GitHub App](https://greptile.com) on your repos. Greptile app settings are configured via the Greptile web dashboard (app.greptile.com). The `greptile.md` rule file in this repo tells Claude how to use Greptile as a fallback reviewer.

### Step 8: Set up CodeRabbit for a repo (per-repo)

For each repo where you want the full workflow:

1. Install CodeRabbit on the repo (via GitHub App settings).
2. Optionally add a `.coderabbit.yaml` to the repo root for custom review rules.
3. The config auto-detects whether CodeRabbit is installed. If it's not, those sections are skipped.

### Step 9: Verify your setup

```bash
# Check symlinks point to this repo
ls -la ~/.claude/CLAUDE.md
ls -la ~/.claude/rules
ls -la ~/.claude/skills/

# Check settings file has correct paths (no /path/to/ placeholders)
grep "path/to" ~/.claude/settings.json && echo "ERROR: placeholders remain" || echo "OK: paths look good"

# Check hooks are executable
ls -la "$(pwd)/.claude/hooks/"
```

You should see:
- `~/.claude/CLAUDE.md` -> this repo's `CLAUDE.md`
- `~/.claude/rules` -> this repo's `.claude/rules`
- Each skill in `~/.claude/skills/` -> `~/.claude/skills-worktree/.claude/skills/<name>`
- No `path/to` placeholders in `~/.claude/settings.json`
- Hook scripts with `x` (execute) permission

---

## Slash Commands

All commands below are invoked as `/command` in a Claude Code session. They are defined as skill files in `.claude/skills/` and symlinked globally.

### Summary

| Command | Category | Description |
|---------|----------|-------------|
| `/pm` | PM | Generate a PM handoff prompt for a new thread |
| `/pm-update` | PM | Re-scan repo and refresh `pm-config.md` |
| `/pm-okr` | PM | View, set, or suggest OKRs |
| `/pm-clean` | PM | Detect stale issues and suggest closures |
| `/prioritize` | PM | Rank backlog issues by business goal impact (OKR-aware) |
| `/pm-team-standup` | PM | Per-contributor activity summary (past 24h) |
| `/pm-rate-team` | PM | Contribution metrics over a configurable period |
| `/pm-sprint-plan` | PM | Generate a 2-week sprint plan |
| `/pm-sprint-review` | PM | Sprint retrospective with velocity metrics |
| `/standup` | Workflow | Daily standup summary (single contributor) |
| `/status` | Workflow | Dashboard of open PRs with review state |
| `/continue` | Workflow | Resume an interrupted review workflow |
| `/merge` | Workflow | Squash merge with merge gate + AC verification |
| `/wrap` | Workflow | End-of-session: merge, lessons, cleanup |
| `/check-acceptance-criteria` | Workflow | Verify Test Plan checkboxes against code |
| `/lessons` | Workflow | Extract and save session learnings to memory |

### PM Skill Family

The PM skills turn Claude Code into a project manager that works across threads. They share a central config file (`pm-config.md`) that stores your team roster, OKRs, infrastructure, and architecture. Run `/pm` first to bootstrap the config, then use the other skills as needed.

#### `/pm [copy]`

Generate a self-contained handoff prompt for starting a new PM thread. On first run, bootstraps `.claude/pm-config.md` with auto-detected infrastructure and architecture. Combines static config with live GitHub state (open issues, PRs, recent merges) into a single prompt.

Pass `copy` to send the output to the clipboard via `pbcopy`.

#### `/pm-update`

Re-scan the repo and refresh the auto-generated sections of `pm-config.md` (Infrastructure, Architecture) while preserving user-edited sections (Role, OKRs, Team, Notes, Dependency Rules, Workflow Rules). Run after major milestones or significant directory restructuring.

#### `/pm-okr [show | set <objectives> | suggest]`

Manage the OKRs section of `pm-config.md`. OKRs drive `/prioritize` ranking and `/pm-sprint-plan` planning.

- `show` (default) — Display current OKRs with cross-references to open issues
- `set <objectives>` — Replace OKRs with the provided text
- `suggest` — Analyze recent merged PRs and closed issues, then suggest OKR updates

#### `/pm-clean [days]`

Scan open issues for staleness and suggest closures. Detects four categories:

1. **Solved by PR** — Issues already fixed by a merged PR
2. **Inactive** — No activity for N days (default: 30)
3. **Superseded** — Replaced by a newer issue
4. **Potential duplicates** — Similar to already-closed issues

Presents recommendations grouped by category. Never auto-closes — always waits for user confirmation.

#### `/prioritize <goal> [| @user constraints | depth]`

Rank open issues by impact on a stated business goal. When OKRs are defined in `pm-config.md`, uses them as an additional ranking signal.

```
/prioritize increase API throughput | @alice backend-only | 25
```

The `|` characters are argument separators (not shell pipes).

Produces a tiered list (Critical / High / Medium / Low) with dependency annotations, OKR alignment, and next actions. Includes a "stop doing" section if the engineer's current work is misaligned.

#### `/pm-team-standup [since-time]`

Multi-contributor standup. Summarizes what each team member did in the past 24 hours — commits, PRs merged/opened, issues created/closed, and reviews given. Uses the Team section from `pm-config.md` for display names and roles.

Default time reference: yesterday at noon ET.

#### `/pm-rate-team [--days N]`

Evaluate team contributions over a configurable period (default: 14 days). Per-contributor metrics include: PRs merged, code volume, average review cycles, issues opened/closed, reviews given, and CR first-pass success rate. Includes constructive qualitative observations and collaboration patterns.

#### `/pm-sprint-plan [--days N]`

Generate a 2-week sprint plan from the open backlog. Detects dependencies between issues, identifies parallel work tracks, assigns issues to team members (from `pm-config.md`), and aligns with OKRs. Warns about circular dependencies and team overload.

#### `/pm-sprint-review [--days N]`

Sprint retrospective covering: what got done, what slipped, velocity metrics (issues closed, PRs merged, avg cycle time), blockers encountered, per-contributor breakdown, and lessons learned with recommendations.

### Workflow Commands

These commands support the day-to-day PR and review workflow.

#### `/standup [since-time]`

Generate a daily standup summary from recent PRs and issues. Groups accomplishments by business themes and explains what the system can now do (not just what code changed). Reads PR bodies for context.

#### `/status`

Dashboard of all open PRs showing review state, unresolved findings, blockers, HEAD SHA, and last update time. Also reports CR quota usage and active agents if applicable.

#### `/continue`

Resume an interrupted or stalled review workflow. Detects where the agent left off and continues from the next incomplete step:

1. Local CR review
2. Push to remote
3. PR creation
4. Review polling (CR / Greptile)
5. Feedback processing and thread resolution
6. Merge gate verification
7. Acceptance criteria check

Each step shows `[DONE]`, `[ACTION]`, `[BLOCKED]`, or `[SKIP]`.

#### `/merge`

Squash merge the current PR after verifying:
- Merge gate satisfied (2 clean CR reviews or Greptile severity gate)
- All acceptance criteria checked off
- All CI checks passing
- Branch deletion after merge
- Work-log updated

#### `/wrap`

End-of-session command that runs the full close-out workflow:
1. Verify no unresolved review findings
2. Squash merge the PR
3. Detect follow-up issues
4. Extract lessons and save to memory
5. Sync work-log to root repo
6. Clean up the worktree

#### `/check-acceptance-criteria [PR-number]`

Verify every Test Plan checkbox in a PR against the actual source code. Checks off passing items by editing the PR body. Reports failures with explanations and flags items that require manual testing. Defaults to the current branch's PR if no number is given.

#### `/lessons`

Extract actionable lessons from the current session — what went wrong, what patterns emerged, what to remember. Categorizes each lesson and saves novel ones to memory with proper frontmatter. Skips lessons that duplicate existing memory entries.

---

## Rule Files

Rule files in `.claude/rules/` auto-load alongside `CLAUDE.md` and define the detailed workflows. They are the behavioral core of this configuration.

| File | Purpose |
|------|---------|
| `issue-planning.md` | Issue creation flow, `@coderabbitai plan` integration, plan merging |
| `cr-local-review.md` | Primary review loop — runs CodeRabbit CLI locally before pushing |
| `cr-github-review.md` | GitHub review polling — three endpoints, rate limits, thread resolution, merge gate |
| `greptile.md` | Greptile fallback reviewer — severity-gated re-reviews, daily budget, self-review fallback |
| `subagent-orchestration.md` | Multi-agent task decomposition (phases A/B/C), monitor mode, heartbeats, handoff files |
| `work-log.md` | Auto-update daily work log on issue create, PR open, PR merge |
| `safety.md` | Destructive command prohibitions, `.env` protection, subagent safety warnings |
| `repo-bootstrap.md` | Auto-provision required GitHub Actions workflows on first touch |
| `trust-dialog-fix.md` | Fix trust dialog re-prompting when bypass permissions are enabled |
| `skill-symlinks.md` | Symlink new skills globally via the skills worktree after creation |

---

## Hook Scripts

Hook scripts in `.claude/hooks/` run automatically during Claude Code sessions. They are registered in `global-settings.json` and fire on specific events.

| Script | Trigger | Purpose |
|--------|---------|---------|
| `post-merge-pull.sh` | PostToolUse (Bash) | Auto-pulls `main` in the root repo after `gh pr merge` succeeds; also syncs the skills worktree. Uses three fallback strategies to locate the root repo. |
| `silence-detector.sh` | PostToolUse (all tools) | Checks if the agent has been silent >5 minutes by comparing heartbeat file mtime. Injects a context warning if the threshold is exceeded. |
| `silence-detector-ack.sh` | Stop (after each response) | Touches the heartbeat file (`/tmp/claude-heartbeat-$SESSION_ID`) to reset the silence timer. |
| `trust-flag-repair.sh` | Stop (after each response) | Auto-repairs trust flags in `~/.claude.json` across all projects. Prevents re-prompting on subsequent operations within a session. |

All hooks are idempotent and fail-safe — they exit silently on errors rather than interrupting the session.

---

## Config Files

| File | Location | Purpose |
|------|----------|---------|
| `CLAUDE.md` | Repo root (symlinked to `~/.claude/CLAUDE.md`) | Core instructions: worktree policy, PR workflow, branch naming, acceptance criteria, CI merge gate, autonomous workflow execution rules |
| `global-settings.json` | Copied to `~/.claude/settings.json` | Hooks, permissions (`allow: ["*"]` for autonomous operation), model preference (`opus`), experimental flags (`AGENT_TEAMS=1`) |
| `.coderabbit.yaml` | Repo root | CodeRabbit review config: assertive profile, token-efficiency checks for rule files, knowledge base integration |
| `.claude/pm-config.md` | Per-repo (bootstrapped by `/pm`) | PM configuration: role, OKRs, team roster, infrastructure/architecture detection, dependency rules, workflow rules |
| `~/.claude/session-state.json` | Runtime (auto-created) | Session orchestration state. **User-editable:** `greptile_daily.budget` (integer, default 40 — max Greptile reviews/day). **System-managed** (do not edit): PR phases, CR quota, active subagents. |

### `pm-config.md` sections

The PM config file is bootstrapped by `/pm` on first run and updated by `/pm-update`. It has two types of sections:

- **User-edited** (preserved across updates): Role, OKRs, Team, Notes, Dependency Rules, Workflow Rules
- **Auto-generated** (refreshed by `/pm-update`): Infrastructure, Architecture

---

## GitHub Actions

| Workflow | File | Purpose |
|----------|------|---------|
| CodeRabbit Plan on Issues | `cr-plan-on-issue.yml` | Auto-comments `@coderabbitai plan` on every new issue (skips bot-created issues). Produces an implementation plan with file recommendations and edge cases before any coding begins. |

---

## Architecture

### Symlink topology

```
~/.claude/
  CLAUDE.md          ->  <repo>/CLAUDE.md
  rules/             ->  <repo>/.claude/rules/
  settings.json         (copied from <repo>/global-settings.json)
  skills/
    pm/              ->  ~/.claude/skills-worktree/.claude/skills/pm/
    standup/         ->  ~/.claude/skills-worktree/.claude/skills/standup/
    ...              ->  ~/.claude/skills-worktree/.claude/skills/.../
  skills-worktree/      (git worktree pinned to main)
```

### Why a skills worktree?

Skills are symlinked through a dedicated worktree (`~/.claude/skills-worktree/`) rather than directly to the root repo. This decouples skill availability from the root repo's branch state. Without it, switching the root repo to a feature branch would make skills added after that branch invisible — their symlink targets wouldn't exist on that branch.

The `post-merge-pull.sh` hook auto-syncs the skills worktree after merges. The `setup-skills-worktree.sh` script handles initial setup and migration from old direct symlinks.

### Session lifecycle

1. **Session start** — Pull remote `main`, create a worktree, verify skills worktree exists, detect work-log directory, check for required GitHub Actions workflows
2. **Issue creation** — Draft issue, post via `gh issue create`, wait for CodeRabbit plan, merge plans into issue body
3. **Implementation** — Code on the worktree's feature branch
4. **Local review** — Run `coderabbit review --prompt-only` until two consecutive clean passes
5. **Push and PR** — Commit, push, create PR with `Closes #N` and Test Plan checkboxes
6. **GitHub review** — Poll CR (7-min timeout), fall back to Greptile if needed, fix findings, reply to threads
7. **Merge** — Verify merge gate (2 clean CR passes or Greptile severity gate), verify AC, squash merge
8. **Cleanup** — Delete branch, sync work-log, optionally remove worktree

### Multi-agent orchestration

For large tasks, work is decomposed into three sequential phases per PR:

| Phase | Scope | Token budget |
|-------|-------|-------------|
| **A: Fix + Push** | Read findings, fix code, commit, push, reply to threads, write handoff file | Heaviest |
| **B: Review Loop** | Poll for reviews, fix new findings, confirm merge gate | Medium |
| **C: Merge Prep** | Verify AC checkboxes, report ready for merge | Lightest |

The parent agent stays in **monitor mode** while subagents are active — polling status every ~60 seconds, sending heartbeats, and launching next-phase agents. Structured handoff files (`~/.claude/handoffs/pr-{N}-handoff.json`) transfer detailed state between phases.

---

## How the review loop works

### Phase 1: Local review (primary)

```
Finish coding on feature branch
       |
       v
Run coderabbit review --prompt-only
       |
       v
CR returns findings? --No--> Run review once more to confirm
       |                              |
      Yes                        Still clean?
       |                              |
       v                             Yes
Fix all valid findings               |
       |                              v
       v                    Local review loop done
Run coderabbit review again          |
       |                              v
       v                    Push branch & create PR
Repeat until clean                    |
                                      v
                            Enter Phase 2 (below)
```

### Phase 2: GitHub review (fallback)

```
PR created, CR auto-reviews on GitHub
       |
       v
Poll for CR comments (60s intervals, 7 min timeout)
       |
       v
CR posts findings? --No--> CR rate-limited?
       |                       |            |
      Yes                     Yes           No
       |                       |            |
       v                       v            v
Verify each finding    Check Greptile   Wait for CR
against code           daily budget     completion signal
       |                  |                  |
       v                  v                  v
Fix all findings    Budget OK?          2 clean CR passes?
in one commit,      Yes: @greptileai         |
push                No: self-review         Yes
       |                  |                  |
       v                  v                  v
Reply to every      Report blocker:     Merge gate met
comment thread      self-review only
       |
       v
Poll again...
repeat until
clean
```

---

## Key Design Decisions

**Worktrees by default.** Every session starts by creating a git worktree — an isolated working directory with its own branch. Multiple Claude Code agents can work on the same repo simultaneously without conflicts. The root repo stays clean on `main`.

**Local first, GitHub as safety net.** The CodeRabbit CLI runs reviews instantly in your terminal — no pushing, no polling, no PR noise. Claude fixes everything locally before the PR is ever created. GitHub-based review stays as a fallback.

**Batch fixes, single push.** Every push consumes a CodeRabbit review from your hourly quota. The config instructs Claude to fix all findings in one commit rather than pushing per-finding.

**Three-tier fallback chain.** CodeRabbit -> Greptile -> self-review. CR is always preferred. If rate-limited or unresponsive, Greptile is used if budget allows (40 reviews/day default cap). If both are unavailable, Claude performs self-review for risk reduction and reports a blocker. Self-review does **not** satisfy the merge gate.

**CI must pass before merge.** All CI check-runs are verified before any merge. Linter suppression comments (`eslint-disable`, `@ts-ignore`, etc.) are prohibited — fix the actual code instead.

**Verify before merge.** Claude won't offer to merge until it has read the source files and confirmed every acceptance criteria checkbox.

**Two consecutive clean reviews (CR path).** Both the local and GitHub loops require two consecutive clean passes. This catches the edge case where CodeRabbit marks a review complete but posts findings shortly after. The Greptile path uses a severity-gated merge gate instead — no P0 findings means merge-ready after one fix push.

**Every PR starts with an issue.** Issues go through CodeRabbit planning (`@coderabbitai plan`) that catches gaps before coding begins. The implementation plan is merged into the issue body as the canonical spec.

---

## Per-project override (optional)

The global config applies to all projects. To customize per repo, copy files into the project instead:

```bash
cp CLAUDE.md /path/to/your/project/CLAUDE.md
mkdir -p /path/to/your/project/.claude/rules
cp -R .claude/rules/. /path/to/your/project/.claude/rules/
```

Claude Code loads project-level `CLAUDE.md` first, then falls back to `~/.claude/CLAUDE.md`. Per-project configs let you override specific rules per repo.

> **Do not use project-level `.claude/settings.json` files for permissions.** They interfere with the global wildcard `allow: ["*"]` and cause more re-prompting, not less. See [Troubleshooting](#troubleshooting).

---

## FAQ

**Why does the config require worktrees?**
Without worktrees, all Claude Code sessions share a single working directory. If two agents work on the same repo, they overwrite each other's edits. Worktrees give each agent its own isolated directory and branch.

**What's the difference between local and GitHub reviews?**
Local reviews run the CodeRabbit CLI (`coderabbit review --prompt-only`) in your terminal. They're instant and don't consume your GitHub review quota. GitHub reviews happen after PR creation — CodeRabbit comments on the PR, and Claude polls the API to process findings.

**Do local reviews count against rate limits?**
No. Local CLI reviews are separate from GitHub PR reviews. The 8-reviews/hour limit only applies to GitHub-based reviews.

**Does this work with CodeRabbit's free tier?**
Yes. The rate limits in the config are tuned for Pro (8 reviews/hour, 50 chats/hour). Free tier limits are lower — you may want to increase polling timeouts.

**What happens when CodeRabbit is slow or down?**
The local review loop times out after 2 minutes. The GitHub loop times out after 7 minutes and falls back to Greptile (budget permitting). If both are unavailable, Claude runs a self-review and reports a merge-gate blocker.

**Can I use this without CodeRabbit?**
Yes. The config auto-detects CodeRabbit. Without it, Claude uses self-review as a fallback, and you still get the PR workflow, branch naming, acceptance criteria verification, and squash-merge flow. (Greptile is only triggered as a fallback when CodeRabbit is installed but rate-limited or unresponsive.)

**Can I use this without Greptile?**
Yes. Greptile is optional — it's only triggered when CodeRabbit is rate-limited or unresponsive. Without it, the fallback chain is CodeRabbit -> self-review.

**What is `pm-config.md` and do I need it?**
It's a per-repo config file bootstrapped by `/pm` on first run. It stores your team roster, OKRs, infrastructure, and architecture detection. You only need it if you use the PM skill family. Other skills and the review workflow work without it.

---

## Troubleshooting

### Claude Code keeps asking for permission even with bypass enabled

This is the most common issue. You've set `"allow": ["*"]` in `~/.claude/settings.json`, but Claude Code still prompts you to approve edits, bash commands, or the trust dialog. There are three independent causes — fix all that apply.

**Cause 1: A project-level `.claude/settings.json` exists in the repo.**

> **Do not use project-level `.claude/settings.json` files for permissions.** This repo previously shipped one and it caused *more* re-prompting, not less.

When a `.claude/settings.json` exists inside a repo (or worktree), Claude Code treats its permissions block as an **override** rather than merging it with `~/.claude/settings.json`. Even with `"allow": ["*"]` in both files, the project-level file's presence interferes with the global wildcard. Four other repos with no project-level settings file work fine on global settings alone — this repo was the only one that re-prompted, and removing the file fixed it.

Related issues: [anthropics/claude-code#17017](https://github.com/anthropics/claude-code/issues/17017), [anthropics/claude-code#13340](https://github.com/anthropics/claude-code/issues/13340), [anthropics/claude-code#27139](https://github.com/anthropics/claude-code/issues/27139).

**Fix:** Delete any `.claude/settings.json` from your repos and rely exclusively on the global settings file (`~/.claude/settings.json`). Use `global-settings.json` from this repo as your template.

```bash
# Find project-level settings files (use . from a repo root, or an absolute path)
find . -name "settings.json" -path "*/.claude/*" -not -path "*/.git/*"

# Inspect each file — if it only contains permissions, it's safe to delete.
# If it has hooks or env vars you want to keep, migrate those to ~/.claude/settings.json first.
find . -name "settings.json" -path "*/.claude/*" -not -path "*/.git/*" \
  -exec sh -c 'echo "== $1 =="; cat "$1"' _ {} \;

# After confirming the files only contain permissions:
find . -name "settings.json" -path "*/.claude/*" -not -path "*/.git/*" -delete
```

**Cause 2: Trust dialog flags reset on new worktrees.**

Every worktree creates a new project entry in `~/.claude.json` with `hasTrustDialogAccepted`, `hasClaudeMdExternalIncludesApproved`, and `hasClaudeMdExternalIncludesWarningShown` all set to `false`. This triggers the trust dialog and external includes approval prompts again.

**Fix:** Run this to set all flags to `true` across all projects:

```bash
python3 -c "
import json, os, sys

path = os.path.expanduser('~/.claude.json')
if not os.path.exists(path):
    print('~/.claude.json not found. Open Claude Code once, then rerun this fix.')
    sys.exit(1)
try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f'Invalid JSON in {path}: {e}')
    print('Repair or restore ~/.claude.json, then re-run this fix.')
    sys.exit(1)

projects = data.get('projects') or {}
if not isinstance(projects, dict):
    print('Invalid ~/.claude.json: \"projects\" must be an object.')
    sys.exit(1)

flags = ['hasTrustDialogAccepted', 'hasClaudeMdExternalIncludesApproved', 'hasClaudeMdExternalIncludesWarningShown']
total = 0
for proj in projects.values():
    if not isinstance(proj, dict): continue
    for flag in flags:
        if not proj.get(flag):
            proj[flag] = True
            total += 1

if total:
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f'Fixed {total} flag(s).')
else:
    print('All flags already set.')
"
```

You'll need to re-run this after creating new worktrees. See `.claude/rules/trust-dialog-fix.md` for more details and a single-project variant.

**Cause 3: Worktree-symlink topology (this repo only).**

> This cause is specific to `claude-code-config` itself. Other repos using worktrees are not affected.

This repo is the source of truth for global Claude Code config — `~/.claude/CLAUDE.md` and `~/.claude/rules` are symlinks pointing **into** this repo. When Claude Code runs in a worktree of this repo, the symlinks resolve to the root repo's files (e.g., `/Users/you/claude-code-config/CLAUDE.md`), which is **outside** the worktree directory (e.g., `/Users/you/claude-code-config/.claude/worktrees/my-worktree/`). Claude Code sees these as "external includes" and creates a new project entry in `~/.claude.json` with all trust flags set to `false`, triggering the trust dialog and external includes approval prompts.

Other repos don't have this problem because their worktrees only *consume* the global symlinks — there's no path collision. This repo is unique because the global symlinks point back *into* it.

Note: `--dangerously-skip-permissions` does **not** bypass trust dialogs — they are a separate security boundary.

**Upstream issues tracking this:**
- [anthropics/claude-code#34437](https://github.com/anthropics/claude-code/issues/34437) — Worktrees should share parent repo's project directory
- [anthropics/claude-code#23109](https://github.com/anthropics/claude-code/issues/23109) — Feature request: trusted workspace patterns
- [anthropics/claude-code#28506](https://github.com/anthropics/claude-code/issues/28506) — `--dangerously-skip-permissions` doesn't bypass workspace trust
- [anthropics/claude-code#9113](https://github.com/anthropics/claude-code/issues/9113) — Pre-configured `~/.claude.json` flags not respected

**Mitigation:** A `Stop` hook (`trust-flag-repair.sh`) automatically repairs all trust flags after every agent response. This prevents re-prompting on subsequent operations within a session, but cannot prevent the initial prompt when creating a brand-new worktree for the first time. For manual repair, use the script under Cause 2 above or see `.claude/rules/trust-dialog-fix.md`.

---

## Customizing

The config is plain Markdown. Edit to match your workflow:

- **Change branch naming** — Modify the `issue-N-short-description` pattern in CLAUDE.md.
- **Adjust polling intervals** — The 60-second interval and 7-minute timeout are in `cr-github-review.md`.
- **Adjust Greptile budget** — The 40 reviews/day default cap is in `greptile.md`. Change the `budget` field in `session-state.json`.
- **Restrict autonomy** — The rules allow Claude to fix all files autonomously. Add restrictions in `CLAUDE.md` if you want approval for certain paths.
- **Skip CodeRabbit** — The config auto-detects. No CodeRabbit = those sections are skipped.
- **Customize PM config** — Edit `.claude/pm-config.md` to set your team roster, OKRs, and workflow rules. User-edited sections are preserved across `/pm-update` runs.

## Contributing

Found an edge case or improvement? PRs welcome. This config evolved from real-world usage across multiple repos.

## License

MIT
