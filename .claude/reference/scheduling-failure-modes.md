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

**Fix.** Use `/loop`, at any interval. For short intervals (≤5 min) it stays warm and avoids the
problem entirely. Don't optimize cadence inside a flaky chain — fix the chain by switching primitive.

> **Superseded (#914).** This entry used to recommend `CronCreate` for long intervals, on the
> reasoning that each tick is a fresh self-contained invocation with no in-memory state to lose.
> That reasoning is sound and the conclusion is still wrong: Pattern 7 measured armed cron jobs
> firing **zero** ticks in-session. A primitive that does not fire cannot fix cold-cache
> fragility. Left visible rather than deleted, because the argument is persuasive enough to be
> reinvented — and the cross-session caveat it carried is also still true (`CronCreate` is
> session-scoped and dies when Claude exits).

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

**Fix.** Apply `scheduling-reliability.md` "Stable-State Backoff": compute the digest, increment `digest_streak`, widen to `max(15m, 3×base)` at streak 3 (for the default 5m base this is 15m — always strictly greater than the base), and pause at streak 9. If `blocker_kind == "user_input"` or the blocker text says the agent is awaiting the user's direction, pause after the first visible message. When deleting or promoting the cron, also cancel sibling `ScheduleWakeup` jobs.

> **Authoritative source decision (issue #794):** the base-relative formula `max(15m, 3×base)` from `babysit-pr/SKILL.md` T5 was made authoritative over the earlier absolute `5m`/`15m` ladder in `scheduling-reliability.md`, because absolute minutes silently no-op at the documented 5m default (widening to 5m from 5m is no change). The base-relative form is correct at every `--cadence` value and was validated live on PR #775.

## Pattern 6 — Background Work With No Armed Observer

**Symptom.** The thread hands work to a subagent (or starts a long background process, or arms a watcher), ends its turn, and goes silent. The last chat message is 15–25 minutes old. Nothing is wrong with the subagent — it is simply still running — but the transcript cannot distinguish "grinding away" from "wedged" from "dead", and the user has to ask "status?" to learn anything.

**Root cause.** Printing a message requires a turn, and nothing in the spawn path guaranteed a turn would happen. The in-context nag (`silence-detector.sh`) is a PostToolUse hook, and a thread waiting on a completion notification makes no tool calls; the launchd watchdog notices the stall but can only raise an OS notification, and it skips sessions whose `claude-active-<id>` marker is gone — which is precisely the ended-its-turn state. The deeper miss: monitoring background work was never *classified* as polling, so none of this file's discipline was applied to it.

**Fix.** `scheduling-reliability.md` now classifies a thread with background work in flight as a polling context, and starting that work arms a turn-independent ceiling watch (`bgwork-ceiling.sh --arm-command` → `Monitor`). The Stop hook blocks a turn that would end unarmed, so this pattern cannot recur through forgetfulness.

**It is mitigation, not an absolute guarantee.** Blocking is bounded at 2 consecutive turns; past that the guard stands down and an unarmed turn *is* allowed to end. That fallback is deliberately loud — stderr, `~/.claude/logs/bgwork-ceiling.log`, and an unguarded marker resurfaced on every later tool call — so a thread that ends up without a ceiling says so, rather than looking identical to a healthy one. Mechanism: `.claude/reference/bgwork-ceiling.md` (#803).

**Note the shape difference from Patterns 1–4.** Those are *dropped* ticks — a schedule existed and stopped. This one is a schedule that was never armed at all, because nobody recognised the situation as scheduling. Detection heuristics keyed on "a polling context with no live job" therefore missed it entirely: there was no polling context recorded to check against.

## Pattern 7 — Armed Poll With Zero Ticks

**Symptom.** A poll is armed successfully, `CronList` still shows it, the REPL is idle for
many multiples of the interval — and **not one tick fires**. Unlike every pattern above, there
is nothing to find wrong with the schedule: it exists, it is listed, and it is silent.

**Shape difference from the other patterns.** Patterns 1/3 *fired once, then dropped* — a
schedule that existed and stopped. Pattern 6 was *never armed at all*. This one is armed,
still listed, and dead. That combination defeats every detection heuristic written before it,
all of which look for a **missing** job. A present job read as proof of a working poll.

**Observed — PR #908, 2026-08-01.** `/babysit-pr 908` armed a `CronCreate` watcher
(`*/5 * * * *`, job `a106ce94`) at ~12:15 PM ET. Across the PR's lifetime not one tick fired
on its own; all six ticks were driven by hand after a `bgwork-ceiling.sh` breach notification.
Two windows with the REPL idle throughout — 12:17→12:34 and 12:42→12:59 — expected three
fires each and produced zero. Both ended with a ceiling breach, not a tick. The branch went
`BEHIND` twice and a bot verdict landed, all discovered ~18 minutes late.

### Reproduction (issue #914, run 2026-08-01 21:03–21:14 ET)

Confirmed under controlled conditions. The procedure, so it can be re-run:

1. Arm two `CronCreate` jobs at different cadences (`*/2` and `*/5`), each appending a
   timestamped line to a log file on disk. Two cadences rule out a cadence-specific quirk.
2. **Capture `CronList` immediately after arming** — this is the evidence the original
   incident lacked, and it is what separates "listed but silent" from "silently dropped".
3. Start an out-of-turn probe (backgrounded `bash`, not a tool call) that samples the log
   every 20s. **The evidence must not depend on the agent being awake to observe it** —
   otherwise "no ticks" is indistinguishable from "the agent never looked".
4. End the turn and stay idle past 3+ intervals. Ending the turn is the whole experiment:
   `CronCreate` fires only while the REPL is idle, so any in-turn observer destroys the
   condition under test.
5. On wake, re-capture `CronList` and count log lines.

**Result: zero ticks in 11 minutes.** Expected ~7 fires (five from the 2-minute job, two from
the 5-minute job). The probe sampled 33 times and recorded `tick_lines=0` on every sample;
`0` was the only value ever observed. `CronList` listed **both jobs as still scheduled** after
the window. The jobs were not dropped and the REPL was genuinely idle — the probe ran
detached, and no agent turn occurred between arming and wake.

### What this does and does not establish

**Established.** An armed, listed `CronCreate` job can produce zero in-session ticks while the
REPL is idle, at more than one cadence, reproducibly. It is not a dropped job, not expiry, not
the documented ≤10%-of-period jitter (which would delay a 2-minute job by ≤12s, not 11 minutes),
and not the "only fires while the REPL is idle" caveat — the REPL *was* idle.

**Not isolated.** A `persistent: true` `Monitor` (the ceiling watch) was armed throughout, as it
was in the original incident, so "a concurrent `Monitor` suppresses cron firing" remains
consistent with the data but unproven. **The control experiment was deliberately not run**: it
requires a window with no background process at all, and every mechanism that guarantees the
agent wakes up again *is* a background process. Removing the variable means risking a session
that never wakes. A future session with a human present can run it — arm one cron job, no
`Monitor`, no backgrounded probe, and have the human observe.

**The `/loop` delegation is confirmed, and it is the propagation path.** Invoking
`/loop 5m <command>` returns the skill's own instructions, whose fixed-interval mode reads:
"Call CronCreate with: `cron` (the expression above), `prompt` (the parsed prompt verbatim),
`recurring: true`." So `/loop <interval>` **is** `CronCreate` underneath. Combined with the zero-tick
result, that means:

> A fixed-interval `/loop` watcher is dead by construction. `/babysit-pr` specifying "the watcher
> is always `/loop`" was not the safeguard it read as — at `--cadence 5m` it produced exactly the
> job that does not fire. The skill text and the runtime never disagreed; both led to `CronCreate`.

`/loop`'s **dynamic mode** (invoked with no interval) is a different path: it self-paces with
`ScheduleWakeup` and arms a `Monitor` as the primary wake signal for event-gated work. Whether the
remaining miss is in `CronCreate`'s scheduler or the idle-detection gate cannot be narrowed further
from outside the harness — both are runtime internals with no repo-authored implementation.

**What was observed firing, this session, under the same conditions:** the `Monitor`-backed silence
ceiling tripped on schedule and forced a turn. `ScheduleWakeup` was not exercised. So of the three
primitives, exactly one has positive evidence, one has negative evidence, and one is untested —
which is why the guidance below prefers `Monitor` and treats presence as no evidence of liveness.

**Fix.** Treat `CronCreate` as a non-firing primitive and back every user-facing poll with
`/loop` (`scheduling-reliability.md` decision tree). Verify **liveness, not presence**, before
ending a polling turn. `.claude/hooks/babysit-tick-watchdog.sh` surfaces a stalled watcher at
2 × cadence, so a dead poll is now reported rather than mistaken for a quiet one.

**The backstop is not the poll.** In the observed incident the ceiling watch did all the work
and the poll contributed nothing. That is a *degraded* state, not the design:
`bgwork-ceiling.md` deliberately separates the two, and the ceiling trips on a silence budget
far wider than any poll cadence. A run where the ceiling is the only thing producing ticks
should be read as a broken poll, not a working watch.

## Detection Heuristics

Treat any of these as a scheduling failure until proven otherwise:

- User says "your polling didn't fire" / "what happened to the check?" / "you said you'd come back"
- User prompts for status after the promised tick time with no intervening agent message
- `session-state.json` records a polling context but `CronList` has no matching job and no `/loop` is visible
- **A job *is* listed (or a watcher is `active`) yet `babysit.last_tick_at` is older than
  2 × `cadence_effective_minutes`, with no manual driver in between** (Pattern 7). Every other
  heuristic here checks for a *missing* job; this is the only one that catches a present-but-dead one.
- Post-compaction recovery finds a `polling_failures` entry or a `monitoring_active: true` flag with no live schedule
- Repeated poll ticks show unchanged `digest`/`digest_streak`, unchanged blocker, and no matching `last_cron_action` backoff

Recovery is always the same: apologize briefly, issue `/loop`, record the incident, continue.

## Canonical Incident — 2026-04-20 Dropped PM Tick

**Context.** During a PM monitoring session, the agent promised "I'll check back at 12:02 PM ET" after a prior successful tick at 11:57 AM. The 12:02 tick never fired. The user prompted at 12:11 PM: "did you check?" — the silent 9-minute gap was the detection signal.

**Root cause (diagnosed post-hoc).** The 11:57 turn ran substantive work and exited without re-arming `ScheduleWakeup`. No error was surfaced because no re-schedule call was made. The 5-minute heartbeat hook could not fire because there was no subsequent turn.

**Fix applied.** Re-established via `/loop 5m /status`. No further drops in that session.

**Lesson.** Documented in memory (`feedback_schedulewakeup_silent_drop.md`) so future sessions recognize the pattern on the first instance rather than the Nth.
