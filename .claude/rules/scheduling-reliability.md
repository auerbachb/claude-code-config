# Scheduling Reliability

> **Always:** Use `/loop` for user-facing "poll/check/watch every N" requests — including the default in-flight-PR watch (`CLAUDE.md`). Run the pre-exit checklist. Record polling state in `session-state.json`.
> **Ask first:** Never — scheduling reliability is autonomous.
> **Never:** Hand-roll a chain of one-shot `ScheduleWakeup` (or equivalent) calls for a recurring user-facing poll. Promise to "check back in N minutes" without backing it with an active `/loop` or `CronCreate` job. Exit a wake-up turn without confirming the next tick is scheduled. Leave background work running with no ceiling armed.

The 5-minute heartbeat rule catches silence during turns; this file covers between-turn polling. **Background work in flight is a polling context** — that wait is between turns too.

## Tool Selection Decision Tree

| User request / context | Primitive | Why |
|------------------------|-----------|-----|
| Recurring: "poll/check/watch every N", "keep running /skill" | **`/loop`** | Runtime owns cadence |
| ≥3 concurrent polls or cross-session durability | **`CronCreate`** | Durable fleet job |
| One-shot "wake me in N minutes" | `ScheduleWakeup` | Single tick only |
| Background work in flight (subagent, background process, watcher) | **ceiling watch** — `bgwork-ceiling.sh --arm-command` → `Monitor` | Backstop, not a poll — still `/loop` if status is due |

> Why the "Never" above: a forgotten re-arm silently kills a hand-rolled one-shot chain; `/loop` re-arms itself.

## PM Monitoring Primitive

Division of responsibility (see `.claude/reference/pm-monitoring-decision.md`):

- `/pm` never creates polls — on-demand orchestration only.
- `/pr-monitor-and-manage` owns PR-fleet between-message polling (`/loop` + optional `CronCreate` auto-wake).
- `/loop` remains valid for explicit user-invoked "poll every N" that is not PR-fleet-specific.
- `CronCreate` for cross-session durability or fleet jobs owned by dedicated skills.

Skill-owned polling turns update `session-state.json` per that skill's contract; stale orchestration state → `monitor-mode.md` PM Monitoring Recovery + this file's dropped-tick handling.

## Mandatory Pre-Exit Checklist for Polling Turns

Before any polling turn ends (`/loop`, `CronCreate`, legacy one-shot, or a turn ending with background work in flight), verify all three:

1. **Next tick scheduled?**
   - `/loop`: verify it is active/re-armed.
   - `CronCreate`: confirm with `CronList`; prior `CronDelete` or 7-day expiry may remove it.
   - Legacy `ScheduleWakeup`: confirm this turn made the next-tick call and it returned cleanly. If skipped/errored, switch to `/loop`.
   - Background work: `bgwork-ceiling.sh --check` passes; if not, arm it (`--arm-command` → `Monitor`). The Stop hook blocks the turn otherwise.
2. **User heartbeat sent this turn?** Timestamped one-liner: what happened, what's next.
3. **Monitoring state recorded?** Update `~/.claude/session-state.json` with tick time, next expected tick, and watermarks (last review ID, last HEAD SHA, etc.). See `handoff-files.md`.

## Stable-State Backoff

Each tick hash `(head_sha, cr_state, bugbot_state, greptile_state, ci_blocking_conclusions_sorted, blocker_kind)` into `prs.{N}.digest_streak` (free-text `blocker` excluded). Widen at streak ≥3→5m, ≥6→15m; `CronDelete` at ≥9 or `blocker_kind == "user_input"`. Resume at base cadence after user message or changed digest. `polling-backoff-warn.sh` enforces this. Backoff cannot reach the ceiling watch: it widens and deletes cron jobs; the watch is a `Monitor`.

## Failure Recovery

If the user reports a dropped tick: re-establish with `/loop` (never a one-shot chain); record in `polling_failures[]`; if new, append to `.claude/reference/scheduling-failure-modes.md`.

## Related

`monitor-mode.md` (in-turn heartbeat/monitor loop) · `.claude/reference/scheduling-failure-modes.md` (observed failure modes) · `.claude/reference/bgwork-ceiling.md` (ceiling mechanism + rationale) · `handoff-files.md` (`session-state.json` schema).
