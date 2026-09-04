# Phase Decomposition — Detailed Procedures

Canonical reference for per-phase subagent procedures. Used by agent definitions (`.claude/agents/phase-{a,b,c}-*.md`) and as a fallback when agent definitions are unavailable.

## Phase A: Fix + Push (heaviest)

1. Read CR/BugBot/Greptile findings, read affected files, fix all valid findings + lint/CI failures
2. Commit all fixes in ONE commit, push once
3. Reply to all review threads (see `greptile.md` for Greptile reply format)
4. Write handoff file (see `handoff-files.md`)
5. Print exit report and EXIT (see `phase-protocols.md`). Do not enter polling loop.

## Phase B: Review Loop (lighter)

1. Read handoff file on startup (GitHub API fallback if missing)
2. Before ANY `@greptileai` trigger, check daily budget (see `greptile.md`)
3. CR path: poll for review (fast-path → check BugBot → 10-min BugBot timeout → Greptile trigger). BugBot path: poll for BugBot review on the 3 endpoints. Greptile path: poll for existing Greptile review; only re-trigger `@greptileai` for P0 findings (max 3 reviews/PR).
4. Greptile findings: classify P0/P1/P2, fix all, commit, push, reply. Re-trigger only for P0 (max 3 reviews/PR).
5. CR gate: verify an explicit `state: "APPROVED"` CR review exists on the current HEAD SHA (stale approvals don't count — re-trigger if the latest approval's `commit_id` is not HEAD)
6. Update handoff file. Deduplicate: `string[]` by exact value, `findings_dismissed` by `.id`.
7. Print exit report and EXIT.

## Phase C: Verify + Wrap (lightest)

1. Start when the parent launches Phase C after `merge_ready` — auto `/wrap`, no approval pause.
2. Read handoff file. Verify merge gate per `cr-merge-gate.md` (reviewer path, CI, resolved threads, and BEHIND checks).
3. Read PR body, verify all AC against final code, check off all boxes.
4. If any gate or AC check fails, report `OUTCOME: blocked` and do not merge.
5. If verification passes, read `.claude/skills/wrap/SKILL.md` and execute that canonical flow. Do not duplicate `/wrap` merge, main-sync, follow-up, or stale-cleanup logic here.
6. Print exit report with `OUTCOME: merged` or `OUTCOME: blocked` and EXIT. Do not delete the handoff file — parent performs deletion after `OUTCOME: merged` and GitHub confirms the PR is merged (see `phase-protocols.md`).

## Non-custom spawns — why the manual paste, and why only the blocks

`subagent-orchestration.md` §Fallback is the binding rule; this section carries the causes and the rationale behind it.

**When it applies.** Three cases, all sharing one remedy:

1. **Built-in Explore/Plan agents.** These omit the project CLAUDE.md hierarchy entirely, so nothing is inherited.
2. **A bare `general-purpose` Agent call** — any spawn that does not name a `.claude/agents/` definition.
3. **A custom `subagent_type` the session has not registered**, which surfaces as `Agent type '<name>' not found`. Two causes: the agent file was created after this session started (agent types resolve at session start, so a brand-new definition needs a restart), or the definition is missing its `name:` frontmatter field. Spawn `general-purpose` instead rather than retrying the custom type.

**Why the verbatim blocks and not the corpus.** Custom `subagent_type` agents inherit the full CLAUDE.md + `.claude/rules/*.md` hierarchy automatically. Pasting that corpus into a spawn prompt therefore **double-pays** it for every custom-agent spawn — the agent receives the rules once by inheritance and again as prompt text, for no added constraint. The SAFETY / MINDSET / SKILLS blocks are the deliberate exception: they are short, safety-critical, and restated on purpose so a non-inheriting spawn is still bound by them.

Measured verification of the inheritance behavior and the double-pay cost: `.claude/reference/token-efficiency-audit-2026-07.md` §FU-1.

<!-- Adapted from obra/superpowers @ b36e0829: skills/dispatching-parallel-agents/SKILL.md -->
<!-- Adapted to auerbachb/claude-code-config Phase A/B/C model. Carried here from the -->
<!-- parallel-dispatch skill retired in issue #1584 — its Steps 1 and 3 only. -->

## Parallel Dispatch: Decide Whether to Parallelize

**Core principle: one agent per independent problem domain.** Run this decision tree before dispatching anything.

```text
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
- The launch gate clears — `phase-protocols.md` §Launch gate binds *every* launch and fails closed on any unreadable stop control; `/subagent` Step 7 is its executable form, owning the pipeline-ceiling count and the armed-deadline decline. Run the gate at one of those two sites rather than re-deriving either here

**Do NOT parallelize when:**

- Failures are related (fixing one may fix others — investigate first)
- Agents would write to the same files, branch, or session state
- You don't yet know what's broken (explore first)
- The pipeline ceiling is already full (`subagent-orchestration.md` §Orchestration)

**This repo's vocabulary:** `/wave` calls this the "dependency- and overlap-filtered independent set"; `/subagent` calls it "disjoint chains run as parallel pipelines." Both terms mean the same thing as "independent problem domain."

Dispatch mechanics — how many Agent calls fit in one response, ceiling arithmetic, overlap-chain sequencing — are `/subagent` Steps 7 to 9. Verification after agents return is the Phase A/B/C Completion Protocols in `.claude/rules/phase-protocols.md`. Neither is restated here.

## Parallel Dispatch: Write Self-Contained Prompts

**No subagent inherits your session.** A registered custom `subagent_type` agent does inherit the project CLAUDE.md + `.claude/rules/*.md` hierarchy (§Non-custom spawns above); nothing else carries over — not your conversation, not your findings, not the files you have read. Everything task-specific reaches the agent **only through what you write into its prompt**, so every prompt must be a complete, standalone brief.

### Mandatory elements in each prompt

| Element | What to include |
|---------|-----------------|
| **Scope** | Exact file(s) or subsystem — not "the codebase" |
| **Goal** | One clear outcome |
| **Evidence** | Relevant error messages, test names, or failing assertions |
| **Constraints** | Files/directories NOT to touch |
| **Output format** | What the agent should return (summary, handoff, exit report) |
| **Guardrail blocks** | Verbatim from `.claude/reference/subagent-phase-guardrails.md`, which names the set this spawn carries |

### Context isolation — repo-specific rules

- **One worktree per agent/PR.** Each agent works in its own worktree (`EnterWorktree`). See `CLAUDE.md` "ALWAYS USE A WORKTREE" and `.claude/rules/main-hygiene.md`.
- **Absolute paths everywhere.** The Bash tool has a minimal `PATH`; bare tool names can resolve wrong. Always pass `/opt/homebrew/bin/<tool>` or a resolved path.
- **No shared mutable state.** Parallel agents must not write to the same branch, file, or session-state key. If they must share output, route it through handoff files with distinct PR-scoped keys.
- **Guardrail blocks are non-negotiable.** Paste them verbatim from `.claude/reference/subagent-phase-guardrails.md`, which is canonical for *which* blocks a given spawn carries — `RESOLVE` and `SAFETY` on every phase; `MINDSET` on every spawn except `phase-c-merger`; `SKILLS` additionally on any non-custom spawn holding the `Skill` tool (`subagent-orchestration.md` §Fallback). Do not reword them — a reworded copy drifts or fails `verbatim-block-lint.sh`.

### Why self-contained prompts matter

A subagent that inherits implicit context from your session will fail when that context is absent (compaction, a fresh spawn, a different thread). Prompts written as if the agent knows nothing are more robust and easier to debug. Detail: `.claude/reference/skill-first-subagent-delivery.md`.

### Concrete prompt template

Model is an Agent-call parameter, never prompt text, and effort is not settable on an Agent call at all — see `subagent-orchestration.md` §Model Selection. The `**Model:** / **Effort:**` header belongs to click-to-launch chips and `mcp__ccd_session__spawn_task` payloads, which `chip-spawn.md` requires to carry both; that contract does not reach an Agent-call prompt body like the one below.

The bracketed lines below are **mandatory substitutions**, not content: replace each with the full verbatim block from `.claude/reference/subagent-phase-guardrails.md` before dispatching. A prompt sent with the brackets still in it carries no guardrails at all. The three shown are the Phase A set; that file names the set for every other spawn type.

```markdown
[replace with the verbatim RESOLVE block from .claude/reference/subagent-phase-guardrails.md]
[replace with the verbatim SAFETY block from .claude/reference/subagent-phase-guardrails.md]
[replace with the verbatim MINDSET block from .claude/reference/subagent-phase-guardrails.md]

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
**Handoff:** Write via `handoff-state.sh --owner-repo auerbachb/claude-code-config` to ~/.claude/handoffs/auerbachb/claude-code-config/pr-<N>-handoff.json. Resolve the script through the RESOLVE block above — never a bare or repo-local `.claude/scripts/` path, which does not exist in a repo without a `.claude/` directory (issue #1189). `--owner-repo` on every call — omit it and the scope is derived from the agent's own cwd, which names a different repo than the PR whenever the agent works from a worktree, or exits 2 when nothing resolves (atomic; exit 6 = lock timeout, retry; exit 4 = wrong field type, fix the call).
```

### Common mistakes

| Wrong | Right |
|-------|-------|
| "Fix all the failing tests" | "Fix the 3 failures in src/foo/bar.test.ts" |
| No error context in prompt | Paste the exact error messages and test names |
| No constraints | "Do NOT touch src/other.ts or test files" |
| Vague output request | "Return Structured Exit Report per phase-protocols.md" |
| Relative paths in prompt | Use absolute paths everywhere |
| Dispatching beyond the ceiling | Run `/subagent` Step 7's gate first; queue excess inline |
