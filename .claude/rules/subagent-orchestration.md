# Subagent Context

> **Always:** Spawn subagents via custom agent definitions in `.claude/agents/` (see "How to Spawn Subagents" below). Use `mode: "bypassPermissions"` on every Agent tool call. Set `model` explicitly at every call site per the Model Selection policy (see below). Use phase decomposition (A/B/C). Timestamp every message (see `monitor-mode.md`). Write handoff files on phase completion (see `handoff-files.md`). Print Structured Exit Report before every subagent exit (see `phase-protocols.md`). Arm the silence ceiling in the same step as the spawn (`scheduling-reliability.md`). Only fall back to manually passing all rule files if `.claude/agents/` is unavailable in the current repo.
> **Ask first:** Respawning a crashed/no-handoff subagent — tell the user what happened first; exhaustion with valid handoff auto-respawns ("Always do").
> **Never:** Summarize rules for subagents. Spawn subagents without `mode: "bypassPermissions"`. Spawn without an explicit `model` parameter. Fire-and-forget subagents.

## How to Spawn Subagents

Use `.claude/agents/` definitions; they embed phase rules. Every Agent call must include:
1. `mode: "bypassPermissions"`.
2. `subagent_type`: `phase-a-fixer`, `phase-b-reviewer`, `phase-c-merger`, or `pm-worker`.
3. Explicit `model` (see "Model Selection").
4. Runtime context: PR/issue/branch, repo, handoff path, HEAD SHA, reviewer, optional pre-fetched findings.
5. The verbatim `SAFETY:` block from `safety.md`.
6. The verbatim `MINDSET:` block from `safety.md` (try CLI/browser before handoff — see "Capability Discovery").
7. The verbatim `SKILLS:` block from `skill-first.md` — **skip for `phase-c-merger`** (no `Skill` tool).
8. Same step, but not part of the call: arm the silence ceiling — `bgwork-ceiling.sh --arm-command` → `Monitor` (`persistent: true`).

See `.claude/agents/README.md` for the full placeholder reference and spawning examples.

### Fallback: Manual Rule Injection

If `.claude/agents/` is unavailable: paste project-local `CLAUDE.md` + every `find .claude/rules -name '*.md'` file in full. Do NOT summarize.

## Model Selection

**Defaults (set at every spawn site).**

| Phase / Agent | Model |
|---------------|-------|
| Phase A (`phase-a-fixer`) | `opus` |
| Phase B (`phase-b-reviewer`) | `opus` |
| Phase C (`phase-c-merger`) | `sonnet` |
| `pm-worker` | `sonnet` |
| Read-only review agents (e.g., `/pr-review-help`) | `sonnet` |

Fleet: **Fable, Opus, Sonnet, Haiku** (Agent `model` takes the lowercase family name). Fable is **never a spawn default** — reserve for interactive step-ups. Alias resolution + rationale: `.claude/agents/README.md`. An explicit `model` overrides frontmatter; escalate to `opus` if a Sonnet-tier agent underperforms.

**Effort is not settable on a spawn** — subagents inherit the parent session's effort level; never write an effort instruction into a subagent prompt.

## Phase Transition Autonomy (Quick Reference)

**Always do:** local CR review; commit/push after clean local review; create PR after push; enter 60s GitHub polling; fix valid reviewer findings; follow CR→BugBot→Greptile→self-review fallback timing; launch Phase B after Phase A; launch Phase C after `merge_ready` (auto — no merge-approval pause); verify AC after merge gate; respawn exhaustion with valid handoff.

**Ask first only:** respawning a crashed/no-handoff subagent.

> **Anti-pattern:** composing "Should I...?" for any "Always do" row — the answer is always yes (CLAUDE.md); execute immediately.

## Token/Turn Exhaustion Protocol (MANDATORY)

Near token exhaustion: write the handoff per `handoff-files.md` and exit; parent auto-launches a replacement.

**NEVER:** ask "should I continue?", die without handoff state, or try to finish "just one more thing."

## Task Decomposition

Give each subagent one phase with explicit exit criteria. **A/B/C decomposition:** procedures in `.claude/agents/phase-{a,b,c}-*.md`; step details: `.claude/reference/phase-decomposition.md`; rationale: `.claude/reference/too-big-recalibration-2026-07.md`.

**Phase C:** Do not duplicate `/wrap` logic; its session-sweep output is **advisory only — never block a merge on a sweep finding**.

**Orchestration:**

- **Transitions:** parent launches Phase A (parallel across PRs allowed); A complete → cleanup per `phase-protocols.md`, then B; B `merge_ready` → launch C within 60s (C verifies gate + AC before `/wrap`).
- **Ceiling:** 3-4 active CR-polled PRs max; at 7+ CR reviews/hour expect Greptile fallback. Below it is a trigger, not a resting state — refill per `CLAUDE.md` "KEEP THE PIPELINE FULL".
- **Scope:** counts only PRs you authored (`@me`); a collaborator's or bot's PRs never enter it (contention is context, never a gate).
- **Overflow:** past-ceiling work **queues inline, never becomes a thread chip** (slots: `.claude/skills/subagent/SKILL.md` Step 7).

## Subagent Review Protocol

Review protocol lives in its canonical sources — `cr-local-review.md`, `cr-github-review.md`, `cr-merge-gate.md`, `bugbot.md`, `greptile.md`. Do NOT duplicate them.

**Three reminders for subagents:**
1. **AUTONOMY:** every phase transition is automatic — do NOT ask "should I?" (table above).
2. **EXIT REPORT:** print a Structured Exit Report as final output (`phase-protocols.md`).
3. **HANDOFF FILE:** write/update/read `~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json` per `handoff-files.md`.
