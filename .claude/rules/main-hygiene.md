# Main Hygiene — Dirty-Main Guard

> **Always:** Run the dirty-main guard at session start before pulling main. Mention the recovery branch to the user when the guard quarantines state. Stay on feature branches — the root repo sits clean on main between sessions.
> **Ask first:** Never — `--check` is read-only and `--quarantine` is non-destructive (creates a recovery branch before resetting main).
> **Never:** Call `--quarantine` on a worktree / feature branch. Delete recovery branches without the user's say-so. Hand-roll `git reset --hard origin/main` on the root repo — use the guard so dirty state is preserved.

Enforces the "never leave anything on main" rule from `CLAUDE.md`. Complements the pre-commit hook from #323 (which blocks *new* commits on main) by catching drift that already exists — stray uncommitted changes or unpushed local commits — whenever a session starts.

## What counts as "dirty"

The guard flags two conditions on the **root repo's** main branch:

1. **Uncommitted tracked changes** — staged or unstaged modifications to files git is tracking. Detected via `git diff --quiet` + `git diff --cached --quiet` (tracked-only by design; untracked files never block — see memory `feedback_porcelain_untracked.md`).
2. **Unpushed commits on main** — `git rev-list --count origin/main..HEAD > 0`. Fetches origin first so the comparison is current; fetch errors degrade gracefully to the existing remote-tracking ref.

Both conditions are independent — either triggers `dirty:` output from `--check` and a quarantine from `--quarantine`.

Feature branches / worktrees are **not** in scope. The guard short-circuits to a clean / no-op exit on any branch other than main.

## Using the guard

Canonical script: `.claude/scripts/dirty-main-guard.sh`. See `--help` for the full contract (exit codes, output format).

```bash
.claude/scripts/dirty-main-guard.sh --check       # exit 0 clean, 1 dirty
.claude/scripts/dirty-main-guard.sh --quarantine  # preserve + reset
```

`--quarantine` creates a `recovery/dirty-main-YYYYMMDD-HHMMSS` branch that preserves every tracked change and unpushed commit, then resets main to origin/main. Untracked files stay put — `git reset --hard` does not touch them, and the guard never invokes `git clean`.

## Session-start integration

`CLAUDE.md` calls `--check` before the main pull; if dirty, runs `--quarantine` and then pulls. When the guard reports `quarantined: recovery/dirty-main-*`, surface the branch name to the user so they know where to find the rescued state.

## Stop hook (mid-session safety net)

`.claude/hooks/dirty-main-warn.sh` is registered as a Stop hook in `global-settings.json`. It runs `--check` after every agent response and emits a loud `additionalContext` warning plus the `--quarantine` command when main is dirty. The hook never quarantines on its own — quarantine is an intentional, session-start operation.

## Recovery workflow

When the guard creates a recovery branch, first list the exact branch name (`recovery/dirty-main-*` is a shell glob; commands like `git branch -D` need the literal name):

```bash
cd "$(.claude/scripts/repo-root.sh)"
git branch --list 'recovery/dirty-main-*'
```

Copy the full branch name from that output and substitute it for `<recovery-branch>` in every subsequent command:

1. Inspect the branch: `git log <recovery-branch> --oneline` or `git diff main..<recovery-branch> --stat`.
2. Cherry-pick, rebase, or open a PR from the branch the same way you would any other branch.
3. Once the content is landed (via PR) or confirmed unneeded, delete the branch: `git branch -D <recovery-branch>`.

Do not delete recovery branches automatically — they are the user's audit trail. Ask first if cleanup comes up.
