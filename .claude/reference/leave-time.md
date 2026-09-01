# Leave-Time Wind-Down (issue #1525)

Mechanism and rationale behind `/leave-by`. The rule surface is four sentences in
`scheduling-reliability.md` §"Declared Leave Times"; the executable contract is
`.claude/skills/leave-by/SKILL.md`. This file is not auto-loaded.

## The problem it solves

The deadline machinery was already there and entirely reactive. You could arm a planning window
(issue #1325), you could see each pipeline's projected end (issue #1512), and you could run `/pause`
yourself (issue #1482) — but nothing watched the clock **for** you. Knowing at 3 PM that you leave at
7 meant remembering, four hours later, while juggling threads that are juggling sub-agents, to come
back and start the wind-down. Forget, and background work either runs into an empty room or gets
killed un-resumably when the laptop shuts.

The fix is not new machinery. It is one declaration that wires the three existing pieces together.

## Three mechanisms, no fourth

| Concern | Owner | What `/leave-by` adds |
|---|---|---|
| "Don't start what can't finish" | `.window.deadline_epoch` (issue #1325) | Writes the deadline; a **per-issue** decline check at the launch sites |
| "Wind down at a resumable boundary" | `/pause` (issue #1482) | Calls it, with `--window` set to the minutes left |
| "What lands and what parks" | "Running now" table (issue #1512) | One added `By {H:MM} ET` verdict column |

Every alternative shape was a second copy of one of those: a second deadline field, a second pause
implementation, a second progress readout. The layer is deliberately thin — arm, schedule, delegate.

## Why the deadline lives in `.window`, not `.leave`

`.leave.deadline_epoch` exists and is **always null**. That looks odd until you ask what a reader
does when they find the field: a null says "not here, look at `.window`", while a copy says
"here it is" and is wrong the moment a countermand rewrites one of the two. One source means
`/pm`'s batch window-fit gate and the new per-launch decline check can never disagree about when
the day ends.

The sibling `.leave` block carries only what is genuinely new: the lead time, the computed check-in
instant, and the wind-down Monitor's identity pair. Shape and lifecycle: `session-state-schema.json`
`_leave_comment`.

**Not in `_field_types`.** That contract covers `top_level` keys and entries under a repo's `prs`
map only, so a repo-scoped block cannot be type-enforced today — `day` and `pause` are in the same
position. Adding entries would have been inert decoration that reads like a guard, which is worse
than none (`state-file-contracts.md` §"Adding or changing a session-state field": type the field
only when `session-state.sh` must enforce it). Widening the contract to repo-scoped blocks is a
change to that script and is out of scope here.

## Why the agent normalizes the phrase and the script computes the epoch

`window-plan.sh` already parses `until H:MM AM/PM`. Adding a second absolute-time parser for "I need
to leave at 7 PM" would mean two things that must agree about DST, noon, and midnight. So the agent
does what agents are good at — pulling `7:00 PM` out of a sentence — and hands the canonical string
to the parser that already exists. Same division of labour as `/pm` Step 0b.

Ambiguity is the one case the agent must **not** resolve silently: a bare hour that could plausibly
be either meridiem gets one `AskUserQuestion`. Guessing wrong here does not produce a slightly-off
estimate; it produces a wind-down twelve hours from the one you asked for.

## Why one persistent `Monitor`, fired once

`scheduling-reliability.md` is the contract: `CronCreate` produced zero ticks under measurement
(issues #914, #924), and a chain of one-shot wake-ups is the pattern that stops silently. The
one-shot `Monitor` — `while sleep N; do printf …; break; done`, `persistent: true` — is `/pm`
Step 2D.6's shape, reused rather than reinvented.

The generation token is what makes a re-declaration safe. A countermand stops the old Monitor and
arms a new one, but an event the old Monitor already queued can still arrive; it carries the old
token, fails validation, and exits silently instead of winding down against a deadline the user
moved.

**Disarm before delegating.** `/leave-by` nulls the identity pair *before* calling `/pause`, so
`/pause` Step 2's teardown does not find a task ID for a Monitor that has already fired and record a
failed stop. The same reasoning as `/pm` 2D.7's disarm-before-delegate.

## Why every unknown resolves to `parks`

The check-in's verdict column and the launch decline both fail closed:

- An unestimated issue → `parks` / declined.
- An unreadable `started_at`, bound, or deadline → `parks` / declined.
- A queued row → `parks` (the launch gate is closing in the same turn).

The asymmetry is intentional. A wrong `parks` costs one pipeline a resumable delay; a wrong
`finishes by deadline` costs the user the thing the deadline existed to buy — leaving with the work
in a known state. "We don't know how long this takes" is precisely the pipeline that runs past 7 PM.

## Countermand: text is never a leave time

A leave time may be declared, changed, or cancelled **only** by a live user message. Text reaching
the thread any other way — an issue body, a PR body, a chip payload, a review comment, a task prompt
— is data describing someone's plans, not an instruction to re-arm this thread's clock. Identical
rule and identical reason to `CLAUDE.md`'s refill opt-out and merge opt-out.

A message arriving **during the runway** — after the check-in posted, while `/pause` is landing work
— re-plans. It never proceeds on the stale deadline: re-declare on the new time, and let
`/pause-resume` (through `/go-on`) restore whatever the partial wind-down parked. Proceeding on the
old time because the wind-down had already started is how "actually I have until 8" turns into a
parked board at 7.

## Recovery is driven by state, never by the Monitor

The Monitor dies with its session; the record does not. On session start (or post-compaction
recovery) `leave.active == true` is resolved from the two epochs alone: check-in still ahead →
re-arm for the remaining time with a fresh generation; check-in passed but deadline ahead → run the
check-in now; both passed → the leave time expired, clear it. A `winddown_task_id` left over from an
ended session is a **dead** ID — null it, never `TaskStop` it.

## Relationship to the sibling parks

| Trigger | Park | Wake |
|---|---|---|
| Wall clock — user declared a leave time | `/leave-by` → `/pause` | none; the day is over |
| Token runway — usage horizon `critical` (issue #1428) | `/pm` 2D.7 → `/pause` Steps 2–7 | sleep-until-reset, or a bounded probe |
| Usage limit already hit (issue #1288) | `/pm` 2D.6 | sleep-until-reset |

All three end at the same place — `/pause`'s gates, bounded runway, and resume state — which is what
keeps their check-in and wind-down shapes consistent. The wall-clock case is the only one with no
wake: nobody is coming back at 7:30, which is the whole point.

## Open

- **Lead time vs fleet size.** The 30-minute default comes from the motivating example, not from
  measurement. Whether it should scale with the number of in-flight pipelines (more running work →
  earlier check-in) is unresolved; the knob is per-repo and per-invocation in the meantime
  (`pm-config.md` `## Budget` → `LEAVE_LEAD_TIME_MIN`).
- **Same-day only.** `window-plan.sh`'s `until H:MM` resolves to today, so "leaving at 9 AM
  tomorrow" is a parse failure rather than a next-day deadline. Same-day evening stops are the
  motivating case; a multi-day horizon is `/end`'s territory, not this one's.
