# Scheduling Reliability

> **Always:** Use a persistent `Monitor` for user-facing "poll every N" requests — including the default in-flight-PR watch (`CLAUDE.md`). Run the pre-exit checklist. Record polling state in `session-state.json`.
> **Ask first:** Never — scheduling reliability is autonomous.
> **Never:** Use `CronCreate`, dynamic `/loop`, or chained one-shot `ScheduleWakeup` calls for a recurring user-facing poll. Promise to "check back in N minutes" without an active `Monitor`. Exit a wake-up turn without confirming the monitor is live and the last tick fired. Leave background work running with no ceiling armed.

This file covers between-turn polling. **Background work in flight is a polling context** — that wait is between turns too. In-turn silence is default (CLAUDE.md #3); the bgwork-ceiling backstop is the liveness signal.

## Tool Selection Decision Tree

| User request / context | Primitive | Why |
|------------------------|-----------|-----|
| Recurring: "poll/check/watch every N", "keep running /skill" | **persistent `Monitor`** | The only primitive with positive idle-liveness evidence (#914, #924) |
| Wall-clock cadence, ≥3 concurrent polls | **persistent `Monitor`** | One out-of-turn process can emit each tick independently |
| One-shot "wake me in N minutes" | `ScheduleWakeup` | Single tick only |
| Declared leave time ("I need to leave at 7 PM", "hard stop at 5:30") | **`/leave-by`** — arms the window, then one persistent `Monitor` (an already-due check-in runs inline, arming none) | Wall-clock wind-down, not a poll |
| Background work in flight (subagent, background process, watcher) | **ceiling watch** — `bgwork-ceiling.sh --arm-command` → `Monitor` | Backstop, not a poll |

## Declared Leave Times

Routing only — `/leave-by` owns the source gate, countermand, and check-in wording; do not restate them here.

- Route a wall-clock stop stated in chat to `/leave-by`, from **any** orchestration thread. Arming one is not becoming a `/pm` thread. Only a live user message arms, changes, or cancels one; a message during the runway **re-plans**.
- The deadline is repo-scoped (`.window.deadline_epoch`); read it through `session-state.sh` and decline over-running pipelines at every launch (`/subagent` Step 7, `phase-protocols.md` §Launch gate).
- **At session start and after compaction, recover it explicitly** — `--session-view` projects no `.leave`, so an unrecovered declaration dies with its Monitor and the wind-down never fires. Run `/leave-by` Step 11 whenever `.repos["<key>"].leave` exists.

Mechanism and rationale: `.claude/reference/leave-time.md`.

## PM Monitoring Primitive

Division of responsibility (`.claude/reference/pm-monitoring-decision.md`):

- `/pm` creates no polls; `/pm day` owns one repo `Monitor`, excluding `/pr-monitor-and-manage`.
- `/pr-monitor-and-manage` owns PR-fleet between-message polling (persistent `Monitor`, including `--auto-wake`).
- `CronCreate` — **never**: see contract below.

Skill-owned polling updates `session-state.json` per skill's contract; stale state → `monitor-mode.md` PM Monitoring Recovery.

### Recurring scheduler contract (authoritative)

**CronCreate is unreliable** — reproducibly zero ticks under common usage (#914, #924) — and **session-only and in-memory**: `durable` has **no effect**, nothing survives a session boundary. Use `Monitor`; **durable work belongs in on-disk state, not a job.** A durable scheduler exists (`mcp__scheduled-tasks__*`); why we decline it: `.claude/reference/cross-session-durability.md`. Failure-mode detail: `.claude/reference/scheduling-failure-modes.md` Pattern 7.

## Mandatory Pre-Exit Checklist for Polling Turns

Before any polling turn ends (`Monitor`, legacy one-shot, or a turn ending with background work in flight), verify all three:

1. **Next tick scheduled — and ticking?** Presence is not liveness: a listed job can produce zero ticks (Pattern 7); confirm `babysit.last_tick_at` is within its interval.
   - `Monitor`: verify its task is active and its command emitted the latest expected tick.
   - Legacy `ScheduleWakeup`: confirm this turn made the next-tick call and it returned cleanly. Never chain it for recurrence; switch to `Monitor`.
   - Background work: `bgwork-ceiling.sh --check` passes; if not, arm it (`--arm-command` → `Monitor`). The Stop hook blocks the turn otherwise.
2. **Any blocker, failure, or decision requiring output?** If yes, surface it immediately (≤2 lines, action first); otherwise stay silent. Defined exceptions — merged PR #N, 4+ file-write status, refill picks — always emit and are not suppressed by silence-by-default.
3. **Monitoring state recorded?** Update `~/.claude/session-state.json` with tick time, next expected tick, and watermarks (last review ID, last HEAD SHA, etc.). See `handoff-files.md`.

## Stable-State Backoff

Hash each tick's `(head_sha, cr_state, bugbot_state, greptile_state, ci_blocking_conclusions_sorted, blocker_kind)` into `prs.{N}.digest_streak` (free-text `blocker` excluded). Widen at streak ≥3 to `max(15m, 3×base)`; stop the poll at ≥9 (`/pm day` pauses resumably instead) or on `blocker_kind == "user_input"`. Resume at base cadence after a user message or a changed digest. Enforced by `polling-backoff-warn.sh`. Backoff never reaches the ceiling watch — it widens or stops the poll; the watch is a `Monitor`.

## Failure Recovery

On a dropped tick: re-establish with `Monitor`; record in `polling_failures[]`; if new, append to `.claude/reference/scheduling-failure-modes.md`.

Monitor mode: `monitor-mode.md`; ceiling mechanism and rationale: `.claude/reference/bgwork-ceiling.md`.
