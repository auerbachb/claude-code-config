---
name: board
description: Render the canonical "Running now" table on demand, in any thread that has dispatched or is monitoring pipelines — the round's running and completed pipelines with their phase, recorded start, projected end and what is left, plus the queued rows the invoking thread knows of, all recomputed live from durable state. Read-only; it never dispatches, merges, or changes a pipeline. Triggers on "/board", "show the board", "where is everything", "what's running right now", "current board".
triggers:
  - board
  - show the board
  - current board
  - where is everything
  - what's running right now
argument-hint: "[--all-repos]"
---

Answer "where is everything right now?" with one keystroke instead of one sentence.

The "Running now" table (`.claude/reference/time-estimates.md` §"Running now Table")
already renders at dispatch, on every heartbeat tick, and whenever the user asks a
progress question in plain language. What it lacked was a **name**: a short command
that summons the current board immediately, from any orchestration thread, without
composing a question. `/board` is that name. Natural-language asks keep working
exactly as before — this is an alias, not a replacement.

**Invocable from any orchestration thread**, including one resumed after a context
compaction: every clock it prints — starts above all — is read back from durable
session state rather than from the thread's memory of the round.

**It boards the repo it is invoked for**, resolved by the standard scoping every
other surface uses (Step 1) — not whichever repo happened to dispatch. Run from
another repo, it shows that repo's round; to span several, pass `--all-repos`. The
resolution is deliberately not special-cased here: the freshness record in Step 5 has
to land on the same key the armed floor watch polls, and a `/board` that resolved its
repo differently from `/subagent` would write a record nothing reads.

**Round membership is not durable, and `/board` says so rather than implying it.**
**Running** rows reconstruct fully from state. **Queued** rows do not: nothing on
disk records which issues are waiting (Step 3), so a thread that did not dispatch the
round — or one whose queue a compaction took — prints none and names that gap in
Step 4's summary line. **Completed** rows inherit the same gap from the other end:
the dispatching thread knows exactly which merged pipelines were its round, while a
non-dispatching thread can only bound them by timestamp and so calls its delivered
count approximate. The board is then honest but partial, never silently short a
row. Both gaps have one root — no durable round key — and one fix: a change to the
dispatcher's write path rather than to this reader, so it is a follow-up, not
something to paper over here.

`/board` is symlinked globally, but its helper scripts are not, so Step 0 resolves
each one — never a bare `.claude/scripts/…` path
(`.claude/reference/portable-skill-resolution.md`).

**Scope boundary.** `/status` is the PR-fleet dashboard — every open PR with its
review state, whether or not this session dispatched it. `/subagent` is the
dispatcher that owns this same table at launch and on heartbeats. `/board` neither
dispatches nor reviews nor merges: it reads state and prints one table. Its **only**
write is the shared table-render timestamp in Step 5, which is not a change to any
pipeline — it is how the hourly freshness floor learns the user has just seen a
current board (`time-estimates.md` §"Table freshness — the hourly floor").

---

## Step 0: Resolve shared tooling

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH=$(resolve_script session-state.sh || true)
ESTIMATE_RESOLVE_SH=$(resolve_script estimate-resolve.sh || true)
OVERRUN_CHECK_SH=$(resolve_script overrun-check.sh || true)
TABLE_FRESHNESS_SH=$(resolve_script table-freshness.sh || true)
```

Read `time-estimates.md` through the matching `.claude/reference/` candidate order.

**When something does not resolve, say so in one line; never skip the contract
silently.**

- `SESSION_STATE_SH` empty → **required**. Print `ERROR: session-state.sh not found (checked all three paths) — /board cannot read round state` and stop. Every row on this board comes from that file; there is no degraded board without it, and inventing rows from the current clock is the one failure the recorded starts exist to prevent.
- `ESTIMATE_RESOLVE_SH` empty → **optional**. Print `DEGRADED: estimate-resolve.sh not found (checked all three paths) — Est column renders as unestimated` and continue.
- `OVERRUN_CHECK_SH` empty → **optional**. Print `DEGRADED: overrun-check.sh not found (checked all three paths) — clock columns render as —` and continue. Still print the table: it carries the round's shape and run order even with three empty columns, and the line above already said why they are empty.
- `TABLE_FRESHNESS_SH` empty → **optional**. Print `DEGRADED: table-freshness.sh not found (checked all three paths) — this render is not recorded against the hourly table-freshness floor` and continue. The board is still correct; only the clock in Step 5 is lost.

---

## Step 1: Resolve repo and session — once

Resolve both **here** and reuse the same pair for every later call. Left to their
defaults, the repo derives from the working directory and the session from an
environment variable re-read at each call, so one call made from elsewhere reads or
writes a different record than the armed floor watch polls
(`time-estimates.md` §"Every call names the same repo and session").

```bash
REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
# `--repo-key` NEVER returns empty: it prints `_unknown` and exits 0 when it cannot
# resolve a repo. Normalise that sentinel to empty once, here, so every `-n
# "$REPO_KEY"` guard below actually fires — otherwise Step 5 records this render
# against `_unknown`, a scope no floor watch ever polls.
[[ "$REPO_KEY" == "_unknown" ]] && REPO_KEY=""
# The `default` fallback is NOT this skill's choice to make: it is the session key
# every other render site already uses (`/subagent` 7.3 and 8.6, `/leave-by`,
# `/pause`). Substituting a unique id here, or failing closed on an unset
# CLAUDE_SESSION_ID, would write a record the armed watch never polls — the exact
# mismatched-clock failure `time-estimates.md` §"Every call names the same repo and
# session" describes. If sharing `default` across concurrent threads is worth
# fixing, it is a change to table-freshness.sh and all of its call sites at once.
TF_SESSION="${CLAUDE_SESSION_ID:-default}"
```

An empty `REPO_KEY` does not stop the board — `--session-view` still resolves its own
scope. It only disables the Step 5 record, which Step 5 reports.

---

## Step 2: Gather round state, read-only

```bash
# `--get` prints the literal string `null` and exits 0 for an absent path, so a
# bare `-n "$VALUE"` guard is TRUE on a miss and every fallback behind it is dead
# code. Normalise once, here, and read every value through this — the sibling
# render sites do the same.
sget() {  # sget <jq-path> -> value, or empty when absent/unreadable
  local v
  v=$("$SESSION_STATE_SH" --get "$1" 2>/dev/null) || return 0
  [[ "$v" == "null" ]] && return 0
  printf '%s' "$v"
}

# .prs and active_agents. A missing or unparseable file is "no round state", never
# an error — Step 4's one-line message is the correct output for it.
STATE=$("$SESSION_STATE_SH" --session-view 2>/dev/null) || STATE=""

# The per-round launch record. `.repos["<key>"].pipelines` is INVISIBLE to
# --session-view (which lifts only .prs and .root_repo out of the repo block), so
# address it by its full path. Never `--get .` — that leaks every repo.
PIPELINES=""
if [[ -n "$REPO_KEY" ]]; then
  PIPELINES=$(sget ".repos[\"$REPO_KEY\"].pipelines")
fi
```

`--all-repos` is the **explicit** cross-repo opt-in, used only when the user asks for
a board spanning repos. It replaces both reads above with a loop, and every repo key
it yields is carried with its rows from here on:

```bash
STATE=$("$SESSION_STATE_SH" --session-view --all-repos 2>/dev/null) || STATE=""
# One pipelines block per repo, each addressed by its OWN key — and that key stays
# attached to every row it produced, because Steps 3-5 need it per row, not per
# board. Never `--get .`.
BOARD_REPOS=$(printf '%s' "$STATE" | jq -r '.repos // {} | keys[]' 2>/dev/null)
for RK in $BOARD_REPOS; do
  RK_PIPELINES=$(sget ".repos[\"$RK\"].pipelines")
  # Accumulate (RK, RK_PIPELINES) pairs; `_unknown` carries no usable repo for the
  # `gh` and estimate lookups below, so skip it rather than guessing one.
done
```

**Under `--all-repos`, every repo-scoped value becomes per-row, not per-board.**
Carry each pipeline's own repo key alongside it and use *that* key — never the
invoking repo's — for its `gh` lookups (Step 3), its `estimate-resolve.sh --repo`
and Issue cell (Step 4), and its freshness record (Step 5). One board spanning three repos is three repos' worth of
scope, and a single `REPO_KEY` applied across it is wrong in three different places
at once.

**`--all-repos` also changes the shape `.prs` is read at, and Step 3 depends on it.**
Default `--session-view` **lifts** the invoking repo's `prs` to the top level, so
`.prs["<N>"]` addresses it. `--all-repos` does not lift anything: it emits
`.repos["<key>"].prs` per repo and no top-level `.prs` at all. A Step 3 that keeps
reading `.prs["<N>"]` therefore matches nothing under `--all-repos` and silently
loses the phase of every pipeline waiting on review — the rows most worth boarding.
Read the per-mode path, and read the per-repo agent list beside it:

```bash
# Default mode: PRS_PATH='.prs'        AGENTS='.active_agents'
# --all-repos:  PRS_PATH=".repos[\"$RK\"].prs"
#               AGENTS='.active_agents' PLUS ".repos[\"$RK\"].active_agents"
```

Top-level `.active_agents` is session-wide and present in **both** modes; each repo
block carries its own `active_agents` as well, so a cross-repo board reads the union
of the two for that repo's rows. Neither list is a substitute for the other.

**A row is keyed by its issue; half its lookups take a PR number. Name the
crossing.** `pipelines` is **issue-keyed** and carries the PR in `.pr`, written when
Phase A completes. `prs` is **PR-keyed**, and its `issue` back-reference exists only
on newer entries — so `.pipelines["<issue>"].pr` is the mapping to use, and inverting
`prs` is not a substitute. Per row, then:

```bash
# ROW_PIPELINES is the block this row came from: PIPELINES in default mode, that
# repo's RK_PIPELINES under --all-repos. Naming it per row keeps the lookup correct
# in both modes and keeps the row bound to its own repo, as Step 2 requires.
ROW_ISSUE="<the pipelines key>"                 # Issue cell, estimate-resolve.sh
ROW_PR=$(printf '%s' "$ROW_PIPELINES" | jq -r --arg i "$ROW_ISSUE" '.[$i].pr // empty')
```

Everything PR-numbered — `gh pr view` for merge state, the `prs["<N>"]` phase read —
takes `ROW_PR`; everything issue-numbered — the `Issue` cell, `estimate-resolve.sh`,
which reads the **issue** body — takes `ROW_ISSUE`. Passing one where the other
belongs does not error: it resolves to a real but unrelated GitHub object and answers
confidently about it. A pipeline with **no `.pr` yet** has not reached Phase A
completion, so there is no merge state to read and it is a running row by definition.

**Start times are read, never derived.** Per pipeline, in order:
`<PRS_PATH>["<ROW_PR>"].pipeline_started_at` — the same per-mode path above, so a
cross-repo board does not lose every recorded start to a `.prs` that is not there —
then that repo's `pipelines["<ROW_ISSUE>"].started_at`. Read both through `sget`, so
an absent first value falls through instead of returning the string `null`.
`gh pr view <ROW_PR> --repo "<that pipeline's key>" --json createdAt` is a
**last-resort** fallback for pipelines that predate the record — never a refresh of
one that exists, and never unqualified: an unqualified lookup resolves the number
against the working directory's repo, so the one path that exists to recover a
missing start is also the one most able to invent a wrong one. Re-deriving a start
moves the Start column on every rebuild after a compaction, which is precisely what
the recorded value prevents (`time-estimates.md` §"Start times come from state").

---

## Step 3: Decide which rows are the current round

`.repos["<key>"].pipelines` is **append-only** — it accumulates every issue this repo
ever dispatched, across sessions. Rendering all of it would print a history, not a
board. Three row classes make up the round:

- **Running** — the pipeline has a live phase: an `active_agents` entry for its issue
  or PR, or a `prs["<N>"]` entry with a recorded `phase` — read at the per-mode path
  above — **and**, in either case, no closed PR. `Status` is the phase: `Phase A`,
  `Phase B`, `Phase C`.

  **The open-state qualifier applies to the agent list too, not only to `prs`.**
  `active_agents` is cleaned up by the parent after Phase C
  (`phase-protocols.md`), so a crash, a compaction, or an interrupted transition
  leaves entries behind; `/pause` already treats the list as possibly stale. An
  unqualified agent entry therefore renders a landed pipeline as `Phase C` — and
  since Step 3 reads `state,mergedAt` live for every PR in the round anyway, the
  same read settles it at no extra cost. A pipeline whose PR is **merged** is a
  completed row, never a running one; one whose PR is **closed unmerged** is
  neither, and drops off the board. Without that qualifier the same pipeline can
  render twice — once as `Phase C`, once as `merged` — or, worse, set the round
  bound below from a start that is no longer in flight.

  A pipeline with **no PR yet** is the one case the agent list decides alone: a
  Phase A row has an `active_agents` entry and nothing to look up, so it stays
  running. Absence of a PR is not a closed PR.
- **Queued** — issues filed or accepted for this round that have not launched.
  **No durable field records them** (the same reason `table-freshness.sh` takes its
  active count as an argument), so these come from the dispatching thread's own
  queue. A thread that did not dispatch the round has no queue to read and prints
  none; say so in Step 4's summary line rather than implying the round has none.
- **Completed this round** — a `.pipelines` entry whose PR is merged **and** which
  belongs to this round. Membership has a durable answer and an approximate one, and
  the board uses whichever it actually has:

  **When this thread dispatched the round, membership is not a guess.** The
  dispatching thread holds the round's issue list — the same list Step 4's queued
  rows come from. Completed rows are then simply *those members whose PR is merged*:
  no timestamp bound, no inference. This is the common case, because the thread that
  renders the board on every heartbeat is the thread that dispatched it.

  **Otherwise, fall back to a timestamp bound: `mergedAt` at or after the earliest
  `started_at` among the running rows *of that pipeline's own repo*.** Under
  `--all-repos` the bound is per repo, like every other repo-scoped value in Step 2:
  a single board-wide bound lets one repo with a running row define a round for every
  other repo on the board, so an idle repo's historical merges that happen to postdate
  that start are rendered as delivered this round. A repo with no running row of its
  own has no bound and therefore no completed rows, whatever its neighbours are doing.
  Note this is a test on `mergedAt` alone.
  Adding an `or started_at >= bound` half admits nothing further — a merged pipeline
  with `started_at >= bound` necessarily has `mergedAt > started_at >= bound`, so the
  `mergedAt` half already caught it — and stating the pair implies a reach the bound
  does not have.

  **The fallback is approximate in both directions — label it, do not launder it.**
  It **misses** a member that both started *and* merged before the earliest running
  start: that pipeline sits entirely below the bound and cannot be recovered from
  `started_at`/`mergedAt` alone. Not a corner case — it is ordinary sequential
  dispatch, where one pipeline lands and its successor launches on the freed slot, so
  the predecessor finished before the survivor began. It equally **over-includes** a
  pipeline from an *earlier* round that sat in review and happened to merge after the
  bound: `mergedAt` cannot tell a late landing from a current one. So a
  non-dispatching thread calls its delivered count **approximate** in Step 4's
  summary line — not a lower bound, which would claim a floor the test does not have
  — the same way it names the queued gap. Widening the window to "everything merged"
  would print the repo's history under a round's heading, and inventing a round-start
  timestamp is a write to the dispatcher, not a read here — the same follow-up that
  would make queued membership durable settles both ends.

  **A queued-only round is the dispatching thread's case, and it needs no bound.**
  Only that thread can see a queue at all, and for it membership is the list itself,
  so its completed rows are exact whether or not anything is running. The timestamp
  fallback never meets this case: a non-dispatching thread with nothing running sees
  no queue and no running row, which is not a round at all but the no-round path
  below. The bound reads running rows only because **queued rows have no
  `started_at`** — that is what their em-dash clocks mean.

  Merge state is read live and **always `--repo`-qualified**:
  `gh pr view <N> --repo "$REPO_KEY" --json state,mergedAt` per PR in the round —
  under `--all-repos`, the key of the repo whose block that pipeline came from.
  `/board` runs from any working directory, so a bare `gh pr view <N>` would resolve
  the number against the cwd's repo and confidently answer for a different PR.
  (`state`, never a `merged` field: `--json merged` is not a field on any `gh`.)

**If there is no running and no queued row, there is no current round** — the lower
bound above is undefined, so completed rows are not computed at all and Step 4 prints
its one-line message. Under `--all-repos` that gate is **per repo** for the same
reason the bound is: a repo contributing neither a running nor a queued row
contributes no completed rows either, rather than borrowing another repo's round to
justify printing its history. When no repo on the board has one, the board as a whole
takes the no-round line. A landed round's terminal board is `/subagent`'s to print at
round end; `/board` does not resurrect one from history.

Row order is execution order: running rows by `started_at` ascending, then queued
rows in queue order. Completed rows sort with the running rows by `started_at`, so a
pipeline keeps its place in the round as it finishes.

---

## Step 4: Render

### No round

One plain line, no table, no error:

```text
No active round — nothing running or queued in <REPO_KEY>.
```

Substitute the key resolved in Step 1; never a literal repo name. Drop the scope
clause entirely — `No active round — nothing running or queued.` — in the two cases
where naming one repo would be wrong or empty: under `--all-repos`, and whenever
`REPO_KEY` is empty.

When Step 2 read nothing at all, keep it to the same single line and stay honest
about why: `No active round — session state unreadable, treating as no round.`

### The board

Print the ET render timestamp, then the canonical table — the same columns and the
same cell semantics as every other surface, per `time-estimates.md`
§"Running now Table". Do not invent columns and do not reshape it into a list.

```bash
TZ='America/New_York' date +'%a %b %-d %I:%M %p ET'
```

```markdown
**Running now**

| Issue | Scope | Status | Est | Start (ET) | Projected end (ET) | Remaining |
|-------|-------|--------|-----|-----------|--------------------|-----------|
| #1512 | Universal dispatch + progress table | Phase B | Est: 90–180 min · plan on 180 | 12:18 PM | 3:18 PM | 1.4 h |
| #1489 | Rebuild the escalation retry window | Phase A | Est: 45–90 min · plan on 90 | 12:41 PM | 2:03 PM | +22 min over plan |
| #1480 | Key catalog entries on normalized path | merged | Est: 15–30 min · plan on 30 | 12:18 PM | 12:44 PM | — |
| #1504 | Re-anchor the scripts README gate | queued | Est: 15–30 min · plan on 30 | — | — | — |
```

Per row:

- **Issue** — `#N`. Under `--all-repos` only, qualify it as `owner/name#N`: the same
  issue number exists in every repo, so a bare `#1512` on a cross-repo board names
  nothing in particular. Single-repo boards keep the plain `#N` the canonical spec
  and every other surface use.
- **Scope** — `printf '%s' "$ISSUE_SCOPE" | cut -c1-40`, so each row stays one line.
- **Est** — `estimate-resolve.sh <N> --repo "<that pipeline's key>"`; `unestimated`
  when it exits 2. `--repo` for the same reason the `gh` calls carry it: the helper
  reads the issue body through `gh`, so an unqualified call reads issue `N` in the
  working directory's repo.
- **Clock columns, started rows** — `overrun-check.sh --readout-cells --bound-min M
  --started-at ISO`, using the start read in Step 2. Never re-implement the time math.
  An **unestimated** started row has no `M`, so it gets no projection — but it keeps
  its recorded Start, which is a fact rather than a forecast.
- **Queued rows** — `—` in all three clock columns.
- **Completed rows** — `merged`, with the delivered clock time in `Projected end` and
  `—` in `Remaining` (`time-estimates.md` §"Running now Table"). They never reach
  `overrun-check.sh`'s **projection** cells; the branch below is what keeps them out.
  Both of their clocks are still **formatted** by that script, because it is the only
  ET formatter in this repo that is safe to call (below).

**Formatting a bare instant — never with a hand-rolled `date`.** Both of a merged
row's clocks arrive as ISO-8601 (`STARTED_AT` from Step 2, `mergedAt` from Step 3's
live read), and so does the Start of a running row the projection helper could not
compute. `overrun-check.sh --readout-cells` prints its **first** cell as the ET
wall-clock of whatever `--started-at` it was given, in the table's `%-I:%M %p` form,
and that cell is a pure function of `--started-at` — `--bound-min` moves only cells 2
and 3. So one call per instant, first cell taken, is the conversion. Compute
`STARTED_AT_ET` for **every** row, not only merged ones; the branches below decide
which of them use it:

```bash
et_clock() {  # ISO-8601 -> "12:18 PM", or empty if it will not parse
  [[ -n "$OVERRUN_CHECK_SH" && -n "$1" ]] || return 0
  "$OVERRUN_CHECK_SH" --readout-cells --bound-min 1 --started-at "$1" 2>/dev/null \
    | cut -f1
}
STARTED_AT_ET=$(et_clock "$STARTED_AT")
MERGED_AT_ET=$(et_clock "$MERGED_AT")
```

`--bound-min 1` is a placeholder, not a claim about the row: only cell 1 is read, and
cell 1 does not depend on it. Reaching for `TZ='America/New_York' date` directly
instead is the one thing to avoid — on a host without tzdata that call does not fail,
it silently returns UTC, printing a four- or five-hour error as a plausible clock
(issue #1529). `overrun-check.sh` probes the resolved offset before trusting the zone
and falls back to an explicitly labelled UTC string; that guard is the reason these
two cells route through it rather than around it. It prints nothing when a timestamp
will not parse, which is exactly the empty the guards below already handle.

```bash
BOUND_MIN=$(printf '%s' "$EST_STR" | sed 's/.*plan on \([0-9]*\).*/\1/' | grep -E '^[0-9]+$' || true)
CELLS=""
if [[ "$ROW_STATUS" != merged && -n "$OVERRUN_CHECK_SH" && -n "$BOUND_MIN" && -n "$STARTED_AT" ]]; then
  # --pr is optional in cell mode and omitted here: a Phase A row has a start but no
  # PR yet, and the computation needs neither.
  CELLS=$("$OVERRUN_CHECK_SH" --readout-cells \
    --bound-min "$BOUND_MIN" --started-at "$STARTED_AT" 2>/dev/null) || CELLS=""
fi
CELL_START="—"; CELL_END="—"; CELL_REMAINING="—"
# Three cells, ALWAYS non-empty when CELLS is non-empty. Use cut -f, never
# `IFS=$'\t' read` — that idiom collapses empty fields and shifts the rest.
if [[ "$ROW_STATUS" == merged ]]; then
  # A landed row is an ACTUAL, never a forecast, so it does not touch the
  # projection helper at all — both of its remaining cells are facts. Formatting
  # STARTED_AT directly also keeps the recorded Start on an UNESTIMATED merged row:
  # routing it through the helper would drop Start whenever BOUND_MIN is empty,
  # losing a value that is right there in state.
  # Guarded, not assigned outright: a pipeline that predates the start record has
  # no STARTED_AT_ET, and an unguarded assignment would blank the cell instead of
  # leaving the `—` that every other unknown clock renders.
  [[ -n "$STARTED_AT_ET" ]] && CELL_START="$STARTED_AT_ET"  # et_clock "$STARTED_AT"
  [[ -n "$MERGED_AT_ET" ]] && CELL_END="$MERGED_AT_ET"      # et_clock "$MERGED_AT"
  CELL_REMAINING="—"
elif [[ -n "$CELLS" ]]; then
  CELL_START=$(printf '%s' "$CELLS" | cut -f1)
  CELL_END=$(printf '%s' "$CELLS" | cut -f2)
  CELL_REMAINING=$(printf '%s' "$CELLS" | cut -f3)
elif [[ -n "$STARTED_AT_ET" ]]; then
  # A running row with no bound: `Est` is `unestimated`, so BOUND_MIN is empty and
  # the projection above never ran. Projected end and Remaining are genuinely
  # unknowable without a bound — but Start is not a projection, it is the recorded
  # launch time, and it is already in state. Keep it for the same reason the merged
  # branch does: an unestimated row loses its forecast, not its history.
  CELL_START="$STARTED_AT_ET"
fi
```

### One summary line after the table

Prose, not new columns — the same place `/subagent` reports blockers. Cover what the
rows cannot say for themselves: anything **blocked** (`blocker`, read at the same
per-mode `prs` path Step 3 used — `.repos["<key>"].prs["<N>"]` under `--all-repos`), and a
count of what is running, queued, and delivered this round. On a **non-dispatching**
thread two of those three are qualified rather than left to look exact — the queue it
cannot see because it did not dispatch the round, and a delivered count that is
**approximate**, since the timestamp fallback both misses pipelines that landed
before the earliest running start and can absorb a late merge from an earlier round
(Step 3). A dispatching thread qualifies neither: its round membership is its own
list, so all three counts are exact. An unknown must never render as a "none", and an
approximate count must not render as a total.

```text
2 running, 1 queued, 1 delivered. #1489 is over plan by 22 min; nothing blocked.
```

---

## Step 5: Record the render against the freshness floor

`/board` is a table-render site like dispatch, the heartbeat, and the `/leave-by`
check-in, and it shares **the same** durable clock rather than keeping a second one —
`.repos["<key>"].table_render["<session>"]`. Recording here is what lets an on-demand
board reset the hour: a user who just asked for the board does not also need the
floor to volunteer one.

The record is keyed **per repo**, so the loop below is the shape in both modes: one
iteration over the single invoking repo by default, one per repo the board carried
under `--all-repos`. `ROW_REPO` and `ROW_ACTIVE` are that repo's own key and its own
running+queued count — never the invoking `REPO_KEY` and never a combined total.

```bash
# ROW_ACTIVE = rows in the table just printed FOR THIS REPO that are running OR
# queued — completed rows excluded. It is caller-declared because nothing can
# derive it: .pipelines is append-only and no durable field tracks queued issues.
# Substitute the integer per repo; the guard below catches an unsubstituted
# placeholder. Default mode: ROW_REPO is Step 1's REPO_KEY and the loop runs once.
for ROW_REPO in <each repo whose rows this board carried>; do
  ROW_ACTIVE=<running + queued rows for ROW_REPO in the table above>

  if [[ -z "$TABLE_FRESHNESS_SH" ]]; then
    : # Step 0 already printed the DEGRADED line for an unresolved helper.
  elif [[ -z "$ROW_REPO" ]]; then
    echo 'DEGRADED: repo key unresolved — this board is not recorded against the table-freshness floor'
  elif [[ ! "${ROW_ACTIVE:-}" =~ ^[0-9]+$ ]]; then
    echo "DEGRADED: active count for $ROW_REPO is not an integer — that repo's board is not recorded against the table-freshness floor"
  elif [[ "$ROW_ACTIVE" -eq 0 ]]; then
    # A rendered board always has at least one running or queued row (Step 3), so a
    # zero here is a miscount, not a terminal board — and passing it through would
    # DISARM a floor whose round is still live. Refuse it loudly instead.
    echo "DEGRADED: active count for $ROW_REPO is 0 on a rendered board — rows miscounted; not recorded, since a 0 here would disarm a live floor"
  else
    "$TABLE_FRESHNESS_SH" --note-rendered --active "$ROW_ACTIVE" \
      --repo "$ROW_REPO" --session "$TF_SESSION" --surface board \
      || echo "DEGRADED: table-freshness clock not recorded for $ROW_REPO — the floor may fire again shortly"
  fi
done
```

**Why per repo and not one call.** The clock is keyed
`.repos["<key>"].table_render["<session>"]`, so a single call records one repo and
leaves every other repo's floor firing at a user who is looking at those rows right
now — and the combined count it wrote would be wrong in the one record it did reach.
Repos with no rows on this board are not touched: nothing was rendered for them.

**Only ever call this when a table was actually printed.** The no-round path of
Step 4 prints none, so it records nothing: stamping `last_rendered_at` without a
table restarts the hour and hides a board that has already gone stale, which is the
exact failure the floor exists to prevent. A render that did not happen is worse
recorded than not recorded.

**`/board` never records a terminal board.** Step 3 forms a round only when something
is running or queued, so a rendered board always carries at least one such row and
`ACTIVE_COUNT` is always ≥ 1 — which is why a computed `0` is refused above as a
miscount rather than passed through. The `--active 0` disarm belongs to the flows
that actually end a round: `/subagent`'s round-end render, `/pause`, and `/end`
(`time-estimates.md` §"Teardown is by data"). A reader does not end a round by
looking at it.

**`/board` records; it does not arm.** Arming the floor watch is `/subagent`
Step 7.3's job once per session, with `/pause-resume` and `/end-resume` re-arming a
resumed round. `/board` in a thread with no armed watch still records correctly — the
record is what the watch reads, so an arm that comes later finds a current clock.

A `TABLE FLOOR:` line from that watch is an instruction to render, and `/board`
satisfies it: run it, and Step 5 clears the line for the next hour.

---

## Boundaries

- **Read-only apart from Step 5.** No dispatch, no launch, no merge, no phase
  transition, no PR write. A board that is out of date is answered by running
  `/board` again, never by nudging a pipeline.
- **Never re-derive a start.** Step 2's order is the whole contract; a start that
  moves between two `/board` calls is a bug, not a refresh.
- **Never widen the round to fill the table.** An empty board is a real answer
  (Step 4), and history is not a substitute for it.
