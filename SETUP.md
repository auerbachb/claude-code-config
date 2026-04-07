# Setup — Claude Code Configuration

This repository configures [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with automated PR workflows, code review integration, and project management skills.

> **Trust notice:** `setup.sh` creates symlinks in `~/.claude/` and copies a settings file. Review `setup.sh` before running if you want to understand what it does. It is idempotent — safe to run multiple times.

## Install

From the root of this cloned repository, run:

```bash
bash ./setup.sh
```

The script handles everything: directory creation, symlinks, settings installation with path replacement, hook verification, and skills worktree setup. It prints a pass/fail summary on completion.

**Do not manually run the individual steps from README.md.** The `setup.sh` script is the single source of truth for installation. The README documents what each step does for reference, but `setup.sh` is the canonical installer.

## What It Does

1. Creates the `~/.claude/skills/` directory
2. Symlinks `CLAUDE.md` (global instructions) to `~/.claude/CLAUDE.md`
3. Symlinks `.claude/rules/` to `~/.claude/rules`
4. Copies `global-settings.json` to `~/.claude/settings.json` with path replacement (backs up any existing file)
5. Verifies all hook scripts exist and are executable
6. Runs `setup-skills-worktree.sh` to create the skills worktree and skill symlinks

## Prerequisites

- **Git** — the repo must be cloned (not downloaded as a zip)
- **GitHub CLI (`gh`)** — needed for the PR workflow: `brew install gh && gh auth login`
- **Claude Code** — `npm install -g @anthropic-ai/claude-code`

Optional tools (for the full review workflow):
- [CodeRabbit](https://coderabbit.ai) — AI code review on PRs
- [CodeRabbit CLI](https://docs.coderabbit.ai/cli) — local pre-push reviews
- [Greptile](https://greptile.com) — fallback reviewer when CodeRabbit is rate-limited

See [README.md](README.md) for full documentation.
