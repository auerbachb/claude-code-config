# Skill-Repo Diff — August 2026 Point-in-Time Audit

**Survey date:** 2026-08-12
**Issue:** [#417](https://github.com/auerbachb/claude-code-config/issues/417)
**Previous cycle:** 2026-07-02 (see `skill-repo-diff.md` Import Log for prior harvests)

This is a dated snapshot of what was true when it was written. The living tracker
(`skill-repo-diff.md`) is updated each cycle to record new survey entries and
import log additions; this file preserves the August 2026 survey state for
point-in-time reference.

## Repos Surveyed This Cycle

| Repo | HEAD SHA surveyed | Shape |
|------|------------------|-------|
| [obra/superpowers](https://github.com/obra/superpowers) | `b36e0829` (2026-08-12) | 14 skills (unchanged count), 4 hook files, 4 scripts, 16 test suites |
| [affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code) | `569b1d5b` (2026-08-12) | ~287 skills, 68 agents, 94 commands, 5 hook files, 23 rule dirs |

**Our repo state at survey:** 29 skills, 25 hooks, 5 agents, 78 scripts, 14 rule files.

## How We Differ (adaptation constraints — unchanged from prior cycle)

Our repo is a workflow-specific config for a GitHub issue → CR plan → worktree →
PR → review → squash-merge pipeline with phase A/B/C subagent orchestration:

- Skills are slash-command procedures, not generic technique libraries.
- Rules auto-load every turn under a hard word budget (`rule-lint`). Generic
  discipline content belongs in `.claude/reference/` (on-demand), not rules.
- Bash + Markdown stack. ECC's JS/TS hooks do not map onto our codebase.
- Superpowers is already installed as a Cursor plugin. Its skills are
  runtime-available; we harvest the judgment patterns, not the skills themselves.

## Gap Analysis by Dimension (August 2026 Cycle)

**Fit legend:** `DF` = direct fit · `NA` = needs adaptation · `NF` = doesn't
fit our workflow · `—` = parity / n/a.

Prior-cycle items already addressed are listed in `skill-repo-diff.md` Import Log
(PRs #485, #529, #530, #532). This section covers what is new or re-evaluated
this cycle.

### 1. Skill library coverage

| Pattern (source) | We have? | Delta | Fit | Priority |
|---|---|---|---|---|
| `dispatching-parallel-agents` skill — discipline for crafting isolated subagent prompts with minimal context (superpowers `skills/dispatching-parallel-agents/SKILL.md`) | Partial — `subagent-orchestration.md` is a rule focused on Phase A/B/C protocol, model selection, and spawn mechanics | We lack a focused skill on the *craft* of writing independent parallel-agent prompts (what to include, what to omit, how to scope context) | `NA` `P1` | **New this cycle** |
| `receiving-code-review` skill — verify before implementing, technical pushback discipline, rationalization-avoidance table (superpowers `skills/receiving-code-review/SKILL.md`) | No — `cr-github-review.md` covers bot-feedback processing loops but not how to evaluate reviewer feedback technically before acting | We have the mechanical loop but no guidance on verification-before-implementation for review feedback | `NA` `P1` | **New this cycle** |
| `skill-create` command — analyze git history to auto-generate SKILL.md files from recurring patterns (ECC `commands/skill-create.md`) | No — `/harness-audit` is the closest (audits existing skills); we have no git-history-to-skill generator | Auto-generating skills from commit patterns could reduce manual skill authoring | `NA` `P2` | **New this cycle** |
| `finishing-a-development-branch` skill — when and how to declare a branch done, checklist for cleanups (superpowers `skills/finishing-a-development-branch/SKILL.md`) | Partial — `/wrap` covers the mechanical merge, but from the tool operator's view, not the developer's discipline | Framing differs: superpowers targets the human developer's judgment; ours targets Claude as the operator | `NF` — `/wrap` already covers our use-case | — |
| Prior-cycle backlog items (brainstorming HARD-GATE, full skill-comply LLM harness) | Still deferred | No change | — | `P2` |

### 2. Hook patterns

| Hook (source) | We have? | Delta | Fit | Priority |
|---|---|---|---|---|
| Cross-platform hook output format — single session-start script handles Cursor vs Claude Code vs Copilot via env-var detection (superpowers `hooks/session-start`) | Our hooks hardcode Claude Code's `hookSpecificOutput.additionalContext` shape | A portable output-format pattern would make our hooks work if we ever support Cursor or Copilot CLI | `NA` `P2` | **New this cycle** — low urgency; we target Claude Code only |
| `stop:evaluate-session` / session activity tracker — records per-session tool use and file-touch metrics (ECC `hooks/memory-persistence`) | No structured session metrics | We have skill usage tracking but no per-session tool-use telemetry | `NA` `P2` — monitoring overhead vs value unclear | **New this cycle** |
| Prior-cycle deferred hooks (`post:quality-gate`, consolidated dispatcher) | Still deferred | No change | — | `P2` |

### 3. CLAUDE.md conventions

| Pattern (source) | We have? | Delta | Fit | Priority |
|---|---|---|---|---|
| `<SUBAGENT-STOP>` guard in session-start-injected skill content — suppresses skill invocation for dispatched subagents (superpowers `skills/using-superpowers/SKILL.md`) | No — our subagent prompts include explicit SAFETY/MINDSET/SKILLS blocks instead | Our approach is deliberate (safety-critical restatement); this is an alternative model | `NF` — our explicit block approach is more auditable | — |
| No new patterns identified this cycle | — | — | — | — |

### 4. Prompt-engineering patterns

| Pattern (source) | We have? | Delta | Fit | Priority |
|---|---|---|---|---|
| Rationalization tables using `Thought` / `Reality` two-column format (superpowers `skills/using-superpowers/SKILL.md` "Red Flags" table) | Partial — prior cycle harvested match-form-to-failure; we now have rationalization table *concept* in `skill-authoring-patterns.md` | The concrete Red Flags format with explicit thought-patterns + rebuttals is more actionable than abstract guidance | `NA` `P1` — could be incorporated into `skill-authoring-patterns.md` as a concrete example | **New this cycle** |
| `<HARD-GATE>` XML tag for implementation-blocking gates in skill prose (superpowers `skills/brainstorming/SKILL.md`) | No equivalent structural convention; our rules use STOP in prose | A named gate pattern makes skip-detection easier in CI | `NA` `P2` | **New this cycle** |

### 5. MCP integrations

| Pattern (source) | We have? | Delta | Fit | Priority |
|---|---|---|---|---|
| `longhand` MCP — indexes raw tool calls from `.claude/projects/*.jsonl` into local SQLite + ChromaDB for verbatim session recall (ECC `mcp-configs/mcp-servers.json`) | No — our memory system uses `~/.claude/projects/*/memory/` (human-readable notes) | Verbatim session recall complements our synthesized memory; useful for debugging session-compaction loss | `NA` `P2` — local infra dependency; niche value | **New this cycle** |
| Prior-cycle deferred items (playwright, sequential-thinking) | Still deferred | No change | — | `P2` |

### 6. Utility scripts / tooling

| Pattern (source) | We have? | Delta | Fit | Priority |
|---|---|---|---|---|
| `silent-failure-hunter` agent — read-only agent specialized in finding silent failures: empty catch blocks, inadequate logging, swallowed errors, missing error propagation (ECC `agents/silent-failure-hunter.md`) | No — Phase B reviewer is general; no dedicated silent-failure specialist | Our Bash scripts have silent-failure risks (mapfile exit-code, `\|\| true` on guards — memory feedback file confirms these patterns recur) | `DF` `P1` — **direct fit**; Bash + Markdown stack; can use as-is with our frontmatter | **New this cycle** |
| `skill-health` command — check if skills are outdated, have broken references, or lack tests (ECC `commands/skill-health.md`) | Partial — `skill-conventions-audit.sh` (from prior cycle) checks formatting conventions | No broken-reference or outdatedness check | `NA` `P2` | **New this cycle** |

## Prioritized Import Backlog (August 2026 additions)

Items from prior cycles remain in `skill-repo-diff.md`. New additions this cycle:

**P1 — High value, adapt and ship as separate PRs:**

1. **`silent-failure-hunter` agent** — direct fit; add to `.claude/agents/silent-failure-hunter.md` with our frontmatter and Bash-first description. Source: `affaan-m/everything-claude-code/agents/silent-failure-hunter.md` @ `569b1d5b`. _Issue [#1163](https://github.com/auerbachb/claude-code-config/issues/1163) filed._
2. **`dispatching-parallel-agents` skill** — adapt superpowers' parallel-dispatch discipline to our Phase A/B/C model. Distill into `.claude/reference/parallel-agent-dispatch.md` (on-demand, not auto-loaded) or a `.claude/skills/subagent-dispatch/SKILL.md`. Source: `obra/superpowers/skills/dispatching-parallel-agents/SKILL.md` @ `b36e0829`. _Issue [#1164](https://github.com/auerbachb/claude-code-config/issues/1164) filed._ *(Shipped as the `subagent-dispatch` skill; retired in [#1584](https://github.com/auerbachb/claude-code-config/issues/1584) after zero invocations on either machine — the parallelize decision and self-contained-prompt rules now live in `.claude/reference/phase-decomposition.md`.)*
3. **`receiving-code-review` skill** — adapt the verify-before-implement discipline + rationalization table for our Phase B reviewer context. Distill into `.claude/skills/receiving-code-review/SKILL.md` — complements existing `cr-github-review.md` (mechanical loop) with the judgment layer. Source: `obra/superpowers/skills/receiving-code-review/SKILL.md` @ `b36e0829`. _Issue [#1165](https://github.com/auerbachb/claude-code-config/issues/1165) filed._

**P2 — Revisit in future cycles:**

- Cross-platform hook output format (low urgency; we target Claude Code only).
- `<HARD-GATE>` XML convention for structural gates in skill prose.
- `longhand` MCP for verbatim session recall.
- Session activity tracker hook.
- `skill-health` broken-reference command.

## Explicitly Rejected (unchanged from prior cycle — still out of scope)

- Per-language TDD / framework / video skills (ECC) — meta-config repo.
- JS/TS hooks: `stop:format-typecheck`, Biome, `console.log` warn (ECC).
- Multi-runtime config mirrors (`.codex`, `.gemini`, `.opencode`).
- Re-importing superpowers skills verbatim (runtime-available as plugin).

## Import Log (August 2026 cycle)

_Populated when PRs merge. Filed issues listed below; PRs to be opened by follow-up agents._

| Date | Source repo | Pattern | Issue | PR | Adaptation notes |
|------|-------------|---------|-------|----|------------------|
| 2026-08-12 | affaan-m/everything-claude-code @ `569b1d5b` | `silent-failure-hunter` agent | [#1163](https://github.com/auerbachb/claude-code-config/issues/1163) | TBD | Add our frontmatter; scope description to Bash/shell scripts as primary target |
| 2026-08-12 | obra/superpowers @ `b36e0829` | `dispatching-parallel-agents` parallel-agent-dispatch skill | [#1164](https://github.com/auerbachb/claude-code-config/issues/1164) | [#1175](https://github.com/auerbachb/claude-code-config/pull/1175) — retired in [#1584](https://github.com/auerbachb/claude-code-config/issues/1584) | Shipped as a skill; never invoked on either machine, so it was retired and its parallelize decision + self-contained-prompt rules folded into `.claude/reference/phase-decomposition.md` |
| 2026-08-12 | obra/superpowers @ `b36e0829` | `receiving-code-review` verification discipline | [#1165](https://github.com/auerbachb/claude-code-config/issues/1165) | TBD | Phase B reviewer focus; complement cr-github-review.md |

## Re-Survey Checklist (next cycle)

1. Re-clone both reference repos; note HEAD SHAs.
2. Check delta since `b36e0829` (superpowers) and `569b1d5b` (ECC).
3. Move any newly-viable P2 items up; ship as own PR.
4. Append to living tracker Import Log and comment on #417.
5. Create new dated audit file `skill-repo-diff-YYYY-MM.md`.
