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

1. the thread has assigned work: its checkout is on a branch named `issue-N-*`,
   **or** (any branch, `main` and detached HEAD included) it is an orchestrating
   thread holding a recorded round for this repo and session (below);
2. no active `/pause` or `/end` gate for the session or the repo, and no
   declared leave time at or before its pause point (`deadline_epoch` minus
   `lead_minutes`); an unreadable gate is not "no gate";
3. nothing running: the background-work ledger, the task registry (stale
   leftovers ignored), and the recorded subagents for the issue are all empty;
4. nothing armed: no silence-ceiling watch (it exists only while work runs);
5. work not finished: on an issue branch, uncommitted changes, unpushed
   commits, or a recorded pipeline whose head is this checkout's HEAD; for an
   orchestrating thread, its round not wound down.

**Orchestrating threads.** A project-manager or subagent-monitoring thread is
usually on `main` or a session branch, so the branch cannot say it has work. Its
work is the state `/subagent` already keeps: `.repos["<owner>/<repo>"].rounds["<session>"]`
(Step 7.0), set to `null` when the round winds down (Step 8 teardown), plus
`table_render["<session>"]` whose terminal board (`active_pipelines` 0, rendered no
earlier than the round's dispatch) also ends it. The round is keyed by the
thread's own session id and read from the repo's own record, so another
session's or another repo's work is never attributed to this thread. A round
with members left, nothing running (no background work, no registry task, no
recorded subagent on any round issue, running or just spawned) and nothing
armed is an entry whatever the branch; its ref is the round's first issue. The
pipeline records (`.repos[...].pipelines`) are not read: they are append-only
with no finished marker and are not session-scoped, so they cannot say what is
still unfinished; a pending phase transition belongs to a round member and is
covered by the round. An ordinary thread (no round) costs the hook one state read
and no entry, so the check is cheap in every thread.

The cause is what the hook can see: a recorded `token_exhaustion` or
`usage_limit_park` handoff reason, a pipeline in review (`waiting_on_review`), a
final message ending in a question (`waiting_on_operator`; only its shape is read,
none of it stored), else `unknown`. `out_of_work` and `blocked_by_error` are not
visible from a Stop hook; the orchestration steps that know them record them with
[`bin/stoppage-note.sh`](../bin/stoppage-note.sh):

- `stoppage-note.sh refill --picked N --reason TEXT`, called once per refill
  evaluation by `/subagent` Step 8 item 4 and `/pm`'s refill (the step that
  already names the idle reason of a slot that stays empty). With nothing
  launched and a reason starting `nothing eligible` it records `out_of_work`,
  evidence `slot idle: <reason>`, ref the round's first issue. Every other idle
  reason (`chained`, `paused`, budget, horizon, priority, ceiling) is a held or
  planned state and records nothing; `/subagent` skips the call on the tick
  that only drains a round whose pipelines all merged (a finished round is not
  a stoppage), while `/pm`'s refill finding the backlog empty is the
  `out_of_work` case. It also records nothing while a subagent
  still works a pipeline of the repo or a round issue, during a `/pause` or
  `/end` gate, or at a leave time's pause point. With N above 0 it closes an
  entry left open for the session (`stoppage resume`), so the idle time ends
  when work is launched again, not at the operator's next prompt.
- `stoppage-note.sh blocked --phase A|B|C (--pr N | --issue N) --reason TEXT`,
  called where `/subagent` Step 9 reports a Phase B `blocked_self_review` or a
  Phase C `blocked` with no recovery under way. It records `blocked_by_error`,
  evidence `phase <X> blocked: <reason>`, whether or not other pipelines run,
  but not during a `/pause` or `/end` gate or at a leave time's pause point
  (a result arriving then is the wind-down).

Both write source `manual`, share the Stop hook's open marker (one entry per
stretch: while an entry stands, neither writes a second), and fail open and
silent like the hook. The reason is the step's own one-line text, stripped to a
plain vocabulary and bounded; the CLI still refuses anything shaped like a
secret. A drained round that finished all its work, an attended thread waiting
for the operator with nothing assigned, a planned stop, and a turn another Stop
hook continues write nothing.

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
- [`tests/stoppage-note.test.sh`](../tests/stoppage-note.test.sh): the
  orchestration helper (`out_of_work`, `blocked_by_error`, and the non-cases),
  with a stub CLI.
- [`tests/stoppage.test.sh`](../tests/stoppage.test.sh): the live path against a
  throwaway schema (skips without `HUMAN_QUEUE_DATABASE_URL`).

### Known limits

- The hook cannot see an orchestrator's empty queue or a tool error; those
  entries come from `stoppage-note.sh`, called by the orchestration steps. A
  thread that never reaches those steps (a crashed orchestrator) is still caught
  by its Stop hook when its round is not wound down, and by `/go-on` otherwise.
- An `out_of_work` or `blocked_by_error` entry is closed when a later refill
  launches work or the thread's next prompt arrives, whichever is first. A
  `blocked_by_error` written while other pipelines keep running therefore
  counts until then, so its idle time reads as an upper bound.
- One entry per stretch: a second blocked pipeline while an entry stands is not
  logged separately.
- A round whose teardown was skipped (the thread died before Step 8) reads as
  not wound down; an entry for it is correct for a dead orchestrator and `why`
  can be corrected afterwards.
- The idle time ends at the next prompt in the thread, or at the `/go-on` that
  picked the work up. A thread restarted by a background-task notification with
  no prompt keeps its entry open until then.
- "Work not finished" is inferred from local git state and recorded pipelines
  (no network call from a Stop hook); a squash-merged branch that still has a
  recorded pipeline can read as unfinished until its record is removed.
