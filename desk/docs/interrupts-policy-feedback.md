## Interrupts, policy, and feedback tags (issue #1783)

The second of `/desk`'s attention increments (`skill/interrupts.md`, migration
`008_event_session.sql`). The desk is **loud by default**: every new Decision
is shown at the next tick, in sets. The operator tunes it down item by item
with feedback tags, and holds it while away or focused. Agents ask exactly as
often as before and decide nothing new on their own; a held question waits in
the store, never in a worker thread.

- **`policy.json`.** `tick_cadence_min` 5 (1 to 60, below the live bound),
  `interrupt_rule` `everything` (or `away`), `eod_time` `17:30` (`HH:MM`,
  America/New_York; the end-of-day sweep, issue #1784), `set_size` 4 (1 to
  4), `live_desk_max_tick_age_min` 15 (1 to 1440), and derived impact's
  `critical_path_rank_top_n` 3 and `critical_path_min_dependents` 2 (each 1
  to 100; issue #1760, "Derived impact" below). One parser, `capture.py`'s
  `load_policy()`, serves the capture hook, `desk-tick.sh`, and
  `bin/desk-policy.sh` (which prints the effective policy as JSON). A missing
  file is the defaults; an unreadable file, a non-object, or any invalid value
  is the defaults for every key, with one warning; unknown keys are ignored.
  `HUMAN_QUEUE_POLICY` names another file (tests). The hook reads the live
  bound on every call, so `desk-tick.sh` reads it again every 30 seconds
  while it sleeps: a bound lowered to the loop's interval or below makes the
  loop tick 30 seconds inside it, cutting short a sleep already under way.
  The cadence and `interrupt_rule` are read when the desk starts; an edit to
  them applies at the next `/desk`, so an invalid edit never flips a running
  `away` desk to `everything`.
- **The interrupt rule.**

  | Subcommand | What it does |
  |------------|--------------|
  | `interrupt get --session S [--default RULE] [--json]` | The rule in force for desk session S: `everything`, `away`, or `focus until 15:30 ET (… UTC)`, ending ` (default)` when S set none (or its focus ended) and RULE, the policy's `interrupt_rule`, applies |
  | `interrupt set everything\|away --session S [--json]` / `interrupt set focus --session S (--until WHEN \| --for MIN) [--json]` | Stores the rule; only the registered control session may (exit 4 otherwise). WHEN is a clock time (`15:30`, `3:30`, `3:30pm`, optionally ` ET`; its next occurrence in America/New_York, a bare 12-hour time the sooner of am and pm) or an ISO 8601 time; a focus ends within a day |

  The rule lives in the reserved state key `interrupt` (`state set` refuses
  it) as `{"session", "rule", "until", "set_at"}` and belongs to the session
  that set it: a newly registered desk starts from the policy's rule. A
  stored value that is not valid JSON or names another session reads as no
  rule, never as an error. State is not an item, so setting it records no
  event.
- **The hold.** `desk-tick.sh` runs `tick --session S --interrupts RULE`.
  While the rule in force is `away` or a focus not yet over, that tick stamps
  `tick_at` (the desk stays live, so worker questions are still queued, never
  shown in their own threads), prints `[]`, and neither reads nor moves the
  watermark: the change feed is the hold buffer, and the first tick after the
  hold (`available` runs one at once; a focus ends on its own, back in the
  policy's rule, so under an `away` policy the hold goes on until
  `available`) reports
  everything that arrived during it, once, in the usual order. Wake-up
  retries keep running.
- **Sets.** `decisions.md` chunks the simple Decisions into sets of
  `set_size` with `desk.jq`'s `desk_batch`, so three new Decisions with no
  day plan are one set.
- **Feedback tags.** `2: not important`, `2: should have defaulted`, or `2:
  good interrupt` (a number in the latest set, or an id) is recognized by
  `desk.jq`'s `desk_feedback` before any typed reply, so a tag is never an
  answer, and recorded with `feedback ID TAG --set SET_ID --json`: one
  `feedback` event whose note is the tag and whose `session_id` is the asking
  thread. The desk acknowledges in one line. Before 008, `feedback` exits 1
  naming `migrate`.
- **Tests.** `tests/interrupts-offline.test.sh` (offline: the policy parser's
  shapes, `desk-policy.sh`, `desk-tick.sh` passing the policy's cadence and
  rule, `interrupt`/`tick --interrupts`/`feedback --set` validation before
  connecting, `desk_sets`, `desk_batch`, `desk_feedback`, and the skill's
  anchors); `tests/interrupts.test.sh` (live, throwaway schema: three
  Decisions in one set at the next tick; `away` holds and `available`
  releases; a focus in the future holds and one that has passed does not;
  another session's rule is ignored; an invalid stored value; a feedback tag
  written with its tag and asking session; 008 over a 007 store).

`migrate` for 008 runs at the next `/desk` start (its step 3), or by hand.
