# PM Monitoring Primitive Decision

## Decision

Division of responsibility between orchestration and fleet monitoring:

- **`/pm` never creates polls.** It is a strictly on-demand orchestrator: cold-start scan, inline execution of selected issues via the `/subagent` A→B→C flow (in-turn Dedicated Monitor Mode, not a recurring poll), thread prompts for the few issues too big for a subagent, on-demand status when the user asks, and handoff generation. At ≥3 active threads it redirects to `/pr-monitor-and-manage`; it does not arm a scheduler.
- **`/pr-monitor-and-manage` owns PR-fleet between-message polling.** It establishes a persistent `Monitor` at the configured cadence, optionally keeps a low-frequency Monitor re-scan running after an idle pause (`--auto-wake`), and dispatches per-PR fixes/merges.
- **Persistent `Monitor` owns explicit user-invoked "poll every N"** that is not PR-fleet-specific. `CronCreate`, both `/loop` modes, and hand-rolled one-shot `ScheduleWakeup` chains are forbidden for recurring polls (#914, #924).
- **`CronCreate` is never a polling fallback.** It is session-only and produced zero ticks in a controlled idle probe (#914); durable work uses on-disk state reconciled at session start (`.claude/reference/cross-session-durability.md`).

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

- `/pm`: runs selected inline-eligible issues via the `/subagent` A→B→C flow (in-turn monitoring) and hands issues too big for a subagent to threads; detects active worker threads after cold start/resume. At ≥3 threads, redirects to `/pr-monitor-and-manage`. Never creates polls. Records passive tracking in `session-state.json`.
- `/pr-monitor-and-manage`: owns PR-fleet between-message polling with persistent Monitor tasks, per-PR dispatch, and idle auto-pause.
- `/subagent`: when it spawns Phase A/B/C agents, it immediately enters Dedicated Monitor Mode for in-turn orchestration and records state. For between-turn PR fleet monitoring, point the user at `/pr-monitor-and-manage`; for explicit user "poll every N" on non-PR work, use `Monitor` per `scheduling-reliability.md`.
- `/status`: remains the default on-demand scan command because it already reconciles PRs, review state, checks, session state, and active agents.
- `/pm-handoff`: captures orchestration state for resume; snapshots any live `polling_jobs[]` owned by other skills for informational continuity but does not instruct the new thread to recreate `/pm` polls.
- `/start-issue`: does not auto-arm monitoring. It creates/starts one coding workflow; monitoring becomes relevant only after a PR, worker thread, or `/subagent` campaign exists.
