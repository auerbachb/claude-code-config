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
