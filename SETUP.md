# Setup — Claude Code Configuration

This repository configures [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with automated PR workflows, code review integration, and project management skills.

> **Trust notice:** `setup.sh` creates symlinks in `~/.claude/` and merges settings into `settings.json`. Review `setup.sh` before running if you want to understand what it does. It is idempotent — safe to run multiple times.

## Install

From the root of this cloned repository, run:

```bash
bash ./setup.sh
```

The script handles everything: directory creation, symlinks, settings merge, hook registration, and skills worktree setup. It prints a pass/fail summary on completion.

**Do not manually run the individual steps from README.md.** The `setup.sh` script is the single source of truth for installation. The README documents what each step does for reference, but `setup.sh` is the canonical installer.

## Account identity — ask, never assume

Machine setup wires several accounts together. **Claude must ask the user which email/account to use for each of these — never infer one from the Claude account, shell environment, or hostname.** (Motivating incident: a new-machine setup reused the Claude account email for git identity; GitHub couldn't link the commits, and CodeAnt refused PR reviews keyed to that email.)

### 1. Git commit identity

Ask the user for the email to use in `git config --global user.email`. If their GitHub account has email privacy enabled (GitHub Settings → Emails → "Keep my email addresses private"), recommend the **noreply form**: `<id>+<username>@users.noreply.github.com`.

### 2. Per-tool account confirmation

Before running each tool's auth command, confirm with the user which account (email) holds that tool's subscription — a browser OAuth flow will otherwise silently bind whatever account happens to be signed in:

| Tool | Auth command | Confirm with the user |
|------|--------------|-----------------------|
| GitHub CLI (`gh`) | `gh auth login` | the GitHub account that owns your repos |
| CodeRabbit CLI | `coderabbit auth login` | account holding the CodeRabbit seat |
| CodeAnt CLI | `codeant login` | account holding the CodeAnt subscription |

The CodeRabbit and CodeAnt **GitHub Apps** must be installed on the personal account or organization that hosts the target repositories. The CLI login account does not need to match the App installation — it needs to hold that vendor's subscription/seat, and `gh auth login` simply needs access to the repos.

**Future tools follow the same pattern:** add a row here and ask before authenticating.

### 3. Where this is stored (inspect any time)

Default locations (may vary with your setup):

| What | Where |
|------|-------|
| Git identity | `~/.gitconfig` (or XDG: `~/.config/git/config`) — view with `git config --global user.email` |
| CodeAnt CLI key | `~/.codeant/config.json` (written by `codeant login`) |
| CodeRabbit CLI auth | `~/.coderabbit/` — inspect with `coderabbit auth status` |
| Optional CodeRabbit API key | `CODERABBIT_API_KEY` in your shell init file (e.g. `~/.zshrc`) — never commit or print it |

## What It Does

> Steps below are the logical workflow — see `setup.sh` for exact step numbering in script output.

1. Creates the `~/.claude/skills/` directory
2. Merges non-hook settings from `global-settings.json` into `~/.claude/settings.json` (existing keys like `permissions`, `model`, `env` are preserved — only missing keys are seeded), including optional Graphite plugin marketplace and `enabledPlugins` when absent. **New sub-keys** (like `permissions.deny`) are seeded on first encounter — they do NOT propagate automatically on subsequent runs, only on a fresh re-run of `bash ./setup.sh` when the sub-key is absent. `statusLine` is skipped here alongside `hooks`: both carry path placeholders that only the skills-worktree registration in step 5 can resolve
3. Optionally runs `gt repo init` for this checkout when Graphite CLI is installed (creates `.git/.graphite_repo_config`; setup fails if `gt repo init` fails when `gt` is installed)
4. Verifies all hook scripts exist and are executable
5. Runs `setup-skills-worktree.sh` which:
   - Creates a dedicated skills worktree and skill symlinks
   - Registers all hooks into `~/.claude/settings.json` with paths pointing to the skills worktree (migrates stale root-repo or placeholder paths automatically)
   - Resolves the `statusLine` command the same way (your own status line, if you have one, is left untouched)
6. Symlinks `~/.claude/CLAUDE.md` → skills worktree (`~/.claude/skills-worktree/CLAUDE.md`)
7. Symlinks `~/.claude/rules` → skills worktree (`~/.claude/skills-worktree/.claude/rules`)
8. Symlinks each `~/.claude/agents/<name>.md` → skills worktree, so the phase agents (`phase-a-fixer`, `phase-b-reviewer`, `phase-c-merger`, `pm-worker`, `researcher`) are spawnable from any repo. **A brand-new `~/.claude/agents/` directory needs a session restart before the types register** — until then, spawn `general-purpose` with the verbatim SAFETY/MINDSET/SKILLS blocks instead (`.claude/rules/subagent-orchestration.md`)
8. Verifies all hook paths in `settings.json` resolve to existing, executable scripts

## Optional: keep this machine current on its own (macOS)

`setup.sh` makes the machine current **now**; session-start hooks keep it current whenever you open a session **here**. A machine you have not worked on lately still drifts — it runs stale rules, and skills or agents merged on another machine are never linked at all.

One command per machine fixes that:

```bash
bash .claude/scripts/install-config-sync.sh
```

That runs the sync once at login and hourly thereafter. To pick a different cadence, run this **instead**:

```bash
bash .claude/scripts/install-config-sync.sh --interval 1800
```

It registers `claude-config-sync.sh` as a launchd LaunchAgent: the job survives reboots, catches up after sleep, fast-forwards the skills worktree, links anything newly merged, and re-runs the idempotent setup steps. It never touches the root repo checkout.

When a sync lands something a live session cannot pick up (a new agent, changed rules), the next session start says `RESTART RECOMMENDED` and the status line shows `↻ restart`; the signal clears once you restart. Repeated failures surface the same way (`⚠ sync failing`) and clear on the next good run. Logs: `~/.claude/logs/claude-config-sync.log`.

Remove it with `bash .claude/scripts/uninstall-config-sync.sh`. Details: [`.claude/reference/skill-sync-hooks.md`](.claude/reference/skill-sync-hooks.md).

## Prerequisites

- **Git** — the repo must be cloned (not downloaded as a zip)
- **GitHub CLI (`gh`)** — needed for the PR workflow: `brew install gh && gh auth login`
- **Claude Code** — install via `npm install -g @anthropic-ai/claude-code` (see [docs](https://docs.anthropic.com/en/docs/claude-code))

Optional tools (for the full review workflow):
- [CodeRabbit](https://coderabbit.ai) — AI code review on PRs
- [CodeRabbit CLI](https://docs.coderabbit.ai/cli) — local pre-push reviews (`coderabbit review --agent`). Install via `brew install coderabbit` (macOS) or `curl -fsSL https://cli.coderabbit.ai/install.sh | sh` (cross-platform); auth via `coderabbit auth login` (browser OAuth) or the `$CODERABBIT_API_KEY` env var for non-interactive use
- [CodeAnt CLI](https://docs.codeant.ai/cli/setup.md) — local pre-push reviews, npm/Node.js required. Install via `npm install -g codeant-cli`; auth via `codeant login` (browser OAuth, key stored in `~/.codeant/config.json`)
- [Graphite CLI](https://graphite.dev/docs/command-line) — stacked PRs; pair with the Graphite Claude Code plugins enabled via `setup.sh` (see [README.md](README.md#getting-started))
- [Greptile](https://greptile.com) — fallback reviewer when CodeRabbit is rate-limited

See [README.md](README.md) for full documentation.
