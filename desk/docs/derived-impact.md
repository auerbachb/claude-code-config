## Derived impact (issue #1760)

What an asking agent declares as impact is inconsistent from thread to
thread and tends to inflate. The real signals already exist: where the
issue ranks in `/pm`'s backlog, how many open issues depend on it, and
whether the agent is parked on the answer. `impact` derives a value from
them and stores it beside the declared one (migration
`014_impact_derived.sql`), and the derived value wins wherever impact orders
items.

| Subcommand | What it does | Event |
|------------|--------------|-------|
| `impact OWNER/REPO ISSUE [--json] [--no-store]` | Derives for one issue and stores the value on its open Decisions (those keyed `issue-ISSUE` in that repo, the repo compared in any case). `--no-store` derives and prints only, without the store | none |
| `impact --open [--max-age MIN] [--json]` | Derives for every open Decision keyed by an issue whose derived impact is missing, older than MIN minutes (default 60; 0 for all), or stored before its agent parked, one GitHub read per repo; `local/…` repos are skipped | none |

- **The rule** (`bin/lib/impact.jq`, one place): **critical-path** when at
  least `critical_path_min_dependents` open issues depend on the issue,
  counted down every chain (so the head of a three-issue chain qualifies at
  the default 2), or when `/pm`'s ranking is under a day old and ranks it in
  the top `critical_path_rank_top_n` (default 3); otherwise **medium** when
  one open issue depends on it or its agent is parked; otherwise **low**.
  Declared impact is never an input: a leaf at rank 40 derives low whatever
  its asker declared. Both thresholds live in `desk/policy.json` (read by the
  capture hook's parser, `desk-policy.sh`: whole numbers from 1 to 100).
- **The rank.** `/pm` writes the order it presents (its ranking with the
  operator's order from `pm-priority.sh` overlaid) to
  `~/.claude/pm-rank/<owner>-<repo>.json` at its Step 1B.4c, on every
  ranking: cold start, re-prioritize, and every refill re-scan.
  `pm-rank-cache.sh read` reports a rank only while that file is under 24
  hours old; otherwise the rank is unknown and the dependents and the parked
  flag decide. An issue a fresh ranking does not hold (in flight, excluded,
  below the shortlist) is "not in the backlog ranking", which adds nothing.
- **The dependents** come from `issue-deps.sh`, the one reading of the
  dependency markers `/pm` 1B.3 lists (`Depends on #N`, `blocked by #N`,
  `unblocks #N`, …, in bodies and comments, any case), which `/pm` and
  `/wave` use too. `impact` reads the repo's open issues once through its own
  `gh` (`HUMAN_QUEUE_GH`, the deadline, no database URL in the child) and
  hands them to `issue-deps.sh dependents --input`. A read that fails, or
  that returns 500 issues (gh's `--limit`, where it stops without saying so,
  so the list may be cut off), stores nothing for that repo and exits 1: an
  outage never demotes an item.
- **Where it orders.** `items.impact_derived` (`critical-path`, `high`,
  `medium`, `low`; the derivation itself never gives `high`, which stays the
  declared scale's), `impact_basis` (the inputs in words, for example `2 open
  dependents, backlog rank unknown, agent parked`), and `impact_derived_at`.
  Every order that reads impact takes the derived value where there is one,
  else the declared one: `tick`, `list`, the desk's sets (`desk_split` and
  `desk_batch` keep the list's order), the day plan's clear-first batch,
  the end-of-day sweep, and `export --kind decisions`, all through
  `items.sh`'s `hq_sql_impact_rank`: parked first, then critical-path, high,
  medium, low, none, then age. It is read through the row's JSON, so a store
  before 014 still orders, by declared impact. `get`/`list`, the desk's
  cards, and the paper copy print `Impact: critical-path (derived: 2 open
  dependents, backlog rank unknown; declared low)`.
- **Bookkeeping, not a change.** 014 replaces `items_mark_change()` keeping
  every annotation column 010 named (the cached summaries and the to-do
  fields) and adding the three impact columns, so a derivation is not a
  change `tick` reports and records no event. Only open Decisions are
  derived: Reviews keep their own order (oldest first).
- **When it runs.** The desk runs `impact --open` before it reads a batch
  (`skill/decisions.md`, step 0), so a new question is ordered by what it
  unblocks the first time it is shown; with nothing stale it reads no
  GitHub at all. A failure there stores nothing for the repo it could not
  read: each Decision keeps its last derived impact if it has one, else its
  declared one, and the failure is said once per desk session.
- **Tests.** `tests/impact-offline.test.sh` (offline, in CI, bash and
  `/bin/bash` 3.2: test plan 5.1–5.3 through `impact --no-store` with a stub
  `gh` and a scratch `PM_RANK_DIR`, the rule table, both thresholds from the
  policy and their defaults, failures, usage, the card's facts line, the
  order expression, and decisions.md's anchored block);
  `tests/impact.test.sh` (live, throwaway schema: storage beside the
  declared value, `tick`/`list`/sweep order, a derivation is not a tick
  change, `--open` and `--max-age`, a re-ask with `--parked` re-derived at
  once, a failed read keeps what was stored, and
  014 over a store without it). The shared scripts have their own suites:
  `.claude/scripts/tests/issue-deps.test.sh` and `pm-rank-cache.test.sh`.

`migrate` for 014 runs at the next `/desk` start (its step 3), or by hand.
