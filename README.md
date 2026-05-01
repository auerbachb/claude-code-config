# Claude Code Configuration

A reusable `CLAUDE.md` configuration that teaches [Claude Code](https://docs.anthropic.com/en/docs/claude-code) to collaborate with [CodeRabbit](https://coderabbit.ai), Cursor BugBot, [Greptile](https://greptile.com), CodeAnt, and Graphite AI Reviews for automated PR planning, code review, and merge workflows — all driven from your terminal. Includes a full PM skill family for project orchestration across threads.

## Table of Contents

- [What You Get](#what-you-get)
- [Getting Started](#getting-started)
- [Slash Commands](#slash-commands)
- [Rule Files](#rule-files)
- [Hook Scripts](#hook-scripts)
- [Scripts Library](#scripts-library)
- [Config Files](#config-files)
- [GitHub Actions](#github-actions)
- [Architecture](#architecture)
- [Per-Project Override](#per-project-override)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [Customizing](#customizing)
- [Contributing](#contributing)
- [License](#license)

---

## What You Get

After setup, Claude Code will automatically:

- **Plan before coding** — Triggers `@coderabbitai plan` on new issues, builds its own plan in parallel, then merges both into one implementation spec before writing any code.
- **Review locally, then on GitHub** — Runs CodeRabbit CLI reviews before pushing (instant feedback, no PR noise). After PR creation, the reviewer chain is CodeRabbit primary, BugBot (Cursor) second tier, Greptile last resort, then self-review only if every reviewer is unavailable; CodeAnt and Graphite AI Reviews provide supplemental AI review signals.
- **Verify and merge** — Checks every acceptance criteria checkbox against the code, confirms CI is green, then squash-merges with branch cleanup.
- **Orchestrate multi-agent work** — Decomposes large tasks into phases (fix, review, merge) with health monitoring, handoff files, and heartbeat enforcement.
- **Manage your project** — 22 slash commands for backlog prioritization, sprint planning, team metrics, standups, and cross-thread orchestration.

Review ownership is sticky once a fallback tier takes over:

| Reviewer | Tier | Role |
|----------|------|------|
| CodeRabbit | Primary | Local CLI review before push, then explicit GitHub approval on the current HEAD SHA |
| BugBot (Cursor) | Second tier | Free fallback when CodeRabbit is rate-limited or times out; clean BugBot pass can satisfy the merge gate |
| Greptile | Last resort | Paid fallback when both CodeRabbit and BugBot fail; severity-gated review path |
| CodeAnt | Supplemental | Additional AI code review signal on PRs; findings are handled alongside other review feedback |
| Graphite AI Reviews | Supplemental | Additional AI code review/check-run signal on PRs; failures or findings are treated as review/CI blockers |
| Self-review | Emergency only | Risk-reduction fallback when all reviewers are unavailable; does not satisfy the merge gate |

---

## Getting Started

### Prerequisites

| Tool | Install | Purpose |
|------|---------|---------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | `npm install -g @anthropic-ai/claude-code` | The CLI / desktop app itself |
| [GitHub CLI (`gh`)](https://cli.github.com/) | `brew install gh && gh auth login` | Issue/PR creation, API calls |
| [CodeRabbit](https://coderabbit.ai) | Install the GitHub App on your repos | AI code review on PRs |
| [CodeRabbit CLI](https://docs.coderabbit.ai/cli) | `curl -fsSL https://cli.coderabbit.ai/install.sh \| sh` | Local pre-push reviews |
| CodeAnt | Install the GitHub App on your repos | Supplemental AI code review on PRs |
| Graphite AI Reviews | Enable in Graphite for your repos | Supplemental AI review/check-run signal on PRs |
| [Graphite CLI](https://graphite.dev/docs/command-line) (`gt`) | `brew install withgraphite/tap/graphite` or `npm install -g @withgraphite/graphite-cli@stable` | Stacked PR workflow; required for the Graphite Claude Code plugins (`graphite`, `graphite-mcp`). MCP integration needs **v1.6.7+**. |

**Optional:** [Greptile](https://greptile.com) — AI code reviewer used as a fallback when CodeRabbit and BugBot are unavailable. Install the GitHub App and configure via the [Greptile dashboard](https://app.greptile.com).

### Install

> **Using an LLM to set this up?** See **[SETUP.md](SETUP.md)** — it has the same `bash ./setup.sh` command with LLM-friendly context.

**Step 1: Clone**

```bash
git clone https://github.com/auerbachb/claude-code-config.git
cd claude-code-config
```

Pick a permanent location — symlinks will point here.

**Step 2: Run the installer**

```bash
bash ./setup.sh
```

This single command handles everything:
1. Creates `~/.claude/skills/` directory
2. Merges settings from `global-settings.json` into `~/.claude/settings.json` (preserves existing keys), including the **Graphite plugin marketplace** and enabled plugins when those keys are missing locally
3. Optionally runs `gt repo init` in this checkout when Graphite CLI (`gt`) is installed, creating `.git/.graphite_repo_config` so the Graphite plugin can auto-detect this repo (skipped quietly if `gt` is missing; **setup fails** if `gt` is present but `gt repo init` fails)
4. Sets up the [skills worktree](#architecture) and symlinks (`CLAUDE.md`, rules, all skills)
5. Registers all hooks with correct paths
6. Installs the git pre-commit hook that blocks root-`main` commits
7. Verifies the installation and prints a pass/fail summary

The script is idempotent — safe to re-run at any time.

After upgrading or first enabling plugins, run **`/reload-plugins`** once inside Claude Code so the Graphite skills and MCP load.

### Graphite CLI + Claude Code plugins (optional)

`global-settings.json` seeds **`extraKnownMarketplaces`** (the [claude-code-graphite](https://github.com/georgeguimaraes/claude-code-graphite) catalog) and **`enabledPlugins`** for `graphite` and `graphite-mcp`. That matches [Anthropic’s team-marketplace pattern](https://code.claude.com/docs/en/discover-plugins#configure-team-marketplaces): Claude Code can **discover** those marketplaces/plugins and **prompt** you to install them after you trust the folder—**explicit consent** is required, and you may still need `/plugin marketplace add` manually if you skip the prompt or in setups where prompting is unreliable. Once installed to your scope, **`enabledPlugins`** from merged settings can enable the extensions without re-running marketplace commands every time.

**Per-repo marker (not committed):** The Graphite plugin detects repos via **`.git/.graphite_repo_config`**. Run **`gt repo init`** in each clone where you want stacked-PR context, or:

```bash
bash /path/to/claude-code-config/.claude/scripts/graphite-repo-init.sh /path/to/other-repo
```

**Opt-out:** Remove or set `enabledPlugins` entries to `false` in `~/.claude/settings.json`, or disable the plugins under `/plugin` → Installed. Omitting Graphite CLI does not break this config — hooks and skills behave as before.

**Step 3: Verify**

```bash
ls -la ~/.claude/CLAUDE.md     # -> ~/.claude/skills-worktree/CLAUDE.md
ls -la ~/.claude/rules         # -> ~/.claude/skills-worktree/.claude/rules
ls -la ~/.claude/skills/       # each skill -> ~/.claude/skills-worktree/.claude/skills/<name>
```

### Set up CodeRabbit for a repo (per-repo)

1. Install CodeRabbit on the repo (via GitHub App settings)
2. Optionally add a `.coderabbit.yaml` to the repo root for custom review rules
3. The config auto-detects whether CodeRabbit is installed — without it, those sections are skipped

---

## Slash Commands

All 22 commands are invoked as `/command` in a Claude Code session. They are defined as skill files in `.claude/skills/` and symlinked globally.

| Command | Category | Description |
|---------|----------|-------------|
| `/pm` | PM | Active PM orchestrator — manage backlog, track threads, suggest next work |
| `/pm-handoff` | PM | Generate a self-contained handoff prompt for a new PM thread |
| `/pm-update` | PM | Re-scan repo, refresh `pm-config.md`, then run stale worktree/branch cleanup |
| `/pm-okr` | PM | View, set, or suggest OKRs |
| `/pm-clean` | PM | Detect stale issues and suggest closures |
| `/prioritize` | PM | Rank backlog issues by business goal impact (OKR-aware) |
| `/pm-team-standup` | PM | Per-contributor activity summary (past 24h) |
| `/pm-rate-team` | PM | Contribution metrics over a configurable period |
| `/pm-sprint-plan` | PM | Generate a 2-week sprint plan |
| `/pm-sprint-review` | PM | Sprint retrospective with velocity metrics |
| `/subagent` | PM | Run Quick/Light issues as Phase A/B/C subagents from a PM thread |
| `/prompt` | Planning | Classify issue complexity, recommend a Claude 4.7/4.6 model tier, generate copy-paste prompt without the removed `effort` field |
| `/start-issue` | Planning | End-to-end issue-to-coding setup — plan polling, plan merge, worktree, branch |
| `/fixpr` | Review | Single-pass PR cleanup — fixes review findings and CI failures, replies to findings, resolves threads |
| `/pr-review-help` | Review | Executive PR review — multi-PR parallel strategic analysis |
| `/standup` | Workflow | Daily standup summary (single contributor) |
| `/status` | Workflow | Dashboard of open PRs with review state |
| `/continue` | Workflow | Resume an interrupted review workflow |
| `/merge` | Workflow | Squash merge with merge gate + AC verification |
| `/wrap` | Workflow | End-of-session: verify, squash merge, aggressively reset root `main`, detect follow-ups, extract lessons |
| `/check-acceptance-criteria` | Workflow | Verify Test Plan checkboxes against code |
| `/lessons` | Workflow | Extract and save session learnings to memory |

Run `/pm` first to bootstrap the PM config, then use the other PM skills as needed. Workflow commands (`/merge`, `/wrap`, `/continue`, etc.) work independently.

---

## Rule Files

Rule files in `.claude/rules/` auto-load alongside `CLAUDE.md` and define the detailed workflows:

| File | Purpose |
|------|---------|
| `issue-planning.md` | Issue creation flow, `@coderabbitai plan` integration, plan merging |
| `cr-local-review.md` | Primary review loop — runs CodeRabbit CLI locally before pushing |
| `cr-github-review.md` | GitHub review polling — three endpoints, rate limits, BugBot fallback, CI checks, thread resolution |
| `cr-merge-gate.md` | Single authoritative merge gate — CR approval or clean BugBot/Greptile path, CI, resolved threads, AC verification |
| `bugbot.md` | BugBot second-tier reviewer — polling, timeout, sticky assignment, merge gate contribution |
| `greptile.md` | Greptile last-resort reviewer — severity-gated re-reviews, daily budget, self-review fallback |
| `scheduling-reliability.md` | Reliable recurring polls — `/loop` requirement, cron escalation, no hand-rolled wakeup chains |
| `subagent-orchestration.md` | Subagent spawning, phase transition autonomy, token exhaustion, phase A/B/C decomposition |
| `monitor-mode.md` | Dedicated monitor mode, monitor loop, heartbeats during batch writes, health monitoring, post-compaction recovery |
| `handoff-files.md` | Handoff file schema, session-state.json format, lifecycle (create/update/delete) |
| `phase-protocols.md` | Structured exit report format, Phase A/B/C completion protocol checklists |
| `safety.md` | Destructive command prohibitions, expanded `.env` protection, subagent safety warnings |
| `main-hygiene.md` | Dirty-main guard, quarantine recovery branches, session-start sync contract |
| `repo-bootstrap.md` | Auto-provision required GitHub Actions workflows on first touch; check `main` branch protection and prompt to enable required status checks if missing |
| `trust-dialog-fix.md` | Fix trust dialog re-prompting when bypass permissions are enabled |
| `skill-symlinks.md` | Symlink new skills globally via the skills worktree after creation |

---

## Hook Scripts

Thirteen hook scripts and hook utilities support Claude Code sessions:

| Script | Event | Purpose |
|--------|-------|---------|
| `session-start-sync.sh` | PostToolUse (first call) | Syncs skills worktree to `origin/main`, auto-registers new hooks from `global-settings.json` |
| `post-merge-pull.sh` | PostToolUse (Bash) | Pulls `main` after `gh pr merge`, syncs skills worktree |
| `worktree-guard.sh` | PreToolUse (Write/Edit/NotebookEdit) | Blocks file edits in `claude-code-config` repo when root is on `main` |
| `env-guard.py` | PreToolUse (Write/Edit/MultiEdit/NotebookEdit/Bash) | Blocks edits and shell writes to `.env` files that may contain secrets |
| `timestamp-injector.sh` | UserPromptSubmit | Injects real system-clock Eastern timestamp context to prevent hallucinated dates |
| `issue-prefix-nudge.sh` | UserPromptSubmit | On the first user message of a session only, nudges when the prompt lacks a leading `[#N]` issue prefix (see CLAUDE.md) |
| `silence-detector.sh` | PostToolUse (all) | Warns if agent has been silent >5 minutes |
| `silence-detector-ack.sh` | Stop | Resets the silence timer after each response |
| `trust-flag-repair.sh` | Stop | Repairs trust flags in `~/.claude.json` for all projects |
| `dirty-main-warn.sh` | Stop | Warns when root `main` has uncommitted drift and points to quarantine recovery |
| `skill-usage-tracker.sh` | PostToolUse (Skill) | Appends each Skill invocation to `~/.claude/skill-usage.log` and updates `~/.claude/skill-usage.csv` for PM and maintenance audits |
| `register-hooks.py` | Utility | Merges hook definitions from `global-settings.json` into user settings |
| `.claude/git-hooks/pre-commit` | Git pre-commit | Blocks commits made on `main` in the root checkout |

All hooks are idempotent and fail-safe.

**Auto-registration:** Hooks are defined in `global-settings.json` with placeholder paths (e.g., `/path/to/claude-code-config/.claude/hooks/session-start-sync.sh`). At install time, `setup-skills-worktree.sh` resolves these to the skills worktree and registers them in `~/.claude/settings.json`. At each session start, `session-start-sync.sh` checks for new hooks added to the repo and registers them automatically — no manual setup needed after the initial install. See [ARCHITECTURE.md](ARCHITECTURE.md#hook-auto-registration) for details.

---

## Scripts Library

Shared helpers in `.claude/scripts/` are used by skills, hooks, and review subagents for repeatable GitHub, git, and PM workflow operations.

| Script | Purpose |
|--------|---------|
| `repo-root.sh` | Resolve the root repo path from a worktree or nested directory |
| `merge-gate.sh` | Verify reviewer ownership, review gate, CI, merge state, and unresolved thread blockers |
| `pr-state.sh` | Gather PR state: review threads, comments, CI, commit statuses, merge metadata |
| `ci-status.sh` | Summarize check-runs/statuses for a PR or SHA |
| `ac-checkboxes.sh` | Extract and update PR Test Plan checkboxes |
| `greptile-budget.sh` | Track and guard Greptile daily review budget |
| `pm-config-get.sh` | Parse named sections from `.claude/pm-config.md` |
| `resolve-review-threads.sh` | Resolve review threads via GraphQL, with minimize fallback |
| `gh-window.sh` | Build GitHub search date windows |
| `cr-plan.sh` | Find or poll for CodeRabbit implementation-plan comments on issues |
| `cycle-count.sh` | Reconstruct review/fix cycle counts for PR metrics |
| `reply-thread.sh` | Reply to CodeRabbit, BugBot, or Greptile review comments with the right fallback path |
| `reviewer-of.sh` | Detect which reviewer currently owns a PR |
| `hhg-state.sh` | Detect HHG state codes for domain-specific workflows |
| `session-state.sh` | Surgically read/update `~/.claude/session-state.json` |
| `repo-bootstrap.sh` | Check or install required repo bootstrap assets |
| `off-peak-minute.sh` | Choose deterministic off-peak cron minutes |
| `workday.sh` | Calculate workday/holiday windows for PM reports |
| `pr-issue-ref.sh` | Extract the linked issue reference from a PR |
| `main-sync.sh` | Sync root `main`, with guarded aggressive reset support for `/wrap` |
| `stale-cleanup.sh` | Sweep stale worktrees and local/remote branches, owned by `/pm-update` |
| `dirty-main-guard.sh` | Detect dirty root `main` state and quarantine it to a recovery branch |
| `repair-worktrees.sh` | Diagnose and optionally remove stale git worktrees |
| `repair-trust-single.sh` | Repair Claude trust flags for one project path |
| `repair-trust-all.sh` | Repair Claude trust flags for all known projects |
| `audit-skill-usage.sh` | Legacy monthly audit against `.claude/data/skill-usage.json` |
| `skill-usage-report.sh` | Markdown rollup from `~/.claude/skill-usage.log` (dead-skill candidates; issue #416) |

See `.claude/scripts/README.md` for detailed contracts, arguments, and exit codes for the most commonly shared helpers.

---

## Config Files

| File | Location | Purpose |
|------|----------|---------|
| `CLAUDE.md` | Repo root (symlinked to `~/.claude/`) | Core instructions: worktree policy, PR workflow, branch naming, acceptance criteria, CI merge gate |
| `global-settings.json` | Merged into `~/.claude/settings.json` | Hooks, permissions (`allow` rules for autonomous operation), model preference, experimental flags, and optional **`extraKnownMarketplaces` / `enabledPlugins`** (Graphite CLI plugins when seeded) |
| `.coderabbit.yaml` | Repo root | CodeRabbit review config: assertive profile, token-efficiency checks, knowledge base integration |
| `.claude/pm-config.md` | Per-repo (bootstrapped by `/pm`) | PM config: role, OKRs, team roster, infrastructure/architecture detection |
| `~/.claude/session-state.json` | Runtime (auto-created) | Session orchestration state: PR phases, **CR hourly consumption** (`cr_hourly.events`), per-PR `cr_explicit_triggers`, active subagents, Greptile daily budget |

---

## GitHub Actions

| Workflow | File | Purpose |
|----------|------|---------|
| CodeRabbit Plan on Issues | `cr-plan-on-issue.yml` | Auto-comments `@coderabbitai plan` on new issues (skips bot-created). Produces implementation plans before coding begins. |

---

## Architecture

`CLAUDE.md`, rules, and all skills are served through a **skills worktree** (`~/.claude/skills-worktree/`) — a git worktree pinned to `main` that decouples config availability from the root repo's branch state. These symlinked assets stay available regardless of what branch the root repo is on.

The `session-start-sync.sh` hook keeps the worktree in sync with `origin/main` at the start of each session. New hooks added to `global-settings.json` are auto-registered without re-running setup.

For the full architecture reference — symlink topology, hook lifecycle, session lifecycle, multi-agent orchestration, review loop flowcharts, and design decisions — see **[ARCHITECTURE.md](ARCHITECTURE.md)**.

---

## Per-Project Override

The global config applies to all projects. To customize per repo, copy files into the project:

```bash
cp CLAUDE.md /path/to/your/project/CLAUDE.md
mkdir -p /path/to/your/project/.claude/rules
cp -R .claude/rules/. /path/to/your/project/.claude/rules/
```

Claude Code loads project-level `CLAUDE.md` first, then falls back to `~/.claude/CLAUDE.md`. The same precedence applies to `.claude/rules/*.md`.

> **Do not use project-level `.claude/settings.json` files for permissions.** They interfere with the global wildcard and cause more re-prompting, not less. See [Troubleshooting](#troubleshooting).

---

## FAQ

**Why does the config require worktrees?**
Without worktrees, all Claude Code sessions share a single working directory. If two agents work on the same repo, they overwrite each other's edits. Worktrees give each agent its own isolated directory and branch.

**What's the difference between local and GitHub reviews?**
Local reviews run the CodeRabbit CLI in your terminal — instant, no PR noise, no quota cost. GitHub reviews happen after PR creation. CodeRabbit is the primary merge-gate reviewer, BugBot and Greptile are fallbacks, and CodeAnt plus Graphite AI Reviews add supplemental PR review signals.

**Does this work with CodeRabbit's free tier?**
Yes. Rate limits in the config are tuned for Pro. Free tier limits are lower — you may want to increase polling timeouts.

**What happens when CodeRabbit is slow or down?**
Local review times out after 2 minutes. GitHub review polling follows the sticky chain: CodeRabbit first, BugBot after CodeRabbit rate-limit/timeout, Greptile after BugBot timeout, then self-review only if all reviewers are unavailable. A self-review reduces risk but does not satisfy the merge gate.

**Can I use this without CodeRabbit / BugBot / Greptile?**
Yes. The config auto-detects reviewer availability. If CodeRabbit is unavailable, Claude uses the next available reviewer tier: BugBot first, then Greptile if needed. Greptile remains optional. The PR workflow, branch naming, acceptance criteria, and squash-merge flow work regardless.

**What is `pm-config.md`?**
A per-repo config bootstrapped by `/pm`. Stores team roster, OKRs, and infrastructure detection. Only needed for PM skills — the review workflow works without it.

---

## Troubleshooting

### Claude Code keeps asking for permission even with bypass enabled

Three independent causes — fix all that apply.

**Cause 1: A project-level `.claude/settings.json` exists in the repo.**

Project-level settings files override (not merge with) global settings. Even with `"allow": ["*"]` in both, the project file's presence interferes.

**Fix:** Delete project-level settings files and rely on `~/.claude/settings.json`:

```bash
find . -name "settings.json" -path "*/.claude/*" -not -path "*/.git/*" -delete
```

Related: [anthropics/claude-code#17017](https://github.com/anthropics/claude-code/issues/17017), [#13340](https://github.com/anthropics/claude-code/issues/13340), [#27139](https://github.com/anthropics/claude-code/issues/27139).

**Cause 2: Trust dialog flags reset on new worktrees.**

Every worktree creates a new project entry in `~/.claude.json` with trust flags set to `false`.

**Fix:** The `trust-flag-repair.sh` hook auto-repairs flags after every response. For manual repair:

```bash
python3 -c "
import json, os
path = os.path.expanduser('~/.claude.json')
with open(path) as f: data = json.load(f)
flags = ['hasTrustDialogAccepted', 'hasClaudeMdExternalIncludesApproved', 'hasClaudeMdExternalIncludesWarningShown']
total = 0
for proj in data.get('projects', {}).values():
    if not isinstance(proj, dict): continue
    for flag in flags:
        if not proj.get(flag): proj[flag] = True; total += 1
if total:
    with open(path, 'w') as f: json.dump(data, f, indent=2)
    print(f'Fixed {total} flag(s).')
else: print('All flags already set.')
"
```

**Cause 3: Worktree-symlink topology (this repo only).**

This repo's global symlinks point back into itself, so worktrees see them as "external includes." The `trust-flag-repair.sh` hook mitigates this after the first response. See `.claude/rules/trust-dialog-fix.md` for full details.

Upstream issues: [#34437](https://github.com/anthropics/claude-code/issues/34437), [#23109](https://github.com/anthropics/claude-code/issues/23109), [#28506](https://github.com/anthropics/claude-code/issues/28506), [#9113](https://github.com/anthropics/claude-code/issues/9113).

---

## Customizing

The config is plain Markdown. Edit to match your workflow:

- **Change branch naming** — Modify the `issue-N-short-description` pattern in `CLAUDE.md`
- **Adjust polling intervals** — The 60-second interval and reviewer timeouts are in `cr-github-review.md`, `bugbot.md`, and `greptile.md`
- **Adjust Greptile budget** — Change the `budget` field in `session-state.json` (default: 40/day)
- **Restrict autonomy** — Add restrictions in `CLAUDE.md` for certain paths
- **Customize PM config** — Edit `.claude/pm-config.md` for team roster, OKRs, workflow rules

## Contributing

Found an edge case or improvement? PRs welcome. This config evolved from real-world usage across multiple repos.

## License

MIT
