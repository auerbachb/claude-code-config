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
