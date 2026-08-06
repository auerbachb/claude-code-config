# Hook Events Evaluation — 2026-08

**Question (issue #813, follow-up from PR #811):** Which of the newer Claude Code hook events map precisely onto things we currently detect indirectly, and which should be wired now versus deferred?

**Verdict summary:**

| Event | Verdict | Action |
|---|---|---|
| `PostCompact` | **Adopt** | New hook `post-compact-reconcile.sh` (this PR) |
| `SubagentStop` | **Partially adopted** | `checkpoint-handoff.sh` already wired (PR #941); bookkeeping aspect deferred |
| `SubagentStart` | **Defer** | `bgwork-ceiling-arm.sh` covers this more broadly |
| `PreCompact` | **Defer** | No meaningful pre-compaction action available |
| `CwdChanged` | **Defer** | No cached state to update; per-call re-derivation is correct |
| `WorktreeCreate` | **Defer** | Wrong semantics for our use case |
| `WorktreeRemove` | **Defer** | Observability-only; low ROI |
| `InstructionsLoaded` | **Defer** | Double-loading already solved statically |

---

## Audit record

| | |
|---|---|
| Runtime | **Claude Code 2.1.221** |
| Event catalog source | Binary strings audit, re-audit 2026-08-05 (`usage-limit-signal-audit-2026-07.md`) |
| Events confirmed | All 32 events on 2.1.221 (see §Event catalog) |
| Audited | 2026-08-05 |
| Linked PR | #1028 (re-audit confirming catalog), #811 (SessionStart migration), #941 (SubagentStop wiring) |

---

## Event catalog (confirmed on 2.1.221)

The binary audit in `.claude/reference/usage-limit-signal-audit-2026-07.md` enumerated all 32 hook events. The full set is:

`ConfigChange`, `CwdChanged`, `DirectoryAdded`, `Elicitation`, `ElicitationResult`, `FileChanged`, `InstructionsLoaded`, `MessageDisplay`, `Notification`, `PermissionDenied`, `PermissionRequest`, `PostCompact`, `PostToolBatch`, `PostToolUse`, `PostToolUseFailure`, `PreCompact`, `PreToolUse`, `SessionEnd`, `SessionStart`, `Setup`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop`, `TaskCompleted`, `TaskCreated`, `TeammateIdle`, `UserPromptExpansion`, `UserPromptSubmit`, `WorktreeCreate`, `WorktreeRemove`, `terminal`.

All eight candidate events (`WorktreeCreate`, `WorktreeRemove`, `CwdChanged`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`, `InstructionsLoaded`) are confirmed present in the catalog. No candidate is wired against an event that doesn't exist.

**Shared hook payload base** (confirmed on 2.1.221 via `Hm()` — identifier changes each build):
```js
{ session_id, transcript_path, cwd, prompt_id, permission_mode, agent_id, agent_type, effort }
```
Per-event payloads extend this with event-specific fields documented below.

---

## Per-event analysis

### PostCompact — ADOPT

**What it replaces:** The "notice an unfamiliar summary block" heuristic in `monitor-mode.md` §"Post-Compaction Recovery". Today's recovery trigger is entirely model-judgment: the agent must notice that a summary block references prior work it doesn't remember and then decide to run the reconciliation sequence. This is a judgment call that can be missed, delayed, or executed incompletely.

**Payload:** Extends the shared base with `compact_summary` (the summary text produced by compaction). No blocking control — the hook cannot prevent compaction or change the summary. Output via `hookSpecificOutput.additionalContext` is the correct channel.

**Firing semantics:** Fires deterministically after every compaction. Unlike `SessionStart` (which fires on compact events too, per its `source` field), `PostCompact` is specific to compaction and carries the compact summary — it is the right event for exactly this trigger.

**What we build:** `post-compact-reconcile.sh` — a `PostCompact` hook that emits `additionalContext` instructing the agent to run the Post-Compaction Recovery sequence from `monitor-mode.md`. The existing compaction-agnostic backstops (`checkpoint-handoff.sh` on SubagentStop, on-disk session-state, handoff files) remain intact as backstops; this hook only makes the reconciliation trigger deterministic.

**Why now:** Direct, low-risk, clearly better than the status quo. The current model-judgment trigger can silently fail; a deterministic event cannot.

---

### SubagentStop — PARTIALLY ADOPTED

**Current wiring:** `checkpoint-handoff.sh` registered on `SubagentStop` since PR #941. This hook writes a portable handoff document automatically after every subagent completion, ensuring the breadcrumb `usage-limit-record.sh` points to is on disk when the recorder looks.

**What the CR plan also suggested:** Pruning/annotating `active_agents[]` in `session-state.json` to replace text-based exit-report parsing in the monitor loop.

**Why the bookkeeping aspect is deferred:**

1. **Race condition risk.** The parent monitor loop manages `active_agents[]` directly via `session-state.sh`. A SubagentStop hook running concurrently with the parent's own state updates creates a write-lock race that `session-state.sh` mitigates with advisory locking but does not fully prevent at the per-field level. The current model — parent owns `active_agents[]` exclusively — is architecturally cleaner.

2. **agent_id matching is not reliable across all spawn shapes.** The hook payload carries `agent_id` for the completed subagent, but the parent's `active_agents[]` entries may have been indexed by task id or other identifiers depending on the spawn path. Wiring a removal on `agent_id` alone risks stale entries.

3. **The primary gap was already filled.** The usage-limit breadcrumb-pointing problem that motivated issue #941 is solved. The remaining bookkeeping use case is incremental improvement to the monitor loop, not a reliability fix.

**Re-check trigger:** Wire the bookkeeping aspect when (a) the parent explicitly annotates spawned agents with a stable id that matches `agent_id` in the hook payload, and (b) `session-state.sh` gains per-key conditional-update support to avoid write-lock pressure from hook executions.

---

### SubagentStart — DEFER

**What it could replace:** The spawn detection in `bgwork-ceiling-arm.sh`, which identifies background work by matching tool names (`Agent`, `Workflow`, `Monitor`) and payload shape (`run_in_background: true` on Bash) in `PostToolUse`.

**Why defer:**

1. **bgwork-ceiling-arm.sh is more complete.** It handles `Monitor` and backgrounded `Bash` — neither of which fires `SubagentStart`. A SubagentStart hook would require the ceiling arm hook to persist anyway for non-subagent background work.

2. **Double-firing risk.** If we register on SubagentStart AND keep arm on PostToolUse for non-subagent cases, an Agent spawn fires both. Removing the Agent case from PostToolUse would require careful arm-hook surgery.

3. **Nested subagent ambiguity.** SubagentStart fires inside the subagent's own session context for its own sub-subagents — not only in the parent. A hook registered globally would trigger for both, requiring session-id filtering that introduces complexity and fragility.

**Re-check trigger:** Wire if (a) bgwork-ceiling-arm.sh is refactored to use SubagentStart for the Agent case specifically, and (b) non-subagent background work (Monitor, backgrounded Bash) gets its own event or remains on PostToolUse.

---

### PreCompact — DEFER

**What it could do:** Run a script immediately before compaction starts.

**Why defer:**

1. **No meaningful action available.** Compaction is not blocking — a PreCompact hook cannot prevent it, choose a different compact strategy, or inject content that survives compaction. The only real option is to write something to disk before the compaction truncates context.

2. **checkpoint-handoff.sh already covers this.** It writes a portable handoff document on every SubagentStop. Since compaction typically happens during active orchestration sessions (when subagents are completing work), the checkpoint is nearly always fresh. A PreCompact hook would duplicate this effort.

3. **No payload advantage.** PreCompact carries no context that PostCompact doesn't — and PostCompact additionally carries `compact_summary`, which is what we actually need for the reconciliation reminder.

**Re-check trigger:** Wire if a specific pre-compaction action that cannot be done post-compaction is identified.

---

### CwdChanged — DEFER

**What it could replace:** Per-call `git rev-parse`/`branch --show-current` re-derivation in `worktree-guard.sh` and `stale-worktree-warn.sh`.

**Why defer:**

1. **No cached cwd state to update.** Both hooks re-derive the current branch on every call because they need the *current* state of the worktree at the time of the tool call or prompt. A CwdChanged hook that updates a cached value would add a race condition (hook fires → cached value written → guard reads stale cached value before the write).

2. **stale-worktree-warn.sh fires on UserPromptSubmit.** This is the correct time — before the agent acts on a prompt about an issue. A CwdChanged hook would fire on directory changes that happen mid-turn (e.g., during a Bash `cd`), which is neither necessary nor useful for stale-worktree detection.

3. **Payload is `old_cwd`/`new_cwd` only.** This tells us where we moved but not whether the new directory is a worktree, which branch it's on, or whether it matches the task issue. The hooks still need git calls — CwdChanged would add a trigger without reducing the work.

**Re-check trigger:** Wire if we build an explicit cwd-state cache that hooks can reliably update and guards can safely read.

---

### WorktreeCreate — DEFER

**What it could replace:** `repair-worktrees.sh` git polling and manual worktree bookkeeping.

**Why defer:**

1. **Wrong semantics for our use case.** `WorktreeCreate` is documented as an event where the hook *creates* the worktree and *returns the created path* — it is a creation-delegation hook, not a creation-observation hook. Our worktrees are created via `EnterWorktree` (the SDK tool) or by git directly; intercepting creation to return a path we didn't choose would conflict with that flow.

2. **repair-worktrees.sh is a maintenance utility, not an automation.** It is run explicitly when worktree bookkeeping is suspected stale. An event-driven replacement would need to handle the full worktree lifecycle (create → track → remove), which is a substantially larger scope change.

3. **CLAUDE.md already governs worktree creation.** The instructions there (EnterWorktree + branch naming + worktree removal after merge) are model-carried. A hook that intercepts creation would need to be harmonized with those instructions without making the two incoherent.

**Re-check trigger:** Wire if we want to enforce branch-naming conventions or automatic session-state registration at worktree creation time.

---

### WorktreeRemove — DEFER

**What it could replace:** Manual `git worktree remove` step after PR merge (CLAUDE.md §"Worktree cleanup").

**Why defer:**

1. **Observability-only event.** `WorktreeRemove` fires after a worktree is removed. It cannot prevent the removal or restore anything. The only action it could take is cleanup of state bookkeeping after the fact.

2. **Low ROI.** Worktree cleanup is already well-handled: merge → `/wrap` Phase 5 → `git worktree remove`. The cleanup step is model-driven and not a reliability problem.

3. **The hook would fire in the removed worktree's context.** By the time it fires, the worktree directory is gone. Any state cleanup (session-state entries, handoff files) would need to operate on paths that may no longer exist, requiring careful dead-path handling.

**Re-check trigger:** Wire if worktree removal triggers a specific cleanup action that the current model-driven approach misses (e.g., automatic handoff file deletion at worktree removal time).

---

### InstructionsLoaded — DEFER

**What it could replace:** The static `claudeMdExcludes` in `.claude/settings.json` that prevents double-loading of `CLAUDE.md` and `.claude/rules/*.md` when working inside this repo (`.claude/reference/double-loading-fix.md`).

**Why defer:**

1. **Double-loading is already solved statically.** The `claudeMdExcludes` approach prevents the loading entirely rather than detecting it after the fact. An `InstructionsLoaded` hook could detect double-loading and warn, but it cannot undo an already-loaded instruction set.

2. **Telemetry-only value.** The main use case is observability: knowing which rule files actually loaded per project session. This is useful for data-driven corpus cuts but not a correctness concern — and the information could be obtained more directly from the existing session state.

3. **P3 priority.** The repo-audit-2026-05.md (Section B, item #9) already classified this as "dev-only, P3." Nothing has changed to raise its priority.

**Re-check trigger:** Wire if we build a per-project instruction-loading telemetry system, or if double-loading resumes as a correctness problem.

---

## What was built

### post-compact-reconcile.sh (new)

Registered on `PostCompact` with a 10 s timeout. Drains stdin, optionally reads `compact_summary` from the payload, and emits `hookSpecificOutput.additionalContext` directing the agent to run the Post-Compaction Recovery sequence in `monitor-mode.md`.

The hook does not replace existing backstops (on-disk `session-state.json`, handoff files, `checkpoint-handoff.sh` on SubagentStop). It makes the model-judgment trigger in `monitor-mode.md` redundant for the case where compaction actually fired.

**Tests:** `.claude/hooks/tests/post-compact-reconcile.test.sh`

---

## What NOT to change

- `bgwork-ceiling-arm.sh` / `bgwork-ceiling-guard.sh` — the ceiling apparatus handles non-subagent background work that SubagentStart would miss. Do not refactor these in pursuit of SubagentStart parity without covering Monitor and backgrounded Bash.
- `claudeMdExcludes` in `.claude/settings.json` — do not remove this static fix in anticipation of an InstructionsLoaded hook. The static fix is reliable and zero-cost; a hook-based detection is not an improvement.
- `stale-worktree-warn.sh` — do not rewire this to CwdChanged. UserPromptSubmit is the correct firing time for stale-worktree detection.

---

## Re-check triggers

| Event | Re-check when |
|---|---|
| `SubagentStop` (bookkeeping) | Parent annotates agents with stable id matching hook `agent_id`; `session-state.sh` gains conditional-update |
| `SubagentStart` | `bgwork-ceiling-arm.sh` refactored to SubagentStart for Agent case; non-Agent bg work gets own event |
| `PreCompact` | Specific pre-compaction action identified that PostCompact cannot cover |
| `CwdChanged` | Explicit cwd-state cache built for guards to read |
| `WorktreeCreate` | Branch-naming enforcement or auto session-state registration at creation time needed |
| `WorktreeRemove` | Specific cleanup action identified that model-driven path misses |
| `InstructionsLoaded` | Per-project instruction telemetry system built, or double-loading recurs as correctness problem |

---

## Related

- Issue #813 — this evaluation
- PR #811 — SessionStart migration (the predecessor that prompted this follow-up)
- PR #941 — SubagentStop / checkpoint-handoff.sh (already wired before this evaluation)
- PR #1028 — binary re-audit confirming 32-event catalog on 2.1.221
- `.claude/reference/usage-limit-signal-audit-2026-07.md` — event catalog and binary audit methodology
- `.claude/reference/double-loading-fix.md` — InstructionsLoaded static fix background
- `.claude/reference/bgwork-ceiling.md` — SubagentStart/Stop ceiling rationale
- `.claude/rules/monitor-mode.md` §"Post-Compaction Recovery" — the sequence PostCompact hook now triggers deterministically
