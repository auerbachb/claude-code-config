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

Skills, rules, and CLAUDE.md are served from `~/.claude/skills-worktree/`, a git worktree permanently checked out to `main`. This decouples config availability from the root repo's branch state. Without it, when the root repo is on a feature branch (e.g., another session left it there), symlink targets may not exist on that branch.

## Session-Start Sync Hook

The `session-start-sync.sh` PostToolUse hook runs once per session (on the first tool call) and syncs the skills worktree to `origin/main`. This ensures skills, rules, and CLAUDE.md are fresh across **all repos** — not just `claude-code-config`. The hook also pulls the root repo's `main` branch if it's currently checked out.

The `post-merge-pull.sh` hook syncs the skills worktree after merges and also refreshes the CLAUDE.md and rules symlinks.

### Hook Auto-Registration

The session-start sync also registers hooks from `global-settings.json` into `~/.claude/settings.json`. This ensures new hooks added to the template are picked up automatically — no need to re-run the setup script.

**How it works:**
- Reads `global-settings.json` from the root repo (source of truth for hook definitions)
- Resolves placeholder paths to the skills worktree hooks directory
- Compares against `~/.claude/settings.json` by script basename per event/matcher
- Adds only missing hooks; existing hooks (including user-customized timeouts) are preserved
- User hooks not in the template are never touched

**To add a new hook to the repo:**
1. Create the hook script in `.claude/hooks/`
2. Add the hook entry to `global-settings.json` (use the `/path/to/claude-code-config` placeholder)
3. Merge to `main` — the next session start auto-registers it in every user's `settings.json`

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

## Verifying Existing Symlinks

To confirm all symlinks are properly set up via the worktree (not copies or root-repo symlinks):

```bash
# Check skills
ls -la ~/.claude/skills/

# Check CLAUDE.md and rules
ls -la ~/.claude/CLAUDE.md
ls -la ~/.claude/rules
```

Every entry should show `->` pointing to `~/.claude/skills-worktree/...`. If any entry:
- Is a regular directory/file (not a symlink) — the setup script will warn but not overwrite
- Points to the root repo — migrate it by re-running the setup script

To fix all symlinks at once, re-run the setup script:

```bash
REPO_ROOT="$(git worktree list | head -1 | awk '{print $1}')"
bash "$REPO_ROOT/setup-skills-worktree.sh"
```
