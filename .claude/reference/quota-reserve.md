# Quota reserve — pause autonomous work before an account runs dry (#1863)

> **Always:** gate only on the weekly used-percent the provider itself reports. Fail open on anything unreadable or stale. Leave the owner's own interactive turns alone, apart from launches.
> **Ask first:** changing the threshold default, or extending the gate to a window other than the weekly one.
> **Never:** gate on a locally estimated figure, block the ordinary tool calls of a turn the owner started (launches are blocked there too), or stop work on a reading that is not both fresh and known.

The owner runs several paid AI coding accounts and wants headroom left to ask questions before one is exhausted. Once an account's weekly usage reaches the threshold (95% by default), work running unattended on it stops. This is the third carve-out in `.claude/rules/safety.md` §Anthropic Quota & Spend Authority. `/quotas` stays display-only; this feature reads the same provider numbers for a different purpose.

## Owner decisions (2026-10-28, Issue #1863)

| Decision | Choice |
|---|---|
| Window | Weekly only (Claude 7-day, Codex weekly). Five-hour windows are ignored. |
| Scope | Only threads on the account that crossed. |
| In reserve | Autonomous work is blocked; the owner's interactive turns are not. |
| Rule | Amend `safety.md` with a provider-reported-percent carve-out. |
| Coverage | Claude Code now. Codex and Cursor are reported, not stopped. |

## How it works

```
ai-quotas.sh --json  ──▶  quota-reserve.sh --refresh  ──▶  ~/.claude/quota-reserve/marker.json
   (provider-reported)         (every ~10 min, only while a session is active)
                                                                  │
 UserPromptSubmit ─▶ quota-reserve-turn.sh   (records owner turn vs automated turn)
 PreToolUse ───────▶ quota-reserve-guard.sh ─▶ quota-reserve.sh --decide ─▶ allow | exit 2
```

- **No daemon.** The guard notices a marker older than the refresh interval and starts a detached `--refresh`. The marker only matters while sessions run, and sessions are what trigger it.
- **Which account is this session on?** The session's own `.claude.json` (`${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`) carries `oauthAccount.emailAddress`. That is account metadata, not a credential, and it works for the desktop app and for CLI profiles alike. The marker is keyed by the email the provider reports.
- **Fast path.** A fresh marker with no account in reserve costs one `grep` and one `stat` per tool call, with no `jq`.
- **The refresh is quiet.** It runs the reader with its history redirected, so a refresh every few minutes does not bury the daily record `/quotas` projects from.

## What is blocked, in a session on an account in reserve

| Call | Result |
|---|---|
| `Agent`, `Workflow`, `Monitor`, `CronCreate`, `ScheduleWakeup`, `RemoteTrigger`, starting or handing off a session, background `Bash` | Blocked, always. These start autonomous work. |
| Any tool call from a subagent (`agent_id` present) or an automated turn | Blocked, except reads (`Read`, `Glob`, `Grep`, `TaskStop`, `TaskOutput`, `ToolSearch`) and a plain invocation of one of the harness's own bookkeeping scripts (`session-state.sh`, `handoff-state.sh`, `execution-pause.sh`, `quota-reserve.sh`, `bgwork-ceiling.sh`, `issue-claim.sh`), so a pipeline can checkpoint and park. "Plain" means optionally `cd <dir> &&` and `VAR=value` prefixes, then the script and simple arguments, with no chaining, pipes, redirects or substitution. A command that only mentions a script name does not qualify. |
| Anything in a turn the owner started | Allowed, apart from the launches above. |

The block message tells an agent to park: write the handoff and stop, per `subagent-thread-limit-park.md`.

An **automated turn** is one whose prompt arrives wrapped by the app or harness: `<ci-monitor-event>`, `<task-notification>`, `<side-sessions-event>`, `[SYSTEM NOTIFICATION`, `<system-reminder>`, `human-queue: D-`, `[Artifact comment`, scheduled-task wrappers. Everything else is the owner typing. The classification is a heuristic on the leading text; a turn it cannot classify is treated as interactive.

## Resuming

Nothing needs to be switched back. When the provider's reset brings the reading under the threshold, the first refresh after it (started by the next tool call once the marker is ten minutes old) clears the state and the guard allows everything. Parked pipelines resume with `/go-on`. The owner gets a desktop notification once when an account crosses in either direction.

## Fails open

| Condition | Result |
|---|---|
| No marker yet | Allow, and start a refresh. |
| Marker older than the stale limit (30 min) | Allow. A failed refresh does not advance the read time, so a dead reader ages out. |
| Reading unknown (`needs-login`, rate-limited, unreachable) | The account is `unknown`; allow. |
| Session's account not in the marker, or `.claude.json` unreadable | Allow. |
| Hook payload unreadable, script missing, `jq` missing | Allow. |
| `enabled = false` or `QUOTA_RESERVE_ENABLED=0` | Allow. |

## Configuration

`## Quota reserve` in `account-config.md`: `threshold_pct = 95`, `enabled = true`. Environment variables win: `QUOTA_RESERVE_THRESHOLD_PCT`, `QUOTA_RESERVE_ENABLED`. Timing: `QUOTA_RESERVE_REFRESH_SECONDS` (600), `QUOTA_RESERVE_STALE_SECONDS` (1800). Full list: `quota-reserve.sh --help`.

## Not covered, on purpose

- **Codex.** The marker holds the Codex accounts and the notification names them, but nothing stops Codex sessions. Codex has lifecycle hooks and a `queue` command; whether a hook can deny work needs a spike. Tracked in #1867.
- **Cursor.** The IDE has no hook surface, and its limit is a dollar cap, which `review-daily-cap.sh` already watches.
- **A turn already running when the line is crossed.** It keeps the kind it started with. Launches and subagent calls stop at once. An automated turn stops at its next tool call; a turn the owner started carries on, by design.
- **Profiles created before this shipped.** A profile's `settings.json` is a copy. Re-run `/quotas-setup share-config <label>` so it picks up the two hooks.

## Related

`usage-horizon.sh` (the harness's own token horizon, #1427), `subagent-thread-limit-park.md` (parking work killed by a limit), `ai-quotas.md` (the reader), `review-daily-cap.sh` (review spend). **Tests:** `.claude/scripts/tests/quota-reserve.test.sh`, `.claude/hooks/tests/quota-reserve-hooks.test.sh`.
