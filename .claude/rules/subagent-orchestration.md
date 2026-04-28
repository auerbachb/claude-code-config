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
   - `pm-worker` — Issue management, repo bootstrap
3. **Set `model` explicitly at the call site** (see "Model Selection" below). Each agent definition also declares a frontmatter default (`opus` for Phase A/B; `sonnet` for Phase C and pm-worker), but the call-site `model` parameter takes precedence and makes the choice visible at every spawn.
4. **Provide runtime context in the `prompt` parameter** — the agent definition supplies workflow rules; the prompt supplies PR-specific details:
   - PR number, issue number, branch name
   - Repo owner/name
   - Handoff file path (`~/.claude/handoffs/pr-{N}-handoff.json`)
   - HEAD SHA, reviewer assignment (`cr`, `bugbot`, or `greptile`)
   - Pre-fetched findings (optional — saves the subagent from re-fetching)
5. **Include the safety warning** in every subagent prompt — copy the `SAFETY:` block from `safety.md` "Subagent Warning (MANDATORY)" verbatim. It covers `.env` handling, destructive commands, secrets/credentials, untrusted installers, and TLS bypass.

See `.claude/agents/README.md` for the full placeholder reference and spawning examples.

### Fallback: Manual Rule Injection

If agent definitions are unavailable (e.g., repo without `.claude/agents/`):

1. Read `CLAUDE.md` — **project root first**, fall back to global
2. Read ALL rule files — **project root first**, fall back to global
3. Include the COMPLETE output in the subagent's task description — do NOT summarize or paraphrase

> **Why project-local first:** Per-project configs override global ones.

## Model Selection

**Defaults (set at every spawn site).** Full rationale: `.claude/agents/README.md` "Model Selection".

| Phase / Agent | Model |
|---------------|-------|
| Phase A (`phase-a-fixer`) | `opus` |
| Phase B (`phase-b-reviewer`) | `opus` |
| Phase C (`phase-c-merger`) | `sonnet` |
| `pm-worker` | `sonnet` |
| Read-only review agents (e.g., `/pr-review-help`) | `sonnet` |

**Rules:**

- **Set `model` at the call site explicitly.** Every Agent tool invocation MUST include `model` alongside `mode` and `subagent_type`.
- **Call-site `model` overrides agent-definition frontmatter.** Override to `opus` when a specific spawn needs more firepower.
- **`CLAUDE_CODE_SUBAGENT_MODEL=opus` is a legacy safety net — not a compliant pattern.** Compliant calls must still set `model` explicitly. The env var only catches undocumented spawns.
- **Cost-optimization ≠ quality regression.** If a Sonnet-tier agent underperforms, escalate to `opus` and document why.

## Phase Transition Autonomy (Quick Reference)

| Transition | Action | Classification |
|------------|--------|----------------|
| Coding complete | Run local CR review (`coderabbit review --prompt-only`) | **Always do** |
| Local review clean (2 passes) | Commit all changes, push branch | **Always do** |
| Branch pushed | Create PR via `gh pr create` | **Always do** |
| PR created/updated | Enter GitHub review polling loop (60s cycle) | **Always do** |
| CR/BugBot/Greptile posts findings | Fix all valid findings, commit, push, reply to threads | **Always do** |
| CR rate-limited (fast-path) | Escalate immediately regardless of elapsed minutes; check BugBot review; if absent, wait up to 10 min for BugBot | **Always do** |
| CR timeout (12 min) | Check BugBot review; if absent, trigger Greptile immediately (BugBot's 10-min window from push has already elapsed) | **Always do** |
| BugBot timeout (10 min, CR already failed) | Trigger Greptile | **Always do** |
| All three reviewers down | Self-review for risk reduction | **Always do** |
| Phase A subagent completes | Parent launches Phase B within 60s | **Always do** |
| Phase B reports merge_ready | Parent launches Phase C | **Always do** |
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

## Task Decomposition (Token Safety)

The 32K limit is the binding constraint. Give each subagent ONE clear phase with explicit exit criteria — no exploratory instructions. Detailed per-phase procedures live in the agent definitions (`.claude/agents/phase-{a,b,c}-*.md`); if agent definitions are unavailable, use `.claude/reference/phase-decomposition.md`.

- **Phase A: Fix + Push** (heaviest) — fix findings, commit once, push once, reply to threads, write handoff, EXIT (parent cleanup detailed in Orchestration rules below).
- **Phase B: Review Loop** (lighter) — poll/trigger reviewer, fix new findings, update handoff, EXIT.
- **Phase C: Merge Prep** (lightest) — verify merge gate per `cr-merge-gate.md` + AC, report readiness, EXIT. Do not delete handoff.

**Orchestration rules:**
- Parent launches Phase A subagents (can run in parallel across PRs)
- Phase A complete → parent removes the Phase A worktree (releases branch lock), then launches Phase B immediately (see `phase-protocols.md` Phase A Completion Protocol for the authoritative cleanup step)
- Phase B merge_ready → parent launches Phase C
- Soft limit: 3-4 active CR-polled PRs to reduce throttling
- Track CR quota: 7+ reviews/hour means expect Greptile as primary reviewer

## Subagent Review Protocol

Review protocol is defined authoritatively in these canonical sources — do NOT duplicate:

- **CR polling, CI checks, thread resolution:** `cr-github-review.md`
- **Merge gate, CI-must-pass, AC verification:** `cr-merge-gate.md`
- **BugBot (Cursor) second-tier reviewer, auto-trigger, merge gate:** `bugbot.md`
- **Greptile trigger, severity classification, daily budget, reply format:** `greptile.md`
- **Local review before push, fix loop, 1 clean pass to exit:** `cr-local-review.md`

**Three reminders for subagents:**
1. **AUTONOMY:** Every phase transition is automatic — do NOT ask "should I?" See the Phase Transition Autonomy table above.
2. **EXIT REPORT:** Print a Structured Exit Report as your final output. See `phase-protocols.md` for format and valid OUTCOME values.
3. **HANDOFF FILE:** Write/update/read `~/.claude/handoffs/pr-{N}-handoff.json` per lifecycle in `handoff-files.md`.
