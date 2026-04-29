# PM Monitoring Primitive Decision

## Decision

Use a **hybrid** PM monitoring model:

- **`/loop` is canonical for user-requested or session-scoped PM monitoring**, especially 1-2 active worker threads where the PM thread remains open and the user wants quick status checks.
- **`CronCreate` is canonical for PM-initiated autonomous campaigns** when either:
  - 3 or more worker threads/PRs are active, or
  - the user asks monitoring to survive session exit/context turnover, or
  - the PM starts work that is expected to outlive the current interactive session.
- **Passive monitoring is only valid when there are no active worker threads, or when the user explicitly chooses passive mode.**

This keeps `/loop` as the default recurring-poll primitive from `scheduling-reliability.md`, while using `CronCreate` only where its durability and fleet-management properties matter.

## Rationale

The canonical PM manager use case is **tracking worker output across GitHub-visible artifacts**: issues, feature branches, PRs, review findings, CI state, handoff files, and Phase A/B/C state. The PM may be coordinating multiple coding threads or `/subagent`-launched Phase agents, but the monitoring loop should not depend on in-memory conversation state.

`/loop` is best when the PM is actively in-session:

- lower setup cost,
- easy cancellation,
- tighter 5-15 minute cadence for active review/merge windows,
- already mandated for explicit "poll/check/watch every N" user requests.

`CronCreate` is best once PM monitoring becomes a small fleet operation:

- runtime-owned cadence survives between user messages,
- optional durable mode can survive session turnover,
- one scheduled PM scan can summarize many PRs without hand-rolled wake-up chains,
- the 7-day expiry bounds stale-job risk.

The threshold is therefore not "PM work always uses Cron"; it is **"PM owns >=3 concurrent worker polls or needs cross-session durability."**

## State contract: `session-state.json`

PM monitoring reads and writes `~/.claude/session-state.json`. Unknown fields must be preserved. The monitoring loop treats GitHub and handoff files as authoritative when state is stale.

### Fields read

- `monitoring_active`: whether any monitor loop should be active.
- `monitoring_mode`: `loop`, `cron`, or `passive`.
- `monitoring_command`: command/prompt to run each tick, usually `/status` until a PM-specific command exists.
- `monitoring_interval_minutes`: intended cadence for `/loop` or human-readable cron cadence.
- `monitoring_durable`: whether the monitor is expected to survive session exit.
- `monitoring_started_at`, `last_poll_at`, `next_expected_poll_at`: timing watermarks.
- `root_repo`: repo path used to run helper scripts.
- `prs`: tracked PR map. Each entry may include `issue`, `phase`, `head_sha`, `reviewer`, `needs`, `status`, `worker`, and `updated_at`.
- `active_agents`: subagent records. Each entry should include `id`, `task`, `issue`, `pr`, `phase`, `launched`, and optional `last_seen_at`.
- `polling_jobs`: active scheduled jobs. Each entry should include `primitive`, `id`, `cron`, `prompt`, `recurring`, `durable`, `created_at`, and `expires_at` when known.
- `polling_failures`: prior dropped-loop recoveries.
- `cr_quota` and `greptile_daily`: review-budget state used by Phase B decisions.

### Fields written

Every polling turn updates:

- `last_updated`
- `last_poll_at`
- `next_expected_poll_at`
- `monitoring_active`
- `monitoring_mode`
- `monitoring_command`
- `monitoring_interval_minutes` or `polling_jobs[].cron`
- `monitoring_durable`

When work changes, the loop also updates:

- `prs[PR].phase`, `head_sha`, `reviewer`, `needs`, `status`, `updated_at`
- `active_agents[]` on launch, completion, exhaustion, or failure
- `polling_jobs[]` after `CronCreate`/`CronDelete`/recovery
- `polling_failures[]` when a dropped loop is detected and re-established

## Recovery protocol

When a PM monitoring loop drops mid-campaign:

1. Run the post-compaction/session-start recovery from `monitor-mode.md`: timestamp the first message, read `session-state.json`, read handoff files, then reconcile with live GitHub.
2. Rebuild the active work table from:
   - `prs`,
   - `active_agents`,
   - `~/.claude/handoffs/pr-*-handoff.json`,
   - open PRs and recent merged PRs,
   - open/closed issues referenced by the tracked PRs.
3. If no active workers/PRs remain, set `monitoring_active=false` and stop.
4. If active work remains and the prior mode was:
   - `loop`: re-establish `/loop` with the recorded cadence, unless the user explicitly chose passive mode.
   - `cron` with `durable=true`: verify the job with `CronList`; create a replacement only if missing.
   - `cron` with `durable=false`: create a fresh session-scoped `CronCreate` job using the recorded cron/prompt if the old session ended.
   - `passive`: keep passive and report that active work exists but monitoring is user-triggered.
5. Append a `polling_failures[]` entry with detection time, prior expected tick, recovery action, and remaining active work.
6. Send a concise heartbeat identifying the recovered PRs/workers and the re-armed primitive.

This extends existing recovery; it does not create a second PM-specific recovery path.

## Rule placement

- `scheduling-reliability.md` owns primitive selection and pre-exit checks.
- `monitor-mode.md` owns in-turn subagent monitoring and recovery behavior.
- This reference doc records the rationale and state contract.
- No new rule file is needed.

## Skill integration decision

- `/pm`: detects active worker threads after cold start/resume. It recommends passive for zero active workers, `/loop` for 1-2 active workers, and `CronCreate` for 3+ workers or requested durability. It should record the selected primitive in `session-state.json`.
- `/subagent`: when it spawns Phase A/B/C agents, it immediately enters Dedicated Monitor Mode for in-turn orchestration and records state. If the user requests between-turn monitoring or the campaign crosses 3 active PRs/workers, it should arm `CronCreate`; otherwise a session `/loop` is sufficient for user-facing recurring status.
- `/status`: remains the default polling command because it already reconciles PRs, review state, checks, session state, and active agents.
- `/pm-handoff`: captures active polling jobs and instructs the next PM thread how to re-establish them.
- `/start-issue`: does not auto-arm monitoring. It creates/starts one coding workflow; monitoring becomes relevant only after a PR, worker thread, or `/subagent` campaign exists.
- New `/pm-monitor` skill: defer. Add it only if `/status` plus `/pm` setup becomes too large or needs a dedicated implementation surface.
