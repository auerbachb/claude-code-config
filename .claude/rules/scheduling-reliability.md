# Scheduling Reliability

> **Always:** Use `/loop` for user-facing "poll/check/watch every N" requests. Run the pre-exit checklist. Record polling state in `session-state.json`.
> **Ask first:** Never — scheduling reliability is autonomous.
> **Never:** Hand-roll a chain of one-shot `ScheduleWakeup` (or equivalent) calls for a recurring user-facing poll. Promise to "check back in N minutes" without backing it with an active `/loop` or `CronCreate` job. Exit a wake-up turn without confirming the next tick is scheduled.

The 5-minute heartbeat rule catches silence during turns; this file covers between-turn polling.

## Tool Selection Decision Tree

| User request / context | Primitive | Why |
|------------------------|-----------|-----|
| Recurring: "poll/check/watch every N", "keep running /skill" | **`/loop`** | Runtime owns cadence |
| ≥3 concurrent polls or cross-session durability | **`CronCreate`** | Durable fleet job |
| One-shot "wake me in N minutes" | `ScheduleWakeup` | Single tick only |

> **Default recurring user-facing poll: `/loop`.** Use `CronCreate` only for cross-session durability or fleet jobs. Never hand-roll one-shot chains.

## Forbidden Pattern: Hand-Rolled One-Shot Chains

Do not recur as "do work, then schedule the next one-shot wakeup." Forgetting or failing the re-arm silently kills the poll. Use `/loop N <command>` once; the runtime re-arms it.

## Mandatory Pre-Exit Checklist for Polling Turns

Before any polling turn ends (`/loop`, `CronCreate`, or legacy one-shot), verify all three:

1. **Next tick scheduled?**
   - `/loop`: verify it is active/re-armed.
   - `CronCreate`: confirm with `CronList`; prior `CronDelete` or 7-day expiry may remove it.
   - Legacy `ScheduleWakeup`: confirm this turn made the next-tick call and it returned cleanly. If skipped/errored, switch to `/loop`.
2. **User heartbeat sent this turn?** Timestamped visible message summarizing what happened and what is next.
3. **Monitoring state recorded?** Update `~/.claude/session-state.json` with tick time, next expected tick, and watermarks (last review ID, last HEAD SHA, etc.). See `handoff-files.md`.

## Stable-State Backoff

Each tick hash `(head_sha, cr_state, bugbot_state, greptile_state, ci_blocking_conclusions_sorted, blocker_kind)` into `prs.{N}.digest_streak` (free-text `blocker` excluded). Widen at streak ≥3→5m, ≥6→15m; `CronDelete` at ≥9 or `blocker_kind == "user_input"`. Resume at base cadence after user message or changed digest. `polling-backoff-warn.sh` enforces this.

## Failure Recovery

If the user reports a dropped tick:

1. Acknowledge it.
2. Re-establish with `/loop`, not another one-shot chain; state cadence and command.
3. Record `polling_failures[]` in `session-state.json`.
4. If new, append the failure mode to `.claude/reference/scheduling-failure-modes.md` after the session.

## Related

- `monitor-mode.md` — in-turn heartbeat and monitor loop
- `.claude/reference/scheduling-failure-modes.md` — canonical list of observed failure modes with case studies
- `handoff-files.md` — `session-state.json` schema, including the polling-state fields this file requires
