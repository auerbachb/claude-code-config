## Morning check-in and reading budget (issue #1770)

The reading budget — how many Reviews to read today — comes from the
operator's own data instead of a fixed guess (`skill/checkin.md`; no
migration: the measurements read `events`, the check-in lives in `state`).
Agents ask exactly as often as before and decide nothing new on their own.

- **Measured from events alone.** `stats [--day YYYY-MM-DD] [--json]`
  (read-only, `lib/budget.sh`) reports one America/New_York day: Reviews read
  (distinct `R-` items with a `reviewed` or `flagged` event), Decisions
  answered (distinct `D-` items with an `answered` event), the median minutes
  from an item's latest `shown` event to its first answer that day, and the
  time at the desk, estimated from the operator's actions (`answered`,
  `reviewed`, `flagged`, `feedback`): each is credited the minutes since the
  previous one when at most 15, else 2 (a break, or the day's first). An
  item's kind is its id's prefix, so nothing joins `items`.
- **The check-in.** At the first tick of the day from 04:00 until `eod_time`,
  `desk-tick.sh` asks `checkin due` (once a day, reserved key
  `checkin_asked`) and prints `desk-tick G morning` before any `new` line;
  `check-in` asks again, and a new plan with none today asks first. The card
  shows the measured pace, then three questions — hours at the desk, energy
  in one word, anything planned — answered in one typed line (`4, ok, the PRD
  until noon`; `desk.jq`'s `checkin_parse`).
- **The budget.**

  | Subcommand | What it does |
  |------------|--------------|
  | `checkin set --session S --hours H --energy WORD [--planned TEXT] [--json]` | Stores today's check-in (reserved key `checkin`) with the budget computed once: round(Reviews an hour, to one decimal, on the most recent of the last 7 days with at least 3 read × hours × the energy factor), so the card's arithmetic is exact; with no such day, the 30 × 20 guess, round(30 × the factor); 0 hours is 0. Control session only |
  | `checkin get [--json]` | Today's check-in, the measured day as it stands, the factor table, Reviews read today, unreviewed Reviews, the budget, and what is left |
  | `checkin due --session S --at HH:MM [--until HH:MM] [--json]` | `due DAY` the first time the store's clock is in the window and no check-in is stored today, `done DAY` after; control session only |

  Energy factors: `low`/`tired` 0.7, `ok`/`fine`/`normal`/`good` 1,
  `high`/`great` 1.2, a word in neither 1; the operator overrides or adds a
  word with the plain state key `energy_factors` (a JSON object, factors 0
  to 2). `state set` refuses `checkin` and `checkin_asked`.
- **Where it shows.** The budget card once, after the check-in; the running
  count (`Reading budget: 9 of 28 Reviews read today · 19 left`) under the
  Reviews view's header; and the day plan (#1784): `plan forecast --json`
  carries `budget`, `read_today`, and `left`, the plan card shows the line,
  and `desk_plan_propose` puts at most `left` Reviews in the clear-first
  batch.
- **Tests.** `tests/checkin-offline.test.sh` (offline: the reply grammar, the
  cards on `tests/fixtures/checkin/`, the Reviews view's running count, the
  plan's cap, `stats`/`checkin` validation before connecting, `desk-tick.sh`'s
  morning step against a stub, and the skill's anchors under bash,
  `/bin/bash` 3.2, and zsh); `tests/checkin.test.sh` (live, throwaway schema:
  test 5.1's fixture day against hand-computed stats, test 5.2's four hours
  at a measured 7 an hour proposing 28, the guess, the factors, an older
  measured day, once a day, the running count in the Reviews view and the
  plan).
