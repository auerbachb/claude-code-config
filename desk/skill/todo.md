# /desk — the operator's own to-do layer

Loaded when the operator's whole message is a to-do verb (below). That holds at any time: with nothing on screen, after a menu, while a long-form prompt waits (it keeps waiting and its card is printed again after), or during a discussion. Every Bash block starts with `SKILL.md`'s prelude (`DESK`, `HQ`, `SID`). Issue #1769; design: `desk/DESIGN.md` 2.8 ("a personal to-do layer comes early").

The operator organizes the queue their own way: tags, a note, a personal priority, and a snooze, on any item (`D-<n>` or `R-<n>`). It is a layer on items, not a second task system: the fields live on the item, each change is one event, and the queue itself is unchanged. A tagged, noted, prioritized, or snoozed Decision still reaches the desk at the next tick, the sweep still lists it, and its thread still waits for it; writing one of these is not a change the next tick shows again.

**Not `/pm`'s priorities.** `mine D-43 2` orders the operator's own list of desk items. `top`, `bump`, `park`, and `drop` (`priorities.md`) order `/pm`'s backlog of GitHub issues (`#N`). They are separate: neither reads the other, and `bump`/`park` here never mean an item.

## The verbs

| The whole message | Runs |
|---|---|
| `tag D-43 prd [urgent …]` | `tag D-43 prd urgent --json`: adds tags (lowercase words joined by hyphens, a letter in each; `#PRD` is `prd`) |
| `untag D-43 prd […]` | `untag D-43 prd --json` |
| `note D-43 <text>` | `note D-43 --json -- <text>`: sets the note (one line, at most 1000 characters), replacing any note |
| `unnote D-43` | `note D-43 --clear --json` |
| `snooze D-43 until <when>` | `snooze D-43 until <when> --json`: `tomorrow`, `friday`, `2026-10-12`, `15:30`, `3pm`, `friday 9am`, `tomorrow 14:30`, or an ISO time |
| `snooze D-43 for <duration>` | `snooze D-43 for <duration> --json`: `30m`, `2h`, `3 days`, `1w` |
| `unsnooze D-43` | `unsnooze D-43 --json` |
| `mine D-43 2` (1 highest … 5) | `mine D-43 2 --json` |
| `mine D-43 off` | `mine D-43 --clear --json` |
| `my list` | `my list` |
| `my list all` / `my list snoozed` / `my list tag prd` | `my list --all` / `--snoozed` / `--tag prd` |

- Any item id works (`R-9`, `d-43`). A number (`tag 2 prd`) is not an item here: a set's numbers are for answers. Ask for the id in one line and run nothing.
- Verbs are case-insensitive. Anything that does not fit this grammar exactly is not a to-do verb: go back to `SKILL.md`'s reply order. Never guess one out of prose.

## Writing

Words go on the command line only after a check, each in single quotes, so nothing the operator typed is ever run by the shell:

- **Tags** — each word only letters, digits, and hyphens, an optional leading `#`. Anything else → `A tag is lowercase words joined by hyphens (prd, call-back).` and run nothing.
- **When** and **duration** — only letters, digits, spaces, and `: + - .`. Anything else → `Snooze until tomorrow, friday, 2026-10-12, 15:30, 3pm, friday 9am, or for 30m, 2h, 3 days.` and run nothing.
- **A note** is the operator's words: it goes through a quoted here-document (block `desk-todo-note`), never inside the command's quotes.

<!-- test-anchor: desk-todo-write -->

```bash
"$HQ" tag D-43 'prd' 'urgent' --json; echo "exit=$?"
```

The same shape for every verb but the note: `"$HQ" untag D-43 'prd' --json`, `"$HQ" note D-43 --clear --json`, `"$HQ" snooze D-43 until 'friday 9am' --json`, `"$HQ" snooze D-43 for '2h' --json`, `"$HQ" unsnooze D-43 --json`, `"$HQ" mine D-43 2 --json`, `"$HQ" mine D-43 --clear --json`.

<!-- test-anchor: desk-todo-note -->

```bash
NOTE_FILE=$(mktemp "${TMPDIR:-/tmp}/desk-todo-note.XXXXXX")
cat > "$NOTE_FILE" <<'DESK_NOTE'
<the note, verbatim, without its surrounding quotes>
DESK_NOTE
"$HQ" note D-43 --json -- "$(cat "$NOTE_FILE")"; rc=$?; rm -f "$NOTE_FILE"; echo "exit=$rc"
```

The note goes between the two delimiter lines exactly as typed, with nothing escaped. If it contains a line that is exactly `DESK_NOTE`, pick another delimiter for both lines. The `--` keeps a note that reads like an option (`--clear`) a note.

`exit=0` prints the item's to-do fields as JSON (`my_priority`, `my_tags`, `my_note`, `snoozed_until_local`, and `changed`). Answer in one line, from it:

| Verb | `changed: true` | `changed: false` |
|---|---|---|
| `tag` / `untag` | `D-43 · tags: prd, urgent.` (every tag it has now; `D-43 · no tags.` when none) | `D-43 already had those tags.` / `D-43 had none of those tags.` |
| `note` | `Noted on D-43.` | `D-43 already has that note.` |
| `unnote` | `D-43's note cleared.` | `D-43 had no note.` |
| `snooze` | `D-43 snoozed until <snoozed_until_local> ET — back on my list then.` | the same line |
| `unsnooze` | `D-43 is back on my list.` | `D-43 was not snoozed.` |
| `mine` | `D-43 is P2 on my list.` / `D-43's priority cleared.` | the same lines |

Then go back to where the operator was. Nothing here is a menu, and nothing is answered or woken.

- **`exit=4`** → its one stderr line, without the `human-queue: ` prefix (no such item, a malformed tag, more than 10 tags, a snooze time in the past or more than 366 days ahead, a note on two lines or too long).
- **`exit=5`** → `That note looks like it holds a credential — not stored. Reword it without the secret.`
- **`exit=1` naming `migrate`** → the store predates migration 010: run `"$HQ" migrate` once, then the same block again. Any other `exit=1` → its stderr line.
- **`exit=7`** → `Store unreachable — nothing changed; try again in a minute.`

## `my list`

<!-- test-anchor: desk-todo-list -->

```bash
"$HQ" my list; echo "exit=$?"
```

With `all`, `snoozed`, or `tag <word>`, add `--all`, `--snoozed`, or `--tag '<word>'` (the tag checked as above). Print the CLI's output as is, without the final `exit=0` line, and nothing else: no state line, no queue counts.

It lists every item with a personal priority or a note that still waits on the operator (an open Decision, an unread Review, a flagged one), priority 1 first and unprioritized last, then oldest first; each note under its item. An item snoozed until a time still ahead is left out, and the header counts it and says when the next one is back (`My list · 3 items · 1 snoozed (next back Fri Oct 9 09:00 ET)`); at that time it is back with nothing to run. The lines are unnumbered on purpose: replies by number (`2: B`) resolve against the latest set, never this list, so reply to an item here by its id.

- `exit=1` naming `migrate`, `exit=7` → as for the writes.

The end-of-day sweep's numbered list and its paper copy (`sweep.md`) show each item's priority, tags, and note on a line under it.
