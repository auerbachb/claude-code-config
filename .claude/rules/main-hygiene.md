# Main Hygiene — Dirty-Main Guard

> **Always:** Run the dirty-main guard at session start before pulling main. Mention the recovery branch to the user when the guard quarantines state. Stay on feature branches — the root repo sits clean on main between sessions.
> **Ask first:** Never — `--check` is read-only and `--quarantine` is non-destructive (creates a recovery branch before resetting main).
> **Never:** Call `--quarantine` on a worktree / feature branch. Delete recovery branches without the user's say-so. Hand-roll `git reset --hard origin/main` on the root repo — use the guard so dirty state is preserved.

Enforces "never leave anything on main" from `CLAUDE.md`. Complements the #323 pre-commit hook (which blocks new commits) by catching pre-existing drift at session start.

## What counts as "dirty"

On the root repo's main branch, either condition triggers `dirty:` output from `--check` and quarantine from `--quarantine`:

1. **Uncommitted tracked changes** — `git diff --quiet` + `git diff --cached --quiet` (tracked-only; untracked files never block — see memory `feedback_porcelain_untracked.md`).
2. **Unpushed commits** — `git rev-list --count origin/main..HEAD > 0`, with origin fetched first; fetch errors degrade to the existing remote-tracking ref.

Feature branches / worktrees are out of scope — the guard short-circuits to a no-op on any branch other than main.

## Using the guard

Canonical script: `.claude/scripts/dirty-main-guard.sh`. See `--help` for the full contract (exit codes, output format).

```bash
.claude/scripts/dirty-main-guard.sh --check       # exit 0 clean, 1 dirty
.claude/scripts/dirty-main-guard.sh --quarantine  # preserve + reset
```

`--quarantine` creates a `recovery/dirty-main-YYYYMMDD-HHMMSS` branch that preserves every tracked change and unpushed commit, then resets main to origin/main. Untracked files stay put — `git reset --hard` does not touch them, and the guard never invokes `git clean`.

## Session-start integration

`CLAUDE.md` §Worktree owns the sequence (check → quarantine → pull) and requires surfacing `quarantined: recovery/dirty-main-*` branch names to the user.

## Stop hook (mid-session safety net)

The `dirty-main-warn.sh` Stop hook (`global-settings.json`) runs `--check` after every response and emits a loud warning + the `--quarantine` command when main is dirty; it never quarantines on its own.

## Recovery workflow

`recovery/dirty-main-*` is a shell glob; `git branch -D` needs the literal name. List it first:

```bash
cd "$(.claude/scripts/repo-root.sh)"
git branch --list 'recovery/dirty-main-*'
```

Then inspect (`git log` / `git diff main..<recovery-branch> --stat`), land via cherry-pick/rebase/PR, and only then delete with `git branch -D <recovery-branch>`. Recovery branches are the user's audit trail — never auto-delete; ask first.
