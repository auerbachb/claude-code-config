# Background-Work Silence Ceiling — Mechanism & Rationale

> Reference material for `.claude/rules/scheduling-reliability.md`, `.claude/rules/monitor-mode.md`, and `.claude/rules/subagent-orchestration.md`. Not auto-loaded. Issue #803.

## The hole this closes

The historical five-minute narration rule has been superseded by `decision-only-output.md`. This watch now prompts a decision check and observes child artifacts; quiet, healthy work needs no routine status. The original gap was background work waiting between turns, where PostToolUse cannot run.

| Piece | What it does | Why it missed this case |
|-------|--------------|-------------------------|
| `silence-detector.sh` | PostToolUse; injects a warning once the heartbeat file is >5 min stale | Fires **after a tool call**. A thread waiting on a completion notification makes none. |
| `silence-detector-ack.sh` | Stop hook; touches `/tmp/claude-heartbeat-<id>` on every visible response | Records the measurement; cannot act on it. |
| `silence-watchdog.sh` | launchd; reads the same file out-of-turn | Can only raise an **OS notification** — it has no path back into the thread. Its inactive-background-work exception now retains desktop notifications; it still cannot inject a turn. |

The single underlying cause: **printing a message requires a turn, and nothing in the spawn path guaranteed a turn would ever happen.** The rules were strict about this for user-facing polls — never promise "I'll check back in N minutes" without a real timer — but monitoring background work was never classified as polling, so spawning a subagent armed nothing.

## What was added

Nothing re-measures silence. `/tmp/claude-heartbeat-<session-id>` already means "time of last user-visible message", and it stays the single source of truth. What was missing was a **turn-independent observer of it that can force a turn**, plus a gate that makes arming that observer non-optional.

- **`.claude/scripts/bgwork-ceiling.sh`** — sole owner of the ceiling number, the derived trip point and poll interval, and the session markers. Full contract: `bgwork-ceiling.sh --help`.
- **`.claude/hooks/bgwork-ceiling-arm.sh`** (PostToolUse, all tools) — records background work, and injects the exact arming call while the ceiling is unarmed. Advisory.
- **`.claude/hooks/bgwork-ceiling-guard.sh`** (Stop) — returns `decision: block` when background work is in flight and the ceiling is unarmed, so the turn cannot end silently. Enforcement.

## Why `Monitor`, and not `ScheduleWakeup` or `CronCreate`

The issue left this open. All three create turn boundaries; only one satisfies every constraint at once.

| Primitive | Verdict |
|-----------|---------|
| `ScheduleWakeup` | **Rejected.** It is the `/loop` dynamic-mode scheduler — its `prompt` parameter is the /loop input to re-fire. It is not available in a plain coding thread, which is exactly where the hole is. |
| `CronCreate` | **Rejected.** It fires on wall-clock cadence whether or not the thread is actually silent, so healthy quiet work would receive unconditional prompts. Its jitter (up to 10% of the period) eats into the ceiling, it only fires while the REPL is idle, and `durable: true` is a documented no-op — it is session-only regardless. |
| `Monitor` | **Chosen.** An out-of-turn process whose stdout lines become chat events. |

`Monitor` wins on four properties the other two cannot supply together:

1. **Turn-independent.** The watch is an OS process, not a scheduled prompt. It runs while the thread has no turn at all — the failing case.
2. **Conditional.** Parent-silence checks and child-progress observations run independently. They emit only deduplicated investigative notices; the caller applies the output policy. A fresh parent does not hide a quiet child.
3. **Armed once per session.** `persistent: true` covers the whole session, so the ceiling is armed on the first background work and every later spawn is already covered. This also sidesteps having to detect *completion* of background work — the watch stays correct whatever the cause of silence.
4. **Out of reach of stable-state backoff.** `scheduling-reliability.md` widens polls to 5m/15m and calls `CronDelete` at streak ≥9. Those operate on cron jobs; a `Monitor` is stopped only by `TaskStop`. Backoff therefore *structurally* cannot push silence past the ceiling — no prose carve-out required.

## Why the number is not published

The ceiling is a backstop that must never read as a target. Publishing two cadences invites the looser one to become the norm: a rule saying "no longer than 20 minutes" quietly authorises 19 minutes of silence, which is worse than what the rules say today. So `CEILING_S_DEFAULT` lives in `bgwork-ceiling.sh` and nowhere else, and every rule file says "the ceiling" or names the script. The number measures a decision-check backstop, not a narration cadence or child-health guarantee.

## Derived timing, not three independent knobs

```
CEILING_S = 1200   # parent-silence decision backstop
CEILING_MARGIN_S = 90
CEILING_POLL_S = 30
TRIP_S = CEILING_S - CEILING_MARGIN_S = 1110
```

The watch trips at `TRIP_S`, not at the ceiling. Worst case, a breach begins just after a poll, so it is detected `TRIP_S + CEILING_POLL_S = 1140s` in — leaving 60s for the model to assess evidence and surface a required notice. Deriving the trip point from the ceiling keeps that invariant true for any `CLAUDE_BGWORK_CEILING_S` override; the test suite asserts `trip + poll <= ceiling` rather than asserting the literals, so the invariant survives retuning.

## Fail-closed, bounded, never silent

`feedback_guard_must_fail_closed.md`: a guard that no-ops on failure turns a bounded operation into an unbounded one. Applied here:

- The **default** is to block. An unarmed turn end does not merely warn.
- Blocking is **bounded** at `CLAUDE_BGWORK_MAX_BLOCKS` (2) consecutive turns — an unbounded block would hang the thread.
- Past the bound the guard **stands down loudly**: stderr line, `~/.claude/logs/bgwork-ceiling.log` entry, and a `claude-bgceiling-unguarded-<id>` marker that the PostToolUse hook resurfaces on *every* later tool call. The thread is never quietly unguarded.
- If the block counter itself cannot be written, the guard refuses to start an unbounded block loop and says so on stderr rather than silently passing.
- `bgwork-ceiling.sh --note-started` exits 5 on an unwritable marker instead of degrading. This is the deliberate opposite of `silence-detector.sh`'s time-injection dedupe, which fails *open* — that one loses a convenience, this one loses the guarantee.
- The arm advisory is rate-limited to keep a burst of tool calls from replaying it into context — but the rate limit is **bypassed** once the guard has stood down. Throttling the only remaining signal on an already-unguarded thread would be the same silent degradation the change exists to remove.

### Arming is matched on the whole command, not a substring

The arm hook recognises the watch by regenerating `--arm-command` and requiring the tool's command to *contain that entire string*, rather than by looking for a `--tick` substring. A guard that can be satisfied by talking about it is not a guard: in this repo, commands that merely mention the watch are routine (a grep, a docs edit, a test run), and any of them would otherwise have marked the session armed with no watch actually running. Regenerating the expected command also keeps detection in step with `--arm-command` automatically if its shape changes.

## Session markers

All under `/tmp` (per `feedback_hook_storage_location.md`: ephemeral per-session sentinels), overridable as a set via `CLAUDE_BGWORK_MARKER_DIR` so the test suites never touch live state.

| Marker | Meaning | Written by |
|--------|---------|-----------|
| `claude-heartbeat-<id>` | Last user-visible message | `silence-detector-ack.sh` (read-only here) |
| `claude-bgwork-<id>` | Background work has started; one line per kind | `--note-started` (read-only by `silence-watchdog.sh`) |
| `claude-bgceiling-armed-<id>` | The ceiling watch is armed | `--record-armed` |
| `claude-bgceiling-emitted-<id>` | Heartbeat mtime of the last reported breach | `--tick` |
| `claude-bgceiling-advised-<id>` | Last time the arm advisory was injected | arm hook |
| `claude-bgceiling-blocks-<id>` | Consecutive blocked turn ends | guard hook |
| `claude-bgceiling-unguarded-<id>` | The guard stood down; thread is unguarded | guard hook |

Breach reporting is deduped on the heartbeat's mtime, so a single stretch of silence produces one message rather than one per poll. When the agent finally speaks, the Stop hook re-stamps the heartbeat, the mtime changes, and the next genuine breach is reportable again — the same shape as `silence-watchdog.sh`'s `already_alerted` state.

## Compaction

Neither half lives in context: the watch is a process, the state is `/tmp` markers. A thread that compacts mid-wait keeps both, so the ceiling holds across compaction with no recovery step. This is why the ceiling is *not* recorded in `session-state.json` — putting it there would add a reconciliation path that the design does not need.

## Known limits

- **Session-scoped.** The watch dies with the session. That is the right scope — a dead session has no chat to go silent in — but it means the ceiling is not a cross-session guarantee.
- **The arm hook advises; only the Stop hook enforces.** A harness that ignored `decision: block` on Stop hooks would reduce this to the advisory layer. The bounded-block behavior is written so that outcome is loud rather than silent.
- **`silence-watchdog.sh` gap 2 closed (issue #809).** The watchdog now fires an OS notification for the marker-absent-with-background-work case: when `claude-active-<id>` is absent but `claude-bgwork-<id>` is present and the heartbeat is genuinely stale, the watchdog falls through to its normal staleness evaluation and notifies. It consults `bgwork-ceiling.sh --status` (read-only) as the primary check, with a direct `claude-bgwork-<id>` existence check as a fallback when `bgwork-ceiling.sh` is unavailable. This closes the gap where an unarmed or pre-hook session would produce no desktop notification.
- **Gap 1 remains deferred.** Injecting *into* a stalled session from the launchd watchdog — forcing a chat turn without user action — is still unsupported. No harness API exists for this today: the SDK `send`/`stream` methods were removed; Channels is a research-preview MCP bridge not usable from a launchd script; IPC/tmux are community-only. The watchdog's action stays an OS notification only.


## Child progress and coverage (Issue #1977)

The existing `--tick` invokes `lib/bgwork-child-progress.py` before every parent-heartbeat early exit. It reads the canonical atomic registry document (8 MiB bound) and selects exact-session Agent rows across repo scopes. It correlates `(repo, session_id, task_id, started_at)`; no ambient working-directory guess substitutes for ownership. It never changes the registry, generation, runtime status or a watch. The private observer cache holds only identities, artifact stat fingerprints, observation times and dedup reasons. It is not an authorization or completion record.

Each observation is bounded at three seconds, 200 live Agent rows and 256 KiB notice output. A hung filesystem/registry read kills only the probe process group and emits unknown. A UID-verified 0700 non-symlink `claude-bgprogress-SESSION.d` directory holds600-mode cache/diagnostic/dedup files. Private reads and locks refuse symlinks, nonregular files, hardlinks and unsafe ownership/modes; writes use private temporary files and atomic entry replacement, never truncating a symlink target. `diagnostic` retains fixed error classes and `unknown` deduplicates failed probes. Unwritable cache/dedup storage produces a diagnostic and may repeat the notice. Parent-silence markers retain their existing independent dedup and exit contracts.

An Agent's declared output/checkpoint files must be readable regular files. Stat fingerprints are hashed; raw artifact paths and generation strings are not repeatedly copied into the cache. The publisher enforces the same 1MiB bound as its reader, including 200 children with long Unicode paths. Changed device/inode, size or nanosecond mtime is activity, not proof of useful progress. After an observed unchanged interval of `BGWORK_CHILD_STALL_S` (default 900 seconds), `CHILD STALL SUSPECT` requests investigation. It never proves a crash and never permits stop/respawn. Missing, malformed, unreadable, future-dated or uncertain evidence produces `CHILD PROGRESS UNKNOWN`. A CPU-bound silent child may be healthy: investigate it rather than terminating it. The first observation starts the interval; no pre-observation history is invented. Changed evidence clears the stretch; terminal/disappeared identities are removed from this cache, and a new generation starts independently. `stop_failed` stays observable. A `rearming` reservation is excluded just as in the registry's live-task contract; it is not a running runtime identity.

| Path | Evidence/check | Limit |
|---|---|---|
| In-turn required notice | Real silence detector decision instruction, raw silence log and acknowledgment | Hook supplies context; it does not classify user text or recovery itself |
| Parent quiet between turns | Existing armed ceiling and independent heartbeat-mtime dedup | Fresh parent never proves child health; a listed armed marker alone does not prove the process is ticking |
| Agent quiet while parent polls, including PMM Step5e | Bounded child artifact observation in every ceiling tick | Suspect/unknown requires runtime investigation, never automatic termination |
| Phase A/B/C orchestration | Existing phase-age investigation thresholds plus exact-runtime correlation | Phase age alone is not a crash verdict |
| Frozen PR polling | Existing digest streak/backoff and frozen-stop checks | Describes PR state, not an executing child's health |
| Bash, Workflow and Monitor tasks | Existing runtime-result/watch ownership and ticking checks | Agent artifact check deliberately does not label quiet watchers stalled; missing registry rows are not proof of health |
| Missing/corrupt inventory, artifact or observation | Unknown notice, retained diagnostic and existing gate refusal | Silence is not a passing result |

No scheduler, new persistent watch, runtime stopping, summarizer or unchanged-tick inference gate is introduced. Issue #1878 owns inference filtering. Other historical narration consumers (such as older table-floor and unrelated skill examples) remain subject to the canonical policy; this change does not claim every installed prompt has been reconciled. Tests cover emitted instructions through real hooks, not model-side semantic classification or measured token savings.

### Child notice delivery and dedup publication

The observer stages private `pending-cache.json` and bounded UTF-8 notices. The
parent verifies the output and candidate state, checks accepted byte counts at
both stages, then writes and flushes notices to
its immediate caller, then publishes the dedup cache. Oversized output, an
interrupted observer or failed delivery cannot record an undelivered notice as
already emitted. Later ticks retry from the previous cache; a failure after
delivery but before publication may repeat a notice. This is at-least-once
delivery at the caller boundary, not an acknowledgment from the ultimate UI.
Pending state is not authoritative; `--clear` removes it. The existing200-child,
256KiB notice,1MiB cache and3-second probe bounds remain. Overflow stays unknown
and retains previous dedup state; it does not certify progress or stop a child.
