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
  `pm-priority.sh` (`top`, `bump`, `park`, `drop`; [Priorities](priorities.md)).
  Neither reads the other.
- **On paper.** The end-of-day sweep's card prints each item's priority,
  tags, and note on a nested line under it (`desk.jq`'s `todo_line`); the
  paper copy, `export` (issue #1759, [Export to paper](export-to-paper.md)), prints the
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
