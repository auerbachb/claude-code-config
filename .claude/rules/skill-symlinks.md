# Skill Symlink Rule

> **Always:** Symlink new skills to `~/.claude/skills/` via the skills worktree. Verify existing skills are symlinks pointing to the worktree, not copies or root-repo symlinks. Ensure the skills worktree exists at session start. CLAUDE.md and rules also go through the skills worktree.
> **Ask first:** Never — symlink creation and worktree setup are autonomous.
> **Never:** Copy skill directories to `~/.claude/skills/`. Symlink directly to the root repo (breaks when root repo isn't on `main`). Leave a new skill without a global symlink. Symlink CLAUDE.md or rules directly to the root repo.

## Source of Truth

This repo (`claude-code-config`) is the single source of truth for all Claude Code skills, global rules, and CLAUDE.md. The global config directory (`~/.claude/`) must contain **symlinks** pointing to a dedicated skills worktree — never standalone copies, and never direct symlinks to the root repo.

The following symlinks all go through the skills worktree:
- `~/.claude/skills/<name>` -> `~/.claude/skills-worktree/.claude/skills/<name>`
- `~/.claude/CLAUDE.md` -> `~/.claude/skills-worktree/CLAUDE.md`
- `~/.claude/rules` -> `~/.claude/skills-worktree/.claude/rules`

## Why a Dedicated Worktree

Served from `~/.claude/skills-worktree/`, a worktree permanently on `main`. Decouples config availability from the root repo's branch state — without it, symlink targets break when the root repo is on a feature branch.

## Session-Start Sync & Hook Auto-Registration

Hooks sync the skills worktree to `origin/main` on session start and after merges. Details: `.claude/reference/skill-sync-hooks.md`.

## Session Start: Verify Skills Worktree

At the start of every session, verify the skills worktree exists. If missing, run the setup script:

```bash
if [[ ! -d "$HOME/.claude/skills-worktree/.claude/skills" ]]; then
  REPO_ROOT="$(.claude/scripts/repo-root.sh 2>/dev/null || true)"
  if [[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]]; then
    bash "$REPO_ROOT/setup-skills-worktree.sh"
  else
    echo "ERROR: could not resolve root repo — cannot bootstrap skills worktree" >&2
  fi
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

## Verifying Existing Symlinks

```bash
ls -la ~/.claude/skills/ ~/.claude/CLAUDE.md ~/.claude/rules
```

Every entry should `->` to `~/.claude/skills-worktree/...`. Regular files (not symlinks) trigger a setup-script warning but aren't overwritten; root-repo-targeted symlinks are migrated by re-running the setup script:

```bash
REPO_ROOT="$(.claude/scripts/repo-root.sh 2>/dev/null || true)"
if [[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]]; then
  bash "$REPO_ROOT/setup-skills-worktree.sh"
else
  echo "ERROR: could not resolve root repo" >&2
fi
```
