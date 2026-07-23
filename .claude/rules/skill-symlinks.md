# Skill Symlink Rule

> **Always:** Symlink new skills to `~/.claude/skills/` via the skills worktree. Verify existing skills are symlinks pointing to the worktree, not copies or root-repo symlinks. Ensure the skills worktree exists at session start. CLAUDE.md and rules also go through the skills worktree.
> **Ask first:** Never — symlink creation and worktree setup are autonomous.
> **Never:** Copy skill directories to `~/.claude/skills/`. Symlink directly to the root repo (breaks when root repo isn't on `main`). Leave a new skill without a global symlink. Symlink CLAUDE.md or rules directly to the root repo.

## Source of Truth

This repo is the single source of truth for skills, global rules, and CLAUDE.md. `~/.claude/` must contain **symlinks** through a dedicated skills worktree — never copies, never direct root-repo symlinks:

- `~/.claude/skills/<name>` -> `~/.claude/skills-worktree/.claude/skills/<name>`
- `~/.claude/CLAUDE.md` -> `~/.claude/skills-worktree/CLAUDE.md`
- `~/.claude/rules` -> `~/.claude/skills-worktree/.claude/rules`

`~/.claude/skills-worktree/` stays permanently on `main`, so symlink targets survive the root repo being on a feature branch.

> **Double-loading note:** these symlinks make the global `CLAUDE.md` + rules resolve into the worktree, so sessions opened *in this repo* would load the corpus twice. Suppressed via project-local `claudeMdExcludes` in `.claude/settings.json` — rationale: `.claude/reference/double-loading-fix.md`.

## Session Start: Verify Skills Worktree

Verify `$HOME/.claude/skills-worktree/.claude/skills` exists; if missing, run `setup-skills-worktree.sh` from the root repo (guarded snippet: `.claude/reference/skill-symlink-setup.md`). Hooks sync the worktree to `origin/main` on session start and after merges — details: `.claude/reference/skill-sync-hooks.md`.

## After Creating a New Skill

**Do all three, every time:**

1. Create the skill in the repo: `.claude/skills/<name>/SKILL.md`
2. Commit and ensure it reaches `main` (via PR merge)
3. **Only then** update the worktree (`fetch` + `reset --hard origin/main`) and `ln -s` the skill into `~/.claude/skills/`

## Verifying Existing Symlinks

`ls -la ~/.claude/skills/ ~/.claude/CLAUDE.md ~/.claude/rules` — every entry should resolve to `~/.claude/skills-worktree/...`. Regular files trigger a setup-script warning but aren't overwritten; root-repo-targeted symlinks need migrating.

Exact commands for steps 3, the session-start guard, and migration: `.claude/reference/skill-symlink-setup.md`.
