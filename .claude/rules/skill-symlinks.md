# Skill Symlink Rule

> **Always:** Symlink new skills to `~/.claude/skills/` via the skills worktree. Verify existing skills are symlinks pointing to the worktree, not copies or root-repo symlinks. Ensure the skills worktree exists at session start. CLAUDE.md and rules also go through the skills worktree.
> **Ask first:** Never — symlink creation and worktree setup are autonomous.
> **Never:** Copy skill directories to `~/.claude/skills/`. Symlink directly to the root repo (breaks when root repo isn't on `main`). Leave a new skill without a global symlink. Symlink CLAUDE.md or rules directly to the root repo.

## Source of Truth

This repo is the single source of truth for skills, global rules, and CLAUDE.md. `~/.claude/` must contain **symlinks** through a dedicated skills worktree — never copies, never direct root-repo symlinks:
- `~/.claude/skills/<name>` -> `~/.claude/skills-worktree/.claude/skills/<name>`
- `~/.claude/CLAUDE.md` -> `~/.claude/skills-worktree/CLAUDE.md`
- `~/.claude/rules` -> `~/.claude/skills-worktree/.claude/rules`

> **Double-loading note:** because these symlinks make the global `CLAUDE.md` + rules resolve into the worktree, sessions opened *in this repo* would otherwise load the corpus twice (global + project). This repo suppresses the global copy via project-local `claudeMdExcludes` in `.claude/settings.json` — full rationale in `.claude/reference/double-loading-fix.md`.

## Why a Dedicated Worktree

`~/.claude/skills-worktree/` stays permanently on `main`, so symlink targets survive the root repo being on a feature branch.

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

**Checklist for every new skill (do all three, every time):**
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

Every entry should `->` to `~/.claude/skills-worktree/...`. Regular files (not symlinks) trigger a setup-script warning but aren't overwritten; migrate root-repo-targeted symlinks by running `bash "$(.claude/scripts/repo-root.sh)"/setup-skills-worktree.sh` unconditionally (skip the session-start snippet's missing-worktree guard).
