## Day plan and end-of-day sweep (issue #1784)

The last of `/desk`'s attention increments (`skill/plan.md`, `skill/sweep.md`;
no migration: both live in `state`). The day is planned in conversation, and
the stored plan decides when questions reach the operator; at `eod_time` the
desk lists everything still open. Agents ask exactly as often as before and
decide nothing new on their own.

- **The dialogue.** `plan`, `plan: …`, or a sentence such as `I need to work
  on the PRD, 30 minutes a section` (one grammar, `desk.jq`'s
  `desk_plan_parse`, so a plan is never guessed out of prose). The desk asks
  for pace and chunking when the sentence has none, forecasts incoming
  questions from `plan forecast` (Decisions asked in the last three hours, by
  how many threads, what is open now), and proposes an order
  (`desk_plan_propose`): a **ten-minute clear-first batch** (parked
  menu-shaped Decisions first, then the other menu-shaped ones and Reviews
  while they fit; a Decision at its declared minutes cost, else 2; a Review
  at 2), then one block per chunk, a tick cadence apart, then what was held
  and the long-form Decisions left for later. `yes` stores it; one sentence
  (`4 sections`, `until 12:30`, `plan: 45 min a section`) changes it, at once
  once stored. `plan?` shows it; `plan off` clears it.
- **The store.**

  | Subcommand | What it does |
  |------------|--------------|
  | `plan get [--json]` | Today's plan (`{"now", "today", "plan"}`; a plan stored on another America/New_York day is not today's) |
  | `plan set --session S [--json]` | Stores the plan read as JSON on stdin (blocks of item, pace, label, start, until; `clear_first`, `later`, `inputs`), checked by the store: 1 to 24 blocks in order, none longer than a day, the last ending after now and within a day, ids only in the lists, no control characters. Only the control session (exit 4 otherwise); a refusal stores nothing |
  | `plan clear --session S [--json]` | Deletes it; any hold it made ends |
  | `plan forecast [--window MIN] [--json]` | Decisions asked in the window (default 180 minutes) and the distinct threads that asked them, open and parked Decisions, unreviewed Reviews, the store's clock |
  | `sweep due --session S --at HH:MM [--json]` | Once the store's clock in America/New_York reaches `HH:MM`, marks the day (reserved key `eod_sweep`) and prints `due DAY` the one time, `done DAY` after; control session only |
  | `sweep list [--json]` | Everything still open: Decisions in list order, then unreviewed Reviews oldest first, at most 99 (`more` counts the rest) |

  `state set` refuses `plan` and `eod_sweep`.
- **The hold.** `lib/interrupts.sh` reads the plan: while a block is in
  force, the rule is `focus until <its end>`, source `plan` (`interrupt get`
  ends ` (plan)`), so `tick --interrupts` holds new Decisions and the first
  tick after the block shows them, once. The desk's own rule comes first:
  `away` holds plan or not, an unexpired focus holds until its own end, and
  `everything` (`available`) set during a block releases that block only.
  The plan belongs to the operator's day, not to a desk session. A plan or
  block that does not parse holds nothing and fails no tick.
- **The sweep.** `desk-tick.sh` reads `eod_time` at start; once this
  machine's clock in America/New_York passes it, it asks `sweep due` (the
  store's clock and once-a-day mark decide) and prints `desk-tick G eod`,
  after any `new` and `retry` lines; after the store answers for a day it
  stops asking that day. `HUMAN_QUEUE_CLOCK` pins the loop's clock (tests).
  The desk then renders `sweep list` as one numbered list (`desk.jq`'s
  `sweep_view`), opened as a set with `set-open` so `2: B` resolves against
  it, and offers the numbered PDF of that set (`export`, issue #1759; see
  "Export to paper"). During a
  hold the sweep waits for the release, like a parked notice.
- **Tests.** `tests/plan-offline.test.sh` (offline: the grammar, merging,
  proposals on `tests/fixtures/plan/` — test 5.1's batch before the block —
  revisions, `plan_card`, `plan_record`, `plan_show`, `sweep_view` — test
  5.2's numbered list — the `plan`/`sweep` validation before connecting,
  `desk-tick.sh`'s end-of-day step against a stub, and the skill's anchors
  under bash, `/bin/bash` 3.2, and zsh); `tests/plan.test.sh` (live,
  throwaway schema: the skill's blocks propose and store test 5.1's plan; a
  block holds and its release shows what it held; `available` releases one
  block; `away` and a focus win; `plan off`; refusals; the forecast; a
  simulated `eod_time` prints `eod` once and the sweep block numbers every
  open item as one set). The live suites that run `desk-tick.sh` pin
  `HUMAN_QUEUE_CLOCK` before any `eod_time`, so the hour they run at never
  adds an `eod` line.
