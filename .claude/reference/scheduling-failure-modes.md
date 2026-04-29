# Scheduling Failure Modes — Observed Patterns

> Reference material for `.claude/rules/scheduling-reliability.md`. Each pattern is recorded as a case study so that future sessions (and future rule edits) have concrete symptoms to match against.

The common thread: **between-turn scheduling has no in-turn observer.** Once the next tick fails to fire, there is no agent turn in which the 5-minute heartbeat hook can warn. The user is the first detector. These patterns exist to shorten the detection loop — recognize the symptom, re-establish with `/loop`, and stop re-committing the same class of error.

## Pattern 1 — First-Tick-Fires-Then-Drops

**Symptom.** The agent sets up a poll ("I'll check back in 5 minutes") and the first tick fires on schedule. The second tick never arrives. The user eventually prompts: "what happened to the polling?" or "did you check?"

**Root cause.** Hand-rolled one-shot chains require the agent to call `ScheduleWakeup` (or equivalent) at the end of *every* turn. Any turn where the agent forgets the re-arm, or where the re-arm call silently errors, ends the chain. The first tick often works because the setup is fresh in-context; subsequent ticks are cold and the re-arm is easy to drop.

**Fix.** Replace with `/loop N <command>`. The runtime owns the cadence; the agent never has to remember.

## Pattern 2 — Cold-Cache Fragility on Long Intervals

**Symptom.** Polling with an interval >5 minutes (especially >10–30 min) exhibits flakier tick behavior than short-interval polling in the same session — partial completion, missed state updates, or skipped re-arms.

**Root cause.** The Anthropic prompt-cache TTL is ~5 minutes. Any tick that fires after the TTL elapses is a cold-cache turn. Cold turns are more vulnerable to:
- Losing in-memory context that the re-arm logic depended on
- Partial completion if the model is under pressure on the cold turn
- Subtle drift in what "the last watermark" meant

**Fix.** For genuinely long intervals, use `CronCreate` — it fires a fresh invocation with a self-contained prompt, so there is no in-memory state to lose. For short intervals (≤5 min), `/loop` stays warm and avoids the problem entirely. Don't optimize cadence inside a flaky chain — fix the chain by switching primitive.

## Pattern 3 — Silent Re-Schedule Failures

**Symptom.** Same as Pattern 1 (user must prompt to discover the drop), but the re-schedule call was actually made — it just failed.

**Root causes observed:**
- **Malformed `prompt` parameter** — e.g., an autonomous sentinel that the runtime does not recognize, or a prompt string with embedded tool-call syntax that the validator rejects.
- **`delaySeconds` outside the clamp** — `ScheduleWakeup` clamps `[60, 3600]`. A call with `30` or `7200` is silently clamped; a call with a non-numeric value errors.
- **Runtime rejection not surfaced to user** — the tool-call error is visible to the agent but not to the user, so if the agent exits without a heartbeat, the user never learns.

**Fix.** `/loop` eliminates the failure surface — there is no re-schedule call to fail. If a one-shot primitive is still in use (rare), the agent MUST verify the scheduling call returned cleanly before exiting the turn, and must surface any error in a user-visible heartbeat.

## Pattern 4 — Scheduler Promise With No Scheduler

**Symptom.** The agent says "I'll check back in N minutes" in user-facing text but never actually issues a scheduling call. The promise is rhetorical. No tick ever fires.

**Root cause.** The agent described the intent but omitted the tool call — a pure output-vs-action mismatch. Often triggered when the agent is summarizing and conflates "I will" with "I did."

**Fix.** Before any message that commits to a future check-back, the same turn must contain an active `/loop` (or `CronCreate`) call. If no scheduler is armed, do not promise one — say "ping me when you want the status" instead.

## Pattern 5 — Stable-State Flooding

**Symptom.** A durable poll keeps firing at base cadence after a PR reaches steady state. Every tick reports the same HEAD SHA, review verdicts, CI blocker, and "awaiting user direction" status, burying useful signal under duplicate heartbeats.

**Root cause.** The scheduler had no stable-state digest or backoff gate, so "nothing changed" was treated like actionable progress forever. In PR #359 on 2026-04-25, cron `e7230e2f` kept a 1-minute cadence while orphan one-shot `4e56074f` also remained alive; ticks #45-#93 repeated the same state for roughly 50 minutes until the user manually stopped it.

**Fix.** Apply `scheduling-reliability.md` "Stable-State Backoff & Auto-Pause": compute the digest, increment `digest_streak`, widen to 5m at streak 3, widen to 15m at streak 6, and pause at streak 9. If `blocker_kind == "user_input"` or the blocker text says the agent is awaiting the user's direction, pause after the first visible message. When deleting or promoting the cron, also cancel sibling `ScheduleWakeup` jobs.

## Detection Heuristics

Treat any of these as a scheduling failure until proven otherwise:

- User says "your polling didn't fire" / "what happened to the check?" / "you said you'd come back"
- User prompts for status after the promised tick time with no intervening agent message
- `session-state.json` records a polling context but `CronList` has no matching job and no `/loop` is visible
- Post-compaction recovery finds a `polling_failures` entry or a `monitoring_active: true` flag with no live schedule
- Repeated poll ticks show unchanged `digest`/`digest_streak`, unchanged blocker, and no matching `last_cron_action` backoff

Recovery is always the same: apologize briefly, issue `/loop`, record the incident, continue.

## Canonical Incident — 2026-04-20 Dropped PM Tick

**Context.** During a PM monitoring session, the agent promised "I'll check back at 12:02 PM ET" after a prior successful tick at 11:57 AM. The 12:02 tick never fired. The user prompted at 12:11 PM: "did you check?" — the silent 9-minute gap was the detection signal.

**Root cause (diagnosed post-hoc).** The 11:57 turn ran substantive work and exited without re-arming `ScheduleWakeup`. No error was surfaced because no re-schedule call was made. The 5-minute heartbeat hook could not fire because there was no subsequent turn.

**Fix applied.** Re-established via `/loop 5m /status`. No further drops in that session.

**Lesson.** Documented in memory (`feedback_schedulewakeup_silent_drop.md`) so future sessions recognize the pattern on the first instance rather than the Nth.
