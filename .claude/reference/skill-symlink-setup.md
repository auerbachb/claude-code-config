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

## Where the symlink installation lives

`.claude/scripts/publish-skill-symlinks.sh` owns the skill, `CLAUDE.md` and `rules` legs (issue #1524); `publish-agent-symlinks.sh` owns the agents leg (issue #1197). `setup-skills-worktree.sh` delegates to both rather than carrying its own copy of the state machine.

That matters because the publishers no longer run only at setup time. They also run on **every session start** (`session-start-sync.sh`) and on **every scheduled tick** (`claude-config-sync.sh`, hourly under launchd — `skill-sync-hooks.md`), which is what makes a skill merged on another machine appear here without anyone re-running setup. Both are idempotent and silent when nothing changed, and both leave user-owned symlinks — any target outside the worktree — alone.

## Installing a new skill's symlink

The publishers do this on their own. The manual form below is for a link you want immediately, without waiting for the next session start or scheduled tick.

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

## Installing the phase-agent symlinks

`setup-skills-worktree.sh` Step 5b delegates to `publish-agent-symlinks.sh`, which publishes `.claude/agents/*.md` into
`~/.claude/agents/` so `subagent_type: "phase-a-fixer"` resolves from any repo,
not just this one. Claude Code discovers agent definitions at both user scope
(`~/.claude/agents/`) and project scope (`<repo>/.claude/agents/`), with project
winning on a `name:` collision — so working in this repo still uses the branch's
own copies, and every other repo gets the `main`-pinned ones.

The leg mirrors **skills**, not **rules**: a real `~/.claude/agents/` directory
holding one symlink per file, rather than one directory symlink. The docs are
explicit that `.claude/rules/` resolves symlinks and silent about `agents/`, and
the per-entry skills topology is already proven on this machine. Reasoning:
`portable-skill-resolution.md` (issue #1189).

**Restart caveat.** A brand-new `~/.claude/agents/` directory is the one case the
file watcher cannot pick up mid-session — it does not cover a directory that did
not exist at session start. The setup script says so when it creates the
directory. Until the restart, spawn `general-purpose` and paste the verbatim
SAFETY/MINDSET/SKILLS blocks plus the role procedure, per
`.claude/rules/subagent-orchestration.md` "Failed custom spawn fallback".

## Verifying and migrating existing links

```bash
ls -la ~/.claude/skills/ ~/.claude/agents/ ~/.claude/CLAUDE.md ~/.claude/rules
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
