# Scheduling Reliability — Polling That Doesn't Die Silently

> **Always:** Use `/loop` for any user-facing "poll every N / check every N / watch for X" request. Run the pre-exit checklist on every wake-up turn. Record polling state in `session-state.json`.
> **Ask first:** Never — scheduling reliability is autonomous.
> **Never:** Hand-roll a chain of one-shot `ScheduleWakeup` (or equivalent) calls for a recurring user-facing poll. Promise to "check back in N minutes" without backing it with an active `/loop` or `CronCreate` job. Exit a wake-up turn without confirming the next tick is scheduled.

The 5-minute heartbeat rule (CLAUDE.md #3, `monitor-mode.md`) catches silence **during** turns. It cannot detect a polling chain that died between turns — once `ScheduleWakeup` stops firing, there is no turn for the hook to warn in. This rule closes that gap.

## Tool Selection Decision Tree

Pick the primitive based on what the user asked for:

| User request / context | Primitive | Why |
|------------------------|-----------|-----|
| "Poll every N", "check every N", "watch for X", "keep running /skill" | **`/loop`** | Runtime manages the cadence — the agent cannot forget to re-schedule |
| ≥3 concurrent autonomous polls, or the job must survive across sessions | **`CronCreate`** | Durable, fleet-managed, fires even when REPL is idle |
| One-shot "wake me up in N minutes for X" with no recurrence | `ScheduleWakeup` (or equivalent single-shot primitive) | Single tick is exactly what the primitive guarantees |

> **Default for any recurring user-facing poll is `/loop`.** Only drop to `CronCreate` when `/loop` doesn't fit (cross-session durability, multi-task fleet). Never drop to a hand-rolled one-shot chain.

## Forbidden Pattern: Hand-Rolled One-Shot Chains

**Do not** promise a recurring poll and implement it as: "run the work this turn, then call `ScheduleWakeup` at the end to fire the next tick." That pattern requires the model to remember — and successfully execute — the re-schedule on every turn. Two silent failure modes:

1. **Model forgets to re-schedule.** No error, no warning, no turn fires — the loop is simply gone.
2. **Re-schedule call fails silently.** Malformed `prompt`, rejected `delaySeconds`, bad sentinel — same end state: no next tick.

Both failures are invisible to the in-turn heartbeat hook because there is no next turn for it to run in. The user discovers it only by pinging: "what happened to the polling you promised?"

**Correct replacement:** issue `/loop N <command>` once. The runtime owns the cadence. If the user wants to stop it, they say "stop polling" or interrupt it — the agent never has to re-arm it.

## Mandatory Pre-Exit Checklist for Polling Turns

Before the end of any turn that is part of a polling loop (whether fired by `/loop`, `CronCreate`, or a legacy `ScheduleWakeup` chain), verify **all three** items below. Missing any one = blocking error — do not exit until it is fixed.

1. **Next tick scheduled?**
   - `/loop`: verify the loop is still active. If you invoked a skill that may have displaced the loop, confirm `/loop` is re-armed (or that the runtime auto-resumes it).
   - `CronCreate`: confirm the job still exists via `CronList` — a prior `CronDelete` or 7-day expiry may have removed it.
   - Legacy `ScheduleWakeup` chain: confirm this turn made the next-tick call **and** that the call returned without error. If the call was skipped or errored, switch the chain to `/loop` now.
2. **User heartbeat sent this turn?** A visible message with a timestamp, summarizing what the tick did and what is next. See `monitor-mode.md` "User Heartbeat". A tick that did no user-visible work is still a tick — report it briefly so the user sees the poll is alive.
3. **Monitoring state recorded?** Update `~/.claude/session-state.json` with the tick timestamp, the next expected tick, and any watermarks (last-seen review ID, last HEAD SHA, etc.) that the next tick will consume. See `handoff-files.md` for the schema. A crashed poll that the next session can reconstruct from `session-state.json` is recoverable; one that left no trace is not.

## Failure Recovery

If the user says "what happened to the polling?" / "your check didn't fire" / anything that implies a dropped tick:

1. **Acknowledge the drop** — do not argue or hand-wave. The silent failure is the symptom, the promise to poll was the commitment.
2. **Re-establish with `/loop`**, not with another hand-rolled chain. State the cadence and the command: "Restarting with `/loop 5m /status` — the runtime owns the cadence now, so it won't drop again."
3. **Record the incident** — add a line to `session-state.json` (`polling_failures` array, if not already present) so post-compaction recovery can see the pattern.
4. **If this is a new failure mode** (not already documented in `.claude/reference/scheduling-failure-modes.md`), append it to that file after the session ends.

## Related

- `monitor-mode.md` — in-turn heartbeat and monitor loop (complements this file: heartbeats catch silence during turns; this file catches silence between turns)
- `.claude/reference/scheduling-failure-modes.md` — canonical list of observed failure modes with case studies
- `handoff-files.md` — `session-state.json` schema, including the polling-state fields this file requires
