# Main Hygiene — Dirty-Main Guard

> **Always:** Run the dirty-main guard at session start before pulling main. Mention the recovery branch to the user when the guard quarantines state. Stay on feature branches — the root repo sits clean on main between sessions.
> **Ask first:** Never — `--check` is read-only and `--quarantine` is non-destructive (creates a recovery branch before resetting main).
> **Never:** Call `--quarantine` on a worktree / feature branch. Delete recovery branches without the user's say-so. Hand-roll `git reset --hard origin/main` on the root repo — use the guard so dirty state is preserved.

Enforces "never leave anything on main" from `CLAUDE.md`. Complements the #323 pre-commit hook (which blocks new commits) by catching pre-existing drift at session start.

## Using the guard

```bash
.claude/scripts/dirty-main-guard.sh --check       # exit 0 clean, 1 dirty
.claude/scripts/dirty-main-guard.sh --quarantine  # preserve + reset
```

**Dirty** on the root repo's main branch — either condition triggers `dirty:` from `--check` and quarantine from `--quarantine`:

1. **Uncommitted tracked changes** — `git diff --quiet` + `git diff --cached --quiet` (tracked-only; untracked files never block — memory `feedback_porcelain_untracked.md`).
2. **Unpushed commits** — `git rev-list --count origin/main..HEAD > 0`, origin fetched first; fetch errors degrade to the existing remote-tracking ref.

Feature branches and worktrees are out of scope; the guard no-ops there.

`--quarantine` creates a `recovery/dirty-main-YYYYMMDD-HHMMSS` branch preserving every tracked change and unpushed commit, then resets main to origin/main. Untracked files stay put — the guard never invokes `git clean`. Full contract (exit codes, output format): `dirty-main-guard.sh --help`.

`CLAUDE.md` §Worktree owns the session-start sequence (check → quarantine → pull) and requires surfacing `quarantined: recovery/dirty-main-*` branch names. The `dirty-main-warn.sh` Stop hook re-runs `--check` after every response and warns loudly; it never quarantines on its own.

## Recovery workflow

`recovery/dirty-main-*` is a glob — `git branch -D` needs the literal name, so list it first with `git branch --list 'recovery/dirty-main-*'` from the root repo. Inspect (`git log`, `git diff main..<branch> --stat`), then land the work through the normal flow — issue → feature branch → PR → `gh pr merge --squash`, using cherry-pick/rebase only to move the commits onto that branch. Never land recovery work directly on main. Delete only after it merges; recovery branches are the user's audit trail — never auto-delete, ask first.
