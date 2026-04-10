# Subagent Context

> **Always:** Spawn subagents via custom agent definitions in `.claude/agents/` (see "How to Spawn Subagents" below). Use `mode: "bypassPermissions"` on every Agent tool call. Set `model` explicitly at every call site per the Model Selection policy (see below). Use phase decomposition (A/B/C). Timestamp every message (see `monitor-mode.md`). Write handoff files on phase completion (see `handoff-files.md`). Print Structured Exit Report before every subagent exit (see `phase-protocols.md`). Only fall back to manually passing all rule files if `.claude/agents/` is unavailable in the current repo.
> **Ask first:** Respawning a failed subagent (crash/no handoff state) — tell the user what happened first. Exhaustion with valid handoff is auto-respawn ("Always do").
> **Never:** Summarize rules for subagents. Spawn subagents without `mode: "bypassPermissions"`. Spawn without an explicit `model` parameter. Fire-and-forget subagents.

## How to Spawn Subagents

Use the custom agent definitions in `.claude/agents/` instead of manually reading and embedding all rule files. Each agent definition is self-contained with embedded phase-specific rules.

### Using Agent Definitions (Preferred)

1. **Always set `mode: "bypassPermissions"`** on the Agent tool call.
2. **Set `subagent_type`** to the appropriate agent definition:
   - `phase-a-fixer` — Fix findings, push, write handoff
   - `phase-b-reviewer` — Poll reviews, process findings, update handoff
   - `phase-c-merger` — Verify merge gate, check AC, report readiness (read-only)
   - `pm-worker` — Issue management, work-log, repo bootstrap
3. **Set `model` explicitly at the call site** (see "Model Selection" below). Each agent definition also declares a frontmatter default (`opus` for Phase A/B; `sonnet` for Phase C and pm-worker), but the call-site `model` parameter takes precedence and makes the choice visible at every spawn.
4. **Provide runtime context in the `prompt` parameter** — the agent definition supplies workflow rules; the prompt supplies PR-specific details:
   - PR number, issue number, branch name
   - Repo owner/name
   - Handoff file path (`~/.claude/handoffs/pr-{N}-handoff.json`)
   - HEAD SHA, reviewer assignment (`cr` or `greptile`)
   - Pre-fetched findings (optional — saves the subagent from re-fetching)
5. **Include the safety warning** in every subagent prompt:

   ```text
   SAFETY: Do NOT delete, overwrite, move, or modify .env files — anywhere, any repo.
   Do NOT run git clean in ANY directory. Do NOT run destructive commands (rm -rf, rm,
   git checkout ., git stash, git reset --hard) in the root repo directory. Stay in your
   worktree directory at all times.
   ```

See `.claude/agents/README.md` for the full placeholder reference and spawning examples.

### Fallback: Manual Rule Injection

If agent definitions are unavailable (e.g., working in a repo without `.claude/agents/`), fall back to the manual approach:

1. Read the root `CLAUDE.md` — check **project root first** (`cat ./CLAUDE.md`), fall back to global (`cat ~/.claude/CLAUDE.md`)
2. Read ALL rule files — check **project root first** (`cat ./.claude/rules/*.md`), fall back to global
3. Include the COMPLETE output of both in the subagent's task description
4. Do NOT summarize, excerpt, or paraphrase — pass the complete files

> **Why project-local first:** Per-project configs override global ones. Passing the global file when a project-level file exists gives subagents the wrong rules.

## Model Selection

The Agent tool's `model` parameter selects which Claude model runs the subagent. Match the model to the phase's cognitive load — this is the cost-efficiency lever.

**Defaults (set at every spawn site):**

| Phase / Agent | Model |
|---------------|-------|
| Phase A (`phase-a-fixer`) | `opus` |
| Phase B (`phase-b-reviewer`) | `opus` |
| Phase C (`phase-c-merger`) | `sonnet` |
| `pm-worker` | `sonnet` |
| Read-only review agents (e.g., `/pr-review-help`) | `sonnet` |

Full per-phase rationale lives in `.claude/agents/README.md` "Model Selection". In short: A/B do the heavy reasoning (fixes, dismissals, severity judgment); C and pm-worker do mechanical verification and data gathering.

**Rules:**

- **Set `model` at the call site explicitly.** Every Agent tool invocation MUST include `model` alongside `mode` and `subagent_type`. Relying on frontmatter defaults or the global `CLAUDE_CODE_SUBAGENT_MODEL` env var hides cost decisions.
- **Call-site `model` overrides agent-definition frontmatter.** Override to `opus` when a specific spawn needs more firepower.
- **`CLAUDE_CODE_SUBAGENT_MODEL=opus` is a legacy safety net — not a compliant pattern.** Do not modify it, and do not rely on it: compliant calls must still set `model` explicitly at the call site. The env var only catches unexpected/undocumented spawns.
- **Cost-optimization ≠ quality regression.** If a Sonnet-tier agent underperforms, escalate that phase's default to `opus` and document why.

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
- Read handoff file. Verify merge gate per `cr-github-review.md` "Completion" section (authoritative definition for both CR and Greptile paths).
- Read PR body, verify all AC against final code, check off all boxes.
- Report ready for merge. Do not delete the handoff file — parent performs deletion after successful user-gated merge (see `phase-protocols.md`).
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
