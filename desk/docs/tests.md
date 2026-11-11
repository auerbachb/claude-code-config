## Tests

```bash
bash desk/tests/run.sh
```

- `cli.test.sh` is offline: it checks the dispatcher, validation before
  connection, the exit-7 contract (with a stub `psql` and, when `psql` is
  installed, an `.invalid` host and a TEST-NET address), and that the URL never
  reaches `psql`'s argv or any output. Each case runs under `bash` and, on
  macOS, under `/bin/bash` 3.2.
- `psql-discovery.test.sh` checks isolated installed-client layouts, including a compatible PATH client beside an old linked/libpq client, explicit overrides and versioned kegs.
- `psql-bindings.test.sh` inspects only its own running stub psql PID and verifies that multiline, Unicode, empty and large application values travel through the child environment, with none on argv or exported back to the parent.
- `lifecycle-cli.test.sh` is offline: `human-queue.sh --help` lists all 18
  subcommands, every lifecycle, set, state, and control validation rule exits
  4 (and every secret 5) without a connection attempt, and the `set-resolve`
  reply parser is checked directly. Same two shells.
- `items-cli.test.sh` is offline too: every `add`/`bump`/`get`/`list`/`show`
  validation rule (exit 4) and secret shape (exit 5) is refused without a
  connection attempt and without echoing the value, and prose that merely
  mentions a password or token is let through. Same two shells.
- `migrate.test.sh`, `items.test.sh`, and `lifecycle.test.sh` run against the real database when
  `HUMAN_QUEUE_DATABASE_URL` is set and skip with a notice otherwise. They
  never touch the queue's own tables: each run creates throwaway schemas named
  `hq_test_<pid>_<random>[_suffix]`, points the CLI at them with
  `HUMAN_QUEUE_SCHEMA`, drops them on exit, and asserts the `public` schema is
  unchanged. With the URL set, an unreachable database fails the suite.
  `items.test.sh` covers the item round trip, dedupe, ten parallel adds (of
  distinct questions and of one question), `bump`, list filters and order, and
  migration 002 over existing rows (sequence seeding, an id beyond bigint,
  duplicate open items). `lifecycle.test.sh` covers answer, pending-for, and
  ack; no-ops that record nothing; review, flag, comment, and feedback; sets
  numbered 1 to n and resolved one pair or several, all or nothing; `tick`,
  including a write held open across a tick by a second connection, two
  concurrent ticks, and a tick that waits for the lock under a URL whose
  `options` default to SERIALIZABLE (every `hq_db_script` transaction is
  pinned to READ COMMITTED); state and register-control; and migration 003
  over a 002 store. `migrate.test.sh` derives its
  expected migrations from `desk/schema/`, so a new migration needs no edit
  there.
- `capture-offline.test.sh` is offline: it runs the capture hook through its
  `.claude/hooks/` symlink with only the environment it sets (`env -i`, as
  the desktop app starts hooks), against a stub CLI that logs every call or
  the real CLI aimed at a TEST-NET address. It covers the registration in
  `global-settings.json`, the live-desk gate (none, never ticked, stale, live,
  and the `desk/policy.json` bound), the deny reason for one and two
  questions, the arguments `add` receives, every fail-open path (one stderr
  line, never the URL), finding the URL in a config file or a profile, and
  `control-status` validation. Same two shells.
- `capture.test.sh` is live under the same rules as the three above (skips
  without the URL, one throwaway schema, `public` unchanged): `control-status`
  and `tick_at`; no live desk queues nothing; a live desk denies a worker and
  allows the desk while both items exist; dedupe; two questions; and the URL
  read from a profile when the environment lacks it.
- `desk-offline.test.sh` is offline: `wake` and `set-resolve`'s id pairs
  validate before connecting; `desk-cli.sh` finds the URL (environment, an
  owner-only config file, a literal profile export) and refuses the rest;
  `wake-target.sh` against a fixture registry (running, dead, terminal,
  `.key` files ignored); `desk-tick.sh` against a stub CLI (new, retry,
  quiet, replaced, replaced between control-status and tick, one error per
  outage, recovered, sleep first, a cadence at or past the live-desk bound);
  the validation of `wake --json`, `wake-due`, `history`, and `pending-for
  --repo/--key`; and the skill's layout, including that its menu prefix is
  the hook's re-render prefix. Same two shells.
- `desk.test.sh` is live under the same rules (one throwaway schema,
  `public` unchanged): two worker sessions' Decisions shown in one set as 1
  and 2, `1: A, 2: C` answered in one transaction with each asking session,
  `woken` and `wake-failed` events, each worker's `pending-for`, replies by
  id, `wake` refusals, a second desk replacing the first (its
  `tick --session` reads nothing and moves no watermark), and `wake` on a
  store without migration 005.
- `wakeups.test.sh` is live under the same rules: retries, `answer-parked`,
  `show`, and `history` (see "Wake-up retries, `answer-parked`, `show`, and
  `history`").
- `priorities-offline.test.sh` is offline: the desk's priority commands
  against the real `pm-priority.sh` in a throwaway repo and HOME (see
  "Priorities").
- `shellcheck.test.sh` runs shellcheck on every shell file here (skips when
  shellcheck is not installed).

CI runs the suites through `.github/scripts/run-hook-tests.sh`, without a
database, so the live suites skip there.
