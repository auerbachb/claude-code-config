## Stoppage log (issue #2292)

Long unattended runs fail when work simply stops. The resume flow already works
out why at the moment you resume, but it kept no history, so the same causes
could recur for weeks unseen. Every unplanned stop now leaves one short entry in
the desk's private Postgres database. The repository is public and stoppages
also happen in other, private projects, so **nothing is written to GitHub or to
any file in a repository**: the database, and a keep-and-retry directory under
`~/.claude/`, are the only homes.

### The entry

| Field | Meaning |
|---|---|
| stop time | when the turn ended (UTC) |
| thread | the session id |
| repo, ref | `owner/name`, and `issue#N` or `pr#N` |
| cause | `out_of_work`, `waiting_on_review`, `waiting_on_operator`, `usage_limit`, `token_exhaustion`, `blocked_by_error`, `crash`, `unknown`. A missing or unrecognised cause is stored as `unknown`, never dropped |
| evidence | one line, at most 200 characters; a fixed vocabulary plus the branch name, never transcript text; refused if it looks like a secret |
| idle time | added when the work resumes |
| correction | the operator's cause and note, kept beside the original cause |

Table and checks: [`schema/018_stoppages.sql`](../schema/018_stoppages.sql). The
migration is applied like any other, by the operator, with
`human-queue.sh migrate`.

### What counts as a stoppage

A turn ends with nothing running, nothing armed to wake it, and the assigned
work not finished. A planned stop (`/pause`, `/end`, a declared leave time) is
not one. The Stop hook ([`hooks/stoppage.sh`](../hooks/stoppage.sh), registered as
`.claude/hooks/stoppage-log.sh`) records an entry only when **all** hold, and any
doubt means no entry:

1. the checkout is on a branch named `issue-N-*` (assigned work);
2. no active `/pause` or `/end` gate for the session or the repo, and no
   declared leave time at or before its pause point (`deadline_epoch` minus
   `lead_minutes`); an unreadable gate is not "no gate";
3. nothing running: the background-work ledger, the task registry (stale
   leftovers ignored), and the recorded subagents for the issue are all empty;
4. nothing armed: no silence-ceiling watch (it exists only while work runs);
5. work not finished: uncommitted changes, unpushed commits, or a recorded
   pipeline whose head is this checkout's HEAD.

The cause is what the hook can see: a recorded `token_exhaustion` or
`usage_limit_park` handoff reason, a pipeline in review (`waiting_on_review`), a
final message ending in a question (`waiting_on_operator`; only its shape is read,
none of it stored), else `unknown`. `out_of_work` and `blocked_by_error` are not
visible from a Stop hook; an orchestrator records them with
`stoppage record --cause`.

An open marker (`~/.claude/desk-stoppages/open/<session>`) prevents a second
entry for the same stretch. The next prompt in the thread (`UserPromptSubmit`)
closes the entry with its idle time; the normal path of that hook is one file
test.

The marker holds the entry's stop time. When another Stop hook continues the
turn (`question-leak-warn.sh` does, once), the continued turn's next Stop
carries `stop_hook_active: true`: the first Stop was not the end of the turn, so
the hook **withdraws** the entry (`stoppage withdraw`, which deletes it) instead
of closing it, and then judges the turn's real end like any other Stop. A closed
entry would have counted as a stoppage a few seconds long. `why` also counts a
kept (not yet sent) `resume` or `withdraw`, so an offline thread that stopped and
resumed is not reported as still stopped.

A session found dead on return is recorded by `/go-on` Step 0.5a from the
evidence Step 0 already reads (ranks 2 to 4: usage-limit park, token
exhaustion, unplanned), with cause `crash` when a task never closed, else
`unknown`. An entry the dead session's own hook already wrote is closed, not
duplicated.

### The command

```
human-queue.sh stoppage record  --thread ID [--repo OWNER/NAME] [--ref issue#N|pr#N]
                                [--cause CAUSE] [--evidence TEXT] [--at TIME] [--source hook|go-on|manual]
human-queue.sh stoppage resume  --thread ID [--at TIME]
human-queue.sh stoppage withdraw --thread ID --at TIME
human-queue.sh stoppage why     [--thread ID] [--json]
human-queue.sh stoppage correct (ID | --thread ID) --cause CAUSE [--note TEXT]
human-queue.sh stoppage list    [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--json]
human-queue.sh stoppage flush
```

`list` is the one command the weekly review reads: entries from `--from` to
`--to` inclusive (the desk's calendar, America/New_York; default the last 7
days), grouped by cause with idle time totalled and sorted by idle time. A
correction is counted instead of the original cause. An entry not yet resumed
counts as a stoppage and adds no idle time; the heading says how many are still
open. `--json` prints `{from, to, total, open, idle_seconds, causes:[{cause,
count, open, idle_seconds}]}`.

When the operator asks "why weren't you working?", the
[`/why-stopped`](../../.claude/skills/why-stopped/SKILL.md) skill answers from
`stoppage why` and saves a correction with `stoppage correct`.

### Unreachable database

The hook fails open exactly like the capture hook. When the database cannot be
reached (or is not migrated yet), `record`, `resume`, and `correct` keep the
operation as one private JSON file (mode 600, directory 700) in
`~/.claude/desk-stoppages` (`HUMAN_QUEUE_STOPPAGE_DIR` overrides it; it is never
a worktree) and exit 0, so a stopping turn is never blocked or failed. Any later
call that reaches the database, or `stoppage flush`, sends the kept operations
in order: a resume kept before its record still lands after it. A record carries
a dedupe key, so a retry that half-succeeded stores the entry once. A kept file
holds only the entry's own fields; the connection string is never written, and
all database access goes through `lib/db.sh`.

### Tests

- [`tests/stoppage-offline.test.sh`](../tests/stoppage-offline.test.sh): the
  CLI's validation, secret refusal and keep-locally path, the list grouping,
  and the hook's every gate, with no database.
- [`tests/stoppage.test.sh`](../tests/stoppage.test.sh): the live path against a
  throwaway schema (skips without `HUMAN_QUEUE_DATABASE_URL`).

### Known limits

- The hook cannot see an orchestrator's empty queue or a tool error; those
  entries come from `record --cause`.
- The idle time ends at the next prompt in the thread, or at the `/go-on` that
  picked the work up. A thread restarted by a background-task notification with
  no prompt keeps its entry open until then.
- "Work not finished" is inferred from local git state and recorded pipelines
  (no network call from a Stop hook); a squash-merged branch that still has a
  recorded pipeline can read as unfinished until its record is removed.
