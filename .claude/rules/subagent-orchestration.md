# Subagent Context

> **Always:** Pass ALL rule files to subagents. Use `mode: "bypassPermissions"` on every Agent tool call. Use phase decomposition (A/B/C). Timestamp every message (see `monitor-mode.md`). Write handoff files on phase completion (see `handoff-files.md`). Print Structured Exit Report before every subagent exit (see `phase-protocols.md`).
> **Ask first:** Respawning a failed subagent — tell the user what happened first.
> **Never:** Summarize rules for subagents. Spawn subagents without `mode: "bypassPermissions"`. Fire-and-forget subagents.

## How to Spawn Subagents

**always pass the FULL contents of ALL rule files into the subagent's prompt.** Subagents do not inherit CLAUDE.md or `.claude/rules/` context.

1. **Always set `mode: "bypassPermissions"`** on the Agent tool call.
2. Read the root `CLAUDE.md` — check **project root first** (`cat ./CLAUDE.md`), fall back to global (`cat ~/.claude/CLAUDE.md`)
3. Read ALL rule files — check **project root first** (`cat ./.claude/rules/*.md`), fall back to global
4. Include the COMPLETE output of both in the subagent's task description
5. Do NOT summarize, excerpt, or paraphrase — pass the complete files

> **Why project-local first:** Per-project configs override global ones. Passing the global file when a project-level file exists gives subagents the wrong rules.

**Handoff file instructions in subagent prompts:**
- Phase A: include PR number + instruction to write `~/.claude/handoffs/pr-{N}-handoff.json` after pushing
- Phase B/C: include PR number, handoff file path, instruction to read it on startup (GitHub API fallback if missing)
- Phase B: instruction to update the handoff file on completion
- Phase C: instruction to delete the handoff file after successful merge

## Phase Transition Autonomy (Quick Reference)

| Transition | Action | Classification |
|------------|--------|----------------|
| Coding complete | Run local CR review (`coderabbit review --prompt-only`) | **Always do** |
| Local review clean (2 passes) | Commit all changes, push branch | **Always do** |
| Branch pushed | Create PR via `gh pr create` | **Always do** |
| PR created/updated | Enter GitHub review polling loop (60s cycle) | **Always do** |
| CR/Greptile posts findings | Fix all valid findings, commit, push, reply to threads | **Always do** |
| CR rate-limited (fast-path) | Trigger Greptile immediately | **Always do** |
| CR timeout (7 min) | Trigger Greptile | **Always do** |
| Both reviewers down | Self-review for risk reduction | **Always do** |
| Phase A subagent completes | Parent launches Phase B within 60s | **Always do** |
| Phase B reports clean | Parent launches Phase C | **Always do** |
| Merge gate met | Verify AC checkboxes against code | **Always do** |
| AC verified, all boxes checked | Ask user about merging | **Ask first** |
| Subagent failed (crash / no handoff state) | Report failure, ask about respawn | **Ask first** |
| Subagent exited with valid exhaustion handoff | Launch replacement for same phase | **Always do** |

> **Anti-pattern:** If you find yourself composing "Should I...?" or "Want me to...?" for any "Always do" row, stop — the answer is always yes. Execute immediately.

## Token/Turn Exhaustion Protocol (MANDATORY)

Subagents have a 32K output token limit. When approaching exhaustion:

1. **Write a handoff** to `~/.claude/session-state.json` (see `handoff-files.md` "Token Exhaustion Handoff" for schema)
2. **Report concisely** to parent/user — what was done, what remains. Do NOT ask "should I continue?"
3. **Exit cleanly.** Do not squeeze in one more tool call.

**Parent response:** Read `session-state.json`, launch a replacement subagent. This is **"Always do"** — do not ask the user.

**NEVER:** Ask "should I continue?", silently die without writing handoff state, or try to finish "just one more thing."

## Subagent `--max-turns` Guidance

| Phase | Recommended approach | Rationale |
|-------|---------------------|-----------|
| Phase A (Fix + Push) | Keep prompts focused — avoid exploration instructions | Heaviest: reads findings, edits, commits, pushes, replies |
| Phase B (Review Loop) | Same | Lighter but polling loops cost turns |
| Phase C (Merge Prep) | Same | Lightest — reads PR body, verifies AC, reports |

**Key insight:** The 32K output token limit is the binding constraint. To maximize effective work:
- Do NOT include exploratory instructions
- Give the subagent ONE clear phase with explicit exit criteria
- Include only the findings/context it needs

## Task Decomposition (Token Safety)

Subagents have a hardcoded **32K output token limit** ([known limitation](https://github.com/anthropics/claude-code/issues/25569)). Break PR lifecycle work into sequential phases:

**Phase A: Fix + Push** (heaviest)
- Read CR/Greptile findings, read affected files, fix all valid findings + lint/CI failures
- Commit all fixes in ONE commit, push once
- Reply to all review threads (see `greptile.md` for Greptile reply format)
- Write handoff file (see `handoff-files.md`)
- Print exit report and EXIT (see `phase-protocols.md`). Do not enter polling loop.

**Phase B: Review Loop** (lighter)
- Read handoff file on startup (GitHub API fallback if missing)
- Before ANY `@greptileai` trigger, check daily budget (see `greptile.md`)
- CR path: poll for review (fast-path + 7-min Greptile trigger). Greptile path: trigger and poll directly.
- Greptile findings: classify P0/P1/P2, fix all, commit, push, reply. Re-trigger only for P0 (max 3 reviews/PR).
- CR clean pass: trigger one more `@coderabbitai full review` for confirmation (2 clean passes needed)
- Update handoff file. Deduplicate: `string[]` by exact value, `findings_dismissed` by `.id`.
- Print exit report and EXIT.

**Phase C: Merge Prep** (lightest)
- Read handoff file. Verify merge gate (CR: 2 clean reviews; Greptile: severity gate per `greptile.md`).
- Read PR body, verify all AC against final code, check off all boxes.
- Report ready for merge. Delete handoff file only after successful merge.
- Print exit report and EXIT.

**Orchestration rules:**
- Parent launches Phase A subagents (can run in parallel across PRs)
- Phase A complete → parent launches Phase B immediately (see `phase-protocols.md`)
- Phase B clean → parent launches Phase C
- Soft limit: 3-4 active CR-polled PRs to reduce throttling
- Track CR quota: 7+ reviews/hour means expect Greptile as primary reviewer

## Subagent Review Protocol

Review protocol is defined authoritatively in these canonical sources — do NOT duplicate:

- **CR polling, CI checks, thread resolution, merge gate:** `cr-github-review.md`
- **Greptile trigger, severity classification, daily budget, reply format:** `greptile.md`
- **Local review before push, fix loop, 2 clean passes:** `cr-local-review.md`

**Three reminders for subagents:**
1. **AUTONOMY:** Every phase transition is automatic — do NOT ask "should I?" See the Phase Transition Autonomy table above.
2. **EXIT REPORT:** Print a Structured Exit Report as your final output. See `phase-protocols.md` for format and valid OUTCOME values.
3. **HANDOFF FILE:** Write/update/read `~/.claude/handoffs/pr-{N}-handoff.json` per lifecycle in `handoff-files.md`.
