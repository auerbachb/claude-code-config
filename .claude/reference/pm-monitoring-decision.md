# PM Monitoring Primitive Decision

## Decision

Division of responsibility between orchestration and fleet monitoring:

- **`/pm` never creates polls.** It is a strictly on-demand orchestrator: cold-start scan, prompt generation, on-demand status when the user asks, and handoff generation. At ≥3 active threads it redirects to `/pr-monitor-and-manage`; it does not offer `CronCreate` or `/loop`.
- **`/pr-monitor-and-manage` owns PR-fleet between-message polling.** It establishes `/loop` at the configured cadence, optionally registers `CronCreate` auto-wake on idle pause, and dispatches per-PR fixes/merges.
- **`/loop` remains valid for explicit user-invoked "poll every N"** that is not PR-fleet-specific (e.g., "poll every 5m /status" on a single thread). Hand-rolled one-shot `ScheduleWakeup` chains are forbidden for recurring polls.
- **`CronCreate` is for cross-session durability or fleet jobs owned by dedicated skills** (`/pr-monitor-and-manage` auto-wake, `/babysit-pr --durable`, etc.) — not `/pm`.

## Rationale

The canonical PM manager use case is **tracking worker output across GitHub-visible artifacts**: issues, feature branches, PRs, review findings, CI state, handoff files, and Phase A/B/C state. The PM may be coordinating multiple coding threads or `/subagent`-launched Phase agents, but `/pm` itself should not arm a recurring poll — that overlaps with `/pr-monitor-and-manage`, which adds per-PR state classification, auto-dispatch to `/fixpr` and `/wrap`, and idle auto-pause.

`/pr-monitor-and-manage` is the built, canonical fleet monitor. Before it existed, `/pm` offered its own `CronCreate`/`/loop` poll; that offer is retired (#522).

`/loop` is still best when the user explicitly requests a session-scoped recurring command:

- lower setup cost,
- easy cancellation,
- already mandated for explicit "poll/check/watch every N" user requests per `scheduling-reliability.md`.

`CronCreate` remains best for skill-owned durable jobs that must survive session turnover.

## State contract: `session-state.json`

PM orchestration reads and writes `~/.claude/session-state.json`. Unknown fields must be preserved. GitHub and handoff files are authoritative when state is stale.

### Fields read

- `monitoring_active`: whether `/pm` is tracking in-flight work (passive/on-demand, not a recurring poll).
- `monitoring_mode`: for `/pm`, always `passive`.
- `root_repo`: absolute path to the **git root** of the repo where PR helpers run (must match `git rev-parse --show-toplevel` for that checkout). Also store the same path on `.prs["N"].root_repo` when multiple PRs/repos share one session file — validate equality before polling so a wrong-repo hazard cannot silently use another checkout.
- `prs`: tracked PR map. Each entry may include `issue`, `phase`, `head_sha`, `reviewer`, `needs`, `status`, `worker`, and `updated_at`.
- `active_agents`: subagent records. Each entry should include `id`, `task`, `issue`, `pr`, `phase`, `launched`, and optional `last_seen_at`.
- `polling_jobs`: active scheduled jobs **owned by other skills** (`/pr-monitor-and-manage`, `/babysit-pr`, etc.). Each entry should include `primitive`, `id`, `cron`, `prompt`, `recurring`, `durable`, `created_at`, and `expires_at` when known. `/pm` does not create or clear this array.
- `polling_failures`: prior dropped-loop recoveries.
- `cr_quota` and `greptile_daily`: review-budget state used by Phase B decisions.
- `pmm_*` fields: owned by `/pr-monitor-and-manage`.

### Fields written

`/pm` updates on demand:

- `last_updated`
- `monitoring_active`
- `monitoring_mode` (`passive`)
- tracked `prs` and `active_agents` when work changes

Skill-owned polling (`/pr-monitor-and-manage`, `/babysit-pr`) updates timing watermarks, `polling_jobs[]`, and `polling_failures[]` per their own contracts.

## Recovery protocol

When a PM session resumes after context turnover:

1. Run the post-compaction/session-start recovery from `monitor-mode.md`: timestamp the first message, read `session-state.json`, read handoff files, then reconcile with live GitHub.
2. Rebuild the active work table from:
   - `prs`,
   - `active_agents`,
   - `~/.claude/handoffs/pr-*-handoff.json`,
   - open PRs and recent merged PRs,
   - open/closed issues referenced by the tracked PRs.
3. If no active workers/PRs remain, set `monitoring_active=false` and stop.
4. `/pm` does **not** restart a `/loop` or `CronCreate` on its own behalf. For between-message PR monitoring, point the user at `/pr-monitor-and-manage`. Jobs in `polling_jobs[]` owned by other skills recover per that skill's contract.
5. Send a concise heartbeat identifying the recovered PRs/workers.

This extends existing recovery; it does not create a second PM-specific recovery path.

## Rule placement

- `scheduling-reliability.md` owns primitive selection for user-invoked recurring commands and pre-exit checks.
- `monitor-mode.md` owns in-turn subagent monitoring and PM orchestration recovery.
- This reference doc records the rationale and state contract.
- No new rule file is needed.

## Skill integration decision

- `/pm`: detects active worker threads after cold start/resume. At ≥3 threads, redirects to `/pr-monitor-and-manage`. Never creates polls. Records passive tracking in `session-state.json`.
- `/pr-monitor-and-manage`: owns PR-fleet between-message polling with `/loop`, optional `CronCreate` auto-wake, per-PR dispatch, and idle auto-pause.
- `/subagent`: when it spawns Phase A/B/C agents, it immediately enters Dedicated Monitor Mode for in-turn orchestration and records state. For between-turn PR fleet monitoring, point the user at `/pr-monitor-and-manage`; for explicit user "poll every N" on non-PR work, use `/loop` per `scheduling-reliability.md`.
- `/status`: remains the default on-demand scan command because it already reconciles PRs, review state, checks, session state, and active agents.
- `/pm-handoff`: captures orchestration state for resume; snapshots any live `polling_jobs[]` owned by other skills for informational continuity but does not instruct the new thread to recreate `/pm` polls.
- `/start-issue`: does not auto-arm monitoring. It creates/starts one coding workflow; monitoring becomes relevant only after a PR, worker thread, or `/subagent` campaign exists.
