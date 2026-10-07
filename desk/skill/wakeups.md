# /desk — wake-up retries and parked answers

Loaded by `SKILL.md` on a `desk-tick … retry` event, and by `decisions.md` when recording a wake-up reports a parked answer. Every Bash block starts with `SKILL.md`'s prelude (`DESK`, `HQ`, `SID`, `SESSION_STATE_SH`). Issue #1781; design: `desk/DESIGN.md` 2.6 ("a dead thread loses nothing").

## The rule

A failed wake-up is retried on the next tick, **up to three times**. The first attempt is the one `decisions.md` makes right after the answer ("Waking the asking threads"). `human-queue.sh wake` counts the failures since the item's latest answer, so the desk keeps no count of its own. When the third retry fails too, `wake` sets the item `answer-parked` in the same transaction. The answer then waits in the store for the next thread on that PR or issue (`pending-for --repo <repo> --key <key>`), and the desk shows it **once**. An answer with no return address has nothing to retry, so it parks on its first failure. A new answer to the item starts the count again.

## A `retry` event

`desk-tick <GEN> retry D-43 D-44`: this tick found answers whose last wake-up failed and that have a retry left. Handle it at once, even while a long-form prompt waits: a retry shows nothing unless an answer parks.

1. **Read what is still due.** Two retry events can queue up while the desk is busy. Read the list again instead of trusting the line, and skip anything retried in the last 30 seconds. The shortest cadence is one minute, so the next tick still retries it:

   <!-- test-anchor: desk-retry-due -->

   ```bash
   "$HQ" wake-due --json --min-age 30; echo "exit=$?"
   ```

   It prints `[{"id": "D-43", "session": "…", "failures": 1, "retry": 1}, …]`, then `exit=0`. Retry only the ids that are both in the event and on this list. Any other id from the event was answered again, acknowledged, woken, or retried a moment ago, so drop it silently. `exit=7` means the store is unreachable: retry nothing. The first tick after `recovered` lists the same ids again.
2. **Wake each one** exactly as `decisions.md` does ("Waking the asking threads", steps 1–3), with the entry's `session`. Find its address with `wake-target.sh`, send `human-queue: D-<k> answered`, and record the result with `wake … --json`. Never skip the record: it is the retry count.
3. **Say nothing** about a retry that worked, or one that failed with retries left (`"retries_left"` above 0). Only a parked answer (below) or a record that failed reaches the operator.

## The parked notice (shown once)

`wake … --json` prints `{"id", "result", "failures", "retries_left", "status", "parked"}`. `parked` is true on exactly one call per parked answer, so that result is the only time the desk shows it. Read the item's `repo` and `key` (`"$HQ" get D-43 --json`; the retry list carries only the id and session), then print one line, action first:

`D-43 parked — its thread never woke (4 tries); the answer waits in the store for the next thread on <repo> <key>. "show D-43" shows its trail.`

When the item has no return address (`session` null, parked on its first failure):

`D-43 parked — it has no return address; the answer waits in the store for the next thread on <repo> <key>.`

While a long-form prompt waits for its reply (`longform.md`), hold the notice the way that file holds tick events, and print it once the group ends. Never print it between a prompt and its answer.

## A wake-up the store did not record

`wake` exit 7 or 1 means the attempt happened but was not counted. `wake-due` sees only recorded wake-ups, so an unrecorded first attempt would never be retried: make the record again rather than drop it. Say it once: `D-43: wake-up not recorded (<the CLI's line>) — recording it again.`

1. Run the same `wake` command (same id, `--result`, and `--note`) again at once.
2. If it fails again, keep that command in this conversation. Run it at the start of the desk's next turn (any `desk-tick` line, `recovered` included, or an operator message), before anything else, until it exits 0 or 4. Running it first means a `retry` line's re-read already sees the attempt.
3. Never send the pointer again for it: the attempt already happened. Handle its `--json` result as any other. A failure with retries left is retried from the next tick, and `"parked": true` prints the parked notice.

Exit 4 (`no item`, or `has no answer yet`), on the first try or a later one, means the item is gone or was reset: drop it silently.
