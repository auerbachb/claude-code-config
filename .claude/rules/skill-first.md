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

Custom `subagent_type` agents inherit this file automatically — no extra work needed. Subagents can't pause for a user answer, so the ladder adapts: borderline match → note it in the exit report and proceed, never block the phase.

**For Explore/Plan built-ins and any general-purpose spawn where injection is uncertain:** paste the verbatim `SKILLS:` block below into the spawn prompt — only for spawns holding the `Skill` tool (`phase-c-merger` and `researcher` carry adapted role-specific notes in their own definitions). Delivery detail: `.claude/reference/skill-first-subagent-delivery.md`.

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
