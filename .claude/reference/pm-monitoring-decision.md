# PM Monitoring Primitive Decision

## Decision

Division of responsibility between orchestration and fleet monitoring:

- **On-demand `/pm` never creates polls.** A bare `/pm` is a strictly on-demand orchestrator: cold-start scan, inline execution of selected issues via the `/subagent` A→B→C flow (in-turn Dedicated Monitor Mode, not a recurring poll), thread prompts for the few issues too big for a subagent, on-demand status when the user asks, and handoff generation. At ≥3 active threads it redirects to `/pr-monitor-and-manage`; it does not arm a scheduler.
- **`/pm day` is the one carve-out, and it is mutually exclusive with `/pr-monitor-and-manage`** (#1194). Continuous mode arms exactly one persistent `Monitor` per repo, re-invoking `/pm day --tick`. See "The day-mode carve-out" below for why this preserves rather than breaks the single-owner invariant.
- **`/pr-monitor-and-manage` owns PR-fleet between-message polling.** It establishes a persistent `Monitor` at the configured cadence, optionally keeps a low-frequency Monitor re-scan running after an idle pause (`--auto-wake`), and dispatches per-PR fixes/merges.
- **Persistent `Monitor` owns explicit user-invoked "poll every N"** that is not PR-fleet-specific. `CronCreate`, both `/loop` modes, and hand-rolled one-shot `ScheduleWakeup` chains are forbidden for recurring polls (#914, #924).
- **`CronCreate` is never a polling fallback.** It is session-only and produced zero ticks in a controlled idle probe (#914); durable work uses on-disk state reconciled at session start (`.claude/reference/cross-session-durability.md`).

## The day-mode carve-out (#1194)

Issue #1194 named this tension deliberately and required it be resolved here rather than left as a side effect. Two options were on the table.

**Rejected — delegate day mode's between-turn ticks to `/pr-monitor-and-manage`.** It looks like the conservative choice, since it leaves the "one poll owner" sentence literally intact. It is in fact the *dangerous* one. Day mode runs `/subagent` A→B→C pipelines, and Phase B and Phase C already dispatch `/fixpr` and `/wrap` against those PRs. `/pr-monitor-and-manage` independently dispatches `/fixpr` and `/wrap` against every PR it discovers — including those same ones. Delegating would put **two owners on one PR**: duplicate fix pushes onto a branch mid-rebase, and two racing merges. Preserving the wording would have broken the property the wording was protecting.

**Chosen — day mode owns its own poll, and cannot run alongside PMM.** The invariant worth keeping was never "`/pr-monitor-and-manage` specifically owns polling." It is **exactly one owner dispatches against a given PR at a time.** Mutual exclusion satisfies that directly:

- `/pm day` refuses to arm while `.pmm_active == true`, telling the user to run `/pmm-stop` first (`/pm` Step 2D.1(a)). An unreadable `.pmm_active` refuses too — failing closed, since "we could not look" is not "nothing is running."
- `/pr-monitor-and-manage` refuses to arm while a day loop is live, with the mirrored message (its Step 0-pre). Neither side can be the only one checking, or whichever starts second wins by default.
- A **paused** fleet (`pmm_active: false` with `.pmm.paused_at` set) is not dispatching, so it does not block. Day mode arms and says the fleet stays paused.
- The day loop's own `active` flag is trusted only inside a freshness window on `last_tick_at`, so a loop whose session died can never permanently block a re-arm from either side.

**The check is publish-then-verify, not read-then-arm.** Each `session-state.sh` call is individually locked, but a read followed by a separate write is not atomic, so two simultaneous starts could each read the other as clear. Both sides therefore write their own claim *first* and then re-read the other's: `/pm day` writes `day.active=true` before re-reading `.pmm_active`; `/pr-monitor-and-manage` writes `pmm_active=true` before re-reading `day.active`. Whoever writes second is guaranteed to observe the other's claim, so **two owners is unreachable**. The residual case is both standing down when they interleave exactly — zero owners, which is safe and costs one re-run. That asymmetry is deliberate: a lease or CAS protocol could also guarantee a winner, but the failure it would buy protection against (a user re-running a command) is trivial, while the failure publish-then-verify already eliminates (two racing merges on one PR) is not.

Day mode is also the strictly better owner for its own PRs: it holds the issue claims, the queue, the ranked backlog, and the phase state for each pipeline. `/pr-monitor-and-manage` re-derives PR state from GitHub every tick by design and knows none of that — it could merge a PR but never start the next issue, which is precisely the half of the loop #1194 exists to automate.

**Polling ownership is not park ownership (#1619).** This document decides who may *poll* a repo between turns. Who may *park* it on an account usage limit is a separate question with a separate answer, recorded once in `.claude/reference/subagent-thread-limit-park.md` §8: a loop may park the work it launched, and every parker claims one shared repo slot by compare-and-set on `limit_cause`, so two loops on one repo cannot both park. That is why a thread running Phase A/B/C subagents may park without becoming a second poll owner, and why `/pr-monitor-and-manage` and `/babysit-pr` honour a park without claiming one (#1444).

**Scope of the carve-out.** It is one `Monitor` per repo, armed only by an explicit `/pm day` or `/pm --run`, torn down on every exit path, and reclaimed by a freshness window when its session dies. Everything else in this document is unchanged: a bare `/pm` still arms nothing, and `CronCreate` is still never an option.

## Paused work resumes where it lives (#1431)

The general rule, of which the paused fleet is one instance: **paused work is resumed in the thread that owns it when that thread still exists, and adopted here when it does not.**

`/pm`'s pre-dispatch ownership sweep (Step 1B.5 and Step 3.4) applies that per candidate. A candidate owned by a live thread — open or paused — is skipped with a one-line surface naming the owner, its state, and its resume route: `/go-on` for an ordinary thread, `/pr-monitor-and-manage-wake` for the paused PR fleet. A candidate whose owner is archived or gone is adopted from its surviving state. Mechanism: `pm-ownership-sweep.md`.

This replaces the hand-maintained fleet carve-out **in prose only**. The fleet stops being a special case in the dispatch path and becomes the instance whose route differs; nothing about how the fleet is armed or taken over changes.

**Arm-time behavior is untouched.** Step 2D.1(a) is a precondition on `/pm day` arming — a different decision from "may I dispatch this backlog candidate?" — and it still reads `.pmm_active`, still refuses a live fleet, and still arms over a *paused* one while saying the fleet stays paused. The dispatch sweep is the **surfacing** side of ownership: it emits `/pr-monitor-and-manage-wake` as a route for a candidate the paused fleet owns, and it never takes over, wakes, or writes fleet state.

## Rationale

The canonical PM manager use case is **tracking worker output across GitHub-visible artifacts**: issues, feature branches, PRs, review findings, CI state, handoff files, and Phase A/B/C state. The PM may be coordinating multiple coding threads or `/subagent`-launched Phase agents, but `/pm` itself should not arm a recurring poll — that overlaps with `/pr-monitor-and-manage`, which adds per-PR state classification, auto-dispatch to `/fixpr` and `/wrap`, and idle auto-pause.

`/pr-monitor-and-manage` is the built, canonical fleet monitor. Before it existed, `/pm` offered its own scheduler; that offer is retired (#522).

`Monitor` is the only recurring primitive with positive out-of-turn liveness evidence:

- it runs independently of agent turns,
- its stdout lines create the tick events,
- its recorded task ID gives exact `TaskStop` cancellation.

Issue #924 adds negative evidence for dynamic `/loop`: PR #937 and PR #944 both stopped while idle until a manual turn. See `scheduling-reliability.md` for the authoritative contract.

## State contract: `session-state.json`

PM orchestration reads and writes `~/.claude/session-state.json`. Unknown fields must be preserved. GitHub and handoff files are authoritative when state is stale.

### Fields read

- `monitoring_active`: whether `/pm` is tracking in-flight work (passive/on-demand, not a recurring poll).
- `monitoring_mode`: for `/pm`, always `passive`.
- `root_repo`: absolute path to the **git root** of the repo where PR helpers run (must match `git rev-parse --show-toplevel` for that checkout). This top-level field is a *default only*: the session file is shared across concurrent sessions, so whichever session wrote last owns it, and it must never gate polling (issue #647). Repo scoping is per PR — `.prs["N"].owner_repo` plus `.prs["N"].root_repo`, written by `polling-state-gate.sh --ensure-session` and validated by **repo identity** (normalized `origin` remote, falling back to the shared git common dir) rather than path equality, so sibling worktrees of one repo agree while a genuine cross-repo mismatch is still refused. "Genuine" means scoping recorded *inside the scope being read*: PR numbers are per-repo, so another repo also tracking an `N` is an expected collision, never a refusal (issue #854) — the gate reads only this repo's scope (or the legacy `_unknown` one), and a PR absent from it is simply unregistered here, which `--ensure-session` fixes.
- `prs`: tracked PR map. Each entry may include `issue`, `phase`, `head_sha`, `reviewer`, `needs`, `status`, `worker`, and `updated_at`.
- `active_agents`: subagent records. Each entry should include `id`, `task`, `issue`, `pr`, `phase`, `launched`, and optional `last_seen_at`.
- `polling_jobs`: legacy `CronCreate` compatibility records from pre-issue #827 sessions. Empty in normal operation — no current skill registers one, and `session-scheduling-reconcile.sh` reconciles leftovers at session start. `/pm` does not create or clear this array.
- `.repos["<owner>/<name>"].day`: day-mode loop state (#1194) — `active`, the `monitor_task_id`/`monitor_generation` identity pair, cadence, `digest`/`digest_streak`, `failure_streak`, `refill_halted`, `stop_requested`, `paused_at`. Repo-scoped because a day loop is one-per-repo, sitting beside the `refill` posture it honors. **Not projected by `--session-view`**, which lifts only `.prs` and `.root_repo` out of the repo block — read it explicitly or an armed loop reads as absent. Written only by `/pm day`.
- `polling_failures`: prior dropped-poll recoveries.
- `cr_quota` and `greptile_daily`: review-budget state used by Phase B decisions.
- `pmm_*` fields: owned by `/pr-monitor-and-manage`.

### Fields written

`/pm` updates on demand:

- `last_updated`
- `monitoring_active`
- `monitoring_mode` (`passive`)
- tracked `prs` and `active_agents` when work changes

Skill-owned polling (`/pr-monitor-and-manage`, `/babysit-pr`) updates timing watermarks, recorded Monitor task IDs, and `polling_failures[]` per their own contracts. `polling_jobs[]` remains the legacy cron-job compatibility array described above.

## Recovery protocol

This extends existing recovery; it does not create a second PM-specific recovery path.

When a PM session resumes after context turnover, follow `.claude/rules/monitor-mode.md`
`## Post-Compaction Recovery` for session-start reconciliation and the recovery heartbeat, then
`## PM Monitoring Recovery` for the PM orchestration rebuild, terminal-state, and scheduler-
ownership boundaries. Apply the state contract above while doing so: repository-scoped GitHub and
handoff data are authoritative when cached session fields disagree. The heartbeat's user-visible
contract remains owned by `CLAUDE.md`.

`polling_jobs[]` is legacy `CronCreate` state, not a recovery registry for current persistent
`Monitor` tasks; `session-scheduling-reconcile.sh` owns its session-start reconciliation. Recover a
current Monitor or a dropped tick through `.claude/rules/scheduling-reliability.md` and the lifecycle
contract of the skill that armed it (`/pr-monitor-and-manage` or `/babysit-pr`).

## Rule placement

- `scheduling-reliability.md` owns primitive selection for user-invoked recurring commands and pre-exit checks.
- `monitor-mode.md` owns in-turn subagent monitoring and PM orchestration recovery.
- This reference doc records the rationale and state contract.
- No new rule file is needed.

## Skill integration decision

- `/pm`: runs selected inline-eligible issues via the `/subagent` A→B→C flow (in-turn monitoring) and hands issues too big for a subagent to threads; detects active worker threads after cold start/resume. At ≥3 threads, redirects to `/pr-monitor-and-manage`. Creates no polls on this path. Records passive tracking in `session-state.json`.
- `/pm day`: the continuous posture (#1194). Arms one persistent `Monitor` for the repo, refuses to arm alongside a live `/pr-monitor-and-manage`, skips the ≥3 redirect (day mode *is* the answer that redirect points at), and tears the Monitor down on every exit. Full contract: `/pm` Step 2D; mechanism and exit taxonomy: `.claude/reference/pm-day-mode.md`.
- `/pr-monitor-and-manage`: owns PR-fleet between-message polling with persistent Monitor tasks, per-PR dispatch, and idle auto-pause. Refuses to arm while a day loop is live — the mirror of day mode's own check, since a guard only one side runs is a guard the second starter walks past.
- `/subagent`: when it spawns Phase A/B/C agents, it immediately enters Dedicated Monitor Mode for in-turn orchestration and records state. For between-turn PR fleet monitoring, point the user at `/pr-monitor-and-manage`; for explicit user "poll every N" on non-PR work, use `Monitor` per `scheduling-reliability.md`.
- `/status`: remains the default on-demand scan command because it already reconciles PRs, review state, checks, session state, and active agents.
- `/pm-handoff`: captures orchestration state for resume; snapshots any legacy `polling_jobs[]` only as informational continuity and states that those session-scoped `CronCreate` jobs are dead on resume. It never treats that array as current `Monitor` identity or instructs the new thread to recreate the jobs.
- `/start-issue`: does not auto-arm monitoring. It creates/starts one coding workflow; monitoring becomes relevant only after a PR, worker thread, or `/subagent` campaign exists.
