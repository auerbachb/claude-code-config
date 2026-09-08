# Leave-Time Wind-Down (issues #1525, #1679)

Mechanism and rationale behind `/leave-by` and the launch gate's leave-time question. The rule
surface is a short pointer block in `scheduling-reliability.md` §"Declared Leave Times"; the
executable contracts are `.claude/skills/leave-by/SKILL.md` and `/subagent` Step 7. This file is
not auto-loaded.

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

## Asking for the time instead of waiting to be told (issue #1679)

Everything above only works if the user volunteers the time. `/leave-by` is reactive by
construction — it is a declaration skill — so a day where nobody says "I'm out at 7" gets none of
the machinery: pipelines plan against an open-ended afternoon, and the laptop closes on work that
either dies un-resumably or runs into an empty room. The one input that makes the whole stack
useful had to arrive unprompted, at the right moment, from a human juggling threads.

So the launch gate asks. **Before the first new-pipeline launch of a thread, when no unexpired
deadline is armed for the repo, `/subagent` Step 7 puts one `AskUserQuestion` up** — two relative
offsets, a clock time, and "No deadline today" — and hands the answer to `/leave-by`, which
normalizes and arms it through its own Steps 1–5. There is no second parser and no second deadline
field: `window-plan.sh` computes the epoch exactly as it does for a typed declaration, and
`.window.deadline_epoch` remains the one home.

**Steps 1–5 only — no Monitor.** The elicited time is a *planning input*: it gates launches, and
that is all this path promises. Arming the Step 6 wind-down Monitor would turn a question the user
answered in passing into a scheduled event that interrupts them later, which is a bigger commitment
than the answer implies. A user who wants the check-in says `/leave-by 7 PM` and gets the full arm,
Monitor included. The two paths write the same state; only Step 6 differs.

**"No deadline today" is an answer, not a refusal.** It writes `.leave.no_deadline_until` — the ET
end-of-day epoch, computed with `credit-budget.sh`'s DST-safe boundary idiom (tomorrow's ET
midnight through the kernel's timezone database, never a hardcoded offset) — alongside
`active: false`, and no `.window` at all. Later launches in the same day read it and stay silent; a
new ET day expires it and the question comes back. Storing "don't ask" as a *time* rather than a
flag is what makes it self-clearing: a boolean set on Monday afternoon would still be suppressing
the question on Thursday.

**A dismissed menu writes the same field, bounded at an hour.** Writing nothing when the user waves
the question away is the nag loop in disguise — repo state is the only thing that suppresses the
ask, so the next launch would put the identical menu up again, and the one after that. An hour is
the smallest bound that ends the loop while leaving the question available later in a long session.
One field carries both scopes because both mean the same thing to every reader — *do not ask again
until this instant* — and a second field would be a second thing to check, forget, and disagree
with.

**Re-asking is gated by repo state alone, never by a session flag.** An armed unexpired deadline or
an unexpired `no_deadline_until` suppresses; an expired deadline or a new day re-arms. A
session-scoped "already asked" flag would have been a fourth thing to recover after a compaction,
and it would ask twice in two threads on the same repo while claiming to ask once.

### The pause point: what the gate actually plans against

The gate compares each issue's planning bound against **`deadline_epoch − lead_minutes × 60`** — the
same instant the check-in fires — not against the raw deadline. Planning to the deadline itself
leaves the wind-down no runway: a pipeline projected to land at 6:59 for a 7:00 stop is a pipeline
that is still merging while the user is closing the laptop. The existing `>=` exact-fit rule is
preserved *against the pause point*, for the same reason it existed against the deadline.

**One subtraction, in one place, from one persisted number.** `deadline_epoch` stays the raw leave
time — the check-in renders its `By {H:MM} ET` column from it, and a shortened stored value would
misreport the time the user actually named. `lead_minutes` is read from `.leave` at the gate,
defaulting to 30 when the block is absent, so the gate's pause point and `/leave-by`'s
`checkin_epoch` are derived from the same figure and cannot disagree. Folding the subtraction into
`window-plan.sh`'s stall margin was the alternative; it would have made `deadline_epoch` mean two
things depending on who wrote it.

### Overrun asks instead of declining in silence

A silent one-line decline is the right default when nobody is watching. In an attended session it
means the thread can sit idle all afternoon without ever offering the choice the user would have
made in two seconds. So an **overrun** verdict — and only the overrun verdict, `plan on N min` —
becomes one `AskUserQuestion`: *Skip for now* (recommended, the existing behavior), *Launch anyway —
parks at the pause point*, or *Change my leave time* (which routes to `/leave-by`'s Step 9
re-declaration path, then Steps 1–7).

The other decline reasons stay silent, deliberately. `unestimated`, `deadline unreadable`,
`deadline malformed`, and `estimate lookup failed` are not choices — they are missing or broken
inputs, and a menu offering to launch through one would be asking the user to authorize a decision
nobody can evaluate.

**The answer is recorded, keyed to the deadline it was given against.** `window.launch_decisions[<issue>]`
holds `{decision, deadline_epoch, at}`; the monitor loop re-applies Step 7's gate on every cycle, so
without the record the same question would fire every 60 seconds — the nag this design exists to
avoid. Keying it to `deadline_epoch` rather than storing a bare verdict is what makes a
re-declaration re-ask: "launch it anyway, I'm here until 7" is not an answer about a day that now
ends at 5.

**Nothing sweeps the map, because nothing has to.** Both writers of `.window` — `/leave-by` Step 5
and `/pm` Step 0b — assign the whole object, so re-arming a deadline drops every recorded decision
with it. The per-record `deadline_epoch` comparison is the second line of defence, for a reader
holding a snapshot taken before that replacement; a retirement pass would be a third mechanism
doing what the existing write already does.

**`launch_anyway` does not move the deadline, and it does not pretend the pipeline lands.** It marks
the row so the check-in's verdict column shows `parks` regardless of its projected finish — the user
chose a pipeline that will be parked resumably rather than one that finishes, and the table must say
so. Reading it as "finishes by deadline" would launder a deliberate park into a promise.

**Attended is a precondition, not a fallback.** Elicitation and the overrun ask fire only when
`AskUserQuestion` is genuinely available and the launch is not a `/pm day` tick, a `/pm --window`
run (Step 0b already armed `.window`, so the "already armed" condition skips it), or a probe/wake
path. Headless runs keep today's silent decline unchanged, and a skipped elicitation is a **skip**,
never a failure: refusing to launch because nobody was there to answer would make the feature a new
way for unattended work to stall. `/leave-by`'s source gate is untouched — an `AskUserQuestion`
answer is a live user turn, while a leave time appearing in a prompt, issue body, or chip payload
still arms nothing.

**Phase transitions are not elicitation points.** A→B, B→C, and replacement respawns finish work
already in flight; they keep `phase-protocols.md`'s existing launch-gate behavior, including the
pause-point comparison and any recorded decision, and they never ask. The question is about
*starting* new work.

## Open

- **Lead time vs fleet size.** The 30-minute default comes from the motivating example, not from
  measurement. Whether it should scale with the number of in-flight pipelines (more running work →
  earlier check-in) is unresolved; the knob is per-repo and per-invocation in the meantime
  (`pm-config.md` `## Budget` → `LEAVE_LEAD_TIME_MIN`).
- **Same-day only.** `window-plan.sh`'s `until H:MM` resolves to today, so "leaving at 9 AM
  tomorrow" is a parse failure rather than a next-day deadline. Same-day evening stops are the
  motivating case; a multi-day horizon is `/end`'s territory, not this one's.
- **The elicitation arms no Monitor** (issue #1679). The question buys the deadline, not the
  wind-down; a user who wants the check-in and the `/pause` delegation declares the time explicitly.
  Whether the menu should carry an "also arm the 30-minute check-in?" follow-up is unresolved — it
  is one more turn spent on a question already answered once.
- **Ask cadence is once per deadline, not once per session.** A session spanning a lunch break gets
  no second question while the morning's deadline is still armed and unexpired; re-declaring with
  `/leave-by <time>` is the explicit path, and it re-arms the overrun ask too (the recorded
  `launch_decisions` entries name the old `deadline_epoch` and stop applying).
- **Splitting an overrun issue is a fourth option this does not add.** When an issue that overruns
  could be cut into increments that fit, "Split and start the first increment now" belongs on the
  same menu; it waits on the time-based split trigger rather than being half-built here.
