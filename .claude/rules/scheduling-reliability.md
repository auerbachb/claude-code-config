# Scheduling Reliability

> **Always:** Use `/loop` (no interval) for user-facing "poll every N" requests — including the default in-flight-PR watch (`CLAUDE.md`). Run the pre-exit checklist. Record polling state in `session-state.json`.
> **Ask first:** Never — scheduling reliability is autonomous.
> **Never:** Hand-roll a chain of one-shot `ScheduleWakeup` (or equivalent) calls for a recurring user-facing poll. Promise to "check back in N minutes" without backing it with an active `/loop`. Exit a wake-up turn without confirming the next tick is scheduled and the last one fired. Leave background work running with no ceiling armed.

The 5-minute heartbeat rule catches silence during turns; this file covers between-turn polling. **Background work in flight is a polling context** — that wait is between turns too.

## Tool Selection Decision Tree

| User request / context | Primitive | Why |
|------------------------|-----------|-----|
| Recurring: "poll/check/watch every N", "keep running /skill" | **`/loop` with NO interval** (dynamic) | A fixed interval delegates to `CronCreate`, which does not fire (#914) |
| Wall-clock cadence, ≥3 concurrent polls | **`Monitor`** | The only primitive observed firing while idle (#914) |
| One-shot "wake me in N minutes" | `ScheduleWakeup` | Single tick only |
| Background work in flight (subagent, background process, watcher) | **ceiling watch** — `bgwork-ceiling.sh --arm-command` → `Monitor` | Backstop, not a poll |

## PM Monitoring Primitive

Division of responsibility (`.claude/reference/pm-monitoring-decision.md`):

- `/pm` never creates polls — on-demand orchestration only.
- `/pr-monitor-and-manage` owns PR-fleet between-message polling (`/loop`, including `--auto-wake`).
- `CronCreate` — **never**: see contract below.

Skill-owned polling turns update `session-state.json` per that skill's contract; stale orchestration state → `monitor-mode.md` PM Monitoring Recovery + this file's dropped-tick handling.

### CronCreate contract (authoritative)

**It does not reliably fire.** Reproduced 2026-08-01 (#914): armed jobs, still listed by `CronList`, produced **zero** ticks across an 11-minute idle window at two cadences. **`/loop <interval>` delegates to it**, so a fixed-interval loop inherits this and is dead by construction — use `/loop` with no interval, or a `Monitor`. Detail: `.claude/reference/scheduling-failure-modes.md` Pattern 7.

It is also **session-only and in-memory**: `durable` has **no effect** and nothing survives a session boundary. **Durable work belongs in on-disk state, not a job** (#827): `session-scheduling-reconcile.sh` purges dead job records at session start. A durable scheduler exists (`mcp__scheduled-tasks__*`); why we decline it: `.claude/reference/cross-session-durability.md`.

## Mandatory Pre-Exit Checklist for Polling Turns

Before any polling turn ends (`/loop`, legacy one-shot, or a turn ending with background work in flight), verify all three:

1. **Next tick scheduled — and ticking?** Presence is not liveness: a listed job can produce zero ticks (Pattern 7); confirm `babysit.last_tick_at` is within its interval.
   - `/loop`: verify it is active/re-armed.
   - Legacy `ScheduleWakeup`: confirm this turn made the next-tick call and it returned cleanly. If skipped/errored, switch to `/loop`.
   - Background work: `bgwork-ceiling.sh --check` passes; if not, arm it (`--arm-command` → `Monitor`). The Stop hook blocks the turn otherwise.
2. **User heartbeat sent this turn?** Timestamped one-liner: what happened, what's next.
3. **Monitoring state recorded?** Update `~/.claude/session-state.json` with tick time, next expected tick, and watermarks (last review ID, last HEAD SHA, etc.). See `handoff-files.md`.

## Stable-State Backoff

Each tick hash `(head_sha, cr_state, bugbot_state, greptile_state, ci_blocking_conclusions_sorted, blocker_kind)` into `prs.{N}.digest_streak` (free-text `blocker` excluded). Widen at streak ≥3 to `max(15m, 3×base)`; stop the poll at ≥9 or `blocker_kind == "user_input"`. Resume at base cadence after user message or changed digest. `polling-backoff-warn.sh` enforces this (reads `babysit.cadence_base_minutes`, defaults to 5). Backoff cannot reach the ceiling watch: it widens or stops the poll; the watch is a `Monitor`.

## Failure Recovery

On a dropped tick: re-establish with `/loop`; record in `polling_failures[]`; if new, append to `.claude/reference/scheduling-failure-modes.md`.

In-turn heartbeat and monitor loop: `monitor-mode.md`; ceiling mechanism and rationale: `.claude/reference/bgwork-ceiling.md`.
