# Dirty-Main Guard — Detection Mechanism & Recovery Commands

Mechanism behind `.claude/rules/main-hygiene.md`. That rule owns enforcement — when to run the guard, what may never be done to a recovery branch. This file carries how "dirty" is computed and the exact commands for inspecting and retiring a recovery branch.

## How `--check` decides "dirty"

Scope: the **root repo on `main`**. Feature branches and worktrees are out of scope and the guard no-ops there, which is why `--quarantine` must never be called from one.

Either condition alone makes the tree dirty:

1. **Uncommitted tracked changes** — `git diff --quiet` plus `git diff --cached --quiet`. Deliberately tracked-only: untracked files never block. Using `git status --porcelain` here was the original bug — it reports untracked files too, so a stray scratch file read as "dirty main" (memory `feedback_porcelain_untracked.md`).
2. **Unpushed commits** — `git rev-list --count origin/main..HEAD > 0`, with origin fetched first. A fetch failure is not fatal: detection degrades to the existing remote-tracking ref rather than erroring out, so an offline session still gets a best-effort answer.

Exit codes and output format: `dirty-main-guard.sh --help`.

## What `--quarantine` does

Creates `recovery/dirty-main-YYYYMMDD-HHMMSS` holding every tracked change and unpushed commit, then resets main to `origin/main`. Untracked files are left exactly where they are — the guard never invokes `git clean`, which would delete gitignored `.env` files (`.claude/rules/safety.md`).

## Recovery-branch commands

`recovery/dirty-main-*` is a glob, and `git branch -D` needs a literal name, so list before doing anything else — from the root repo:

```bash
git branch --list 'recovery/dirty-main-*'
```

Inspect what it holds:

```bash
git log --oneline main..<branch>
git diff main..<branch> --stat
```

Then land the work through the normal issue → feature branch → PR → `gh pr merge --squash` flow, using `git cherry-pick` or `git rebase --onto` only to move the commits onto the feature branch. Never land recovery work directly on main.

Delete only after the work has merged, and only with the user's say-so — these branches are the user's audit trail:

```bash
git branch -D recovery/dirty-main-20260801-193000
```

## The Stop hook

`dirty-main-warn.sh` re-runs `--check` after every response and warns loudly on a dirty root main. It is a detector only: it never quarantines on its own, so a warning always leaves the decision with the session.
