# Cross-Session Durability — what exists, and why our schedulers decline it

Background for issue #827, which redesigned the three features built on the
false promise that `CronCreate` survives session turnover. Read this before
proposing that any skill "just use a durable job" — the durable primitive exists,
and the reason we do not use it is not ignorance of it.

Prior art: issue #808 (discovery), PR #825 (doc-only correction),
`scheduling-reliability.md` (the authoritative `CronCreate` contract).

## The two primitives, compared

| | `CronCreate` | `mcp__scheduled-tasks__*` (`/schedule`) |
|---|---|---|
| Storage | in-memory, per session | on disk: `~/.claude/scheduled-tasks/{taskId}/SKILL.md` |
| Survives session exit | **No** — `durable: true` is a documented no-op | **Yes** |
| App closed when due | job is gone | runs on next launch |
| Expiry | 7 days | none |
| Run context | the current session | **a fresh session, no memory of the creator** |
| Cadence precision | exact | several-minute deterministic dispatch delay |

So the answer to "does the harness provide cross-session durability?" is **yes**
— `mcp__scheduled-tasks__*` genuinely persists. The design question is not
whether we *can* use it but whether each feature *should*.

## Why all three features declined it

**1. It would silently convert supervised work into standing automation.**

`/babysit-pr` and `/pr-monitor-and-manage` auto-dispatch `/fixpr` and `/wrap`,
and `/wrap` squash-merges. A scheduled task runs in a *fresh, unattended
session*. Porting either watcher onto it would turn "watch this PR while I'm
here" into "merge my PRs on a cron, forever, with nobody reading the output" —
an authorization escalation nobody asked for, granted by a flag whose name
(`--durable`) suggests only a scheduling detail. `CLAUDE.md`'s merge authority is
scoped to a live session's work, not a standing job.

This is the load-bearing objection. It is about **what the job would be allowed
to do**, not about whether the scheduler works.

**2. The durable record we actually needed was never a job.**

Both remaining needs were already satisfied by state on disk:

- A paused PR fleet resumes from `.pmm.paused_at` in `session-state.json` —
  read by `pmm-lifecycle.md` Step 0a on the next invocation, in any session.
- The monthly audit's cadence is driven by
  `~/.claude/harness-audit/last-run.json`, checked at session start.

Reconciling durable state at session start is strictly more reliable than any
scheduler for these: sessions begin many times a day, there is no job id to
orphan, no expiry to lapse, and no MCP dependency to be absent in a headless
run. A scheduler would have been a less reliable way to reach state we can
simply read.

**3. Cadence fit.** A several-minute dispatch delay is irrelevant monthly and
wrong for a 1–5 minute PR watcher.

## What replaced them (issue #827)

One mechanism serves all three: **durable on-disk state, reconciled at session
start.** `.claude/scripts/session-scheduling-reconcile.sh`, invoked by the
`SessionStart` hook (`session-start-sync.sh`):

1. Purges bookkeeping that cannot have survived — `polling_jobs[]`,
   `.pmm.auto_wake_cron_id`, every `babysit.cron_job_id`.
2. Deactivates `babysit` watchers whose last tick predates this process (a live
   watcher rewrites `last_tick_at` every tick, so this cannot reap a live one).
3. Surfaces what is still meaningful: an audit month come due, a paused fleet.

Per feature: `--durable` was **dropped** from `/babysit-pr` (accepted and
ignored, so an old chip payload does not hard-error); `--auto-wake` was
**reframed** to a `/loop` re-scan in `/pr-monitor-and-manage`, keeping its
user-visible promise while deleting a fail-closed cron teardown that had been
duplicated across three files; `/harness-audit`'s daily-registration cadence
became the **session-start watermark check** above.

## When to revisit

Adopting `mcp__scheduled-tasks__*` would be reasonable for a task that is
genuinely unattended-safe — advisory, read-only, or output-only, with no merge,
push, or write authority — and that needs to fire on wall-clock time rather than
when a human happens to start a session. Nothing in this repo met that bar in
July 2026. If something does later, the objection to re-read is #1 above:
enumerate what the fresh session would be *permitted* to do, not just what it is
*intended* to do.

Whatever the outcome, do not reintroduce the claim that `CronCreate` is durable.
It is not, in any configuration.
