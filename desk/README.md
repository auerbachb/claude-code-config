# desk/ — the human queue

One store and one CLI for everything that needs the operator: **Decisions**
(questions that hold an agent) and **Reviews** (landed work). The design and
its reasoning are in [`DESIGN.md`](DESIGN.md); this file is the operating
contract for the code. Everything for the queue lives in this folder so it can
be spun out as its own project later.

## Layout

| Path | What it holds |
|------|---------------|
| `bin/human-queue.sh` | The CLI, and the only program that reads or writes the store |
| `bin/cmd/<name>.sh` | One file per subcommand, found at run time |
| `bin/lib/common.sh` | One-line diagnostics, exit codes, `HUMAN_QUEUE_SCHEMA` |
| `bin/lib/db.sh` | Connection handling: URL parsing, the two-second probe, psql |
| `bin/lib/items.sh` | Item ids, input checks mirrored from the schema, the shared item renderer |
| `bin/lib/secrets.sh` | The secret-shape detector behind exit 5 |
| `schema/NNN_<name>.sql` | Migrations, applied by `human-queue.sh migrate` |
| `hooks/` | Hook implementations (the capture hook arrives with issue #1755) |
| `skill/` | The `/desk` skill (arrives with the `/desk` issues) |
| `tests/` | `run.sh` plus `*.test.sh` suites |

`.claude/skills/desk` and the hook entries under `.claude/hooks/` will be
symlinks into this folder, added by the issues that create that content, so the
repo's skill-symlink rule keeps holding.

## Provisioning the database (once)

The store is one Postgres database on Neon, shared by every machine. The
project `human-queue` (region `aws-us-east-1`) already exists; these steps are
for a fresh setup or a new machine.

1. Create the project once, from any machine with
   [`neonctl`](https://neon.tech/docs/reference/neon-cli) authenticated:

   ```bash
   neonctl projects create --name human-queue --region-id aws-us-east-1
   ```

2. On each machine, write the connection URL into the shell profile without
   echoing it to the terminal. The profile is restricted to its owner
   **before** the secret goes in, so it is never readable by others, even if
   the append is interrupted. `connection-string` returns the direct
   (non-pooled) endpoint unless `--pooled` is given; either works, because the
   CLI selects its schema inside each transaction rather than through startup
   options.

   ```bash
   touch ~/.zprofile && chmod 600 ~/.zprofile \
     && url=$(neonctl connection-string --project-id <project-id>) \
     && printf "export HUMAN_QUEUE_DATABASE_URL='%s'\n" "$url" >> ~/.zprofile
   unset url
   ```

   A non-login shell may need `source ~/.zprofile` before the variable is set.

3. Apply the schema: `desk/bin/human-queue.sh migrate`.

`HUMAN_QUEUE_DATABASE_URL` is a secret. Never commit it, paste it into an issue
or PR, or print it. The CLI never prints it and never puts it on a command
line: it parses the URL into libpq environment variables that only the `psql`
child process sees. Supported URL parameters are `sslmode`, `channel_binding`,
`sslrootcert`, `sslnegotiation`, and `options`; anything else, or a multi-host
URL, is refused with exit 7 rather than silently dropped.

## Environment

| Variable | Meaning |
|----------|---------|
| `HUMAN_QUEUE_DATABASE_URL` | `postgres://` URL of the store. Required; secret |
| `HUMAN_QUEUE_SCHEMA` | Schema every statement runs in (default `public`), applied with `SET LOCAL search_path` inside each transaction. Tests set it to a throwaway schema |
| `HUMAN_QUEUE_PSQL` | `psql` binary to use (default `/opt/homebrew/bin/psql`, else `psql` on `PATH`) |

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | ok |
| `1` | unexpected failure, such as a migration's SQL error (its transaction is rolled back) |
| `4` | validation or usage error: unknown subcommand, stray argument, invalid `HUMAN_QUEUE_SCHEMA`, invalid input, or an item id that does not exist |
| `5` | secret refused: free text that looks like a credential is never stored (`add`, and `bump --note`) |
| `7` | database unset, unparseable, client missing, or unreachable |

Exit 7 always arrives **within two seconds** with **exactly one line** on
stderr, so a caller such as the capture hook can fail open. libpq's own
`connect_timeout` cannot promise that (its floor is two seconds, per resolved
address), so the CLI first runs a `SELECT 1` probe under a 1.5-second watchdog
and only then does real work. One trade-off follows: a Neon compute waking from
suspend more slowly than that reads as exit 7. Callers fail open, and the next
call finds the compute awake. Every later connection in the same run gets the
same 1.5-second connect deadline, so a database that goes away after the probe
also ends in exit 7 rather than a hang; once a connection is up, the SQL itself
is not time-limited.

Validation and the secret check always run before any connection attempt, and
`--help` (global or per subcommand) never touches the database. The one exit 4
that needs the store is an item id that does not exist; it is reported after
connecting.

## Items

Every item is a Decision (`D-43`: needs the operator, holds an agent) or a
Review (`R-88`: landed work). Ids are short and typeable; a lowercase `d-43` is
accepted everywhere and printed as `D-43`. Each subcommand's `--help` is its
full contract.

| Subcommand | What it does |
|------------|--------------|
| `add --kind K --repo O/N --key KEY --question TEXT [...]` | Writes an item and its `asked` event, then prints the new id alone. Optional: `--session`, up to three `--context`, up to 26 `--option`, `--default`, `--default-at`, `--impact`, `--parked`, `--cost`, `--focus` |
| `bump ID [--note TEXT]` | Records a `bumped` event and refreshes `updated_at` |
| `get ID [--json]` | Prints one item |
| `show ID [--json]` | Prints one item, then its events, oldest first |
| `list [--kind K] [--status S] [--json]` | Prints matching items: parked first, then impact, then age |

- **Validation.** `add` checks the required fields in the order kind, repo,
  key, question, and names the first one missing (exit 4). Every limit in the
  schema (a one-line question of at most 500 characters, at most three context
  lines with 600 characters in total, at most 26 options, the impact values)
  is checked first in the CLI, so the database never sees a value it would
  reject. When options are given, `--default` must be one of them;
  `--default-at` is ISO 8601 with a time zone.
- **Secrets.** Every value `add` takes, and `bump`'s note, is scanned for
  secret shapes: private keys; AWS, Google, Slack, GitHub, Stripe, `sk-`, and
  Neon `npg_` keys; JSON Web Tokens; bearer values; URLs with
  `user:password@`; and labeled values such as `password=...`. A match exits 5
  naming the flag, never the value, and nothing is stored. The scan is a
  heuristic; it cannot recognize every secret.
- **Dedupe.** If an *open* item already has the same kind, repo, key, and
  question (compared ignoring case and runs of whitespace), `add` bumps it
  instead of creating a second one: it prints the same id, records `bumped`,
  and the fields given on that call replace the stored ones (the session
  becomes the new return address). An answered or closed question asked again
  is a new item. Concurrent adds are safe: an advisory lock per question
  serializes them, ids come from per-kind sequences, and a partial unique
  index (`items_open_question_key`) makes a second open copy impossible.
- **Printed shape.** `get`, `show`, and `list` share one renderer: a header
  line, the question in bold, the context as a numbered list, lettered
  options, the default and when it applies, one line of triage facts, and the
  answer once there is one. Times are UTC.

  ```text
  D-43 · decision · open · auerbachb/claude-code-config · pr-1775
  **Ship the migration before the CLI?**
  1. Migration 002 adds the id sequences.
  2. The CLI allocates ids from them.
  Options: A. Ship now · B. Wait for review
  Default: B. Wait for review, at 2026-10-05 22:00 UTC
  Asked 2026-10-05 21:40 UTC · Impact: high · Cost: ~10 min · Parked · Session: abc
  ```

- **Events** record state changes only (`asked`, `bumped`, ...), with an
  optional note of at most 200 characters: never transcripts or diffs.
  Reading (`get`, `show`, `list`) records nothing.

## Migrations

- Name files `NNN_<name>.sql` with a lowercase `[a-z0-9_]` name, for example
  `002_item_ids.sql`. They apply in lexical order.
- The runner records each applied file by its **full filename** in
  `schema_migrations`, so two branches that both add a `002_` file both apply.
- Each file runs in one transaction together with its ledger row: a failing
  file leaves nothing behind. Do not put `BEGIN` or `COMMIT` in a migration.
- Never edit a migration after it merges. Change the schema with a new file.
- Use unqualified table names: `HUMAN_QUEUE_SCHEMA` picks the schema.
- Concurrent `migrate` runs (for example from two machines) serialize on an
  advisory lock; the later run waits for it, finds the work done, and exits 0.
  The wait is capped at 30 seconds (`lock_timeout`), so a stuck run cannot
  hang the next one: past the cap the later run exits 1 having changed
  nothing, and re-running it is safe.
- A merged migration reaches the shared store only when someone runs
  `human-queue.sh migrate` against it. Until `002_item_ids.sql` is applied,
  `add` exits 1 with a hint to run `migrate`.

## Adding a subcommand

Add `bin/cmd/<name>.sh` (name: `[a-z][a-z0-9-]*`). The dispatcher finds it; do
not edit `human-queue.sh`. The file:

- starts with `# shellcheck shell=bash` and a `# summary: <one line>` header,
  which `human-queue.sh --help` lists;
- defines `cmd_usage` (printed for `<name> --help`) and `cmd_run "$@"`;
- validates its arguments first (exit 4 through `hq_die_validation`), then calls
  `hq_db_connect`, then runs SQL through `hq_db_script` (one transaction in the
  selected schema) or `hq_psql`, mapping failures with `hq_db_fail`;
- sources `lib/items.sh` for ids, input checks, and the item renderer, and
  `lib/secrets.sh` (`hq_refuse_secret`) for any free text it stores; values
  reach SQL only as psql variables (`-v name=value`, used as `:'name'`).

## Tests

```bash
bash desk/tests/run.sh
```

- `cli.test.sh` is offline: it checks the dispatcher, validation before
  connection, the exit-7 contract (with a stub `psql` and, when `psql` is
  installed, an `.invalid` host and a TEST-NET address), and that the URL never
  reaches `psql`'s argv or any output. Each case runs under `bash` and, on
  macOS, under `/bin/bash` 3.2.
- `items-cli.test.sh` is offline too: every `add`/`bump`/`get`/`list`/`show`
  validation rule (exit 4) and secret shape (exit 5) is refused without a
  connection attempt and without echoing the value, and prose that merely
  mentions a password or token is let through. Same two shells.
- `migrate.test.sh` and `items.test.sh` run against the real database when
  `HUMAN_QUEUE_DATABASE_URL` is set and skip with a notice otherwise. They
  never touch the queue's own tables: each run creates throwaway schemas named
  `hq_test_<pid>_<random>[_suffix]`, points the CLI at them with
  `HUMAN_QUEUE_SCHEMA`, drops them on exit, and asserts the `public` schema is
  unchanged. With the URL set, an unreachable database fails the suite.
  `items.test.sh` covers the item round trip, dedupe, ten parallel adds (of
  distinct questions and of one question), `bump`, list filters and order, and
  the id-sequence seeding in migration 002. `migrate.test.sh` derives its
  expected migrations from `desk/schema/`, so a new migration needs no edit
  there.
- `shellcheck.test.sh` runs shellcheck on every shell file here (skips when
  shellcheck is not installed).

CI runs the suites through `.github/scripts/run-hook-tests.sh`, without a
database, so the live suites skip there.
