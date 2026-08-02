# Skill-First Reflex — Subagent Delivery

Expanded delivery detail for `.claude/rules/skill-first.md` §Reaching Subagents. The binding rule is there; this file carries the mechanism and the per-agent-type matrix.

## Why delivery is a problem at all

A subagent inherits the parent's instruction **snapshot** taken at spawn time. It does not re-read `.claude/rules/*.md` from disk, and it never picks up a later edit to them. Whatever reflex the subagent has, it has because the text was in its system context or its prompt at spawn.

That means the skill-first reflex cannot simply live in a rule file and be assumed to apply fleet-wide. It has to be delivered, and there are exactly two delivery paths.

## Path 1 — custom agent types

`phase-a-fixer`, `phase-b-reviewer`, `phase-c-merger`, and `pm-worker` are defined in `.claude/agents/*.md`. Each definition carries a short embedded reminder of the reflex. That definition loads as system context regardless of what the spawn prompt says, so these agents get the reflex even when the spawning code forgets to paste anything.

## Path 2 — everyone else

Ad-hoc spawns with no custom definition get nothing automatically. They must receive the verbatim `SKILLS:` block from `.claude/rules/skill-first.md` in the spawn prompt. This is item 7 of the spawn checklist in `.claude/rules/subagent-orchestration.md`, and the block is byte-compared by `.github/scripts/verbatim-block-lint.sh` — reword it in one place and the lint fails.

## The `Skill`-tool precondition

The block instructs the agent to invoke skills via the `Skill` tool. Pasting it into an agent that has no `Skill` tool produces an instruction the agent cannot follow, which is worse than silence.

| Agent | Has `Skill`? | Gets the verbatim block? |
|---|---|---|
| `phase-a-fixer` | Yes | Yes |
| `phase-b-reviewer` | Yes | Yes |
| `pm-worker` | Yes | Yes |
| Most ad-hoc spawns | Yes | Yes |
| `phase-c-merger` | No | **No** — adapted, non-invoking note in its own definition |
| `researcher` | No | **No** — adapted, non-invoking note in its own definition |

## Ladder adaptation for autonomous agents

The parent-agent confidence ladder resolves a borderline match by asking the user one line and following the answer. A subagent has no user to ask mid-phase, so the borderline rung adapts: note the borderline match in the Structured Exit Report and proceed on the agent's own judgment. Blocking a phase waiting for an answer that cannot arrive is the failure mode this adaptation exists to prevent.

The "no match → stay silent" and "never auto-invoke an authorization-carrying skill on a fuzzy match" rungs do not adapt — they bind subagents exactly as they bind the parent.

## Why the reflex is enforced at all

Hand-rolling a multi-step task that an existing skill already covers skips `~/.claude/skill-usage.log`, because only `Skill`-tool calls are logged. That log is the input to prune audits and skill telemetry, so an unlogged reimplementation makes a used skill look unused and puts it on the chopping block.
