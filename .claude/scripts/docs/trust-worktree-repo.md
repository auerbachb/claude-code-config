# Trust, Worktree & Repo

<!-- catalog:category id=trust-worktree-repo order=110 -->
<!-- catalog:covers Scripts that repair trust flags, detect stale worktrees, and sync main -->

Scripts that repair trust flags, detect stale worktrees, and sync main.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin -->
| [claude-config-sync.sh](../claude-config-sync.sh) | One idempotent per-machine freshen pass — fast-forward the skills worktree, publish every symlink, verify links, re-run hook registration and trust repair, and record the restart/failure signal; never touches the root repo checkout |
| [dirty-main-guard.sh](../dirty-main-guard.sh) | Detect and quarantine dirty tracked state on the root repo's main branch |
| [main-sync.sh](../main-sync.sh) | Sync a repo's local main branch with `origin/main` |
| [publish-agent-symlinks.sh](../publish-agent-symlinks.sh) | Publish the `~/.claude/agents/` symlinks from the skills worktree; idempotent, re-run on every session start |
| [publish-skill-symlinks.sh](../publish-skill-symlinks.sh) | Publish the `~/.claude/skills/`, `CLAUDE.md` and `rules` symlinks from the skills worktree; idempotent, silent when already correct |
| [repair-trust-all.sh](../repair-trust-all.sh) | Fix trust flags for all projects in `~/.claude.json` |
| [repair-trust-single.sh](../repair-trust-single.sh) | Fix trust flags for one project in `~/.claude.json` |
| [repair-worktrees.sh](../repair-worktrees.sh) | Detect stale git worktrees (merged/deleted branch) and optionally remove them |
| [repo-bootstrap.sh](../repo-bootstrap.sh) | Check and optionally install required repo configuration (provisioned file set, branch protection) |
| [repo-root.sh](../repo-root.sh) | Resolve the absolute path of the root (main) worktree (every git call wall-clock bounded; exit 3 on timeout) |
| [stale-cleanup.sh](../stale-cleanup.sh) | Detect and optionally remove stale worktrees, branches, and orphaned worktree registrations (out-of-band, safe; every registration read wall-clock bounded) |
<!-- catalog:rows:end -->

---

[← back to the index](../README.md)
