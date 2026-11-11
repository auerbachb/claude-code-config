## Exit codes

| Code | Meaning |
|------|---------|
| `0` | ok |
| `1` | unexpected failure, such as a migration's SQL error (its transaction is rolled back) |
| `4` | validation or usage error: unknown subcommand, stray argument, invalid `HUMAN_QUEUE_SCHEMA`, invalid input, an item id that does not exist, or a write the item's state refuses (for example `ack` of an item with no answer) |
| `5` | secret refused: credential-shaped text is rejected before database access. Stored-text checks cover `add`, `bump --note`, `wake --note`, `answer`, `flag`’s positional note or `--note`, `comment`, `note`, `set-resolve`, `state set`, `register-control`, `review --comment`, `summary set`, `checkin set` (`--session` and `--planned`), `plan set` (plan text and `--session`), and `interrupt set --session`; lookup-only checks also cover `state get`’s key, `pending-for`’s session/repo/key, and `--session` for `tick`, `sweep due`, `checkin due`, `plan clear`, and `interrupt get`. |
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
