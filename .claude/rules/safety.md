# Safety — Destructive Command Prohibitions

> **Always:** Stay in your worktree directory. Treat `.env` files as untouchable. Warn subagents about these rules.
> **Ask first:** Never — these are absolute prohibitions with no exceptions.
> **Never:** Delete `.env` files. Run `git clean`. Run destructive commands in the root repo. Operate in the root repo directory.

These rules exist because a thread accidentally deleted a repo's `.env` file by running destructive commands in the root repo directory instead of staying in its worktree. The user only caught it because the file happened to be open in their IDE.

## Absolute Rules (no exceptions)

1. **NEVER delete, overwrite, move, or modify `.env` files.** Not in root, not in worktrees, not anywhere, not in any repo. `.env` files contain secrets and credentials that cannot be recovered.
2. **NEVER run `git clean` in ANY directory.** It removes untracked files — including `.env` files that are in `.gitignore`.
3. **NEVER run destructive file commands in the root repo directory.** This includes `rm -rf`, `rm`, `git checkout .`, `git stash` (which can drop untracked files), and `git reset --hard`. All work happens in worktrees — the root repo stays untouched on `main`.
4. **NEVER `cd` to the root repo and run file operations there.** Stay in your assigned worktree directory at all times. The only safe root-repo operations are read-only: `git worktree list`, `find` for locating directories, reading files.

## Subagent Warning (MANDATORY)

When spawning subagents, include this warning in the prompt:

```
SAFETY: Do NOT modify or delete .env files. Do NOT run git clean. Do NOT run destructive
commands (rm -rf, git checkout ., git reset --hard) in the root repo directory. Stay in
your worktree directory at all times.
```
