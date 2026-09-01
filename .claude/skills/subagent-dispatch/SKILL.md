---
name: subagent-dispatch
description: Use when designing a parallel agent dispatch, deciding whether to parallelize work, or writing isolated subagent prompts. Teaches the prompt-crafting discipline for independent parallel agents in the Phase A/B/C model.
triggers:
  - dispatch parallel agents
  - parallel dispatch
  - should I parallelize
  - write isolated subagent prompt
  - one agent per domain
  - parallel subagents
argument-hint: "(no arguments — describe the work you want to parallelize)"
---

<!-- Adapted from obra/superpowers @ b36e0829: skills/dispatching-parallel-agents/SKILL.md -->
<!-- Adapted to auerbachb/claude-code-config Phase A/B/C model. -->

**Core principle: one agent per independent problem domain.**

This skill teaches the _craft_ of designing and writing independent parallel-agent prompts. Spawn mechanics, model selection, and Phase A/B/C orchestration are in `.claude/rules/subagent-orchestration.md` — do not duplicate them here.

---

## Step 1: Decide Whether to Parallelize

Run this decision tree before dispatching anything.

```
Multiple tasks?
 └─ Are failures/tasks related?
     ├─ YES (related) → Single agent investigates all
     └─ NO (independent) → Can they work without shared state?
         ├─ NO (shared state, e.g. same file) → Sequential agents
         └─ YES (no shared state) → Parallel dispatch
```

**Parallelize when:**
- Tasks span different subsystems, files, or problem domains
- Each task can be understood without context from the others
- Agents will not edit the same files or shared state
- The ceiling allows it (see Step 2)

**Do NOT parallelize when:**
- Failures are related (fixing one may fix others — investigate first)
- Agents would write to the same files, branch, or session state
- You don't yet know what's broken (explore first)
- The pipeline ceiling is already full

**This repo's vocabulary:** `/wave` calls this the "dependency- and overlap-filtered independent set"; `/subagent` calls it "disjoint chains run as parallel pipelines." Both terms mean the same thing as "independent problem domain."

---

## Step 2: Check the Pipeline Ceiling Before Dispatching

> **Pipeline ceiling** (3–4 active PRs, per `.claude/rules/subagent-orchestration.md`) — how many concurrently reviewed PRs the parent thread manages.
>
> **Silence/bgwork ceiling** (`bgwork-ceiling.sh`) — a separate backstop that fires when background work goes quiet. Do not confuse the two.

Count your currently open PRs (`gh pr list --author "@me" --state open`) as a conservative proxy for pipeline load. Dispatch only enough agents to stay at or below the pipeline ceiling (3–4). Agents that would exceed the ceiling queue inline — they do not get their own chips. (The canonical ceiling definition — actively CR-polled PRs authored by `@me` — lives in `.claude/rules/subagent-orchestration.md`; dormant open PRs are counted here for safety.)

**Then check the armed deadline, per agent (issue #1525).** A planning window (`/pm --window`) or a declared leave time (`/leave-by`) writes one `deadline_epoch` into `.repos["<key>"].window`; an agent whose planning bound cannot finish before it is not dispatched. **Run `/subagent` Step 7's fenced block** (`<!-- test-anchor: subagent-step7-deadline-decline -->`) — it is the canonical executable form and owns the sentinel handling (only the literal `null` and exit 3 mean "no deadline"), the bound comparison, and the decline wording. Read it there; do not restate or fork it here, because two copies of one gate is how the two come to disagree.

Dispatch-specific behavior only: the check runs **per agent**, so a declined agent is simply not dispatched while every **independent** agent in the batch is still evaluated on its own bound — this gate declines individuals, never the batch, and never reorders it.

**A declined agent still holds its overlap chain.** `/subagent` Step 7 is explicit that `declined` is **not** a terminal, so a declined chain *head* releases nothing: its successors stay queued until that head actually reaches `merged` or `blocked`. "Every other agent" above means every agent not sequenced behind a declined one — dispatching a successor because its head was skipped would break the serialization the chain exists to enforce, and do it precisely when the deadline made the head unsafe to start.

Spawn mechanics, model tiers (Opus for Phase A/B, Sonnet for Phase C/PM), and mode settings live in `.claude/rules/subagent-orchestration.md`. Read that file; do not restate it here.

---

## Step 3: Write Self-Contained Prompts

Each subagent inherits **only what you write into its prompt** — it does not inherit your session history, context, or loaded files. Every prompt must be a complete, standalone brief.

### Mandatory elements in each prompt

| Element | What to include |
|---------|-----------------|
| **Scope** | Exact file(s) or subsystem — not "the codebase" |
| **Goal** | One clear outcome |
| **Evidence** | Relevant error messages, test names, or failing assertions |
| **Constraints** | Files/directories NOT to touch |
| **Output format** | What the agent should return (summary, handoff, exit report) |
| **Safety/Mindset blocks** | Verbatim from `.claude/reference/subagent-phase-guardrails.md` |

### Context isolation — repo-specific rules

- **One worktree per agent/PR.** Each agent works in its own worktree (`EnterWorktree`). See `CLAUDE.md` "ALWAYS USE A WORKTREE" and `.claude/rules/main-hygiene.md`.
- **Absolute paths everywhere.** The Bash tool has a minimal `PATH`; bare tool names can resolve wrong. Always pass `/opt/homebrew/bin/<tool>` or a resolved path.
- **No shared mutable state.** Parallel agents must not write to the same branch, file, or session-state key. If they must share output, route it through handoff files with distinct PR-scoped keys.
- **Guardrail blocks are non-negotiable.** Include the verbatim `SAFETY:` and `MINDSET:` blocks from `.claude/reference/subagent-phase-guardrails.md` in every spawn prompt. Do not reword them — a reworded copy drifts or fails `verbatim-block-lint.sh`.

### Why self-contained prompts matter

A subagent that inherits implicit context from your session will fail when that context is absent (compaction, a fresh spawn, a different thread). Prompts written as if the agent knows nothing are more robust and easier to debug. Detail: `.claude/reference/skill-first-subagent-delivery.md`.

### Concrete prompt template

```markdown
**Model:** Opus — Phase A fixer
**Effort:** High

[SAFETY block from .claude/reference/subagent-phase-guardrails.md]
[MINDSET block from .claude/reference/subagent-phase-guardrails.md]

You are a Phase A fixer. Repo: auerbachb/claude-code-config.

**Scope:** /absolute/path/to/repo/src/foo/bar.ts — the `validateInput` function only.
**Goal:** Fix the 2 failing tests listed below without touching other files.
**Failing tests:**
  - "should reject null input" — TypeError: Cannot read property 'length' of null
  - "should handle empty string" — AssertionError: expected '' to be rejected

**Constraints:**
  - Do NOT change test files
  - Do NOT change /absolute/path/to/repo/src/foo/baz.ts

**Return:** Structured exit report per .claude/rules/phase-protocols.md.
**Handoff:** Write via `<ABSOLUTE_REPO_ROOT>/.claude/scripts/handoff-state.sh --owner-repo auerbachb/claude-code-config` to ~/.claude/handoffs/auerbachb/claude-code-config/pr-<N>-handoff.json. `--owner-repo` on every call — omit it and the scope is derived from the agent's own cwd, which names a different repo than the PR whenever the agent works from a worktree, or exits 2 when nothing resolves (atomic; exit 6 = lock timeout, retry; exit 4 = wrong field type, fix the call).
```

---

## Step 4: Dispatch in Parallel

Multiple Agent tool calls in a **single response** run concurrently. One per response runs sequentially.

```
# Parallel — all three calls in one response
Agent("Fix auth-flow.test.ts failures")
Agent("Fix batch-completion.test.ts failures")
Agent("Fix abort-handling.test.ts failures")
```

Include model, mode (`bypassPermissions`), and the verbatim SAFETY/MINDSET blocks in each call. Add the SKILLS block for general-purpose or built-in spawns without a `subagent_type` — custom `subagent_type` agents inherit it automatically. Full contract: `.claude/rules/subagent-orchestration.md`.

**Do not exceed the pipeline ceiling.** If you have 3 agents queued and you already have 2 open PRs (with a ceiling of 4), dispatch only 2 agents in parallel and hold the 3rd to queue inline as PRs complete.

---

## Step 5: Verify After Agents Return

STOP and verify before declaring the work done.

1. **Read each exit report.** Every agent must print a Structured Exit Report (`.claude/rules/phase-protocols.md`). No exit report = silent failure — check GitHub, not memory.
2. **Check for conflicts.** Did two agents edit the same file? Merge manually if so.
3. **Run the full test suite.** Individual-agent passes do not guarantee combined correctness.
4. **Integrate handoff state.** Each agent writes to `~/.claude/handoffs/<owner>/<repo>/pr-<N>-handoff.json`. Read each file; check `phase_completed` and `head_sha` before proceeding. Writes go through `handoff-state.sh` (atomic); exit code 6 = lock timeout (retry); exit code 4 = wrong field type (fix the call). Field names: `.claude/reference/handoff-file-schema.json`.
5. **Verify Phase A handoff and trigger Phase B.** See `.claude/rules/phase-protocols.md` Phase A Completion Protocol — the parent session owns this transition automatically.

---

## Not this command's job

| Task | Use instead |
|------|------------|
| Issue triage and ranking | `/pm` |
| Picking which issues can run in parallel | `/wave` |
| Overlap serialization and merge sequencing | `/subagent` |
| Phase A/B/C protocol, model selection, spawn mechanics | `.claude/rules/subagent-orchestration.md` |
| Verbatim SAFETY/MINDSET/SKILLS spawn blocks | `.claude/reference/subagent-phase-guardrails.md` |
| Per-phase exit report format | `.claude/rules/phase-protocols.md` |
| Handoff file schema and write contract | `.claude/rules/handoff-files.md` + `.claude/reference/handoff-file-schema.json` |

**STOP if you catch yourself:**
- Restating Phase A/B/C protocol steps
- Inlining the SAFETY/MINDSET/SKILLS blocks into this file (link to `subagent-phase-guardrails.md` instead — the verbatim blocks belong in your spawn prompts, not here)
- Picking issues or ranking work (that is `/wave` and `/pm`)
- Merging or wrapping (that is `/wrap`)

---

## Common Mistakes

| Wrong | Right |
|-------|-------|
| "Fix all the failing tests" | "Fix the 3 failures in src/foo/bar.test.ts" |
| No error context in prompt | Paste the exact error messages and test names |
| No constraints | "Do NOT touch src/other.ts or test files" |
| Vague output request | "Return Structured Exit Report per phase-protocols.md" |
| Relative paths in prompt | Use absolute paths everywhere |
| Dispatching beyond the ceiling | Count open PRs first; queue excess inline |

---

## Usage

```
/subagent-dispatch
```

No arguments — describe the work you want to parallelize in the conversation and this skill will walk the decision tree, check the ceiling, and help you write the prompts.

**Typical flow:**
1. You describe the independent tasks
2. This skill checks whether parallel dispatch fits
3. You verify the pipeline ceiling
4. This skill helps you write each self-contained prompt
5. You issue all Agent calls in a single response
6. After agents return, this skill guides exit verification
