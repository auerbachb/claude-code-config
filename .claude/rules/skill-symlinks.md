# Skill Symlink Rule

> **Always:** Symlink new skills to `~/.claude/skills/` after creating them. Verify existing skills are symlinks, not copies.
> **Ask first:** Never — symlink creation is autonomous.
> **Never:** Copy skill directories to `~/.claude/skills/`. Leave a new skill without a global symlink.

## Source of Truth

This repo (`claude-code-config`) is the single source of truth for all Claude Code skills. The global skills directory (`~/.claude/skills/`) must contain **symlinks** pointing back to this repo — never standalone copies. Copies diverge silently and miss updates.

## After Creating a New Skill

Every time a new skill is created in `.claude/skills/<name>/SKILL.md`, the agent must also symlink it globally. Resolve the repo root dynamically:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
ln -s "$REPO_ROOT/.claude/skills/<name>" ~/.claude/skills/<name>
```

This makes the skill available in every repo, not just this one. Without the symlink, the skill only exists locally in this repo's `.claude/skills/` directory.

**Checklist (do both, every time):**
1. Create the skill: `.claude/skills/<name>/SKILL.md`
2. Symlink it globally: `ln -s "$(git rev-parse --show-toplevel)/.claude/skills/<name>" ~/.claude/skills/<name>`

If `~/.claude/skills/` does not exist, create it first: `mkdir -p ~/.claude/skills/`.

## Verifying Existing Skills

To confirm all skills are properly symlinked (not copies):

```bash
ls -la ~/.claude/skills/
```

Every skill entry should show `->` pointing to this repo's `.claude/skills/` directory. If any skill entry is a regular directory (not a symlink), replace it with a symlink:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
rm -rf ~/.claude/skills/<name>
ln -s "$REPO_ROOT/.claude/skills/<name>" ~/.claude/skills/<name>
```
