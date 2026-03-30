# Skill Symlink Rule

> **Always:** Symlink new skills to `~/.claude/skills/` via the skills worktree. Verify existing skills are symlinks pointing to the worktree, not copies or root-repo symlinks. Ensure the skills worktree exists at session start.
> **Ask first:** Never — symlink creation and worktree setup are autonomous.
> **Never:** Copy skill directories to `~/.claude/skills/`. Symlink directly to the root repo (breaks when root repo isn't on `main`). Leave a new skill without a global symlink.

## Source of Truth

This repo (`claude-code-config`) is the single source of truth for all Claude Code skills. The global skills directory (`~/.claude/skills/`) must contain **symlinks** pointing to a dedicated skills worktree — never standalone copies, and never direct symlinks to the root repo.

## Why a Dedicated Worktree

Skills are served from `~/.claude/skills-worktree/`, a git worktree permanently checked out to `main`. This decouples skill availability from the root repo's branch state. Without it, when the root repo is on a feature branch (e.g., another session left it there), skills added after that branch was created become invisible — their symlink targets don't exist on that branch.

The `post-merge-pull.sh` hook automatically syncs the skills worktree after merges, so new skills on `main` appear without manual intervention.

## Session Start: Verify Skills Worktree

At the start of every session, verify the skills worktree exists. If missing, run the setup script:

```bash
if [[ ! -d "$HOME/.claude/skills-worktree/.claude/skills" ]]; then
  REPO_ROOT="$(git worktree list | head -1 | awk '{print $1}')"
  bash "$REPO_ROOT/setup-skills-worktree.sh"
fi
```

## After Creating a New Skill

Every time a new skill is created in `.claude/skills/<name>/SKILL.md`, the agent must also symlink it globally via the skills worktree.

**Checklist (do all three, every time):**
1. Create the skill in the repo: `.claude/skills/<name>/SKILL.md`
2. Commit and ensure it reaches `main` (via PR merge)
3. After it's on `main`, update the worktree and symlink:

```bash
# Update the skills worktree to pick up the new skill
git -C "$HOME/.claude/skills-worktree" fetch origin main --quiet
git -C "$HOME/.claude/skills-worktree" reset --hard origin/main --quiet

# Create the symlink
ln -s "$HOME/.claude/skills-worktree/.claude/skills/<name>" "$HOME/.claude/skills/<name>"
```

If `~/.claude/skills/` does not exist, create it first: `mkdir -p ~/.claude/skills/`.

## Verifying Existing Skills

To confirm all skills are properly symlinked via the worktree (not copies or root-repo symlinks):

```bash
ls -la ~/.claude/skills/
```

Every skill entry should show `->` pointing to `~/.claude/skills-worktree/.claude/skills/<name>`. If any skill entry:
- Is a regular directory (not a symlink) — replace it with a symlink to the worktree
- Points to the root repo's `.claude/skills/` — migrate it to the worktree

To fix all skills at once, re-run the setup script:

```bash
REPO_ROOT="$(git worktree list | head -1 | awk '{print $1}')"
bash "$REPO_ROOT/setup-skills-worktree.sh"
```
