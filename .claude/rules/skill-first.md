# Skill-First Reflex

> **Always:** Before hand-rolling any multi-step task, scan the in-context skill catalog for a match. Invoke matched skills via the Skill tool — never reimplement one from memory (only Skill-tool calls reach the usage log).
> **Ask first:** Borderline matches — one line ("this looks like /go-on — run it?"), then follow the user's answer.
> **Never:** Mention skills when nothing matches (precision over recall). Auto-invoke an authorization-carrying skill (`/merge`, `/wrap`, `/pr-monitor-and-manage`) unless the user explicitly asked for that outcome.

## Confidence ladder

| Match | Behavior |
|-------|----------|
| Clear — the request is a skill's core job | Invoke via the Skill tool immediately |
| Borderline — overlaps, fit uncertain | One-line suggestion; proceed per the answer, no long detour |
| None | No skill mention at all |

"Clear" means the skill's description names the requested task (e.g. "summarize what this PR changed" → `/recap`; "what should I work on next?" → `/pm` or `/prioritize`).

## Reaching Subagents

Subagents inherit the parent's instruction **snapshot** at spawn and never re-read this file from disk. Two paths deliver the reflex anyway:

1. **Custom agent types** (`phase-a-fixer`, `phase-b-reviewer`, `phase-c-merger`, `pm-worker`) carry a short embedded reminder in their own `.claude/agents/*.md` definition, loaded as system context regardless of prompt content.
2. **Everyone else** (ad-hoc spawns with no custom definition) gets the verbatim `SKILLS:` block below in the spawn prompt (`subagent-orchestration.md` checklist).

Subagents run autonomously and can't pause for a user answer, so the ladder adapts: borderline match → note it in the exit report and proceed on your own judgment, don't block the phase waiting for input.

**Requires `Skill` tool access.** Paste the block only into spawns that have it (`phase-a-fixer`, `phase-b-reviewer`, `pm-worker`, most ad-hoc spawns). Agents lacking `Skill` (`phase-c-merger`, `researcher`) carry an adapted, non-invoking note in their own `.claude/agents/*.md` definition — don't paste this block there.

```text
SKILLS: Before hand-rolling a multi-step task, check whether an existing skill
already does this job — invoke it via the Skill tool instead of reimplementing
from memory (only Skill-tool calls reach ~/.claude/skill-usage.log). Clear match
-> invoke immediately. Borderline match -> note it in your exit report, then
proceed on your own judgment; do not block waiting for an answer. No match ->
stay silent. Never auto-invoke an authorization-carrying skill (/merge, /wrap,
/pr-monitor-and-manage) on a fuzzy match — running one as your assigned job
isn't a fuzzy match. Full rules: .claude/rules/skill-first.md.
```
