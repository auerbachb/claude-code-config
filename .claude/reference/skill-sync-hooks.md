# Skill Sync Hooks — How They Work

## Scheduled Sync — `claude-config-sync.sh` (primary, issue #1524)

The hooks below only fire when someone opens a session on that machine. A machine you have not worked on lately therefore drifts silently: it runs stale rules, and skills or agents merged elsewhere are never linked at all.

`.claude/scripts/claude-config-sync.sh` is the machine-level answer — one idempotent freshen pass that:

1. fast-forwards `~/.claude/skills-worktree` to `origin/main` (bootstrapping via `setup-skills-worktree.sh` when it is missing),
2. publishes every managed symlink through `publish-skill-symlinks.sh` and `publish-agent-symlinks.sh`,
3. verifies the managed links still resolve,
4. re-runs the other idempotent setup — `register-hooks.py` and `repair-trust-all.sh`,
5. records a durable restart-recommended / sync-failure signal.

`install-config-sync.sh` registers it as a launchd LaunchAgent (macOS only): `RunAtLoad` for one pass at login, `StartInterval` for the hourly repeat, and launchd's own coalescing for the runs missed during sleep. `uninstall-config-sync.sh` removes it. Both are opt-in — `setup.sh` does not call them.

**Scope boundary.** The job touches the skills worktree and the `~/.claude` links, nothing else. It never pulls, resets, or checks out the root repo; root `main` hygiene stays a session-start concern behind `dirty-main-guard.sh` (`.claude/rules/main-hygiene.md`).

**Concurrency.** The scheduled job and the session-start hook do the same work, so both take one `state-lock.sh` mutex on `~/.claude/logs/claude-config-sync-state.json`. Whichever arrives second skips its region cleanly — the scheduled job reports `outcome: skipped` and exits 0; the hook records a notice and leaves the worktree alone. Neither ever proceeds unserialized.

The two sides wait for different lengths of time, because they are bounded by different things:

| Variable | Read by | Default | Why that default |
|----------|---------|---------|------------------|
| `CLAUDE_CONFIG_SYNC_LOCK_TIMEOUT` | `claude-config-sync.sh` | 30s | The scheduled tick can afford to wait for a session-start sync to finish; if it still cannot get in, the next tick is an hour away and costs nothing. |
| `CLAUDE_CONFIG_SYNC_HOOK_LOCK_TIMEOUT` | `session-start-sync.sh` | 10s | The hook is registered with `timeout 30` and has a root-repo pull still to do. A scheduled sync holding the lock longer than 10s has already done the hook's work, so waiting further buys nothing. |

A real critical section is milliseconds; both defaults are sized for the contention tail, not the common case. The marker's read is lock-free — a contended session start still surfaces the restart notice — and only the startup *clear* re-takes the lock, for at most 5s.

**Signal path.** `~/.claude/sync-restart-recommended.json` carries two independent portions:

| Portion | Written when | Cleared when |
|---------|--------------|--------------|
| `restart_recommended` | a landed sync changed `.claude/agents/`, `.claude/rules/`, `.claude/skills/` or `CLAUDE.md`, published a new agent symlink, or bootstrapped the worktree | `session-start-sync.sh` sees `source == "startup"` — a genuinely new session has already loaded the change |
| `sync_failure` | the consecutive-failure streak reaches `CONFIG_SYNC_FAILURE_THRESHOLD` (default 3), carrying how long it has been failing | the next successful tick |

Both surface twice: in the session's context via `session-start-sync.sh`'s `additionalContext`, and as a statusline badge (`↻ restart`, `⚠ sync failing`) for the human between sessions. Run detail lands in `~/.claude/logs/claude-config-sync.log`; failure and recovery events in `~/.claude/logs/claude-config-sync-events.jsonl`. When neither portion applies the marker file is removed, so a healthy machine shows nothing.

Restart automation is deliberately out of scope: no scheduler restarts a live Claude session. The visible signal is the ceiling.

## Session-Start Sync Hook (backstop)

The `session-start-sync.sh` SessionStart hook runs at every session start (fresh session, resume, clear, compact, fork) and syncs the skills worktree to `origin/main`, publishes the skill and agent symlinks, and registers hooks — all inside the shared lock above. This ensures skills, rules, and CLAUDE.md are fresh across **all repos** — not just `claude-code-config`. Outside the lock, the hook also pulls the root repo's `main` branch if it's currently checked out.

It remains the backstop for machines without the LaunchAgent, and the only place the restart signal is cleared. With the scheduler installed the common case needs no restart at all: everything is already linked before the session opens.

The `post-merge-pull.sh` hook syncs the skills worktree after merges and also refreshes the CLAUDE.md and rules symlinks.

## Hook Auto-Registration

The session-start sync also registers hooks from `global-settings.json` into `~/.claude/settings.json`. This ensures new hooks added to the template are picked up automatically — no need to re-run the setup script.

**How it works:**
- Reads `global-settings.json` from the skills worktree (always at `origin/main`)
- Resolves placeholder paths to the skills worktree hooks directory
- Compares against `~/.claude/settings.json` by script basename per event/matcher
- Adds only missing hooks; existing hooks (including user-customized timeouts) are preserved
- User hooks not in the template are never touched

**To add a new hook to the repo:**
1. Create the hook script in `.claude/hooks/`
2. Add the hook entry to `global-settings.json` (use the `/path/to/claude-code-config` placeholder)
3. Merge to `main` — the next session start auto-registers it in every user's `settings.json`
