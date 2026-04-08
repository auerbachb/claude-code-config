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

## What It Does

> Steps below are the logical workflow — see `setup.sh` for exact step numbering in script output.

1. Creates the `~/.claude/skills/` directory
2. Merges non-hook settings from `global-settings.json` into `~/.claude/settings.json` (existing keys like `permissions`, `model`, `env` are preserved — only missing keys are seeded)
3. Verifies all hook scripts exist and are executable
4. Runs `setup-skills-worktree.sh` which:
   - Creates a dedicated skills worktree and skill symlinks
   - Registers all hooks into `~/.claude/settings.json` with paths pointing to the skills worktree (migrates stale root-repo or placeholder paths automatically)
5. Symlinks `~/.claude/CLAUDE.md` → skills worktree (`~/.claude/skills-worktree/CLAUDE.md`)
6. Symlinks `~/.claude/rules` → skills worktree (`~/.claude/skills-worktree/.claude/rules`)
7. Verifies all hook paths in `settings.json` resolve to existing, executable scripts

## Prerequisites

- **Git** — the repo must be cloned (not downloaded as a zip)
- **GitHub CLI (`gh`)** — needed for the PR workflow: `brew install gh && gh auth login`
- **Claude Code** — `npm install -g @anthropic-ai/claude-code`

Optional tools (for the full review workflow):
- [CodeRabbit](https://coderabbit.ai) — AI code review on PRs
- [CodeRabbit CLI](https://docs.coderabbit.ai/cli) — local pre-push reviews
- [Greptile](https://greptile.com) — fallback reviewer when CodeRabbit is rate-limited

See [README.md](README.md) for full documentation.
