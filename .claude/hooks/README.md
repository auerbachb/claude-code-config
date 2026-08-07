# Claude Code Hooks

This directory contains Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) that automate workflow tasks.

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

Each record carries `recorded_at`, `session_id`, `cwd`, `transcript_path`, a truncated `last_assistant_message`, and a `resume_hint`.

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

**It is document-only.** No wind-down, no stopping, no decision. The hand-invoked pause command keeps its contract — it runs when asked and for no other reason — because this is a different producer of the same artifact, not that command on a timer.

**Safety.** No token, spend, or quota arithmetic anywhere, and no output gates a decision. `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" is satisfied as written and was not amended, the same standing the recorder has.

### The degrade ladder

`portable-handoff-lint.sh` rejects relative `.claude/` paths, phase vocabulary, internal state-file names, and slash-command names. A mechanical renderer walks into all of these: run it in this repo and the changed-file list is full of `.claude/scripts/…`. A human rewrites the offending line; a script cannot.

So it renders, lints, and drops to a less specific rendering on failure, shipping the first tier that passes:

| Tier | Contents |
|---|---|
| 1 | changed-file paths listed, pull request titles quoted |
| 2 | paths replaced by a count and a `git status` instruction |
| 3 | titles dropped — pull requests by number and URL only |
| 4 | minimal: absolute working directory, counts, universal commands |

If even tier 4 fails it writes **nothing** — a document that fails its own portability gate is the outcome the ladder exists to prevent. In this repository tier 2 is the normal result.

### Throttle

Writes at most once per `CLAUDE_CHECKPOINT_MIN_INTERVAL` (default 600 s), and additionally whenever the local state fingerprint changes inside that window. Time is the primary trigger: in an orchestration session the parent's own git state barely moves while subagents work in their own worktrees, so a purely fingerprint-gated checkpoint would go stale in the session that most needs a current one. The fingerprint lives in an HTML comment in the document, so this needs no sidecar state file and takes no lock.

### Outputs

- `~/.claude/handoffs/portable-handoff-<stamp>-<session>-checkpoint.md` — matches the glob the recorder already scans

Checkpoints older than 7 days are pruned. A handoff written by the pause command is **never** a deletion candidate at any age — the `-checkpoint.md` suffix is what separates them.

### Prerequisites

- `git` — the hook exits 0 silently without it. `jq` is optional and affects only one line.
- `CLAUDE_HANDOFF_DIR` overrides the output directory (used by the tests)
- Run it by hand with `--stdout` to see what it would write without publishing

**Tests:** `.claude/scripts/tests/checkpoint-handoff.test.sh`
