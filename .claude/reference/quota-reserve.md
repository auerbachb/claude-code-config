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
| `Agent`, `Workflow`, `Monitor`, `CronCreate`, `ScheduleWakeup`, `RemoteTrigger`, starting, spawning or handing off a session, moving one to the cloud, creating, running or updating a scheduled task, background `Bash` | Blocked, always. These start autonomous work. |
| Any tool call from a subagent (`agent_id` present) or an automated turn | Blocked, except reads (`Read`, `Glob`, `Grep`, `TaskStop`, `TaskOutput`, `ToolSearch`) and a plain invocation of one of the harness's own bookkeeping scripts (`session-state.sh`, `handoff-state.sh`, `execution-pause.sh`, `quota-reserve.sh`, `bgwork-ceiling.sh`, `issue-claim.sh`), so a pipeline can checkpoint and park. "Plain" means either optionally `cd <dir> &&` and `VAR=value` prefixes then the script run from a `.claude/scripts/` path, or `cd` into a `.claude/scripts/` directory and run the script by name, then simple arguments, with no chaining, pipes, redirects, substitution or newlines. A command that only mentions a script name, or runs a same-named script from elsewhere, does not qualify. |
| Anything in a turn the owner started | Allowed, apart from the launches above. |

The block message tells an agent to park: write the handoff and stop, per `subagent-thread-limit-park.md`.

An **automated turn** is one whose prompt arrives wrapped by the app or harness: `<ci-monitor-event>`, `<task-notification>`, `<side-sessions-event>`, `[SYSTEM NOTIFICATION`, `<system-reminder>`, `human-queue: D-`, `[Artifact comment`, scheduled-task wrappers. Everything else is the owner typing. The classification is a heuristic on the leading text; a turn it cannot classify is treated as interactive.

## Resuming

Nothing needs to be switched back. When the provider's reset brings the reading under the threshold, the first refresh after it (started by the next tool call once the marker is ten minutes old) clears the state and the guard allows everything. Parked pipelines resume with `/go-on`. On macOS the owner also gets a desktop notification once when an account crosses in either direction, on a best-effort basis: a notifier that is missing or fails is ignored, and a crossing is only noticed when a session is active to trigger a refresh. `QUOTA_RESERVE_NOTIFY_CMD` points it at another notifier.

A confirmed Claude reserve crossing uses the same fresh weekly quota read to
suggest the registered Claude launcher with the most room. The notice points
from the stopped account to `/go-on --resume-options --target <launcher>`.
That opens the read-only list with the existing manual commands or handoffs
for that account. It never opens a session or queries a provider again. If all
compatible alternatives are known ineligible, the notice says none has room;
missing, unreadable or stale evidence that could change the choice says
"next account unknown." An unknown reading keeps the last confirmed notice
state only to avoid duplicate alerts; the guard still uses the current reading.

## Fails open

| Condition | Result |
|---|---|
| No marker yet | Allow, and start a refresh. |
| Marker older than the stale limit (30 min) | Allow. A failed refresh does not advance the read time, so a dead reader ages out. |
| Marker dated in the future after a clock rollback | Allow and request a fresh reading. |
| Reading unknown (`needs-login`, rate-limited, unreachable) | The account is `unknown`; allow. |
| Session's account not in the marker, or `.claude.json` unreadable | Allow. |
| Hook payload unreadable, script missing, `jq` missing | Allow. |
| `enabled = false` or `QUOTA_RESERVE_ENABLED=0` | Allow. |

## Configuration

`## Quota reserve` in `account-config.md`: `threshold_pct = 95`, `enabled = true`. Environment variables win: `QUOTA_RESERVE_THRESHOLD_PCT`, `QUOTA_RESERVE_ENABLED`. Timing: `QUOTA_RESERVE_REFRESH_SECONDS` (600), `QUOTA_RESERVE_STALE_SECONDS` (1800). Full list: `quota-reserve.sh --help`.

## Not covered, on purpose

- **Codex.** Weekly readings still appear in the marker and notifications. The reserve does not stop Codex turns; see the #1867 experiment below.
- **Cursor.** The IDE has no hook surface, and its limit is a dollar cap, which `review-daily-cap.sh` already watches.
- **A turn already running when the line is crossed.** It keeps the kind it started with. Launches and subagent calls stop at once. An automated turn stops at its next tool call; a turn the owner started carries on, by design.
- **Programs started inside an owner's foreground shell call.** Background Bash means the harness's `run_in_background` flag. The reserve does not parse arbitrary shell programs or prevent their child processes; the owner's foreground shell remains available. Automated-turn and subagent shell calls still require the bookkeeping allowlist.
- **Profiles created before this shipped.** A profile's `settings.json` is a copy. Re-run `/quotas-setup share-config <label>` so it picks up the two hooks.

## Codex experiment (#1867)

On 2026-11-09, isolated profiles on macOS exercised Codex CLI 0.166.0 and the desktop-bundled 0.167.0-alpha.3.2 binary against a loopback model fixture. The fixture requested a Bash command that wrote a sentinel file. It used no signed-in account or real model traffic.

| Question | Observed result |
| --- | --- |
| Can a hook deny a tool call? | Yes. `PreToolUse` exit 2 prevented the sentinel write on both builds. The allow control and malformed-output control wrote the file. The denied turn still made a second model request in the fixture, so blocking one tool does not pause the turn. [OpenAI Docs: hooks](https://learn.chatgpt.com/docs/hooks#pretooluse). |
| Can the CLI stop a running turn? | `codex queue` delivered text to the isolated server; with `--resume` it could start a queued turn. A queue request during a held turn left that turn active. `codex agents` opens a session browser and rejected a noninteractive `--stop` option. The separate App Server `turn/interrupt` call ended the held turn with `interrupted`. It needs a connection to the server that owns the turn and its thread and turn IDs. [OpenAI Docs: CLI](https://learn.chatgpt.com/docs/cli/reference) and [App Server](https://learn.chatgpt.com/docs/app-server#interrupt-a-turn). |
| Can a hook know the account? | Both builds passed the fixture's `CODEX_HOME` to the hook. That identifies the profile path when the launcher sets it; it does not identify who started the turn or prove which account is signed in. App Server `account/read` with token refresh disabled returned a null account for the isolated profile. A client of an authenticated server can ask for account metadata via that endpoint without parsing credentials; this spike did not query a live account. [OpenAI Docs: account read](https://learn.chatgpt.com/docs/app-server#1-check-auth-state). |
| Does this reach the desktop? | The binary shipped with the desktop app reproduced the allow, deny, and error controls. The app provides hook trust controls in Settings > Hooks. The fixture tested the shipped engine with temporary profiles; it did not test a live desktop schedule. [OpenAI Docs: hook trust](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks). |

In the isolated server, a manual turn, a `turn/start` explicitly tagged as automation, and a turn delivered by `codex queue` ran the same input. Both `UserPromptSubmit` and `PreToolUse` ran in all three cases and exposed the same fields. Neither callback received the caller's turn-origin tag. A shared profile or prompt text cannot distinguish the owner's input from queued work.

Keep Codex reported-only. These hook inputs do not identify which turns the reserve can safely block while allowing the owner’s work. A future launcher could withhold work it can prove is autonomous, or interrupt a turn it owns on a connected App Server, after mapping the profile to a verified quota row. Missing origin, missing account mapping, or a read error must allow normal work.

When rechecking on a later build, use identical prompt text for the manual, automation-tagged, and queued cases, and correlate each hook’s `turn_id` with the server’s turn events. Include a queue request during an active manual turn so a future classifier cannot mistake a queued message for permission to stop the owner’s turn.

## Related

`usage-horizon.sh` (the harness's own token horizon, #1427), `subagent-thread-limit-park.md` (parking work killed by a limit), `ai-quotas.md` (the reader), `review-daily-cap.sh` (review spend). **Tests:** `.claude/scripts/tests/quota-reserve.test.sh`, `.claude/hooks/tests/quota-reserve-hooks.test.sh`.
