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
| `CLAUDE_CONFIG_SYNC_HOOK_LOCK_TIMEOUT` | `session-start-sync.sh` | 5s | The wait is charged against the same `timeout 30` hook budget the lock-held git region must finish inside, so it is capped short to leave that region a usable deadline (the hook reserves the remainder for git and declines calls that cannot complete). A scheduled sync still holding the lock after 5s has already done the hook's work, so waiting longer buys nothing. |

A real critical section is milliseconds; both defaults are sized for the contention tail, not the common case. The marker's read is lock-free — a contended session start still surfaces the restart notice — and only the startup *clear* re-takes the lock, for at most 5s.

**Bounded execution.** `state-lock.sh` breaks a lock on *age alone*, with no liveness check, so any lock-held call that stalls past `STALE_AGE` (120s default) invites a second sync to mutate the same worktree concurrently. Every lock-held call on both sides is therefore scheduled against one deadline — the hook's registered `timeout 30`, the job's staleness window — and a call with too little budget left is **declined and recorded** rather than started and killed. A recorded failure keeps the publish guard and the marker-clear guard honest; a kill records nothing, which is the failure these bounds exist to remove. Issue #1593 extended the same treatment to the symlink publishers and the hook's root-repo sync leg, which PR #1553 had left outside the budget. The per-call ceilings, all clamped to what is left of their region:

| Variable | Read by | Default | Bounds |
|----------|---------|---------|--------|
| `CLAUDE_CONFIG_SYNC_GIT_BOUND` | `claude-config-sync.sh` | half the staleness window (60s) | one lock-held `fetch`/`reset`/bootstrap |
| `CLAUDE_CONFIG_SYNC_PUBLISH_BOUND` | `claude-config-sync.sh` | a sixth of the window (20s) | one lock-held symlink publisher |
| `CLAUDE_CONFIG_SYNC_HOOK_GIT_BOUND` | `session-start-sync.sh` | 8s | one lock-held `fetch`/`reset` |
| `CLAUDE_CONFIG_SYNC_HOOK_SETUP_BOUND` | `session-start-sync.sh` | 18s | `setup-skills-worktree.sh` (clone + fetch + publish + register) |
| `CLAUDE_CONFIG_SYNC_HOOK_PUBLISH_BOUND` | `session-start-sync.sh` | 5s | one symlink publisher |
| `CLAUDE_CONFIG_SYNC_HOOK_ROOT_SYNC_BOUND` | `session-start-sync.sh` | 6s | the post-lock root-repo `main-sync.sh` / `pull --ff-only` leg |

The hook's post-region calls reserve only the genuinely unbounded tail (the marker `jq`, the scheduling reconcile, the JSON emission), which is what makes its 9s post-git reserve arithmetic rather than a guess: the work it covers now bounds itself.

**Signal path.** `~/.claude/sync-restart-recommended.json` carries two independent portions:

| Portion | Written when | Cleared when |
|---------|--------------|--------------|
| `restart_recommended` | a landed sync changed `.claude/agents/`, `.claude/rules/`, `.claude/skills/` or `CLAUDE.md`, published a new agent symlink, or bootstrapped the worktree | `session-start-sync.sh` sees `source == "startup"` **and** it actually ran the sync region **and** its lock acquire was uncontended **and** the marker still holds the same `restart_recommended` it surfaced — only then has this session demonstrably loaded the change. Any other combination leaves the signal for the next startup: a duplicate reminder, never a lost one |
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
