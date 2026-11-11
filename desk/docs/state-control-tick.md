## State, control, and tick

| Subcommand | What it does |
|------------|--------------|
| `state get KEY` / `state set KEY VALUE` | One key of operator state (the desk's bookkeeping; the day plan has `plan`). `get` prints the value exactly; a key that is not set exits 4. A value is at most 65536 characters and 131000 bytes (it travels as one child environment entry, and Linux caps one at 128 KiB) |
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
  ticks. Registering a different control session waits for preceding ticks
  and clears `tick_at`. Named desk ticks (`--session`) are checked against the
  registered owner under the same locks. The argument-free compatibility
  command has no caller identity: any such tick committing after registration
  can make it live, so its stamp does not prove the new session itself ticked.
