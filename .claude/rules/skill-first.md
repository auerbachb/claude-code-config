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

Scope: parent-agent sessions. Subagents run from narrow agent definitions — extending the reflex to them is a follow-up (see issue #571 Notes).
