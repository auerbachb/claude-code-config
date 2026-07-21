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

## Why

Skills encode hard-won process. Hand-rolling does the work worse and skips `~/.claude/skill-usage.log`, undercounting live skills and poisoning prune audits (issue #431) and durable telemetry (issue #572).

Scope: parent-agent sessions read this file directly; subagents reach it via "Reaching Subagents" below (issue #587).

## Reaching Subagents

Subagents inherit the parent's instruction **snapshot** at spawn — they never re-read this file from disk afterward (verified during PR #585). Two paths deliver the reflex anyway:

1. **Custom agent types** (`phase-a-fixer`, `phase-b-reviewer`, `phase-c-merger`, `pm-worker`) carry a short embedded reminder in their own `.claude/agents/*.md` definition, loaded as system context regardless of prompt content.
2. **Everyone else** (ad-hoc / `general-purpose` spawns with no custom definition) gets the verbatim `SKILLS:` block below, pasted into every spawn prompt per `subagent-orchestration.md`'s "How to Spawn Subagents" checklist.

Subagents run autonomously and can't pause for a user answer, so the ladder adapts: borderline match → note it in the exit report and proceed on your own judgment, don't block the phase waiting for input.

```text
SKILLS: Before hand-rolling a multi-step task, check whether an existing skill
already does this job — invoke it via the Skill tool instead of reimplementing
from memory (only Skill-tool calls reach ~/.claude/skill-usage.log). Clear match
-> invoke immediately. Borderline match -> note it in your exit report, then
proceed on your own judgment; do not block waiting for an answer. No match ->
stay silent. Never auto-invoke an authorization-carrying skill (/merge, /wrap,
/pr-monitor-and-manage) on a fuzzy match — and this never overrides your own
phase's assigned task (e.g. Phase C's mandated /wrap run is the assigned task,
not a fuzzy match). Full rules: .claude/rules/skill-first.md.
```
