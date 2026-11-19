# Monitor expiry and re-arm (Issue #2201)

The loaded rule (`scheduling-reliability.md`) says: every `Monitor` can expire — arm it at the maximum `timeout_ms`, pass `persistent: true` only where the tool schema lists it, and re-arm on each expiry notice until the owning workflow ends. This file holds the mechanism behind that sentence.

## Runtime facts

| Kind | Fact |
|------|------|
| Documented | The Claude Code `Monitor` tool takes a deadline (`timeout_ms`): default 5 minutes, maximum 30 minutes. |
| Observed (desktop app Code tab) | The schema is `command` or `ws`, `description`, `timeout_ms` ≤ 1,800,000. **There is no `persistent` parameter.** The tool result says the watch "expires in 30m unless the source ends first; you get one notice at expiry — re-arm if you still need the watch". |
| Observed (other hosts) | A probe recorded a `persistent: true` watch ticking out of turn (`scheduling-failure-modes.md` Pattern 7, the #914 controlled probe). Where the schema lists `persistent`, pass it. |

Evidence: PR #2186's CI took 3h01m; the PR watch and the silence-ceiling watch each expired every 30 minutes and were re-armed by hand six times. A later orchestration run re-armed three watches (PM day tick, silence ceiling, table-freshness floor) about every 30 minutes for hours. Every re-arm worked — and every one depended on the thread acting on a single notice.

Treat every Monitor as expiring. Code that is correct on an expiring runtime is also correct on a persistent one.

## The re-arm procedure

1. Arm with `timeout_ms` at the runtime maximum (1800000 where capped). Pass `persistent: true` only if the schema lists it.
2. When an expiry notice arrives, check the owning workflow's terminal conditions first (table below). Terminal → re-arm nothing; finish that workflow's teardown.
3. Otherwise re-arm **the same command shape** with a fresh generation (where the workflow uses generations), and publish the new task ID through the workflow's existing compare-and-set or guarded publication. Never arm beside a recorded task that may still be live.
4. Re-arming after expiry is automatic recovery: it is silent (`decision-only-output.md`). Surface a line only when the watch cannot be restored.

### The expiry receipt

Most workflows require an exact, successful `TaskStop` of the recorded task before a replacement may be armed, and they rightly refuse to read silence or an "absent" stop error as proof of death. An expired task cannot return a successful stop, so the expiry notice takes its place under a narrow definition:

> An **expiry receipt** is an expiry notice that names the exact recorded task ID while the recorded generation still matches the one that task was armed with.

A receipt substitutes for a successful exact stop of **that one ID** and nothing else. Replacement still goes through the workflow's existing CAS or guarded publication. A notice that cannot be bound — another ID, a newer generation already recorded, a cleared record — is not a receipt: liveness is unknown and the workflow takes its existing stale path.

## Per-workflow terminal conditions

| Workflow | Recorded identity | Terminal — do not re-arm |
|----------|-------------------|--------------------------|
| `/babysit-pr` (EXPIRY MODE) | `.prs[N].babysit.monitor_task_id` + `monitor_generation` | PR merged or closed, hard blocker, `--max-iter`, stable-frozen, `stop_requested`, `cadence_transition` in flight |
| `/pr-monitor-and-manage` main watch | `.pmm_monitor_task_id` + `.pmm_monitor_generation`, under the `.pmm_rearm` claim | `pmm_active` false, `.pmm.stop_requested`, paused (`.pmm.paused_at`), idle limit reached, a pending `.pmm_rearm` claim |
| `/pr-monitor-and-manage` auto-wake | `.pmm.auto_wake_monitor_task_id` + generation | fleet no longer paused, or stopped |
| `/pm day` | day `monitor_task_id` + day generation | day parked, stopped, ended, awaiting manual resume, probe-count bound reached |
| `/leave-by` wind-down (one-shot) | `.leave.winddown_task_id` + `winddown_generation` | check-in already due (run it now instead), leave time passed (retire), generation changed |
| `/subagent` table-freshness floor | `FLOOR_REPO_KEY` + `FLOOR_SESSION` | the round has ended (current board count zero) |
| `/desk` tick | desk `monitor_task_id` + generation | desk stopped or replaced (its own SKILL.md table already re-arms on expiry) |
| Silence ceiling (`bgwork-ceiling.sh`) | the arm hook's armed marker | no background work this thread waits on is still running |

## Detecting a missed re-arm

The expiry notice arrives once. A thread that is mid-turn, compacting, or simply misses it loses the watch with nothing in the watch left to say so. Detectors that do not expire with the watch:

| Detector | Covers | Limit |
|----------|--------|-------|
| `bgwork-ceiling.sh` tick marker + `--check` exit 3 → `bgwork-ceiling-guard.sh` Stop notice | the silence ceiling | Needs a later Stop. One notice per lapse; never a block. |
| `babysit-tick-watchdog.sh` at Stop (and PostToolUse) | `/babysit-pr` watches, via `last_tick_at` vs `max(2 × cadence, 2m)` | Needs a later Stop or tool call. |
| `silence-watchdog.sh` (launchd) | an idle session whose armed ceiling lapsed within two hours | macOS only, optional install; an OS notification, not a turn. |
| `/subagent` Step 8 table-freshness gate | the floor watch | Runs on the thread's next wake-up. |

The ceiling expires on the same schedule as the watches it guards, so it cannot report their death on its own — which is why its liveness is read from outside it. `/pm day` and `/pr-monitor-and-manage` have no Stop-time detector yet; their tick records (`.day.last_tick_at`, `.pmm_last_tick_at`) are the follow-up's inputs.

## Session-id handoff for the ceiling

`bgwork-ceiling.sh --arm-command` must embed the session id the arm hook keys on (the hook payload's `session_id`). Bash and Monitor commands often run without `CLAUDE_SESSION_ID`, and the script used to fall back to `default` — a watch that ran but never counted.

- `session-start-sync.sh` appends `export CLAUDE_BGCEILING_SESSION_ID='<id>'` to `CLAUDE_ENV_FILE` on every SessionStart source (startup, resume, clear, compact, fork), after validating the id (1–256 characters of `[A-Za-z0-9_.-]`). Append only; it never sets `CLAUDE_SESSION_ID`.
- `bgwork-ceiling.sh` resolves `--session`, then `CLAUDE_BGCEILING_SESSION_ID`, `CLAUDE_SESSION_ID`, `CLAUDE_CODE_SESSION_ID`. `--arm-command` and `--check` **exit 4** when none resolves, and reject an empty or flag-looking `--session`.
- **Degraded mode.** A host without `CLAUDE_ENV_FILE` (the desktop app may be one) gets no export and no notice — the script's exit 4 is the loud signal. A host that offers the file but cannot be written, or a payload with no usable id, adds a one-line `SESSION ID HANDOFF DEGRADED` notice to the SessionStart context. Either way, the exact command in the bgwork-ceiling hook advisory always carries the right id.
- The arm hook names a watch pinned to another session: "targets session X; this session is Y".

## Open questions

To confirm on a live desktop session: whether `CLAUDE_ENV_FILE` is provided and sourced into Bash and Monitor commands; the exact expiry-notice text and whether it names the task ID; whether a Stop `additionalContext` notice is visible to the user.
