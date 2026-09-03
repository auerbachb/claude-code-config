# Time Estimate Vocabulary

> This document is the single source of truth for capture-time estimates. All three
> skills — `/issue-maker`, `/prompt`, `/start-issue` — share this table and format.
> The seed table below is replaced by measured actuals as history accumulates —
> see [`estimate-actuals.md`](estimate-actuals.md) for the current recalibrated table
> (regenerated via `estimate-log.sh --rollup`).

## Format

```
Est: {lo}–{hi} min · plan on {bound}
```

- `{lo}` and `{hi}` — expected wall-clock range in whole minutes.
- `plan on {bound}` — the planning bound: the single number a day-planner reserves.
  Always equals `{hi}`.
- Both values are plain integers separated by an en-dash (`–`, U+2013).

**Example:** `Est: 45–90 min · plan on 90`

**Machine-parse pattern:** `^Est:\s+(\d+)–(\d+)\s+min\s+·\s+plan\s+on\s+(\d+)$`

Group 1 = lo, Group 2 = hi, Group 3 = planning bound. A valid estimate requires Group 1 < Group 2 (lower bound < upper bound) and
Group 3 == Group 2 (planning bound must equal upper bound). Reject lines where either
constraint fails — e.g. `Est: 30–15 min · plan on 15` (inverted bounds) or
`Est: 15–30 min · plan on 90` (mismatched planning bound) are both malformed. Later increments
(dispatch makespan, actuals logging) read estimates from issue bodies using this pattern.

## Measurement Window

The estimate measures **wall-clock elapsed time from issue claim to PR merged** in a
single attended pipeline:

- **Start:** the moment the coding thread claims the issue (before any repo reads or
  planning).
- **End:** the GitHub merge timestamp on the squash-merged PR.
- **Scope:** implementation → local review → push → AI-review rounds (CodeRabbit /
  BugBot / Greptile) → CI → merge.
- **Attended** means the session is actively driving — a human is available to
  approve CI, respond to review escalations, and trigger the next phase. Idle wait
  time (CI queue, reviewer latency during a session) is included because it is real
  wall-clock time from a day-planner's perspective.
- **Out of scope:** overnight / unattended queuing, multi-agent parallel dispatch,
  cross-timezone handoffs. The unattended margin is increment 4's concern.

## Tier → Time Seed Table

| Tier | Range | Planning bound | Estimate line |
|------|-------|---------------|---------------|
| **Light** | 15–30 min | 30 min | `Est: 15–30 min · plan on 30` |
| **Standard** | 45–90 min | 90 min | `Est: 45–90 min · plan on 90` |
| **Heavy** | 90–180 min | 180 min | `Est: 90–180 min · plan on 180` |

**Tier vocabulary** is identical to `tier-inference.md` (issue-maker) and `/prompt`
Step 5: Heavy / Standard / Light, evaluated using the same signals.

**Default:** use the table row for the issue's tier. Do not adjust unless scope
clearly warrants it — e.g., a Standard-tier issue touching a single well-understood
file may be closer to Light (15–30 min). State the reason in one sentence when
adjusting; never adjust silently.

## Usage by Skill

| Skill | Behavior |
|-------|----------|
| `/issue-maker` | Infer tier from the issue signals, look up the estimate line, add `## Estimate` section to the issue body before filing. |
| `/prompt` | Surface the estimate in the Tier Recommendation output. If the issue body already has `## Estimate`, echo that line; otherwise derive from tier + this table. |
| `/start-issue` | Surface the estimate in the ready-to-code summary. Same fallback logic as `/prompt`. |
| `/pm` | Show `Est:` line under each suggested issue. Resolved via `estimate-resolve.sh`. |
| `/subagent` | Show `Est:` line in the launch report and completion summary. Resolved via `estimate-resolve.sh`. |
| `/wave` | Show batch makespan after the wave block. Computed via `makespan.sh`. |

Read this file through the standard candidate order (`portable-skill-resolution.md`):
`$HOME/.claude/skills-worktree/.claude/reference/time-estimates.md` first, then
`$HOME/.claude/reference/`, then `.claude/reference/`. If unavailable, print
`DEGRADED: time-estimates.md not found (checked all three paths) — using inline fallback`
and use the inline values from the table above; never silently omit the estimate.

---

## Batch Makespan Model (increment 3)

The batch makespan answers "when will this batch finish?" — a number per-issue estimates alone cannot give because pipelines overlap, chains serialize, and a shared reviewer cap throttles throughput.

**Helper:** `makespan.sh` (same resolution order as other scripts). Input: JSON object `{"issues":[{"num":N,"est_lo":lo,"est_hi":hi,"deps":[...]},...]}` where `est_lo`/`est_hi` are minutes or `null` for unestimated issues. Output: one line — `lo–hi [h|min] · binding: <bound> · plan on ~HH:MM AM/PM ET`.

### Three bounds; makespan = max of all three

| Bound | Formula | When binding |
|-------|---------|--------------|
| **parallel-work** | `max(max(est_hi), sum(est_hi) / ceiling)` | Most batches — implementation time dominates |
| **critical-chain** | Longest `Depends on` path (sum of `est_hi` along that path) | Any batch with a serialized increment chain |
| **reviewer-throughput** | `n_issues × (60 / 5)` = `n × 12 min` | Large batches of fast issues (Light tier or faster) |

The reviewer-throughput floor uses **5 reviews/hour** — the CodeRabbit Pro cap from `cr-github-review.md` "Rate Limits". When this bound is binding, the report says so: adding more parallel agents stops helping because CR is the bottleneck.

**Concurrency ceiling:** 4 (from `subagent-orchestration.md`; configurable via `--ceiling`).

### Unestimated issues

An issue with no `## Estimate` section and no complexity tier label resolves to `unestimated`. `makespan.sh` uses the Standard-tier fallback (45/90 min) for unestimated issues so the batch always has a result; the count of fallbacks is noted in the output line. `estimate-resolve.sh` exits 2 and prints `unestimated` for fully unresolved issues — never a blocker for dispatch.

### Output format

```
45 min–1.5 h · binding: parallel-work · plan on ~10:30 PM ET
2.5 h–4.5 h · binding: critical-chain · plan on ~1:30 AM ET
1.5 h (1 unestimated → Standard fallback) · binding: reviewer-throughput (6 issue(s) × 12 min/review at 5/hr) · plan on ~7:00 PM ET
```

The finish clock time is `now + makespan_hi` in Eastern Time.

---

## Progress Readout Format (increment 5)

The readout answers "how far along is this pipeline?" using elapsed wall-clock time and the planning bound. One format, used everywhere progress comes up: in-flight heartbeats, on-demand answers, and chip-launched thread status messages.

```
Est {bound} · {elapsed} elapsed · on track — likely done in ~{remaining}
Est {bound} · {elapsed} elapsed · running slow — revised finish ~{revised_total} total
```

### Field definitions

| Field | Value |
|-------|-------|
| `{bound}` | Planning bound from the issue's `## Estimate` section (e.g. `90 min`, `1.5 h`) |
| `{elapsed}` | Wall-clock time since the issue was claimed (claim-comment timestamp → PR `createdAt` fallback) |
| `{verdict}` | `on track` when elapsed ≤ bound; `running slow` when elapsed > bound |
| `{remaining}` | `bound − elapsed` (on-track path only) |
| `{revised_total}` | `elapsed × (elapsed / bound)` — pace-scaled: a pipeline 2× over budget projects 4× total (running-slow path only) |

**Duration formatting:** values < 60 min use `N min`; values ≥ 60 min use `N h` or `N.N h` (tenths, dropping trailing zeros).

**Examples:**
- Bound 90 min, elapsed 45 min → `Est 90 min · 45 min elapsed · on track — likely done in ~45 min`
- Bound 90 min, elapsed 2 h (120 min) → `Est 90 min · 2 h elapsed · running slow — revised finish ~2.7 h total`

### Pace model

Simple elapsed/bound ratio — no phase weighting. When elapsed ≤ bound the pipeline is on track regardless of which phase it is in; the first calibration rows are too sparse to weight A/B/C differently. Revisit once actuals accumulate in `estimate-actuals.md`.

### Helper: `overrun-check.sh --readout`

`overrun-check.sh --readout --pr N --bound-min M --started-at ISO8601` computes and prints the readout line to stdout (exit 0 always). No window, no state marker — safe to call on every heartbeat tick. When the helper is unavailable, compute inline using the formulas above.

### Usage by surface

| Surface | When to emit |
|---------|-------------|
| `/subagent` heartbeat (Step 8.5) | Superseded by the "Running now" table below — the readout's verdict now lives in that table's Remaining column |
| `/subagent` on-demand | When the user asks "how far along?" — answer with the table below, so single- and multi-pipeline answers share one shape |
| `/pm day` D5 heartbeat | Superseded by the "Running now" table below (issue #1527) — the readout's verdict now lives in that table's Remaining column, for the whole round rather than one pipeline at a time |
| Chip-launched thread | Lead the **first status message** with the readout; repeat whenever the user asks for a progress update |

---

## "Running now" Table (increment 6)

The readout answers "how far along?"; it does not answer "when will this land?". A
reader juggling several sub-threads — testing between rounds, filing the next batch
as results arrive — has to plan against a clock, and prose bullets carrying only a
duration force them to remember launch times and do the arithmetic themselves.

**One table, everywhere a round is dispatched.** The moment a batch is filed or
queued, and on every later multi-pipeline progress update, the thread renders one
table covering **every issue in the round, in execution order** — queued rows
included. It replaces the bulleted-list shape, not just augments it.

### Columns

| Column | Value |
|--------|-------|
| **Issue** | `#N` |
| **Scope** | Short description, truncated to 40 chars (`cut -c1-40`) so each row stays one line |
| **Status** | `queued` for a not-yet-launched row; `merged` for one that has landed; otherwise the phase — `Phase A`, `Phase B`, `Phase C` |
| **Est** | `Est: {lo}–{hi} min · plan on {bound}` from `estimate-resolve.sh`, or `unestimated` |
| **Start (ET)** | Wall-clock launch time, e.g. `12:18 PM` |
| **Projected end (ET)** | On-track: start + planning bound. Over the bound: the pace-scaled revised finish |
| **Remaining** | On-track: `bound − elapsed`. Over the bound: the overrun marker `+{over} over plan` |

**Queued rows carry `—` in all three clock columns** — Start, Projected end, and
Remaining. Nothing has started, so there is nothing honest to print; the row exists
to show run order and the estimate.

**A started row never shows an ETA in the past.** Once elapsed exceeds the planning
bound, the row switches to the revised finish plus the overrun marker, keeping the
same on-track / running-slow semantics the readout above already has.

**Completed rows carry `merged` in Status, and an actual rather than a projection.**
A row whose PR has landed keeps its recorded Start, shows the delivered clock time in
`Projected end`, and carries `—` in `Remaining` because nothing remains. The `merged`
status is what marks that middle cell as a fact instead of a forecast: a landed PR
must never read as a future-tense claim, and re-labelling the column per row would
give one table two column meanings. Delivered time is the PR's own `mergedAt`, read
back like every other timestamp here and never taken from the render-time clock.

### Example

```markdown
**Running now**

| Issue | Scope | Status | Est | Start (ET) | Projected end (ET) | Remaining |
|-------|-------|--------|-----|-----------|--------------------|-----------|
| #1512 | Universal dispatch + progress table | Phase B | Est: 90–180 min · plan on 180 | 12:18 PM | 3:18 PM | 1.4 h |
| #1489 | Rebuild the escalation retry window | Phase A | Est: 45–90 min · plan on 90 | 12:41 PM | 2:03 PM | +22 min over plan |
| #1480 | Key catalog entries on normalized path | merged | Est: 15–30 min · plan on 30 | 12:18 PM | 12:44 PM | — |
| #1504 | Re-anchor the scripts README gate | queued | Est: 15–30 min · plan on 30 | — | — | — |
```

### Helper: `overrun-check.sh --readout-cells`

`overrun-check.sh --readout-cells [--pr N] --bound-min M --started-at ISO8601 [--now ISO8601]`
prints ONE tab-separated line — `{Start}\t{Projected end}\t{Remaining}` — for a single
started row (exit 0 always). Same inputs, same pace model, and the same
no-window/no-state-marker guarantee as `--readout`, whose output it leaves untouched.

- **`--pr` is optional here** (and in `--readout`), required only on the breach path
  that keys session state by PR. A Phase A pipeline has a `started_at` but no PR yet,
  so callers must be able to omit it — demanding one turned a launch table with real
  clocks into em dashes on the next heartbeat tick. Supply it and it is still validated.

- Both clock cells are ET `%-I:%M %p` with **no** `ET` suffix; the column headers carry
  the zone.
- On track: `Projected end = start + bound`, `Remaining = bound − elapsed`.
- Over the bound: `Projected end` is the pace-scaled revised finish, **floored at
  `--now`** so it is never a clock time in the past; `Remaining` becomes
  `+{over} over plan` (e.g. `+22 min over plan`) — rendered `+<1 min over plan`
  for the first 59 s past the bound, so a row in the overrun branch never reads
  as on-plan.
- Consume with `cut -f1`/`-f2`/`-f3`, **not** `IFS=$'\t' read` — that idiom collapses
  empty fields and shifts the rest.
- Prints nothing (still exit 0) when a timestamp will not parse or the start is in the
  future; render `—` in that case, exactly as for a queued row.

When the helper is unavailable, leave the three clock columns blank or `unestimated`
per the caller's degraded-mode rule — never omit the table.

### Deadline variant: the `By {H:MM} ET` column (issue #1525)

When a deadline is armed — `/pm --window`, or a leave time declared through `/leave-by` — the
leave-time check-in renders **this same table plus one trailing column**, headed `By {H:MM} ET` and
holding `finishes by deadline` or `parks` per row. It is an added column, never a different table:
the reader comparing "what is running" against "what survives the deadline" should not have to
reconcile two shapes.

The verdict is computed, not judged, and it reads the **same projected finish the row already
displays** — the on-track `start + bound` while a row is inside its bound, and the pace-scaled
revised finish once it is over (the `Projected end` rules above). `finishes by deadline` when that
effective projected finish is at or before `deadline_epoch`. Comparing the original bound instead
would let an overrun row claim `finishes by deadline` while its own `Projected end` cell shows a
clock time past the deadline — the row contradicting itself, in the one direction that costs the
user the guarantee. **Every other case is `parks`** —
a queued row, an unestimated row, an overrun row whose revised finish will not resolve, and any row
whose start or bound would not read. Fail closed: a
wrong `parks` costs one pipeline a resumable delay, while a wrong `finishes by deadline` costs the
user the guarantee the deadline existed to buy (`leave-time.md` §"Why every unknown resolves to
`parks`").

### Start times come from state, never from the clock at read time

Each pipeline's launch timestamp is recorded **once, at spawn**, into
`.repos["<key>"].pipelines["<issue>"].started_at` (issue-keyed — no PR exists yet) and
copied verbatim into `.prs["<pr>"].pipeline_started_at` once Phase A creates the PR.
Every later render reads it back. Re-deriving it — from `gh pr view --json createdAt`,
or from "when this tick noticed the pipeline" — would move Start on every rebuild
after a context compaction, which is precisely what the recorded value prevents.
`createdAt` stays a last-resort fallback for pipelines that predate the record.

### Usage by surface

| Surface | When to emit |
|---------|-------------|
| `/subagent` launch (Step 7) | Immediately after the batch is filed/queued — the whole round, launched rows and queued rows alike |
| `/subagent` heartbeat (Step 8 item 6) | Re-render every tick: Start unchanged, Remaining recomputed, queued rows flipping to started as they launch |
| `/subagent` on-demand | Same table when the user asks "how far along?" |
| `/board` | The same table on demand, in any orchestration thread — the named command for the question `/subagent`'s on-demand answer handles in prose (issue #1581). **Partial for a non-dispatching thread:** round membership is not durable, so a `/board` run from a thread that did not dispatch the round renders no queued rows and reports its delivered count as approximate (the timestamp fallback misses anything that merged before the earliest running start, and can absorb a late merge from an earlier round), saying so both times. Running rows rebuild fully from durable state, with merge state read live per PR (`gh pr view --json state,mergedAt`) — the one field the board does not take from disk |
| `/pm` | **Adopted** (issue #1527). The round's progress view is this table, rendered by running `/board` rather than by a second copy of the mechanics: `/subagent` Step 7.2's launch table serves the dispatch turn, the day-mode D5 heartbeat carries it on the freshness trigger below (one line otherwise), and any progress question answers with it. `/pm` is the dispatching thread, so the board renders **complete** — its own queued rows, no `Phase A (unconfirmed)` row for a pipeline it holds a handle for, and neither count qualified. `/pm`'s Active Work table (3.2) is a separate assignment ledger, not a rival shape: it carries rows that are not pipelines (`Chip offered`, `Prompt generated`, `Active`, `Tracking`, `Deferred (cap)`) and chip handles, for which the Status vocabulary here has no cell |
| `/pr-monitor-and-manage` | **Documented divergence** for its per-tick fleet table (below), which answers a different question; the round-progress question routes to `/board` and renders this table unaltered (issue #1527) |
| `/leave-by` check-in | At `deadline − lead`, unprompted — this table plus the `By {H:MM} ET` column above |

Ad-hoc orchestration threads — a feedback round that files issues then dispatches
agents — emit the same shape by reading this section; the table is venue-independent
by construction.

### Documented divergence: `/pr-monitor-and-manage` (issue #1527)

One venue keeps its own columns, and this is where that is granted rather than left
unreconciled. `/pr-monitor-and-manage`'s per-tick fleet table stays
**Issue | PR | State | Reviews | CI | Unresolved Threads | Verdict | Subagent**
(`pr-monitor-and-manage/references/pmm-classify.md` §"Table format"). Three reasons,
none of which is "the columns happen to differ":

- **It answers a different question.** This table answers *when will this round land*;
  the fleet table answers *what does each PR need next*. A reader deciding whether to
  wait needs clocks; a fleet manager deciding what to dispatch needs gate state.
- **Six of those eight columns are load-bearing, not presentational.** `State`,
  `Reviews`, `CI`, `Unresolved Threads`, `Verdict` and `Subagent` are read back by
  PMM's Step 5 dispatch. Replacing them with `Est` and the clock cells would remove
  the inputs the skill acts on; adding the clock cells beside them makes an
  eleven-column row that no longer fits a line.
- **PMM dispatches no round.** It discovers open PRs by author every tick, so it has
  no execution order to render, no queue, and no `started_at` of its own for a PR it
  did not launch. Rows would carry em dashes in the columns that justify the shape.

**The divergence is bounded, not a licence.** PMM still owes the canonical table for
the canonical question: a progress ask, or a `TABLE FLOOR:` line, routes to `/board`,
which renders this shape unaltered — including its own honesty about a non-dispatching
thread's missing queued rows and approximate delivered count. And PMM re-derives no
Start: `/board` Step 2's read-back order is the only source, `createdAt` only for
pipelines predating the record. A future PMM that dispatches rounds of its own should
revisit this entry rather than widen it.

### Table freshness — the hourly floor (issue #1580)

The silence ceiling (`bgwork-ceiling.sh`) bounds how long a thread can go without
**saying** anything while background work runs. It measures *messages*, so a bare
"still running, nothing new" one-liner satisfies it — and a thread can stay
technically live for hours while the last full board the user saw goes stale. The
user plans testing rounds around that board.

**These are two complementary bounds, not one.** Message-freshness is the ceiling's
job; **table**-freshness is the floor's. A future consolidation that keeps only one
drops a guarantee — say so before merging them.

**The guarantee:** while at least one pipeline is running or queued, a full "Running
now" table is never more than an hour old, whatever mix of one-liners, notifications
and merge lines the thread emits in between.

Three rules, all owned by `table-freshness.sh` — it holds the floor number and the
stale/fresh arithmetic, so no caller re-derives either:

1. **Record every render.** Every site that emits the table — dispatch, heartbeat,
   on-demand, `/leave-by` check-in, `/board` — calls
   `table-freshness.sh --note-rendered --active <N>` immediately after printing it,
   where `N` is the number of pipelines running **or queued** at that moment. The
   timestamp goes to durable session state
   (`.repos["<key>"].table_render["<session>"]`), so a context compaction cannot
   reset the clock: the freshness check reads the file, never the thread's memory.
2. **A stale status message carries the table.** Before emitting any
   liveness/heartbeat/status output, run `table-freshness.sh --check --active <N>`.
   Exit 1 (`stale`) means **this message must include the full re-rendered table**,
   not a one-liner. Exit 0 (`fresh`, `idle`, `unrecorded`) leaves the one-liner
   available. Pass `--active` whenever the count is known — with no recorded render
   it is what makes the verdict fail closed rather than guess.
3. **A hard floor fires unprompted.** Arm `table-freshness.sh --arm-command` as a
   **persistent `Monitor`** in the same step as the round's first dispatch — the same
   primitive and the same reasoning as the ceiling watch (`scheduling-reliability.md`;
   never `CronCreate`, never chained one-shot wake-ups). The tick prints one line when
   the hour elapses with work still active, deduped per recorded render, so a thread
   re-rendering on its own cadence never sees a floor message at all.

**Idle threads are exempt, explicitly.** When nothing is running or queued, the
round-end summary is the terminal board and the thread stays quiet. The exemption is
mechanical, not a matter of judgment: the round-end render is recorded with
`--active 0`, which disarms the floor until the next dispatch. There is deliberately
**no always-on hourly pulse** — that would fight the stable-state backoff design in
`scheduling-reliability.md`, which exists to make a quiet thread quieter.

**Teardown is by data, not by killing the watch.** Every flow that ends a round —
the round's own completion, `/pause`, `/end`, a `/leave-by` wind-down — records the
terminal board (`--note-rendered --active 0`) or calls `--clear`. That is what
disarms the floor, and it is deliberately independent of the Monitor's fate: the
tick reads `active_pipelines` and exits silently at `0`, so a watch whose `TaskStop`
failed, or that no step held an ID for, goes quiet anyway. A teardown that only
stopped the task would leave the opposite failure — a stale `active_pipelines > 0`
waiting to fire the moment anything re-armed.

**Every call names the same repo and session.** Pass `--repo <owner/name>` and
`--session <id>` explicitly on `--note-rendered`, `--check`, and `--arm-command`
alike, resolving both **once** and reusing them. Left out, the repo derives from the
current working directory and the session from an environment variable read at each
call — so one call made from a different directory, or after that variable changed,
reads and writes a different record than the armed watch polls, which is a floor
firing forever against a board the thread is faithfully re-rendering. An unresolved
repo key arms nothing: report it in one `DEGRADED:` line rather than arming a watch
on `_unknown`, which no render would ever reach.

Because the rules hang off the table spec rather than off any one skill, a venue that
adopts the table (issue #1527) inherits the freshness guarantee by adopting this
section — nothing to restate. Full contract: `table-freshness.sh --help`; field
contract: `.claude/reference/session-state-schema.json`.
