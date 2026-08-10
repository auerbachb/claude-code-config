# Issue #1121 — Custom Agent Registration: Diagnosis and Resolution

**Date:** 2026-08-08
**Scope:** Why custom `subagent_type` values fail with "Agent type not found", and how it was fixed.
**Related:** Issue #864 (browser rung verification), PR for Issue #1121.

## Observed Error

```
Agent type 'pm-worker' not found
```

Observed in session working Issue #864. The same error occurs for every custom type in `.claude/agents/`: `phase-a-fixer`, `phase-b-reviewer`, `phase-c-merger`, `pm-worker`, `researcher`.

The built-in types available in that session (and documented in the system-reminder): `claude`, `claude-code-guide`, `Explore`, `general-purpose`, `Plan`, `statusline-setup`, `vercel:ai-architect`, `vercel:deployment-expert`, `vercel:performance-optimizer`.

## Root Cause

All five `.claude/agents/*.md` files were missing the required `name:` frontmatter field.

The Claude Code sub-agents documentation states (verified 2026-08-08):

> "The subdirectory path doesn't affect how a subagent is identified or invoked, because identity comes only from the **name frontmatter field**."

> "Only **name** and **description** are required."

Without `name:`, the agent file is loaded at session start but cannot be matched against the `subagent_type` string passed to the Agent tool. The prior `.claude/agents/README.md` incorrectly stated that identity came from the filename — that was never true per the product schema.

Additionally, two files (`phase-c-merger.md`, `researcher.md`) used an `allowed-tools:` frontmatter key that is not part of the documented schema. The correct key is `tools:`. An unrecognized key is silently ignored, which means the read-only restrictions on those agents were never actually enforced.

## Fix Applied

1. Added `name:` as the first frontmatter key to all five agent files, with values matching the filename stem exactly:
   - `phase-a-fixer.md` → `name: phase-a-fixer`
   - `phase-b-reviewer.md` → `name: phase-b-reviewer`
   - `phase-c-merger.md` → `name: phase-c-merger`
   - `pm-worker.md` → `name: pm-worker`
   - `researcher.md` → `name: researcher`

2. Renamed `allowed-tools:` to `tools:` in `phase-c-merger.md` and `researcher.md` so tool restrictions actually take effect.

3. Updated `.claude/agents/README.md` to state that identity comes from `name:`, that a session restart is needed after adding/editing files, and that `tools:` (not `allowed-tools:`) is the correct key.

4. Updated `.claude/rules/subagent-orchestration.md` to add `researcher` to the enumerated types, add a precondition note about `name:` and session restart, and add a fallback path for when a custom spawn fails.

5. Added `.github/scripts/agents-frontmatter-lint.sh` and wired it into `.github/workflows/rule-lint.yml` to prevent regression.

## Restart Precondition

Claude Code scans `.claude/agents/` at session start. The fix applies when the updated files exist AND a new session has been started. An existing session that predates the merge will still see "Agent type not found" for custom types. After session restart the agents register normally.

## Live Verification — Issue #1130 (2026-08-10)

Confirmed in a fresh session started after PR #1131 merged (2026-08-08, squash `9a4ab06`). All five custom `subagent_type` values were spawned live via the Agent tool:

| Type | Spawn result | Tool-restriction check |
|------|--------------|-------------------------|
| `phase-a-fixer` | PASS — resolved, replied `OK` | n/a (all tools) |
| `phase-b-reviewer` | PASS — resolved, replied `OK` | n/a (all tools) |
| `phase-c-merger` | PASS — resolved, replied `OK` | PASS — self-reported Write/Edit absent from its toolset (`tools: Read, Glob, Grep, Bash`) |
| `pm-worker` | PASS — resolved, replied `OK` | n/a (all tools) |
| `researcher` | PASS — resolved, replied `OK` | PASS — self-reported Write/Edit absent from its toolset |

Zero "Agent type not found" errors across all five.

**Method and its limit (tool-restriction check):** each probe asked the agent to state whether Write/Edit appear in its own available toolset, without attempting to call either — this is a self-report of what the harness handed the model, not an observed blocked call. It is still meaningful evidence for the `allowed-tools:` → `tools:` rename specifically: under the pre-fix key, the restriction was silently ignored and the agent would have had the full default toolset (Write/Edit included) to self-report. Getting "absent" back is therefore consistent with the `tools:` key now taking effect, not merely with it parsing — but it does not by itself rule out every failure mode (e.g. a tool present in the manifest but rejected only on invocation). Static corroboration: this session's own Agent-tool system listing (visible before any spawn) independently showed all five custom types with descriptions and tool sets matching each file's current frontmatter.

Issue #1130 closed with this evidence; no `.claude/agents/*.md` changes were needed.

## Fallback (Pre-Restart or Edge Cases)

If a spawn returns `Agent type '<name>' not found`, use `general-purpose` and paste the verbatim SAFETY/MINDSET/SKILLS blocks plus the role-specific procedure. See `.claude/rules/subagent-orchestration.md` §Fallback for the full contract.

## Doc Drift Resolved

`.claude/agents/README.md` previously stated:

> "When spawning a subagent with `subagent_type: "phase-a-fixer"`, Claude Code loads `.claude/agents/phase-a-fixer.md`..."

This implied identity came from the filename. The authoritative mechanism is `name:` frontmatter. The README now states this correctly.

## Evidence

- Observed error and session context: `.claude/reference/issue-852-browser-rung-verification.md` §Doc drift item 1
- Schema source: `https://docs.anthropic.com/en/docs/claude-code/sub-agents` §Supported frontmatter fields (fetched 2026-08-08)
- Lint regression guard: `.github/scripts/agents-frontmatter-lint.sh`
- Live spawn verification (all 5 types, both tool-restricted types confirmed): Issue #1130, session 2026-08-10
