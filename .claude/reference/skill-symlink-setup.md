# Skill Symlink Setup — Commands and Rationale

Expanded detail for `.claude/rules/skill-symlinks.md`. The binding rules are there; this file carries the setup commands and the reasoning.

## Why a dedicated worktree instead of direct root-repo symlinks

`~/.claude/skills-worktree/` stays permanently on `main`.

If `~/.claude/skills/<name>` pointed straight at the root repo, every symlink target would follow whatever branch the root repo happened to be on. Check out a feature branch that predates a skill and the skill vanishes globally; check out one mid-refactor and every session picks up half-finished instructions. The worktree decouples "what the repo is doing right now" from "what the installed skills are."

Copies have the opposite failure: they go stale silently and drift from the repo that is supposed to be the source of truth.

## Session-start bootstrap

Verify the worktree exists; if missing, run the setup script:

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

## Installing a new skill's symlink

Only after the skill has reached `main`:

```bash
SKILL="$HOME/.claude/skills-worktree/.claude/skills/<name>"
git -C "$HOME/.claude/skills-worktree" fetch origin main --quiet \
  && git -C "$HOME/.claude/skills-worktree" reset --hard origin/main --quiet \
  && [[ -e "$SKILL" ]] \
  && ln -s "$SKILL" "$HOME/.claude/skills/<name>"
```

Chained deliberately. If the fetch or reset fails, or the skill is not present in the refreshed worktree (wrong name, or it never reached `main`), the symlink is never created. An unchained run would link a path that does not exist, producing a dangling skill that fails at load time.

Create `~/.claude/skills/` first with `mkdir -p` if it does not exist.

## Verifying and migrating existing links

```bash
ls -la ~/.claude/skills/ ~/.claude/CLAUDE.md ~/.claude/rules
```

Every entry should resolve to `~/.claude/skills-worktree/...`.

- **Regular files** (not symlinks) trigger a setup-script warning and are deliberately not overwritten — they may be hand-authored local content.
- **Root-repo-targeted symlinks** are the case to migrate. Run the setup script unconditionally, skipping the missing-worktree guard from the bootstrap snippet above:

  ```bash
  bash "$(.claude/scripts/repo-root.sh)"/setup-skills-worktree.sh
  ```

## Related

- `.claude/reference/skill-sync-hooks.md` — the hooks that sync the worktree to `origin/main` on session start and after merges
- `.claude/reference/double-loading-fix.md` — why this repo suppresses the global CLAUDE.md copy via `claudeMdExcludes`
