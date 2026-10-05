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
   echoing it to the terminal. `connection-string` returns the direct
   (non-pooled) endpoint unless `--pooled` is given; either works, because the
   CLI selects its schema inside each transaction rather than through startup
   options.

   ```bash
   url=$(neonctl connection-string --project-id <project-id>) \
     && printf "export HUMAN_QUEUE_DATABASE_URL='%s'\n" "$url" >> ~/.zprofile \
     && unset url && chmod 600 ~/.zprofile
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
| `4` | validation or usage error: unknown subcommand, stray argument, invalid `HUMAN_QUEUE_SCHEMA`, or invalid input |
| `5` | secret refused: free text that looks like a credential is never stored (used by `add`, issue #1775) |
| `7` | database unset, unparseable, client missing, or unreachable |

Exit 7 always arrives **within two seconds** with **exactly one line** on
stderr, so a caller such as the capture hook can fail open. libpq's own
`connect_timeout` cannot promise that (its floor is two seconds, per resolved
address), so the CLI first runs a `SELECT 1` probe under a 1.5-second watchdog
and only then does real work. One trade-off follows: a Neon compute waking from
suspend more slowly than that reads as exit 7. Callers fail open, and the next
call finds the compute awake.

Validation always runs before any connection attempt, and `--help` (global or
per subcommand) never touches the database.

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
  advisory lock; the later run finds the work done and exits 0.

## Adding a subcommand

Add `bin/cmd/<name>.sh` (name: `[a-z][a-z0-9-]*`). The dispatcher finds it; do
not edit `human-queue.sh`. The file:

- starts with `# shellcheck shell=bash` and a `# summary: <one line>` header,
  which `human-queue.sh --help` lists;
- defines `cmd_usage` (printed for `<name> --help`) and `cmd_run "$@"`;
- validates its arguments first (exit 4 through `hq_die_validation`), then calls
  `hq_db_connect`, then runs SQL through `hq_db_script` (one transaction in the
  selected schema) or `hq_psql`, mapping failures with `hq_db_fail`.

## Tests

```bash
bash desk/tests/run.sh
```

- `cli.test.sh` is offline: it checks the dispatcher, validation before
  connection, the exit-7 contract (with a stub `psql` and, when `psql` is
  installed, an `.invalid` host and a TEST-NET address), and that the URL never
  reaches `psql`'s argv or any output. Each case runs under `bash` and, on
  macOS, under `/bin/bash` 3.2.
- `migrate.test.sh` runs against the real database when
  `HUMAN_QUEUE_DATABASE_URL` is set and skips with a notice otherwise. It never
  touches the queue's own tables: each run creates throwaway schemas named
  `hq_test_<pid>_<random>`, points the CLI at them with `HUMAN_QUEUE_SCHEMA`,
  drops them on exit, and asserts the `public` schema is unchanged. With the
  URL set, an unreachable database fails the suite.
- `shellcheck.test.sh` runs shellcheck on every shell file here (skips when
  shellcheck is not installed).

CI runs the suites through `.github/scripts/run-hook-tests.sh`, without a
database, so the live suite skips there.
