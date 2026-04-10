# Safety — Destructive Command Prohibitions

> **Always:** Stay in your worktree directory. Treat `.env` files as untouchable. Warn subagents about these rules.
> **Ask first:** Never — these are absolute prohibitions with no exceptions.
> **Never:** Delete `.env` files. Run `git clean`. Run destructive commands in the root repo. Operate in the root repo directory.

Prevent accidental `.env` deletion and other destructive operations from the repo root. All work happens in worktrees.

## Absolute Rules (no exceptions)

1. **NEVER delete, overwrite, move, or modify `.env` files.** Not in root, not in worktrees, not anywhere, not in any repo. `.env` files contain secrets and credentials that cannot be recovered.
2. **NEVER run `git clean` in ANY directory.** It removes untracked files — including `.env` files that are in `.gitignore`.
3. **NEVER run destructive file commands in the root repo directory.** This includes `rm -rf`, `rm`, `git checkout .`, `git stash` (which can drop untracked files), and `git reset --hard`. All work happens in worktrees — the root repo stays untouched on `main`.
4. **NEVER `cd` to the root repo and run file operations there.** Stay in your assigned worktree directory at all times. The only safe root-repo operations are read-only: `git worktree list`, `find` for locating directories, reading files.

## Subagent Warning (MANDATORY)

When spawning subagents, include this warning in the prompt AND always set `mode: "bypassPermissions"` on the Agent tool call (see `subagent-orchestration.md` "How to Spawn Subagents" for why):

```
SAFETY: Do NOT delete, overwrite, move, or modify .env files — anywhere, any repo.
Do NOT run git clean in ANY directory. Do NOT run destructive commands (rm -rf, rm,
git checkout ., git stash, git reset --hard) in the root repo directory. Stay in your
worktree directory at all times.
```
