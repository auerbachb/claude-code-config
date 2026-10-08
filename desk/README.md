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
| `bin/lib/report.sh`, `bin/lib/report.jq` | The weekly attention report's thread-model lookup and its one-page rendering (see "Weekly attention report") |
| `bin/lib/todo.sh` | The operator's to-do layer: tag and snooze-time parsing, and the one locked write `tag`, `untag`, `note`, `snooze`, `unsnooze`, and `mine` share (see "The to-do layer") |
| `bin/lib/budget.sh` | The reading budget's measurements from `events`, shared by `stats`, `checkin`, and `plan forecast` (see "Morning check-in and reading budget") |
| `bin/lib/impact.jq` | The derived-impact rule behind `impact` (see "Derived impact") |
| `bin/lib/export.sh`, `bin/lib/export.jq` | The paper copy's PDF renderers and its Markdown, text, and HTML rendering (see "Export to paper") |
| `schema/NNN_<name>.sql` | Migrations, applied by `human-queue.sh migrate` |
| `hooks/` | Hook implementations: `capture.sh` and its logic `capture.py`, the capture hook (see "Capture hook") |
| `policy.json` | The desk's defaults: tick cadence, interrupt rule, end of day, set size, live-desk bound (see "Interrupts, policy, and feedback tags"), and the critical-path thresholds (see "Derived impact") |
| `skill/` | The `/desk` skill: `SKILL.md` (router) and one file per kind of work (see "The desk") |
| `tests/` | `run.sh` plus `*.test.sh` suites |

The hook entries under `.claude/hooks/` are symlinks into this folder
(`human-queue-capture.sh` → `hooks/capture.sh`), and so is `.claude/skills/desk`
(→ `../../desk/skill`), so the repo's skill-symlink rule keeps holding.

## Provisioning the database (once)

The store is one Postgres database on Neon, shared by every machine. The
project `human-queue` (region `aws-us-east-1`) already exists; these steps are
for a fresh setup or a new machine.

1. **A fresh setup only** (a new machine joining the existing project skips
   to step 2): create the project once, from any machine with
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
| `HUMAN_QUEUE_EXPORT_RENDERER` | `export`'s PDF renderer: `auto` (default: pandoc, then headless Chrome, then cupsfilter), one of those three, or `markdown` (none) |
| `HUMAN_QUEUE_PANDOC`, `HUMAN_QUEUE_CHROME`, `HUMAN_QUEUE_CUPSFILTER` | That renderer's binary; set to anything that is not an executable file, it counts as not installed (tests) |
| `HUMAN_QUEUE_EXPORT_TIMEOUT` | Seconds each `export` renderer may run, 1 to 86400 (defaults: pandoc 120, Chrome 60, cupsfilter 30; any other value keeps them) |

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | ok |
| `1` | unexpected failure, such as a migration's SQL error (its transaction is rolled back) |
| `4` | validation or usage error: unknown subcommand, stray argument, invalid `HUMAN_QUEUE_SCHEMA`, invalid input, an item id that does not exist, or a write the item's state refuses (for example `ack` of an item with no answer) |
| `5` | secret refused: free text that looks like a credential is never stored (`add`, `bump --note`, `answer`, `flag --note`, `comment`, `note`, `set-resolve`, `state set`, `register-control`), nor sent to `psql` as a lookup value (`state get`'s key, `pending-for`'s session, repo, and key) |
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
| `state get KEY` / `state set KEY VALUE` | One key of operator state (the desk's bookkeeping; the day plan has `plan`). `get` prints the value exactly; a key that is not set exits 4. A value is at most 65536 characters and 131000 bytes (it travels as one `psql` argument, and Linux caps one at 128 KiB) |
| `register-control SESSION [--json]` | Registers the desk's one control session (the last registration wins) and names the one it replaced; a different session also clears `tick_at` |
| `tick [--session SESSION [--interrupts RULE]]` | Prints, as one JSON array in the `list --json` shape, the items new or changed since the last tick. With `--session`, only as the registered control session: checked inside the tick's transaction under `register-control`'s lock; any other session exits 4 with nothing read, the watermark unmoved, and no `tick_at` stamped. With `--interrupts`, honors the desk's interrupt rule: while it holds items back, prints `[]`, stamps `tick_at`, and leaves the watermark (see "Interrupts, policy, and feedback tags") |
| `control-status [--json]` | Read-only: the registered control session, when the last tick ran, and how many seconds ago on the database's clock (`{"session", "last_tick_at", "tick_age_seconds"}`, each null when unset). The capture hook's live-desk check |

- **Reserved keys.** `tick_watermark` and `tick_at` (written by `tick`) and
  `control_session` (written by `register-control`) are readable with
  `state get`; `state set` refuses them, and every `filed:` key (written by
  `filed`, see "Ideas"), `interrupt`, `plan`, and `eod_sweep` (see "Day plan
  and end-of-day sweep"). State is not an item, so it records
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
plan and end-of-day sweep the third (issue #1784, "Day plan and end-of-day
sweep" below), and the numbered PR
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

## Weekly attention report (issue #1771)

One page a week on what the queue costs the operator, computed when it runs
from the events table alone: no migration, and no new logging (the store
keeps state changes only). It exists to tune the interrupt policy and the
agents' defaults, not to be read daily.

- **The command.** `report [--week YYYY-MM-DD] [--json]`, read-only. A week
  runs Monday to Sunday on the America/New_York calendar; the default is
  this week on the store's clock. A week still running, its Sunday
  included, is titled `(to date)`, and one not started yet
  `(not started)`. It prints a bold title, the five measures
  as a numbered list, and one small Markdown table; `--json` gives the same
  measures as one object (`report --help` has its shape).
- **The measures.** A desk event is `shown` or one of the operator's actions
  (`answered`, `reviewed`, `flagged`, `feedback`, `commented`).
  1. *Minutes spent answering*: desk events split into sittings at any gap
     over 10 minutes; a sitting with an operator action counts first to
     last event plus 1 minute, one of `shown` alone nothing.
  2. *Items per day*: items answered, reviewed, or flagged each day (once a
     day), averaged over desk days, then listed day by day.
  3. *Median age of an open Decision*: over Decisions open at some time in
     the week, asked to first answer, or to the week's end (or now) for one
     still open then; none for a week not started yet.
  4. *Interrupts tagged not important*, beside the Decisions shown.
  5. *Questions tagged should have defaulted*, by thread and model: the
     table counts each tagged thread's three tags and the Decisions it asked
     that week. The thread is the feedback event's `session_id` (migration
     008); the model is read when the report runs from that thread's Claude
     Code transcript on this machine (`HUMAN_QUEUE_TRANSCRIPTS_DIR`, default
     `~/.claude/projects`; the latest reply outside a sidechain), never
     stored, and `unknown` for a thread that ran elsewhere. An `asked`
     event names no session, so a Decision counts as asked by its return
     address when the report runs (a bump from another thread moves it).
- **The desk.** `report` (`report <YYYY-MM-DD>`) prints it as is
  (`skill/attention.md`), with no state line. After the `eod` event's sweep
  on a Friday, one line offers it (`skill/sweep.md`, "Friday"): the event
  comes once a day and a typed `sweep` never offers, so the offer comes once
  a week.
- **Tests.** `tests/report-offline.test.sh` (offline: validation before
  connecting, the rendering on `tests/fixtures/report/week.json`, the model
  lookup on fixture transcripts, and the skill's blocks under bash,
  `/bin/bash` 3.2, and zsh); `tests/report.test.sh` (live, throwaway schema:
  test 5.1, a fixture week of events whose every measure matches its
  hand-computed value, the week's edges, an empty week, the default week,
  nothing recorded, and a store before 008 exiting 1 naming `migrate`).

## The to-do layer (issue #1769)

The operator's own organizing on top of the queue (`skill/todo.md`, migration
`010_todo_layer.sql`): tags, a note, a personal priority, and a snooze on any
item, and `my list`, which shows the items by that priority with their
notes. Deliberately small: a layer on items, not a second task system. Four
item fields, one event per change, no new table, no state key.

| Subcommand | What it does | Event |
|------------|--------------|-------|
| `tag ID WORD... [--json]` / `untag ID WORD... [--json]` | Adds or removes the operator's tags: lowercase words joined by hyphens, each at most 32 characters with a letter (`#PRD` is `prd`), at most 10 an item, kept in the order added | `tagged` / `untagged` (note: the tags changed) |
| `note ID TEXT [--json]` / `note ID [--json] -- TEXT` / `note ID --clear [--json]` | Sets (replacing) or clears the operator's note: one line, at most 1000 characters, secret-checked (exit 5). After `--` the note is taken word for word, even one that reads as an option | `noted` (note: `set` or `cleared`; the text stays on the item) |
| `snooze ID until WHEN [--json]` / `snooze ID for DURATION [--json]` / `unsnooze ID [--json]` | Hides the item from `my list` until a time, or ends that. WHEN: `tomorrow`, a weekday, `YYYY-MM-DD` (00:00 America/New_York), a clock time (its next occurrence, `interrupt`'s grammar), a day and a time (`friday 9am`), or ISO 8601; DURATION: `30m`, `2h`, `3 days`, `1w`. On the store's clock; in the future and at most 366 days ahead | `snoozed` (note: `until <UTC>`) / `unsnoozed` |
| `mine ID PRIORITY [--json]` / `mine ID --clear [--json]` | The operator's personal priority, 1 (highest) to 5 | `prioritized` (note: the priority or `cleared`) |
| `my list [--tag WORD] [--all] [--snoozed] [--json]` | Read-only: the items with a priority or a note (with `--tag`, carrying that tag) still waiting on the operator (`open`, or a `flagged` Review; `--all` for every status), priority first (unset last), then oldest first, each note under its item. Snoozed items are left out and counted, with the next return time, until their time comes; `--snoozed` lists them too | none |

- **The fields.** `items.my_tags` (`text[]`, default empty), `my_note`,
  `my_priority`, `snoozed_until`, in every item's JSON (`get --json`, `list
  --json`, `tick`, `sweep list --json`). The `my_` prefix keeps them apart
  from the interrupt-tuning feedback tags (`feedback` events, which tune when
  the desk interrupts) and from the events' `note`. `get`, `show`, and
  `list` print them on two lines after the facts line (`My priority: 2 ·
  Tags: prd · Snoozed until … UTC`, then `My note: …`), only when set, read
  through the row's JSON so the renderer works before 010.
- **No-ops and events.** Each write locks the item's row and records exactly
  one event when the field changes; writing the value it already has (a tag
  it carries, the same note, the same priority, `unsnooze` of an unsnoozed
  item) is a no-op, exit 0, no event. `--json` prints the item's to-do
  fields after the call with `changed`.
- **The queue is unchanged.** A to-do write is not a change `tick` reports:
  010 replaces `items_mark_change()` so that an update changing only
  annotation columns (007's cached summaries and these four fields) keeps
  the row's change marker. A snooze hides an item from `my list` only: a
  snoozed Decision still reaches the desk at the next tick, the sweep still
  lists it, and its thread still waits on it. Holding questions is the
  interrupt rule's job.
- **Not `/pm`'s priorities.** `mine` orders the operator's list of desk
  items (`D-`/`R-` ids). `/pm`'s backlog order for GitHub issues is
  `pm-priority.sh` (`top`, `bump`, `park`, `drop`; "Priorities" above).
  Neither reads the other.
- **On paper.** The end-of-day sweep's card prints each item's priority,
  tags, and note on a nested line under it (`desk.jq`'s `todo_line`); the
  paper copy, `export` (issue #1759, "Export to paper" below), prints the
  same line in the item's section.
- **The event kinds.** 010 adds `tagged`, `untagged`, `noted`, `snoozed`,
  `unsnoozed`, and `prioritized` to whatever `events_kind_check` allows when
  it runs (read from the constraint's own definition), so a migration from a
  parallel branch that extended the list first keeps its kinds. Before 010
  every to-do command exits 1 naming `migrate`.
- **Tests.** `tests/todo-offline.test.sh` (offline, bash and `/bin/bash`
  3.2: every validation exits 4 or 5 before connecting, `--help` for each
  command, `todo_line` and `sweep_lines` on a fixture, the skill's anchors
  and router row); `tests/todo.test.sh` (live, throwaway schema: test 5.1
  through the skill's blocks — tag, note, snooze, and prioritize one item,
  `my list` shows it in order, and after the snooze time it reappears —
  plus untag, no-ops that record nothing, `--tag`/`--all`/`--snoozed`, the
  snooze grammar on the store's clock, refusals, `tick` not re-reporting a
  to-do write while a bump still is, the renderer, the sweep's paper line,
  the additive event-kind constraint, and 010 over a 008 store).

`migrate` for 010 runs at the next `/desk` start (its step 3), or by hand.

## PR drill-down (issue #1768)

Below the Reviews view's level 3 (one diff, pasted whole): a PR made
addressable by number, so the operator can open one hunk and ask about it
(`skill/drilldown.md`). No migration, and nothing is stored: every call
rebuilds the outline from GitHub.

| The operator types | The desk runs |
|--------------------|---------------|
| `outline R-<n>` | `get R-<n> --json`, then `bin/pr-outline.sh OWNER/REPO pr-N` |
| `open R-<n> <node>…` | the same, with the nodes (`2`, `2.3`, `T1`, `T1.2`) after the key; `open R-<n>` alone stays level 2 |
| `ask R-<n>: <question>` | the outline, then one `open` of the nodes the question needs (every node's head checked against the outline's; a push in between means outline and open again); the answer ends `Read: 2.3, T1.1 · head <sha>` |

- **`bin/pr-outline.sh OWNER/REPO N [NODE...]`** is read-only. Without
  nodes it prints the outline: the files that are not tests numbered `1, 2,
  …` in GitHub's order (status, `+added -deleted`), their hunks `2.1, 2.2,
  …` (new-side line range, counts, heading), the tests touching each file as
  leaves, then `Tests` (`T1, T2, …`, the files each touches, its hunks). A
  test is a changed file the Reviews view counts as one; it touches a file
  when their stems match or its patch names the file's basename. With nodes
  it opens them in order: a file is its whole patch with a `[2.k]` line
  before each hunk; a hunk is widened from the file at head to
  `HQ_OUTLINE_CONTEXT` (20) lines on each side, as one hunk with a
  recomputed `@@` line, stopping at a neighbouring hunk or the file's edge
  and saying so. Each node starts with `=== ID · PATH · … · head SHA`.
- **GitHub calls.** `repos/O/R/pulls/N`, then `repos/O/R/pulls/N/files`
  (paginated), then `pulls/N` again: the file list has no SHA of its own, so
  a push in between lists the files again under the new head (up to three
  listings; a PR still moving exits 1, never pairing one head with another
  head's diff). Then, for opened hunks of changed files only, the file's blob
  at head (`git/blobs/<sha>`, raw), once per file per call. Each goes through
  `bin/lib/github.sh`, so `HUMAN_QUEUE_GH` and `HUMAN_QUEUE_GH_TIMEOUT` apply.
- **What it will not guess.** A file GitHub sent no patch for shows no hunks
  and says why; a patch whose hunks do not add up to their headers or to the
  file's counts is marked `patch incomplete`; a file at head that does not
  match the patch, or a fetch that fails, prints the hunk as GitHub gave it
  with one `(more context unavailable: …)` line; a partial file list says how
  many files it holds. GitHub's text prints with control characters as `?`,
  and a newline inside a path as `?`, so a path never starts a line.
- **Exit codes.** 0 ok; 1 GitHub failed (or a deadline, or a PR pushed to
  during each of three listings); 3 no such PR, an
  `issue-N` key (no GitHub call), or a node the outline lacks (its line names
  the ids it has; nothing on stdout); 4 usage (a node that is not `F`, `F.H`,
  `Tn`, or `Tn.H`, a context cap outside 1 to 500).
- **Tests.** `tests/drilldown-offline.test.sh` (offline, `tests/lib/gh-stub.sh`
  serving `tests/fixtures/drilldown/`): test 5.1's outline of a PR with three
  source files and two test files; test 5.2's `open 2.3` (eight lines above,
  stopped at hunk 2.2; twenty below), `open 2.1`/`2.4` at the file's edges,
  `open 2` with its markers; one fetch per file; the edge cases above;
  a push between the reads (listed again, the new head cited) and a PR that
  keeps moving (exit 1); a newline in a path; a CRLF file at head, with an
  LF or a CRLF patch, widened like any other;
  not found, unknown nodes, failures, the deadline; no temp file left; the
  skill's blocks under bash and zsh against a stub CLI. Under bash and
  `/bin/bash` 3.2. What `ask` answers is checked by a live run.

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
  `desk_batch` keep the list's order), the day plan's clear-first batch, and
  the end-of-day sweep, all through `items.sh`'s `hq_sql_impact_rank`:
  parked first, then critical-path, high, medium, low, none, then age. It is
  read through the row's JSON, so a store before 014 still orders, by
  declared impact. `get`/`list` and the desk's cards print `Impact:
  critical-path (derived: 2 open dependents, backlog rank unknown; declared
  low)`.
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

## Export to paper (issue #1759)

The operator reads long material on paper, marks it by pen, and dictates or
types the answers back. `export` prints a batch as a numbered PDF whose
numbers are a set's, so a reply typed from the paper (`2: B`, `D-43: B`)
lands on the right item.

- **The command.** `export --out FILE.pdf` with exactly one batch:
  `--kind decisions` (every open Decision, list order), `--kind reviews`
  (every unreviewed Review, oldest first; `--today` for today's), `--ids
  D-43 R-9 …` (that order), or `--set N` (a set at its own numbers: the
  end-of-day sweep's). `--level 1|2` picks how much of each Review (2, the
  cached twenty-line summary, by default); `--dry-run` reports the batch and
  the Reviews still missing a summary without writing or recording
  anything; `--json` prints the result as one object. At most 99 items, the
  rest counted as `more`. `export --help` has the whole contract.
- **Numbering.** `--kind` and `--ids` open a new set, as `set-open` does
  (`shown` events); `--set` opens nothing. Every item's heading carries its
  id, so `D-43: B` works whatever set is current.
- **Layout (ISO 2145).** A title, the set, the count, and the export time;
  then one section per item headed `n  D-43 · the question`: its repo, key,
  and triage facts, its context, a Review's summary, its options as `n.1
  A. Yes (Recommended)`, `n.2  B. No`, the default and when it applies, the
  operator's own priority, tags, and note when it carries them (#1769), the
  link, and a blank answer line (an item answered since shows its answer).
  A footer carries the export time: from headless Chrome on every page, with
  page numbers; from pandoc or the print system once, at the end (the
  header line on the first page carries the time too).
  `bin/lib/export.jq` renders it three ways (Markdown, plain text, HTML)
  from one item model, reusing `skill/desk.jq`'s labels and links. It runs
  as the head of the main jq program (`lib/export.sh`'s `hq_export_jq`),
  never as an included module: jq 1.8 aborts when a module's def calls a
  `desk.jq` function that calls another one.
- **Renderers.** No new dependency: the first of these that produces a PDF
  is used. pandoc (the Markdown, when pandoc and a PDF engine are
  installed; the items' text is escaped and read literally: its Markdown,
  raw TeX and HTML, math, YAML blocks, and images stay text, so nothing in
  it reaches the engine or is fetched, and no smart punctuation turns
  `--force` into a dash);
  headless Google Chrome or Chromium (the HTML, under a throwaway profile,
  so a running Chrome is never touched; offline, since no host name
  resolves; stopped once it reports the file written, because on macOS it
  can keep running after); the macOS print system (`/usr/sbin/cupsfilter`,
  the plain text). With none, the Markdown is written next to the
  requested path (`FILE.md`), the exit is still 0, and one stderr line
  names it and what each renderer did. Every renderer runs without the
  store's URL in its environment, with its temp files (`TMPDIR`, and
  Chrome's `MAC_CHROMIUM_TMPDIR`) in the export's private scratch
  directory, which is removed on exit, and under a deadline
  (`HUMAN_QUEUE_EXPORT_TIMEOUT`); an export interrupted mid-render stops
  its renderer. To get PDFs on a machine with none: install Google Chrome,
  or pandoc with a PDF engine.
- **The file.** Written through a temp file and a rename, owner-only
  (0600: it holds open questions); an existing file is replaced. The desk
  writes into `~/.claude/desk-exports/` (0700) unless the operator names a
  path.
- **Recording.** One `exported` event per item (note `set N #k`), in the
  transaction that reads the batch, so nothing else is logged. When the
  file then cannot be written, a second transaction removes that record
  (the set it opened, and its `shown` and `exported` events by the ids the
  first transaction returned), so no unseen set becomes the latest; exit 1,
  `nothing was recorded`. Migration
  `013_exported_event.sql` adds the kind to whatever `events_kind_check`
  allows (as 010 does), so it applies before or after #1769's 010. Before
  013 is applied, `export` exits 1 naming `migrate` and records nothing; a
  dry run needs no migration. The weekly report does not count `exported`.
- **The desk.** `export` after a sweep prints that sweep's set; otherwise
  `export`, `export decisions`, `export reviews` (`level 1`, `today`), and
  `export D-43 R-9 …`, any of them `… to <path>.pdf` (`skill/export.md`).
  Before Reviews go out at level 2, the desk writes any missing twenty-line
  summary first (`reviews.md`'s `open` steps; summaries stay lazy). The
  sweep no longer writes its own Markdown copy.
- **Tests.** `tests/export-offline.test.sh` (offline: validation before
  connecting, the three renderings of `tests/fixtures/export/batch.json`
  — ISO 2145 numbering, the to-do line, escaping, levels — the renderer
  order and fallbacks against stub binaries, the URL kept out of their
  environment, their temp files in the scratch directory, Chrome offline
  and stopped after it writes, a renderer stopped when the export is
  interrupted, images in the text escaped, the same paper from every jq
  on the machine (and `HQ_T_EXTRA_JQ`, for a jq 1.8), a real cupsfilter and Chrome
  PDF read back by `pdftotext` on macOS, and the skill's blocks under bash,
  `/bin/bash` 3.2, and zsh); `tests/export.test.sh` (live, throwaway
  schema: test 5.1, three fixture Decisions to a PDF with three sections
  whose ids `pdftotext` finds; test 5.2, the Markdown fallback and its
  warning; the set and its events, `--set`, `--ids`, Reviews at both
  levels, `--today`, a dry run, the 99 cap, an empty batch, refusals, and a
  store before 013).
