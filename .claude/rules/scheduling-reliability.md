# Scheduling Reliability

> **Always:** Use `/loop` for any user-facing "poll every N / check every N / watch for X" request. Run the pre-exit checklist on every wake-up turn. Record polling state in `session-state.json`.
> **Ask first:** Never — scheduling reliability is autonomous.
> **Never:** Hand-roll a chain of one-shot `ScheduleWakeup` (or equivalent) calls for a recurring user-facing poll. Promise to "check back in N minutes" without backing it with an active `/loop` or `CronCreate` job. Exit a wake-up turn without confirming the next tick is scheduled.

The 5-minute heartbeat rule catches silence during turns; this file covers polling that must survive between turns.

## Tool Selection Decision Tree

| User request / context | Primitive | Why |
|------------------------|-----------|-----|
| Recurring: "poll/check/watch every N", "keep running /skill" | **`/loop`** | Runtime owns cadence |
| ≥3 concurrent polls or cross-session durability | **`CronCreate`** | Durable fleet job |
| One-shot "wake me in N minutes" | `ScheduleWakeup` | Single tick only |

> **Default for any recurring user-facing poll is `/loop`.** Only drop to `CronCreate` when `/loop` doesn't fit (cross-session durability, multi-task fleet). Never drop to a hand-rolled one-shot chain.

## Forbidden Pattern: Hand-Rolled One-Shot Chains

Do not implement recurrence as "do work, then schedule the next one-shot wakeup." Forgetting or failing the re-schedule silently kills the poll. Correct replacement: issue `/loop N <command>` once; the runtime re-arms it until the user stops it.

## Mandatory Pre-Exit Checklist for Polling Turns

Before the end of any polling turn (`/loop`, `CronCreate`, or legacy one-shot chain), verify all three. Missing one is blocking.

1. **Next tick scheduled?**
   - `/loop`: verify the loop is still active. If you invoked a skill that may have displaced the loop, confirm `/loop` is re-armed (or that the runtime auto-resumes it).
   - `CronCreate`: confirm the job still exists via `CronList` — a prior `CronDelete` or 7-day expiry may have removed it.
   - Legacy `ScheduleWakeup` chain: confirm this turn made the next-tick call **and** that the call returned without error. If the call was skipped or errored, switch the chain to `/loop` now.
2. **User heartbeat sent this turn?** Timestamped visible message summarizing what happened and what is next.
3. **Monitoring state recorded?** Update `~/.claude/session-state.json` with tick time, next expected tick, and watermarks (last review ID, last HEAD SHA, etc.). See `handoff-files.md`.

## Failure Recovery

If the user reports a dropped tick:

1. Acknowledge it.
2. Re-establish with `/loop`, not another one-shot chain; state cadence and command.
3. Record `polling_failures[]` in `session-state.json`.
4. If new, append the failure mode to `.claude/reference/scheduling-failure-modes.md` after the session.

## Related

- `monitor-mode.md` — in-turn heartbeat and monitor loop (complements this file: heartbeats catch silence during turns; this file catches silence between turns)
- `.claude/reference/scheduling-failure-modes.md` — canonical list of observed failure modes with case studies
- `handoff-files.md` — `session-state.json` schema, including the polling-state fields this file requires
