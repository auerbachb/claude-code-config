# Claude Code Hooks

This directory contains Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) that automate workflow tasks.

For the full per-event hook roster (canonical source of truth), see [`.claude/reference/diagrams/hook-lifecycle.md`](../reference/diagrams/hook-lifecycle.md).

## Hook Auto-Registration

Hooks are **automatically registered** in `~/.claude/settings.json` on every session start. The `session-start-sync.sh` hook (registered under `SessionStart`) reads `global-settings.json` (the hook manifest) and registers any missing hooks on each session start and resume. Existing hooks and user-customized timeouts are preserved.

**To add a new hook:**
1. Create the script in this directory (`.claude/hooks/`)
2. Add the hook entry to `global-settings.json` at the repo root (use `/path/to/claude-code-config` as the path placeholder)
3. Merge to `main` — the next session start registers it automatically

Shared code that hooks source (rather than run) lives in `lib/` and is deliberately absent from `global-settings.json` — registration matches by basename, so anything listed there would be executed as a hook in its own right.

**Initial setup** is handled by `setup-skills-worktree.sh` (see `SETUP.md`). The ongoing sync is a safety net that catches hooks added after initial setup.

`register-hooks.py` — the helper `session-start-sync.sh` calls — also syncs the top-level **`statusLine`** key by the same rules (issue #779). That key is not a hook event, but its `command` carries the same path placeholder and must resolve to the skills worktree the same way. It is seeded when absent, path-repaired when it points at our own `statusline.sh`, and left completely alone when the user has pointed it at their own script. `--statusline-only` runs that sync without touching hooks; `setup-skills-worktree.sh` Step 6b uses it so install-time and session-start behavior share one implementation. See [ARCHITECTURE.md](../../ARCHITECTURE.md#status-line).

---

## post-merge-pull.sh

Automatically pulls `main` in the root repo after every successful `gh pr merge`. This keeps hardlinked rule files in `~/.claude/rules/` up to date without manual intervention.

**How it works:** When Claude Code runs a Bash command matching `gh pr merge`, this hook detects success and runs `git pull origin main --ff-only` in the root repo (not the worktree). It uses three fallback strategies to locate the root repo:

1. **`$cwd` from the hook input** — resolves the root via `git worktree list` (works when the worktree still exists)
2. **Script path** — walks up from `.claude/hooks/` to find the parent repo (works even if the worktree is gone)
3. **Repo name search** — extracts the repo name from `git remote` and searches common directories (`~/Documents/Develop`, `~/repos`, `~/projects`, `~/src`)

If all strategies fail, a visible warning is printed to stderr instead of exiting silently.

> **Note:** This hook is a safety net, not the primary mechanism. The primary mechanism is the session-start `git pull origin main --ff-only` rule in `CLAUDE.md`, which catches all missed pulls regardless of how a merge happened (web UI, other sessions, hook failures).

This hook is registered automatically — see [Hook Auto-Registration](#hook-auto-registration) above.

### Prerequisites

- `jq` must be installed (`brew install jq` on macOS)
- The repo must have a git remote named `origin` with a `main` branch
- The hook script must be executable: `chmod +x .claude/hooks/post-merge-pull.sh` (the repo tracks it as executable, but some systems may strip the bit on checkout)

## silence-detector.sh + silence-detector-ack.sh

Enforces the 5-minute heartbeat rule. If the agent goes >5 minutes without sending a visible message to the user, a warning is injected into the agent's context after every tool call until a message is sent.

**How it works:** Two hooks work together:
- **`silence-detector-ack.sh`** (Stop hook): Fires when Claude finishes a response. Touches a heartbeat file in `/tmp` to record the timestamp.
- **`silence-detector.sh`** (PostToolUse hook, all tools): After every tool call, checks the heartbeat file's mtime. If >5 min elapsed, injects a warning via `additionalContext` that the agent sees. Below the threshold it injects `Current system time` at most once per `SILENCE_TIME_INJECT_S` (default 60s; marker `/tmp/claude-time-injected-$SESSION_ID`) and emits `{}` otherwise, so tool-call bursts don't re-inject a near-identical timestamp on every call (issue #773).

The heartbeat file is session-scoped (`/tmp/claude-heartbeat-$CLAUDE_SESSION_ID`) and cleaned up automatically by the OS.

These hooks are registered automatically — see [Hook Auto-Registration](#hook-auto-registration) above.

### Prerequisites

- All hook scripts must be executable: `chmod +x .claude/hooks/silence-detector*.sh`

## bgwork-ceiling-arm.sh + bgwork-ceiling-guard.sh

Puts a hard ceiling on chat silence while background work runs (issue #803). The pair above enforces the 5-minute heartbeat *within* a turn; this pair covers what happens *after* one ends — a thread that spawns a subagent, ends its turn, and waits makes no tool calls, so no PostToolUse hook can ever fire for it.

**How it works:** the measurement is not re-implemented. `/tmp/claude-heartbeat-$SESSION_ID` already means "last user-visible message"; what these hooks add is an observer of it that can force a turn, plus a gate making that observer non-optional.

- **`bgwork-ceiling-arm.sh`** (PostToolUse, all tools): records background work — an `Agent` spawn, a `Workflow`, a `Monitor`, or a `Bash` call with `run_in_background: true` — and, while the ceiling is unarmed, injects the exact arming call into context. Arming is recognised by the `--tick` sentinel in the command text, so the ceiling watch is never miscounted as new background work. **Advisory only.**
- **`bgwork-ceiling-guard.sh`** (Stop): returns `decision: block` when background work is in flight and the ceiling is unarmed, so the turn cannot end silently. **This is the enforcement.** Blocking is bounded at 2 consecutive turns (`CLAUDE_BGWORK_MAX_BLOCKS`); past the bound it stands down loudly — stderr, `~/.claude/logs/bgwork-ceiling.log`, and an unguarded marker the arm hook resurfaces on every later tool call.

The armed watch is a `Monitor` running `bgwork-ceiling.sh --tick` on a loop. It prints nothing unless the heartbeat file is genuinely stale, so a thread sending normal heartbeats never sees a message from it, and `persistent: true` means the ceiling is armed **once per session** rather than once per spawn.

All state lives in `/tmp` markers (overridable as a set via `CLAUDE_BGWORK_MARKER_DIR`, which is what the test suites use) and in `.claude/scripts/bgwork-ceiling.sh`, which owns the ceiling duration — no rule file states it. Rationale, the `Monitor`-vs-`ScheduleWakeup`-vs-`CronCreate` call, and the derived-timing invariant: `.claude/reference/bgwork-ceiling.md`.

### Prerequisites

- `jq` must be installed
- `.claude/scripts/bgwork-ceiling.sh` must be present and executable — both hooks exit 0 silently without it, so a checkout missing it degrades rather than breaks

## pause-launch-gate.sh + background-task-complete.sh

These hooks make `/end` and `/pause` cost-quiescent (Issue #1308).

- **`pause-launch-gate.sh`** (PreToolUse): while the current repo/session has an
  active execution pause, rejects Agent, Workflow, Monitor, and background Bash
  starts. Foreground Bash remains available for checkpoint and teardown.
- **`bgwork-ceiling-arm.sh`** (PostToolUse): in addition to its silence-ceiling
  job, captures the exact runtime ID returned by every background-start tool
  and records successful `TaskStop` calls.
- **`background-task-complete.sh`** (SubagentStop): marks the exact agent runtime
  ID done, failed, or stopped. Logical agent names are never used for TaskStop.

An active marker makes the launch gate fail closed if session state becomes
unreadable after activation. Other hook/dependency failures stay fail-open so a
malformed payload cannot brick all tool use.

A registry write failure creates
`claude-background-registry-failed-<session>` in the configured background-work
marker directory (default `/tmp`), falling back to `$HOME/.claude` if that
directory is unwritable. If neither location accepts the marker, the hook exits
non-zero with a critical diagnostic. `/end` and `/pause` treat either
marker as an incomplete audit until runtime inspection proves no untracked task
remains.

**Tests:** `.claude/hooks/tests/pause-lifecycle-hooks.test.sh`

## skill-usage-tracker.sh + skill-command-tracker.sh

Records every skill invocation to `~/.claude/skill-usage.log` (and the aggregate `~/.claude/skill-usage.csv`), which `.claude/scripts/skill-usage-report.sh` rolls up.

Two hooks are needed because invocations arrive two different ways:
- **`skill-usage-tracker.sh`** (PostToolUse, matcher `Skill`): model- and agent-initiated calls, including chip threads.
- **`skill-command-tracker.sh`** (UserPromptSubmit): slash commands the user types. These reach the model already expanded into the prompt and produce no `Skill` tool call, so the PostToolUse hook never sees them — user-typed skills logged nothing at all before issue #584.

Both write through `lib/skill-usage-recorder.sh`, which owns the storage layout and a short-lived marker that keeps an invocation seen by both paths at exactly one line. Design notes and the audit trust boundary: `.claude/memory/skill_usage_telemetry.md`.

### Prerequisites

- `python3` (both hooks) and `jq` (PostToolUse tracker only)
- Registered automatically via `global-settings.json` — see **Hook Auto-Registration** above

## usage-limit-record.sh

Records a durable breadcrumb when a turn dies because the account hit an Anthropic usage limit, so the next session finds a pointer instead of silence (issue #824).

Registered on **`StopFailure`** with matcher **`rate_limit`** — the first use of that event in this repo. The runtime fires `StopFailure` instead of `Stop` when an API error ends a turn, and matches on the payload's `error` field.

**This is a recorder, not a wind-down.** `StopFailure` is documented by the runtime as *"Fire-and-forget — hook output and exit codes are ignored"*, and it fires only after the turn has already failed. The hook therefore cannot warn the session, inject context, or gate any decision — it writes to disk and exits 0.

Claude Code exposes **no** approaching-limit signal to any hook, skill, or session; the only surface carrying `rate_limits` is the status line, which is display-only and never executes in a headless desktop-app session. Full evidence: `.claude/reference/usage-limit-signal-audit-2026-07.md`.

**Safety.** Its sole input is the runtime's own `error` classification. It estimates nothing and gates nothing, so `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" is satisfied as written and was not amended.

**Outputs**

- `~/.claude/usage-limit-events.jsonl` — append-only history, rotated to `.1` past 256 KiB
- `~/.claude/usage-limit-last.json` — the most recent event, written atomically; read this first when resuming

Each record carries `recorded_at`, `session_id`, `cwd`, `transcript_path`, a truncated `last_assistant_message`, a `resume_hint`, and — since issue #1633 — `limit_kind` (`plan_window` | `overage` | `unclassified`) with `reset_at`.

**Which limit was hit.** `error == "rate_limit"` says a limit was hit but not which one, and the two are opposite facts: a plan-window wall (rolling 5-hour or weekly) means the account is on plan and spent nothing, while an overage means it spent. `credit-budget.sh` read every record here as the second and froze autonomous dispatch for a full ET day on four events that were all the first. Classification happens at write time through `.claude/scripts/lib/usage-limit-classify.sh` — the one place the vendor's prose is parsed, shared with that gate. The dependency is deliberately **optional**: with the library absent both fields are null and the record is otherwise unchanged, because a recorder must never become a new failure mode.

### Prerequisites

- `jq` must be installed — the hook exits 0 silently without it
- Override the output directory with `CLAUDE_USAGE_LIMIT_DIR` (used by the tests)

---

## post-compact-reconcile.sh

Emits a deterministic post-compaction reconciliation prompt after every context compaction (issue #813, follow-up from PR #811).

Registered on **`PostCompact`** with a 10 s timeout.

**Why it exists.** `monitor-mode.md` §"Post-Compaction Recovery" requires the agent to reconcile session state after compaction, but today that trigger depends on model judgment: the agent must notice an unfamiliar summary block and decide to run the recovery sequence. A missed or delayed judgment means stale state goes undetected. `PostCompact` fires deterministically after every compaction; this hook guarantees the reconciliation prompt reaches the agent regardless of how clearly the compact summary signals the prior state.

**What it does.** Drains stdin (the `PostCompact` payload, including `compact_summary`), and emits `hookSpecificOutput.additionalContext` with the full Post-Compaction Recovery sequence from `monitor-mode.md`:

1. Timestamp and rerun session-start checks.
2. Read `session-state.json` + handoffs; reconcile each open PR on GitHub.
3. Per polled PR: `polling-state-gate.sh <N> --verify-state`, then `polling-state-gate.sh <N>`.
4. Reconcile state; verify stale agents and stalled transitions; launch as needed.
5. Resume monitoring — one heartbeat line, no report.

When `compact_summary` is present in the payload and `jq` is available, it is appended to the context so the agent has immediate visibility into what the compaction covered.

**It does not replace existing backstops.** On-disk `session-state.json`, per-PR handoff files in `~/.claude/handoffs/`, and `checkpoint-handoff.sh` on `SubagentStop` remain intact. This hook makes the model-judgment trigger in `monitor-mode.md` redundant rather than necessary.

**Evaluation:** `.claude/reference/hook-events-evaluation-2026-08.md` — full analysis of all candidate newer events and their adopt/defer verdicts.

**Tests:** `.claude/hooks/tests/post-compact-reconcile.test.sh`

---

## checkpoint-handoff.sh

Writes a portable handoff document automatically while work is in progress, so `usage-limit-record.sh` has something real to point at when a turn dies without warning (issue #941).

Registered on **`SubagentStop`** with a 15 s timeout.

**Why it exists.** The recorder above names the most recent portable handoff in its breadcrumb, but the only thing that wrote one was invoked by hand. On 2026-08-01 an account limit killed three concurrent sessions and every record came out with `"portable_handoff": null`, because no handoff existed — a limit that arrives without warning is exactly the case where nobody ran the command. This closes the gap from the other side: it produces the artifact and nothing else.

**It is document-only.** No wind-down, no stopping, no decision. The hand-invoked `/end` command keeps its contract — it runs when asked and for no other reason — because this is a different producer of the same artifact, not that command on a timer.

**Safety.** No token, spend, or quota arithmetic anywhere, and no output gates a decision. `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" is satisfied as written and was not amended, the same standing the recorder has.

### The degrade ladder

`portable-handoff-lint.sh` rejects relative `.claude/` paths, phase vocabulary, internal state-file names, slash-command names, missing repository/worktree/Git fields, and unsafe resume guidance. A mechanical renderer walks into several of these: run it in this repo and the changed-file list is full of `.claude/scripts/…`. A human rewrites the offending line; a script cannot.

So it renders, lints, and drops to a less specific rendering on failure, shipping the first tier that passes:

| Tier | Contents |
|---|---|
| 1 | changed-file paths listed, pull request titles quoted |
| 2 | paths replaced by a count and a `git status` instruction |
| 3 | titles dropped — pull requests by number and URL only |
| 4 | minimal: explicit repository/worktree/Git unknowns where necessary, absolute working directory, separate tracked/untracked counts, universal commands, and non-stop resume guidance |

If even tier 4 fails it writes **nothing** — a document that fails its own portability gate is the outcome the ladder exists to prevent. In this repository tier 2 is the normal result.

### Throttle

Writes at most once per `CLAUDE_CHECKPOINT_MIN_INTERVAL` (default 600 s), and additionally whenever the local state fingerprint changes inside that window. Time is the primary trigger: in an orchestration session the parent's own git state barely moves while subagents work in their own worktrees, so a purely fingerprint-gated checkpoint would go stale in the session that most needs a current one. The fingerprint lives in an HTML comment in the document, so this needs no sidecar state file and takes no lock.

### Outputs

- `~/.claude/handoffs/portable-handoff-<stamp>-<session>-checkpoint.md` — matches the glob the recorder already scans

Checkpoints older than 7 days are pruned. A canonical handoff written by `/end` is **never** a deletion candidate at any age — the `-checkpoint.md` suffix is what separates them.

### Prerequisites

- `git` — the hook exits 0 silently without it. `jq` is optional and affects only one line.
- `CLAUDE_HANDOFF_DIR` overrides the output directory (used by the tests)
- Run it by hand with `--stdout` to see what it would write without publishing

**Tests:** `.claude/scripts/tests/checkpoint-handoff.test.sh`, `portable-handoff-context.test.sh`, and `portable-handoff-publish.test.sh`

## spend-session-tracker.sh

Records a **thread-type telemetry** event each time a genuinely new Claude Code session starts. Part of the spend/thread-type telemetry pipeline introduced by Issue #710; pair with `spend-subagent-tracker.sh`.

Registered on **`SessionStart`** with a 5 s timeout.

**What it does:**

- Reads the `source` field from the `SessionStart` payload (`startup`, `resume`, `compact`, `clear`).
- **Only records on `startup` (or absent `source`)** — compact, resume, and clear fire inside an already-live session and must not inflate the thread count. An absent source is treated conservatively as startup for backward compatibility.
- Extracts `session_id` and `model` from the payload; normalises `model` to a family tier (`opus`, `sonnet`, `haiku`, `fable`, `unknown`) via a substring match.
- Appends one TSV line to `~/.claude/spend-telemetry.log` (schema: `ISO8601Z event_type exec_type model_tier agent_type session_id agent_id tokens`). The `agent_type` is always `session`; `agent_id` and `tokens` are always empty for this event.
- Always exits `0` and emits `{}` — never blocks the session.

**Observational-only.** Data produced here MUST NOT gate any agent decision or quota check (`safety.md` §"Anthropic Quota & Spend Authority").

**Shared library:** sources `.claude/hooks/lib/spend-telemetry-recorder.sh` for sanitization, session resolution, and the append write.

**Tests:** `.claude/hooks/tests/spend-telemetry-tracker.test.sh`

---

## spend-subagent-tracker.sh

Records an **inline-type telemetry** event each time an inline `Agent`-tool subagent finishes. Part of the spend/thread-type telemetry pipeline introduced by Issue #710; pair with `spend-session-tracker.sh`.

Registered on **`SubagentStop`** with a 5 s timeout.

**What it does:**

- Reads `session_id`, `agent_id`, `agent_type`, and `agent_transcript_path` from the `SubagentStop` payload.
- Derives model tier from the agent definition frontmatter (`model:` field in `.claude/agents/<agent_type>.md`). Falls back to `unknown` if the file is absent or has no `model:` line. This is a **derived** value, not a runtime measurement — see reliability caveats in `.claude/reference/spend-telemetry-pipeline.md`.
- Best-effort token extraction: if `agent_transcript_path` is set and the file exists, sums `input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens` across all JSONL records with a `usage` key. The `tokens` field is left empty on any parse error or missing file. **Empty ≠ zero spend.**
- Appends one TSV line to `~/.claude/spend-telemetry.log` (same schema as `spend-session-tracker.sh`; `exec_type` is always `inline`).
- Always exits `0` and emits `{}` — never blocks the session.

**Observational-only.** Data produced here MUST NOT gate any agent decision or quota check (`safety.md` §"Anthropic Quota & Spend Authority").

**Shared library:** sources `.claude/hooks/lib/spend-telemetry-recorder.sh`.

**Reporting:** `bash .claude/scripts/spend-telemetry-report.sh [--days N]`

**Schema and caveats:** `.claude/reference/spend-telemetry-pipeline.md`

**Tests:** `.claude/hooks/tests/spend-telemetry-tracker.test.sh`
