# /desk — `report`: the weekly attention report

Loaded when the operator's whole message is `report` (any case), or `report <YYYY-MM-DD>` for the week holding that day; Friday's end-of-day sweep offers it once a week (`sweep.md`, "Friday"). That holds at any time, like `history`: after a menu, while a long-form prompt waits, or during a discussion. It is read-only and writes nothing to the store. Every Bash block starts with `SKILL.md`'s prelude. Issue #1771; design: `desk/DESIGN.md` 2.8 ("a weekly attention report measures what the queue costs you") and 2.5 (state changes only).

The report exists to tune the interrupt policy and the agents' defaults, not to be read daily: one page, offered once a week, shown whenever asked.

## Output rule

Print the CLI's output and nothing else. It is already the page: a bold title naming the week, five numbered measures, and one small table. No "Desk live …" line, no queue counts, no tick age, no menu, before or after it. Then go back to where the operator was. A waiting long-form prompt prints its card again (`longform.md`), and a discussion continues (`discuss.md`).

## `report`

<!-- test-anchor: desk-report -->

```bash
"$HQ" report; echo "exit=$?"
```

For another week, run `"$HQ" report --week 2026-10-05` (any day of that week). A week runs Monday to Sunday on the America/New_York calendar; "this week" is the store's clock, and a week still running is titled `(to date)`.

The measures, all computed from the events table when the report runs (`"$HQ" report --help` defines each):

1. **Minutes spent answering**: the operator's sittings at the desk (desk events no more than 10 minutes apart), each counted from its first event to its last plus a minute.
2. **Items per day**: Decisions answered and Reviews reviewed or flagged, on average per desk day, then each day of the week so far.
3. **Median age of an open Decision**: from asked to its first answer, or to the week's end for one still open then.
4. **Interrupts tagged not important**, beside the Decisions shown that week.
5. **Questions tagged should have defaulted**, and the table: by thread (its first eight characters) and the model it ran on, with each thread's other tags and the Decisions it asked. A model reads `unknown` when that thread ran on another machine.

- Print everything before `exit=0` as is, without the `exit=0` line. An empty week still prints the page, every measure as none.
- `exit=4` (a bad date) → its one stderr line.
- `exit=1` naming `migrate` → `The report needs migration 008: run /desk again (it migrates), then report.` Another `exit=1` → its one stderr line.
- `exit=7` → `Store unreachable — can't build the report right now.`
