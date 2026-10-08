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
| `bin/lib/lifecycle.sh` | The answer transaction shared by `answer` and `set-resolve`, row locking, the `!reason` refusal protocol |
| `bin/lib/secrets.sh` | The secret-shape detector behind exit 5 |
| `bin/desk-cli.sh` | `human-queue.sh` for the desk: same arguments, the store's URL found the way the capture hook finds it (see "The desk") |
| `bin/desk-policy.sh` | The effective `policy.json` as one JSON object, through the capture hook's parser (see "Interrupts, policy, and feedback tags") |
| `bin/desk-tick.sh` | The `/desk` Monitor loop (see "The desk") |
| `bin/wake-target.sh` | A Decision's return address → the running session's messaging address (see "The desk") |
| `bin/idea-target.sh` | Which repository a desk idea is filed in (see "Ideas") |
| `bin/lib/filings.sh` | The desk's pending filings, shared by `filed` and `sync-reviews` (see "Ideas") |
| `schema/NNN_<name>.sql` | Migrations, applied by `human-queue.sh migrate` |
| `hooks/` | Hook implementations: `capture.sh` and its logic `capture.py`, the capture hook (see "Capture hook") |
| `policy.json` | The desk's defaults: tick cadence, interrupt rule, end of day, set size, live-desk bound (see "Interrupts, policy, and feedback tags") |
| `skill/` | The `/desk` skill: `SKILL.md` (router) and one file per kind of work (see "The desk") |
| `tests/` | `run.sh` plus `*.test.sh` suites |

The hook entries under `.claude/hooks/` are symlinks into this folder
(`human-queue-capture.sh` → `hooks/capture.sh`), and so is `.claude/skills/desk`
(→ `../../desk/skill`), so the repo's skill-symlink rule keeps holding.

## Provisioning the database (once)

The store is one Postgres database on Neon, shared by every machine. The
project `human-queue` (region `aws-us-east-1`) already exists; these steps are
for a fresh setup or a new machine.

1. Create the project once, from any machine with
   [`neonctl`](https://neon.tech/docs/reference/neon-cli) authenticated. The
   store needs PostgreSQL 16 or later (the interrupt rule's reader uses
   `pg_input_is_valid`), so the version is pinned rather than left to Neon's
   default; `migrate` refuses an older server by name:

   ```bash
   neonctl projects create --name human-queue --region-id aws-us-east-1 --pg-version 17
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
| `4` | validation or usage error: unknown subcommand, stray argument, invalid `HUMAN_QUEUE_SCHEMA`, invalid input, an item id that does not exist, or a write the item's state refuses (for example `ack` of an item with no answer) |
| `5` | secret refused: free text that looks like a credential is never stored (`add`, `bump --note`, `answer`, `flag --note`, `comment`, `set-resolve`, `state set`, `register-control`), nor sent to `psql` as a lookup value (`state get`'s key, `pending-for`'s session, repo, and key) |
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
`--help` (global or per subcommand) never touches the database. The exit 4s
that need the store (an item id that does not exist, a set number that is not
in the set, an answer letter past the last option, an item with no answer to
acknowledge, a state key that is not set) are reported after connecting, and
the transaction that found them writes nothing.

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
| `show ID [--json]` | Prints one item, then its events, oldest first: the item's whole sub-thread (`/desk`'s `show D-<n>`) |
| `list [--kind K] [--status S] [--json]` | Prints matching items: parked first, then impact, then age. Statuses: `open`, `answered`, `acknowledged`, `reviewed`, `flagged`, `closed`, `answer-parked` |
| `history [--date YYYY-MM-DD] [--json]` | Read-only: the Decisions answered on that America/New_York day (default today), once each, in answer order, whatever their status now |

- **Validation.** `add` checks the required fields in the order kind, repo,
  key, question, and names the first one missing (exit 4). Every limit in the
  schema (a one-line question of at most 500 characters, at most three context
  lines with 600 characters in total, at most 26 options, the impact values)
  is checked first in the CLI, so the database never sees a value it would
  reject. The text an item carries (question, context, options, notes,
  comments, session ids, answers) may not hold control characters other than
  tab — answers may also span lines — because `list`, `show`, and `set-open`
  print it raw to a terminal. (`state` values are opaque and stored exactly.)
  When options are given, `--default` must be one of them; `--default-at` is
  ISO 8601 with a time zone (an offset of at most 14:00 either way).
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
  becomes the new return address). New options given without `--default`
  clear a stored default that is not among them, with its time. An answered
  or closed question asked again is a new item. Concurrent adds are safe: an advisory lock per question
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
  Reading (`get`, `show`, `list`, `pending-for`) records nothing.

## Lifecycle

| Subcommand | Takes | What it does | Event |
|------------|-------|--------------|-------|
| `answer ID ANSWER` | Decisions | Stores the answer and sets `answered`. A single letter naming one of the item's options stores that option's text; free text may span lines (at most 4000 characters, trimmed). The last answer wins and returns an acknowledged item to `answered` | `answered` (note `option B` for a letter) |
| `ack ID [--answer TEXT]` | Decisions | A thread has read the answer: `answered` or `answer-parked` becomes `acknowledged` and the item is no longer parked. `--answer` acknowledges only if the stored answer is still TEXT | `acknowledged` |
| `pending-for [SESSION] [--repo O/N --key KEY] [--json]` | Decisions | Read-only: the answered or `answer-parked`, not yet acknowledged items whose return address is SESSION; with `--repo`/`--key`, the `answer-parked` items of that PR or issue, whoever asked them (the next thread on that work). Oldest answer first | none |
| `review ID` | Reviews | Sets `reviewed` (also clears a flag) | `reviewed` |
| `flag ID [--note TEXT]` | Reviews | Sets `flagged`; the note says what to follow up. Turning it into an issue is the desk's job | `flagged` |
| `comment ID TEXT` | any item | A one-line note in the item's history; the item is unchanged | `commented` |
| `wake ID --result sent\|failed [--note TEXT] [--json]` | answered Decisions | Records whether the desk woke the asking thread after an answer. Every call appends (each attempt is a fact); an item with no answer is refused. The failure that uses up the third retry (or any failure with no return address) also sets `answer-parked`; otherwise the item is unchanged and `tick` does not report it again. `--json` prints `{id, result, failures, retries_left, status, parked}` | `woken` or `wake-failed` (note: the address and the tool's status, or the reason); `answer-parked` when it parks |
| `wake-due [--min-age SECONDS] [--json]` | answered Decisions | Read-only: the answers whose last wake-up since their latest answer failed and that have a retry left (at most 3 after the first attempt), oldest failure first | none |
| `feedback ID TAG [--set SET_ID] [--json]` | any item | An interrupt-tuning tag: `not-important`, `should-have-defaulted`, `good-interrupt`, or any other hyphenated lowercase tag. The event also records the asking thread (the item's `session_id`; migration 008). With `--set`, ID may be the item's number in that set; `--json` prints `{id, tag, session, recorded}` | `feedback` (note: the tag) |

- **One event per change.** Every write records exactly one event per item it
  changes, in the same transaction. A call that would change nothing (an
  `ack` of an acknowledged item, re-sending the same answer, reviewing a
  reviewed item, repeating a flag's note, giving a tag the item already has)
  is a no-op: exit 0, no event. `comment` always appends.
- **The id prefix is the kind**, so `answer`/`ack` refuse `R-` ids and
  `review`/`flag` refuse `D-` ids before connecting (exit 4).
- **The worker loop.** A thread that asked with `add --session S` polls
  `pending-for S`, acts on each answer, then runs `ack ID --answer TEXT`. If
  the operator changed the answer in between, that `ack` exits 4 and the
  thread reads it again. A thread that takes over a PR or issue whose asking
  thread has ended reads the answers parked for it with `pending-for --repo
  O/N --key KEY` and acknowledges them the same way.
- **Concurrency.** Each write locks the item rows first and reads them again in
  the next statement, so concurrent calls never double-record. Several items
  are locked in id order, so multi-item writes cannot deadlock.

## Sets

| Subcommand | What it does |
|------------|--------------|
| `set-open ID... [--json]` | Numbers 1 to 99 distinct items 1..n under a new set id, in argument order, and records one `shown` event per item (note `set N #k`). Prints `set N` and one `k. ID **question**` line per item |
| `set-resolve REPLY [--set ID] [--json]` | Maps the operator's reply to the set's items and answers them, exactly as `answer` does. `--json` answers carry each item's `session` (its return address), so the desk wakes threads without another read |

- **Replies.** `"2: B"`, `"1: A, 2: C"`, `"D-43: B"`, or `"1: yes, but after
  CI; 3: use staging"`. A pair is opened by an item's number in the set or by
  its id (issue #1779; the id must be in the set, and one item may not be
  named by both). A pair starts at the beginning, or after a comma, semicolon, or
  line break followed by `N:` or `D-<n>:`; anything else continues the answer before it,
  so commas and line breaks inside an answer survive. A reply is at most 8000
  characters, which bounds the parse to under a second on bash 3.2.
- **All or nothing.** Every pair is validated (the number is in the set, the
  item is a Decision, a letter names one of its options) before any answer is
  written, and all answers are written in one transaction. One bad pair
  writes nothing.
- **Which set.** The latest set by default; a caller that holds a set id
  passes `--set`. Numbering restarts at 1 in every set. Four per menu is the
  question tool's limit, not the store's.

## State, control, and tick

| Subcommand | What it does |
|------------|--------------|
| `state get KEY` / `state set KEY VALUE` | One key of operator state (the day plan, for example). `get` prints the value exactly; a key that is not set exits 4. A value is at most 65536 characters and 131000 bytes (it travels as one `psql` argument, and Linux caps one at 128 KiB) |
| `register-control SESSION [--json]` | Registers the desk's one control session (the last registration wins) and names the one it replaced; a different session also clears `tick_at` |
| `tick [--session SESSION [--interrupts RULE]]` | Prints, as one JSON array in the `list --json` shape, the items new or changed since the last tick. With `--session`, only as the registered control session: checked inside the tick's transaction under `register-control`'s lock; any other session exits 4 with nothing read, the watermark unmoved, and no `tick_at` stamped. With `--interrupts`, honors the desk's interrupt rule: while it holds items back, prints `[]`, stamps `tick_at`, and leaves the watermark (see "Interrupts, policy, and feedback tags") |
| `control-status [--json]` | Read-only: the registered control session, when the last tick ran, and how many seconds ago on the database's clock (`{"session", "last_tick_at", "tick_age_seconds"}`, each null when unset). The capture hook's live-desk check |

- **Reserved keys.** `tick_watermark` and `tick_at` (written by `tick`) and
  `control_session` (written by `register-control`) are readable with
  `state get`; `state set` refuses them, and every `filed:` key (written by
  `filed`, see "Ideas"). State is not an item, so it records
  no event.
- **What `tick` reports.** An item whose row was written: added, bumped,
  answered, acknowledged, reviewed, or flagged. `comment`, `feedback`, and
  `shown` events are annotations the desk writes itself and do not re-report
  an item. The first tick ever reports every item.
- **Why the watermark is a snapshot, not a time.** `updated_at` is `now()`,
  the start of the writing transaction, so a write that starts before a tick
  and commits after it carries a time older than that tick and would be
  missed for good. Instead, migration 003 stamps every item write with its
  transaction id (`items.change_xid`, kept out of the JSON), and each tick
  stores the database snapshot it read under (`pg_current_snapshot()`) as the
  watermark. The next tick reports exactly the items whose last write that
  snapshot could not see: every write that committed after the previous tick
  read, including one still in flight while it ran, and nothing twice.
  Concurrent ticks serialize on an advisory lock.
- **When the desk last ticked.** The watermark is not a time, so each tick
  also stores its own time (UTC ISO 8601) under `tick_at`. `control-status`
  turns it into an age; it reads any tick, and in practice only the desk
  ticks. Registering a different control session clears `tick_at`, so a
  replacement desk is live only after its own first tick, never on the
  previous desk's.

## Capture hook

`hooks/capture.sh` (with its logic in `hooks/capture.py`) is a `PreToolUse`
hook on `AskUserQuestion`, registered as `.claude/hooks/human-queue-capture.sh`,
a symlink into this folder, through `global-settings.json` (timeout 15 s). It
registers globally at the next session start.

| Situation | What the asking thread sees | What the store gets |
|-----------|-----------------------------|---------------------|
| No live desk | The menu, as before | Nothing |
| Live desk, the desk's own session | The menu | One Decision per question, except a question in the desk's set format (`1. [D-43] …`), which is a queued item shown again and adds nothing |
| Live desk, any other session | The call denied with the reason below | One Decision per question |
| The hook cannot do its job | The menu, plus one warning line on stderr | Whatever was written before the failure |

- **Live desk.** A control session is registered (`register-control`) and
  `control-status` says the last tick is at most **15 minutes** old: three
  missed ticks at the desk's default five-minute cadence. Override it with
  `live_desk_max_tick_age_min` (1 to 1440) in `desk/policy.json`; an invalid
  value keeps 15 and warns. With no live desk (none registered, never ticked,
  or the desk session died) every menu renders in its thread as before, so no
  question is stranded during rollout or while the desk is down.
- **The reason.** `Queued as D-43. Print exactly: question D-43 sent to human
  queue. Then proceed on your recommended default or park and wait for a
  wake-up.` A call with several questions names every id:
  `Queued as D-43, D-44. Print exactly: questions D-43, D-44 sent to human
  queue. ...`
- **What a Decision carries.** `--kind decision`; the question on one line
  (whitespace collapsed, control characters dropped, at most 500 bytes); each
  option label as `--option`; `--default` is the label ending in
  `(Recommended)`, else the first option (`ask-menu.md` puts the recommended
  one first); context lines for the header, a multi-select note, and the
  option descriptions (600 characters in total); `--session` is the asking
  session, the return address. `--repo` is the `owner/name` of the cwd's
  `origin` (else `local/<directory>`). `--key` is `issue-N` when the branch is
  `issue-N-*`, else `branch:<name>`, else (on `main` or a detached HEAD)
  `session:<id>`, so unrelated threads never share an item. A key over 200
  bytes keeps its start and ends in `~` and 12 hex digits of its SHA-256, so
  two long branch names that share a prefix stay two keys. `add`'s dedupe
  applies: asking the same open question again bumps it.
- **Finding the store.** The desktop app starts hooks without sourcing a
  shell profile, so `HUMAN_QUEUE_DATABASE_URL` is taken from the first of:
  the environment; `${XDG_CONFIG_HOME:-~/.config}/human-queue/database_url`
  (the URL on one line; used only when it is a file you own with mode 600);
  the last `export HUMAN_QUEUE_DATABASE_URL=...` line of the first of
  `~/.zprofile`, `~/.zshenv`, `~/.zshrc`, `~/.bash_profile`, `~/.bashrc`,
  `~/.profile` that sets it. A profile line counts only when its value is a
  literal (single-quoted, double-quoted without `$`, backtick, or backslash,
  or bare): the profile is read, never run. The URL goes only into the CLI's
  environment and is never printed.
- **Failing open.** No URL, no CLI, a CLI exit other than 0 (7: the store is
  unreachable, within two seconds), output it cannot read, malformed input,
  python3 missing, or a call over 6 s (the whole hook gives up at 12 s): the
  menu renders and stderr carries one line, prefixed `human-queue-capture:`.
  The hook never prints the URL, raw CLI output, or exception text, and never
  blocks a thread because of its own failure. A failure after some questions
  of one call were queued names them; those items stay in the store.
- **Cost.** With no live desk the hook makes one `control-status` call
  (about half a second against Neon); with a live desk, one `add` per
  question as well.

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
  `add` exits 1 with a hint to run `migrate`; until `003_lifecycle.sql` is
  applied, `set-open` and `tick` do. If the store already holds two
  open items with the same kind, repo, key, and question, 002 stops and names
  their ids, changing nothing: close all but one of each group and run it
  again.

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

## The desk (issue #1779)

`/desk` (`skill/SKILL.md`, published as `.claude/skills/desk`) is the control
session: the one thread where questions render. Its first increment covers
simple Decisions; long-form, multipart, and `discuss` are #1780, and wake-up
retries, `answer-parked`, `show`, and `history` are #1781 (below).

- **Start.** `migrate`, then `register-control` with the session id the
  capture hook sees (`$CLAUDE_CODE_SESSION_ID`, never the desktop app's
  `local_…` id), one inline tick, then a persistent Monitor running
  `desk-tick.sh` (default: `policy.json`'s `tick_cadence_min`, 5 minutes;
  1 to 60 and shorter than the live-desk bound, which `desk-tick.sh` reads through the capture hook's own
  policy parser and enforces with exit 4). From the inline tick on,
  the desk is live and worker threads' menus are queued instead of shown.
- **`desk-cli.sh`.** The desktop app's Bash tool and Monitor do not source the
  shell profile, so the URL is usually missing there. The wrapper calls the
  capture hook's own resolver (`capture.py`'s `resolve_url`: environment,
  owner-only config file, literal profile export) and runs `human-queue.sh`
  with it; exit 7 with one line when there is none. `HUMAN_QUEUE_CLI`
  replaces the CLI (tests).
- **`desk-tick.sh`.** Sleeps first, then each cycle: `control-status` (when
  another session is registered, prints `desk-tick G replaced` and exits, so
  two desks never split the change feed), then `tick --session`, which
  repeats that check inside the tick's own transaction so a registration
  landing between the two calls cannot let the replaced loop consume the
  feed (a refusal confirmed by `control-status` prints `replaced` too),
  printing `desk-tick G new D-43 D-44` only for open Decisions. A failing call prints
  one `error` line per outage and one `recovered` line; a quiet tick prints
  nothing. `HUMAN_QUEUE_TICK_SECONDS` (1 to 3600, and under the live-desk
  bound like the cadence) overrides the cadence (tests); 0 is refused.
- **Sets and replies.** Simple Decisions (2 to 4 options, a cost not in
  hours or days) are numbered with `set-open` four at a time and shown as one
  menu per set, each question prefixed `N. [D-<n>]`. Clicks and typed replies
  both go through `set-resolve --set ID --json`.
- **Wake-ups.** For each changed answer, `wake-target.sh SESSION` reads the
  harness's session registry (`~/.claude/sessions/<pid>.json`, never the
  `.key` files beside it) for a running session with that id and prints its
  `local_…` id, or its name for a terminal session; exit 3 when none is
  running, exit 5 when it is running but has no messaging address, exit 1
  when it cannot tell (the registry cannot be listed, or no readable file
  matches while some file could not be read or parsed). The
  desk sends exactly `human-queue: D-<n> answered` with
  `SendMessage` (or the app's `send_message`) and records the outcome with
  `wake`. The thread reads the answer from `pending-for`; a thread that is
  gone loses nothing: the desk retries, then parks the answer (#1781).

## Long-form, multipart, and discuss (issue #1780)

The desk's second increment (`skill/longform.md`, `skill/discuss.md`). The
deterministic parts live in one jq library, `skill/desk.jq`, which both
`decisions.md` and `longform.md` call (`jq -L "$DESK/skill" 'include
"desk"; …'`), so the menus and the long-form view share one classification.

- **Long-form.** A Decision a menu cannot hold: no options, one option, more
  than four, or a declared cost in hours, days, or weeks (`2h`, `1h30`,
  `half a day`). It is shown alone, as a quoted text card (never a menu), and
  the operator's next message is its answer, stored word for word (outer
  whitespace trimmed and a lone option letter stored as that option, as for
  every answer).
- **Multipart.** The store has no parts field: a multi-question ask is
  already one Decision per question. A multipart Decision is the open
  long-form Decisions that share a repo, a key, and a return address (one
  thread asking several things about one PR or issue), in list order. The
  desk opens one set per group, so part *k* is number *k*, and shows the
  parts one at a time; each keeps its own id, answer, and wake-up.
- **`answer --stdin` and `--json`.** `answer ID --stdin` reads the answer
  from standard input instead of the command line, so quotes, `$(...)`,
  backticks, and lines such as `2: B` arrive as written (at most 16000 bytes
  are read; a NUL byte is refused as a control character; the 4000-character
  limit and the trim of leading and trailing whitespace are unchanged).
  `--json` prints `{"id", "answer", "changed", "session"}`, the fields the
  desk's wake rule reads. Both are flags wherever they appear, so an answer
  that is exactly `--json` or `--stdin` goes through `--stdin`.
- **`discuss <n|D-id>`.** Loads one item with `get` and prints a card: the
  question, context, options with the default, impact and cost, where the
  answer goes, and a link to its PR or issue derived from `repo` and `key`
  (`pr-N`, `issue-N`, `branch:NAME`; none for `local/` repos or shortened
  keys). Follow-ups are answered from the card and read-only reads of the
  link; discussion writes nothing to the store, then presents the item again
  for an answer.
- **Tests.** `tests/longform-offline.test.sh` runs `desk.jq` on fixtures and
  checks `answer --stdin/--json` validation offline;
  `tests/longform.test.sh` (live, throwaway schema) stores a reply full of
  shell metacharacters through the skill's own here-document and compares it
  byte for byte.

## Wake-up retries, `answer-parked`, `show`, and `history` (issue #1781)

The desk's last part-1 increment (`skill/wakeups.md`, `skill/history.md`,
migration `006_answer_parked.sql`). A dead thread loses nothing: its answer
is retried, then parked for the next thread on that PR or issue.

- **Retries.** A failed wake-up is retried on the next tick, up to three
  times after the first attempt. The count is the `wake-failed` events since
  the item's latest `answered` event, so there is no counter column and a new
  answer starts afresh. Each cycle `desk-tick.sh` runs `wake-due --json`
  after `tick` and prints `desk-tick G retry D-43 D-44`. The desk reads
  `wake-due --json --min-age 30` again, so two queued events cannot retry one
  answer twice, then wakes each answer as it does after an answer and
  records the result with `wake --json`. `wake-due` sees only recorded
  wake-ups, so a `wake` the store did not take (exit 7 or 1) is run again
  until it is, never dropped. A failing `wake-due` is one `error`
  line per outage, and the tick's `new` line is still printed, because that
  tick already moved the watermark.
- **`answer-parked`.** The failure that uses up the third retry sets the
  status `answer-parked` and records one `answer-parked` event (note `4
  wake-ups failed`) in the same transaction, under the item's row lock. An
  item with no return address parks on its first failure (`no return
  address`), because there is nothing to retry. Only an `answered` item is
  parked, so exactly one `wake` call returns `"parked": true`, and the desk
  shows the parked answer once, from that result. The answer waits for the
  next thread on that work: `pending-for --repo O/N --key KEY` lists it,
  `pending-for SESSION` still lists it for its own thread, and `ack` accepts
  it. Re-sending the answer it holds is a no-op; a different answer returns
  it to `answered`, and the count starts again. Before 006 the store refuses
  the status, so `wake` names `migrate` and records nothing (the desk runs
  `migrate` at start).
- **`show D-<n>`** is `show`: the item, then every event oldest first with
  its note (asked, shown, answered, woken or wake-failed, answer-parked,
  acknowledged). That is its whole sub-thread, because the store keeps no
  transcripts.
- **`history`** lists the Decisions with an `answered` event on one
  America/New_York calendar day (default today on the database's clock),
  once each at their latest answer that day, in answer order, whatever their
  status now. `--date YYYY-MM-DD` picks another day.
- **No state line.** The skill prints `show`'s and `history`'s output and
  nothing else (DESIGN 4.1.4).
- **Tests.** `tests/wakeups.test.sh` (live, throwaway schema; no wake-up is
  sent, because the sessions are ids nobody has, resolved against a fixture
  registry) covers test 5.1 through `desk-tick.sh --once` and the skill's
  blocks: the answer is stored, the first failure and three retries are
  recorded, and the item reaches `answer-parked` on tick 3, shown once. It
  covers test 5.2 (two answers today, an answer at 23:30 ET yesterday left
  out, `--date`), `show`, `pending-for --repo --key`, `ack`, the
  no-return-address and new-answer cases, and a store without 006.
  `tests/desk-offline.test.sh` covers the `retry` line and the new
  validations against a stub CLI.

## Priorities: the operator's backlog order for `/pm` (issue #1767)

The desk's Priorities surface (`skill/priorities.md`; DESIGN 2.1). The
operator types `top: #a #b`, `bump #N`, `park #N until <date>`, `drop #N`, or
`priorities`, each optionally ending `in <repo>`, and `/pm` honors the order
at its next ranking or refill: ordered issues first, parked issues skipped
until their date, everything else in its own OKR-aware ranking.

- **Not in the store.** The order is a file in the target repo,
  `.claude/pm-priority.json` at its main checkout, next to `pm-config.md`
  (DESIGN 7.6: per repo). Both its writer and its reader are
  `.claude/scripts/pm-priority.sh`, which `/pm` already resolves with its other
  helpers, so `/pm` honors the file even where no desk runs. Nothing here
  touches the database.
- **Overlay, not a re-score.** `/pm` scores and excludes as it always did,
  then pipes the eligible list through `pm-priority.sh apply`. Dropping an
  issue therefore restores its ranked place, and an absent file changes
  nothing. An unreadable file stops `/pm`'s autonomous launches until it reads
  again, because it may be hiding a park.
- **Tests.** `.claude/scripts/tests/pm-priority.test.sh` covers the helper
  (tests 5.1 and 5.2, AC 4.3, a corrupt file, worktrees, concurrent writers,
  `--repo`) and `/pm`'s own blocks. `tests/priorities-offline.test.sh` covers
  this skill: the routing lines and the anchored block run against the real
  helper.

## Reviews (issue #1756)

Reviews are pulled from GitHub, so no thread has to cooperate: a PR merged
from any tool, and any issue filed through `/issue-maker` or the desk, becomes
one `R-n` to look at. Summaries are lazy and layered, written by the desk only
when the operator asks, never at wrap time.

| Piece | What it does |
|-------|--------------|
| `sync-reviews [--since TIME] [--json]` | Adds one Review per PR you authored that merged in the window (`gh search prs --author @me --merged`) and per issue you filed in it whose body has the line `_Captured via /issue-maker._`, in any repository. Prints one line per new Review and a tally |
| `bin/pr-summary-material.sh OWNER/REPO N --level 1\|2\|3 [--path FILE]` | Read-only: prints the raw material for one PR or issue at a depth (below). `N` may be the item's key, `pr-N` or `issue-N` |
| `summary get ID [--level 1\|2]` / `summary set ID [--level 1\|2] [--file PATH]` | Reads, or caches once, a Review's level-2 summary (`items.summary_l2`, the default) or, with `--level 1`, its one line (`items.summary_l1`, migration 007, issue #1782) |
| `review ID [--comment TEXT]` | As above, and the comment rides on the `reviewed` event (a comment on an already-reviewed item is a `commented` event) |
| `review --synced-today [--comment TEXT]` | Every Review synced today (America/New_York) that is still unreviewed, in one transaction; prints the ids it marked (issue #1782) |
| `flag ID "TEXT"` | As above; the note may follow the id (the form the desk writes) or come with `--note`, once |
| `list --kind reviews --unreviewed [--json]` | The Reviews still `open` (a flagged one was read), then `N unreviewed · ~M lines at level 2` (20 lines an item); `--json` prints `{count, level2_lines, today, items}`, the items without `summary_l2` (read a cached summary with `summary get`) and with `synced_on` (issue #1782). `--kind` also takes `decisions` and `reviews` |

### Sync

- **The window.** `--since` takes a date (00:00 UTC) or an ISO 8601 time with
  a zone. Without it the window starts one hour before the stored watermark,
  which covers GitHub's search-index lag. The first sync has no watermark and
  exits 4 asking for `--since`: where Reviews begin is the operator's call,
  never a silent backfill. The watermark is the reserved state key
  `reviews_watermark` (readable with `state get`, refused by `state set`); it
  moves to the sync's start time only after every row is written, and never
  backwards.
- **Once each.** A Review is keyed on its repository (case-insensitive) plus
  `pr-N` or `issue-N`. A PR or issue that already has a Review, in any status,
  is never added again, so overlapping windows, repeated syncs, and two syncs
  at once are safe (an advisory lock serializes them). Rows are written 50 to
  a transaction; a failure leaves earlier batches written, and re-running is
  safe.
- **Bounded.** Each search asks for at most 1000 results (GitHub's cap,
  `HUMAN_QUEUE_SYNC_LIMIT` lowers it); a search that returns its limit may
  have been cut short, so the sync stops, writes nothing, and keeps the
  watermark. Each GitHub call has a deadline (`HUMAN_QUEUE_GH_TIMEOUT`,
  default 60 s). The database is checked first, so exit 7 still comes within
  two seconds and before any GitHub call. GitHub failures exit 1.
- **What is stored.** The title as the question (control characters replaced,
  at most 500 characters; a credential-shaped title becomes `PR #N (title
  withheld: it looks like a credential)`), the link and the merge or filing
  time as the two context lines, and one `asked` event noted `synced from
  GitHub`. Never a body, a diff, or a transcript: an issue's body is read only
  to find the footer. A row GitHub returns malformed is skipped and counted.

### Summary levels

| Level | A PR | An issue | Stored |
|-------|------|----------|--------|
| 1, one line | title, labels, the closing issue's title | title, labels, a body excerpt | once, as `summary_l1` (007, #1782) |
| 2, about twenty lines | level 1 plus size, body, commit subjects, files with line counts, tests touched, links | title, labels, body, link | once, as `summary_l2` |
| 3, on demand | the diff, or one file's section with `--path`, capped by lines and bytes | the full body | never |

The desk's loop for level 2: `summary get R-n`; when it exits 4 (none
cached), run `pr-summary-material.sh OWNER/REPO pr-N --level 2`, write the
summary in the operator's shape, and `summary set R-n` it. The shape is
checked: line 1 one bold statement (`**...**`), then numbered points for what
changed functionally, the judgment calls, what was deferred, the tests, and the
links (indented continuation lines and blank lines allowed), at most 40 lines
and 4000 characters, secret-checked. A different second summary is refused, so
a cached summary is never regenerated; the same text again is a no-op.
Migration `004_reviews_summary.sql` keeps `tick` from reporting an item whose
only change is its cached summary (an annotation the desk writes itself, like
`comment`); before 004 is applied the item is reported once more, nothing
else differs. After a `flag`, the desk offers to open a follow-up issue seeded
with the item's title, link, and the flag's note (the Reviews view, #1758).

`pr-summary-material.sh` exits 0 ok, 1 when GitHub fails (including a diff
GitHub will not render), 3 when the number, the `pr-`/`issue-` kind, or the
`--path` file does not exist, and 4 on usage. Its caps are
`HQ_MATERIAL_EXCERPT_CHARS` (600), `HQ_MATERIAL_BODY_CHARS` (6000),
`HQ_MATERIAL_DIFF_LINES` (2000), and `HQ_MATERIAL_DIFF_BYTES` (200000); a
section a cap cuts ends with a `[truncated: ...]` line, and a list GitHub
returned only in part (labels, closing issues, commits, files) says how many
it left out. GitHub's text is untrusted, so a CRLF prints as LF and every
other control character but tab and newline prints as `?`.

### GitHub access and tests

Every GitHub read goes through `gh`, found by `bin/lib/github.sh`:
`HUMAN_QUEUE_GH` when set, else `/opt/homebrew/bin/gh`, else `gh` on `PATH`.
`jq` is required. The tests point `HUMAN_QUEUE_GH` at `tests/lib/gh-stub.sh`,
which serves `tests/fixtures/github/` (and the search results a suite writes),
so they run offline.

- `reviews-cli.test.sh` is offline: every new validation exits 4 or 5 without
  connecting, and `pr-summary-material.sh` prints the expected sections at
  each level from the fixtures (`--path` narrowing, caps, issues, not found,
  GitHub failures, the deadline). Both shells.
- `reviews.test.sh` is live (throwaway schemas, like the suites above): three
  merged PRs and two captured issues make five Reviews and a second sync none;
  the watermark, the limit and failure paths, 120 rows across batches, two
  concurrent syncs, `flag`, `review --comment`, `summary`, `list
  --unreviewed`, and `tick` with 004. It ends with a smoke run of
  `sync-reviews` and `pr-summary-material.sh` against the real GitHub API
  (skipped when `gh` is not authenticated).

The first live `sync-reviews` against the queue's own schema, and `migrate`
for 004, are run once by hand after this merges.

## The Reviews view (issue #1782)

The first of `/desk`'s attention increments (`skill/reviews.md`, migration
`007_reviews_summary_l1.sql`). Interrupts, policy, and feedback tags are the
second (issue #1783, "Interrupts, policy, and feedback tags" below), the day
plan and end-of-day sweep the third (issue #1784), and the numbered PR
outline is issue #1768.

| The operator types | The desk runs |
|--------------------|---------------|
| `reviews` | `sync-reviews`; `pr-summary-material.sh --level 1` and `summary set --level 1` for each unreviewed item with no line yet; `list --kind reviews --unreviewed --json` through `desk.jq`'s `reviews_view` |
| `open R-<n>` | `get --json`: the cached `summary_l2` when there is one (no GitHub call), else `--level 2` material, then `summary set` |
| `diff R-<n> [path]` | `pr-summary-material.sh --level 3 [--path FILE]`; nothing is stored |
| `reviewed R-<n>` / `reviewed all today` | `review R-<n>` / `review --synced-today` |
| `flag R-<n> "…"` | `flag R-<n> --note …`, the note through a quoted here-document |
| `follow up R-<n>` (`… again` after an interrupted filing) | `comment R-<n> "follow-up: filing"`, then `gh issue create --repo <the item's repo>` (seven sections, the capture footer), then `comment R-<n> "follow-up: <url>"`; a `filing` mark with no URL after it stops the next `follow up` until `again` |

- **Level 1 is cached.** One line, at most 200 characters, written by the
  desk the first time the item is listed and stored with `summary set ID
  --level 1`; write-once like level 2. Migration 007 adds the column and
  extends 004's rule, so caching either summary is not a change `tick`
  reports. Before 007, level-1 calls exit 1 naming `migrate` and the view
  prints titles.
- **The view.** One line per unreviewed item, `R-12 · PR #1787 · <line>`,
  grouped `Today · <repo> (n)`, `Yesterday · …`, or `Mon Oct 5 · …`: the day
  the item was synced (its `created_at`, America/New_York), newest first,
  then repositories by name (the owner shown only when two share a name),
  oldest item first. An item still without its line shows its title, marked
  `(title; not summarized yet)`.
- **`reviewed all today`** marks only Reviews synced today that are still
  `open`: a flagged one keeps its flag (its follow-up is open), and
  reviewing an item twice records nothing.
- **Tests.** `tests/reviews-view-offline.test.sh` checks the new validation
  (exit 4 or 5 before connecting), `reviews_view` and `review_header` on
  `tests/fixtures/reviews/unreviewed.json`, and the skill's anchors.
  `tests/reviews-view.test.sh` (live, throwaway schema, the `gh` stub)
  runs the skill's own blocks: test 5.1 (the first `open R-2` calls GitHub,
  the cache block stores level 2, a second `open` makes no GitHub call), test
  5.2 (`reviewed all today` marks R-1 and R-2 only), the grouped view, a
  `diff` that stores nothing, a flag note full of shell metacharacters stored
  byte for byte, the follow-up issue, and a store without 007.

`migrate` for 007 runs at the next `/desk` start (its step 3), or by hand.

## Ideas (issue #1766)

At the desk, `idea: <text>` (or `file: <text>`) files a GitHub issue without
leaving the desk and without switching it into capture mode
(`skill/ideas.md`). The filing is `/issue-maker`'s **one-shot entry**: the
same reflection, duplicate search, labels, seven-section body, and footer,
written up in `.claude/skills/issue-maker/references/one-shot-filing.md` and
created by the same script both use, `.claude/scripts/issue-file.sh`, which
refuses a body missing a section or the footer, drops labels the repo lacks
or that would hide the issue from `/pm`, and never assigns. The desk prints
the issue URL as its closing line.

- **Which repository.** `bin/idea-target.sh` reads the message on stdin: a
  first word that is `owner/name` or a GitHub link to a repository you can
  file issues in (checked with `gh repo view`), else this desk session's
  default (the state key `idea_repo:<session>`, checked again the same way
  each time, since access can change), else exit 3, and the desk
  asks once, in plain text, for `repo: owner/name`, suggesting the
  repository it runs in. `repo:` saves the default (and can change it any
  time). A path such as `desk/skill` stays in the idea's text.
- **Back as a Review.** The footer is what `sync-reviews` finds captured
  issues by, so the issue comes back as a Review like any other. Right after
  filing, the desk runs `filed OWNER/NAME N`:

  | Subcommand | What it does |
  |------------|--------------|
  | `filed OWNER/NAME NUMBER [--json]` | Records that the desk filed the issue. When its Review exists, one `commented` event, note `filed from the desk`, goes on it now (`noted R-12`); otherwise a pending filing waits as the reserved state key `filed:<owner/name>:issue-<N>` (lowercased; `pending`). Again is a no-op: a Review never gets a second note |

  `sync-reviews` consumes the pending filings whose Review exists, after its
  inserts and in the watermark's transaction: the event goes on, the key is
  deleted, and the tally adds `; N desk filing(s) noted on their Reviews`
  (`desk_filings_noted` in `--json`). `state set` refuses `filed:` keys. No
  migration: `state`, `events`, and the `commented` kind exist since 001.
- **Picked up by `/pm`.** An open, unassigned issue without an excluded label
  is what `/pm` ranks; its Step 1B.2 block `pm-1b2-new-issues` names every
  such issue created since the repo's last backlog scan (`NEW_ISSUES`), adds
  it to the shortlist, and shows it with its tier, on a cold start and on a
  backlog refill.
- **Stored.** Never the idea's text: only the session's default repository
  and the pending filing, both state rows, plus the Review's one event.
- **Tests.** `tests/ideas-offline.test.sh` (offline: `idea-target.sh`'s
  precedence and refusals against a `gh` stub and a store stub, the skill's
  `desk-idea-target` and `desk-idea-file` blocks run as written, `filed`
  and `state set filed:…` validation, the router); `tests/ideas.test.sh`
  (live, throwaway schema: pending, consumed by `sync-reviews` into one
  event, noted at once when the Review already exists, never twice).
  `issue-file.sh` and the `/pm` block have their own suites under
  `.claude/scripts/tests/` (`issue-file.test.sh`,
  `pm-backlog-new-issue.test.sh`).

## Prose-question nudge (issue #1778)

The capture hook only sees questions asked through `AskUserQuestion`. A
question written as prose would wait in a transcript nobody reads, so a
second hook, `hooks/question-leak-warn.sh` (registered on `Stop` as
`.claude/hooks/question-leak-warn.sh`), warns once per turn when the final
assistant message ends a line with `?` outside code fences and prints no
receipt line (`question D-<n> sent to human queue`) after it. The warning
names the fix from `.claude/rules/human-queue.md`. It never blocks, needs no
database, and fails open. Detection rules and output: `hooks/README.md`, "The
prose-question nudge". Tests: `tests/question-leak-warn.test.sh` (offline).

## Interrupts, policy, and feedback tags (issue #1783)

The second of `/desk`'s attention increments (`skill/interrupts.md`, migration
`008_event_session.sql`). The desk is **loud by default**: every new Decision
is shown at the next tick, in sets. The operator tunes it down item by item
with feedback tags, and holds it while away or focused. Agents ask exactly as
often as before and decide nothing new on their own; a held question waits in
the store, never in a worker thread.

- **`policy.json`.** `tick_cadence_min` 5 (1 to 60, below the live bound),
  `interrupt_rule` `everything` (or `away`), `eod_time` `17:30` (`HH:MM`,
  America/New_York; the end-of-day sweep is issue #1784), `set_size` 4 (1 to
  4), `live_desk_max_tick_age_min` 15 (1 to 1440). One parser, `capture.py`'s
  `load_policy()`, serves the capture hook, `desk-tick.sh`, and
  `bin/desk-policy.sh` (which prints the effective policy as JSON). A missing
  file is the defaults; an unreadable file, a non-object, or any invalid value
  is the defaults for every key, with one warning; unknown keys are ignored.
  `HUMAN_QUEUE_POLICY` names another file (tests).
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
  hold (`available` runs one at once; a focus ends on its own) reports
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
