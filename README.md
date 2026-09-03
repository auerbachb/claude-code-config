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
- [Documentation map](#documentation-map)
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
- **Manage your project** — 38 slash commands for backlog prioritization, OKR tracking, daily standups, PR-fleet monitoring, and cross-thread orchestration.

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
| [CodeRabbit CLI](https://docs.coderabbit.ai/cli) | `brew install coderabbit` (macOS) or `curl -fsSL https://cli.coderabbit.ai/install.sh \| sh`; then `coderabbit auth login` (see [SETUP.md](SETUP.md) for the `$CODERABBIT_API_KEY` non-interactive option) | Local pre-push reviews |
| CodeAnt | Install the GitHub App on your repos | Supplemental AI code review on PRs |
| [CodeAnt CLI](https://docs.codeant.ai/cli/setup.md) | `npm install -g codeant-cli` (Node.js required); auth via `codeant login` | Local pre-push reviews |
| Graphite AI Reviews | Enable in Graphite for your repos | Supplemental AI review/check-run signal on PRs |
| [Graphite CLI](https://graphite.dev/docs/command-line) (`gt`) | `brew install withgraphite/tap/graphite` or `npm install -g @withgraphite/graphite-cli@stable` | Stacked PR workflow; required for the Graphite Claude Code plugins (`graphite`, `graphite-mcp`). MCP integration needs **v1.6.7+**. |

**Optional:** [Greptile](https://greptile.com) — AI code reviewer used as a fallback when CodeRabbit and BugBot are unavailable. Install the GitHub App and configure via the [Greptile dashboard](https://app.greptile.com).

> **Account identity:** during setup, Claude must explicitly ask which email/account to use for git identity and for each CLI tool it authenticates (GitHub CLI, CodeRabbit, CodeAnt today — the checklist is extensible) — never assume one. See [SETUP.md — Account identity](SETUP.md#account-identity--ask-never-assume) for the checklist and where each credential is stored.

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

All 38 commands are invoked as `/command` in a Claude Code session. They are defined as skill files in `.claude/skills/` and symlinked globally.

| Command | Category | Description |
|---------|----------|-------------|
| `/pm` | PM | Active PM orchestrator — rank the backlog by business-goal impact (OKR-aware), track threads, suggest next work |
| `/pm-handoff` | PM | Generate a self-contained handoff prompt for a new PM thread |
| `/pm-update` | PM | Re-scan repo, refresh `pm-config.md`, then run stale worktree/branch cleanup |
| `/pm-okr` | PM | View, set, or suggest OKRs |
| `/pm-clean` | PM | Detect stale issues and suggest closures |
| `/pm-forgotten-pr` | PM | One-shot triage of open PRs idle above a threshold — classify as close or merge, render a Forgotten PRs block, dispatch confirmed merges |
| `/subagent` | PM | Run Quick/Light issues as Phase A/B/C subagents from a PM thread |
| `/wave` | PM | Offer the largest dependency- and overlap-free set of backlog issues as click-to-launch chips, capped at the concurrent-pipeline ceiling |
| `/board` | PM | Render the canonical "Running now" table on demand in any orchestration thread — the current round's phases, recorded starts, projected ends, and remaining time, recomputed live from durable state. Complete from the dispatching thread; any other thread renders no queued rows at all and labels the delivered count approximate, since round membership is not yet durable. Changes no pipeline, writing only the shared table-render timestamp |
| `/subagent-dispatch` | PM | Teach the craft of writing independent parallel-agent prompts — decision tree for when to parallelize, context-isolation guidance, and exit-verification steps |
| `/prompt` | Planning | Classify issue complexity, recommend a Claude 4.7/4.6 model tier, generate copy-paste prompt without the removed `effort` field |
| `/start-issue` | Planning | End-to-end issue-to-coding setup — plan polling, plan merge, worktree, branch |
| `/issue-maker` | Planning | Capture-only thread mode — drafts and opens well-structured issues, reflects before writing, no implementation |
| `/fixpr` | Review | Single-pass PR cleanup — fixes review findings and CI failures, replies to findings, resolves threads |
| `/monitor` | Review | Audit all open PRs for engagement from the 4 AI reviewers (CodeRabbit/CodeAnt/BugBot/Graphite); render a gap matrix and post missing triggers after confirmation |
| `/babysit-pr` | Review | Watch one PR on a persistent Monitor and auto-dispatch `/fixpr` or `/wrap` until it merges or hard-blocks |
| `/babysit-pr-stop` | Review | Clean-cancel companion to `/babysit-pr` — stops the watcher for one PR |
| `/pr-monitor-and-manage` | Review | PR fleet manager — rediscover open PRs each tick and drive the per-PR decision tree until the fleet is clean |
| `/pr-monitor-and-manage-stop` | Review | Clean-cancel companion to `/pr-monitor-and-manage` — tears down the fleet Monitor and its state |
| `/pr-monitor-and-manage-wake` | Review | Resume companion to `/pr-monitor-and-manage` — wakes a paused fleet monitor and re-arms it |
| `/pr-review-help` | Review | Executive PR review — multi-PR parallel strategic analysis |
| `/receiving-code-review` | Review | Judgment layer for evaluating bot review findings before implementing — six-step READ→UNDERSTAND→VERIFY→EVALUATE→RESPOND→IMPLEMENT pattern with rationalization table and decline discipline |
| `/recap` | Workflow | Functional summary of a single PR or issue — nested bullets or table |
| `/standup` | Workflow | Daily standup summary (single contributor) |
| `/status` | Workflow | Dashboard of open PRs with review state |
| `/harness-audit` | Workflow | Monthly check of whether the harness now does natively what our rules, skills, scripts, and hooks do by hand — verdicts each artifact against live harness behavior and files issues; advisory only, never edits |
| `/review-stack-audit` | Workflow | Monthly re-measure of the AI review stack — each tool's billed state, observed caps, throughput, and unique value, compared against the recorded baseline; files one issue per drift finding, advisory only, never edits |
| `/memory-clean` | Workflow | Audit the durable memory store — report orphaned files, dangling index pointers, index size, advisory stale entries; prune only on confirmation |
| `/go-on` | Workflow | Universal resume — classify the stoppage from recorded evidence (`/pause`, `/end`, token-exhaustion handoff, crash, stalled review loop) and continue from the right place; refill stays paused without `--resume-refill` |
| `/merge-conflict` | Workflow | Classify merge/rebase conflicts against `main`, auto-resolve safe hunks, report complex ones (also dispatched from `/fixpr`) |
| `/merge` | Workflow | Squash merge with merge gate + AC verification |
| `/admin-merge` | Workflow | Merge a solo-owner PR blocked by branch protection — auto-runs the no-protection-change plain shape, prints the `enforce_admins` toggle shape for the user (Claude never modifies branch protection) |
| `/wrap` | Workflow | End-of-session: verify, squash merge, aggressively reset root `main`, detect follow-ups, extract lessons |
| `/end` | Workflow | Long-horizon token/credit stop with a 5-minute default checkpoint window: blocks launches, stops owned current-session background tasks, and attempts to atomically publish a canonical cross-agent handoff with exact worktree/recovery state; publication failures preserve a recovery draft |
| `/end-resume` | Workflow | Explicitly reopen work stopped by `/end`; optionally clear the independent refill pause with `--resume-refill` |
| `/pause` | Workflow | Short-break or laptop-close pause with a 15-minute default runway: land safe work, park recovery state, and hard-stop every owned background task |
| `/pause-resume` | Workflow | Restore the paused board, explicitly reopen launches, and re-arm selected stopped work without duplicating live tasks |
| `/leave-by` | Workflow | Say once when you have to stop ("I need to leave at 7 PM") — arms that time as the repo's planning deadline so dispatch declines pipelines that cannot finish before it, then checks in unprompted at a configurable lead (default 30 min, `--lead Nm`) and winds down through `/pause`, so everything is merged or resumable by the time you go |

Run `/pm` first to bootstrap the PM config, then use the other PM skills as needed. Workflow commands (`/merge`, `/wrap`, `/go-on`, etc.) work independently.

---

## Rule Files

Rule files in `.claude/rules/` auto-load alongside `CLAUDE.md` and define the detailed workflows. Each file's own header block states its scope.

The canonical rule index — grouped by area (Issues & planning, Review & merge, Orchestration, Safety & hygiene) — lives in **[CLAUDE.md §Rule Files](CLAUDE.md#rule-files-clauderules)** and is kept in sync by `rule-lint.sh`.

---

## Hook Scripts

Hook scripts in `.claude/hooks/` automate Claude Code session lifecycle events. All hooks are idempotent and fail-safe.

Hooks auto-register on every session start — no manual setup needed after the initial install.

For the full per-hook manifest (script name, event, purpose) and auto-registration mechanics see **[.claude/hooks/README.md](.claude/hooks/README.md)**. For the hook event sequence see **[ARCHITECTURE.md §Hook Lifecycle](ARCHITECTURE.md#hook-lifecycle)** and **[ARCHITECTURE.md §Hook Auto-Registration](ARCHITECTURE.md#hook-auto-registration)**.

---

## Scripts Library

Shared helpers in `.claude/scripts/` are used by skills, hooks, and review subagents for repeatable GitHub, git, and PM workflow operations.

See **[.claude/scripts/README.md](.claude/scripts/README.md)** for the script catalog — a category index linking one doc per category under [.claude/scripts/docs/](.claude/scripts/docs/), each carrying a one-sentence purpose per script. For full contracts, arguments, and exit codes run the script with `--help` or read the script header.

---

## Config Files

| File | Location | Purpose |
|------|----------|---------|
| `CLAUDE.md` | Repo root (symlinked to `~/.claude/`) | Core instructions: worktree policy, PR workflow, branch naming, acceptance criteria, CI merge gate |
| `global-settings.json` | Merged into `~/.claude/settings.json` | Hooks, the **`statusLine`** command (ET time · branch · agents · watchers — see [ARCHITECTURE.md](ARCHITECTURE.md#status-line)), permissions (`allow` rules for autonomous operation), model preference, experimental flags, and optional **`extraKnownMarketplaces` / `enabledPlugins`** (Graphite CLI plugins when seeded) |
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

Mermaid diagram stubs (skills worktree, review pipeline, hook sequence) live under [.claude/reference/diagrams/](.claude/reference/diagrams/) and are filled in alongside doc updates.

---

## Documentation map

Long-form material is split so **rules + `CLAUDE.md` stay token-efficient** (see the word-budget section in `CLAUDE.md`). Use this table to find the right doc.

| Path | Audience | Auto-loaded? |
|------|----------|----------------|
| [README.md](README.md) (this file) | New users, operators | No |
| [SETUP.md](SETUP.md) | Installers, LLM-guided setup | No |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Anyone debugging symlinks, hooks, worktrees | No |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contributors | No |
| [CLAUDE.md](CLAUDE.md) | Every Claude Code session (global symlink) | **Yes** (with project `CLAUDE.md` taking precedence when present) |
| [.claude/rules/](.claude/rules/) | Session workflows | **Yes** — each `*.md` alongside `CLAUDE.md` |
| [.claude/skills/](.claude/skills/) | Slash-command procedures | On skill invocation |
| [.claude/agents/](.claude/agents/) | Subagent definitions | On Agent tool spawn |
| [.claude/reference/](.claude/reference/) | Schemas, long `gh` recipes, audits | **No** — on-demand only |
| [.claude/scripts/README.md](.claude/scripts/README.md) | Script contracts | No |

**Audits and research** (reference, not rules): [ai-review-tool-audit-2026-04.md](.claude/reference/ai-review-tool-audit-2026-04.md), [repo-audit-2026-05.md](.claude/reference/repo-audit-2026-05.md), [graphite-stacked-prs-research-2026-05.md](.claude/reference/graphite-stacked-prs-research-2026-05.md).

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
Without worktrees, all Claude Code sessions share a single working directory. If two agents work on the same repo, they overwrite each other's edits. Worktrees give each agent its own isolated directory and branch. See [ARCHITECTURE.md §Skills Worktree](ARCHITECTURE.md#skills-worktree) for the full rationale.

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
