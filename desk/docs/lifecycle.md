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
