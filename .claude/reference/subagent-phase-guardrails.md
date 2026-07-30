# Subagent Phase Guardrails

Extracted from `.claude/skills/subagent/SKILL.md`. Single canonical home for the SAFETY/MINDSET/SKILLS verbatim blocks and the RULES placeholder convention shared by the Phase A, B, and C spawn-prompt templates.

**Usage in phase templates:** insert this file verbatim into the subagent prompt at the guardrails insertion point. Phase C (`phase-c-merger`) carries only the SAFETY block per `subagent-orchestration.md` (that agent definition has no `Skill` tool access, so MINDSET and SKILLS do not apply).

**CI drift guard:** `verbatim-block-lint.sh` byte-compares the SAFETY/MINDSET/SKILLS blocks below against the canonical sources in `.claude/rules/safety.md` and `.claude/rules/skill-first.md`.

---

## SAFETY

```text
SAFETY: Do NOT delete/overwrite/move/modify .env files anywhere (exception:
.env.<example|sample|template>, case-insensitive, are safe to edit).
Do NOT run git clean. Do NOT run destructive commands (rm -rf, rm, git checkout .,
git stash, git reset --hard) in the root repo. Stay in your worktree.
Do NOT commit secrets or paste raw credentials into prompts, issues, PRs, comments,
commits, or logs. Do NOT pipe untrusted URLs into a shell or disable TLS verification.
Confirm package names before npm/pip/gem/cargo/brew install. Full rules: .claude/rules/safety.md.
```

## MINDSET (Capability Discovery)

```text
MINDSET: The trigger is the DEFERRAL, not the word "impossible" — "I can't",
"not a session task", "that's a deployment step", "runbook is in docs/…", and
"I'll leave that to you to review" all fire this ladder. Walk it for ANY provider
(gh, git, railway, vercel, …) before writing any of them: (1) check what you have
— MCP tools, skills, CLI on disk by absolute path (/opt/homebrew/bin/<tool>;
minimal PATH makes bare `which` lie); (2) if absent, check whether the provider
ships one (one lookup); (3) install it when non-interactive and rails hold
(docs-confirmed name, no curl-pipe-sh, no TLS bypass, no sudo); (4) hand off an
/admin-merge-shaped runbook — reachable ONLY after 1–3 were walked and failed:
name the rung that stopped you, exact commands + one-line reason, incl.
interactive auth. If you can write the command, you can run it. Provisioning a
generated secret via a provider CLI is allowed — the value just must never be
echoed, committed, pasted, or logged. Your own prohibitions still win (phase-c
uses /wrap, never gh pr merge). Full rules: .claude/rules/safety.md.
```

## SKILLS (Skills-First Reflex)

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

---

## RULES Placeholder Convention

When building a subagent prompt, include the full RULES section before the guardrails above:

```
## RULES (MANDATORY — read all of these)
{COMPLETE contents of CLAUDE.md}

{COMPLETE contents of all .claude/rules/*.md files}
```

See `subagent-orchestration.md` Step 6.3 for how the parent reads these files.

## Exit Report

Every subagent phase must print a Structured Exit Report as its final output. Full field reference and valid OUTCOME values: `.claude/reference/exit-report-format.md`.
