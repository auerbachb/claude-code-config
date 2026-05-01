# Subagent Context

> **Always:** Spawn subagents via custom agent definitions in `.claude/agents/` (see "How to Spawn Subagents" below). Use `mode: "bypassPermissions"` on every Agent tool call. Set `model` explicitly at every call site per the Model Selection policy (see below). Use phase decomposition (A/B/C). Timestamp every message (see `monitor-mode.md`). Write handoff files on phase completion (see `handoff-files.md`). Print Structured Exit Report before every subagent exit (see `phase-protocols.md`). Only fall back to manually passing all rule files if `.claude/agents/` is unavailable in the current repo.
> **Ask first:** Respawning a failed subagent (crash/no handoff state) — tell the user what happened first. Exhaustion with valid handoff is auto-respawn ("Always do").
> **Never:** Summarize rules for subagents. Spawn subagents without `mode: "bypassPermissions"`. Spawn without an explicit `model` parameter. Fire-and-forget subagents.

## How to Spawn Subagents

Use `.claude/agents/` definitions; they embed phase rules. Every Agent call must include:
1. `mode: "bypassPermissions"`.
2. `subagent_type`: `phase-a-fixer`, `phase-b-reviewer`, `phase-c-merger`, or `pm-worker`.
3. Explicit `model` (see "Model Selection").
4. Runtime context: PR/issue/branch, repo, handoff path, HEAD SHA, reviewer, and optional pre-fetched findings.
5. The verbatim `SAFETY:` block from `safety.md`.

See `.claude/agents/README.md` for the full placeholder reference and spawning examples.

### Fallback: Manual Rule Injection

If agent definitions are unavailable (e.g., repo without `.claude/agents/`):

1. Read project-local `CLAUDE.md`, then all project-local `.claude/rules/*.md`.
2. If missing, fall back to global copies.
3. Paste complete contents; do NOT summarize.

## Model Selection

**Defaults (set at every spawn site).** Full rationale: `.claude/agents/README.md`.

| Phase / Agent | Model |
|---------------|-------|
| Phase A (`phase-a-fixer`) | `opus` |
| Phase B (`phase-b-reviewer`) | `opus` |
| Phase C (`phase-c-merger`) | `sonnet` |
| `pm-worker` | `sonnet` |
| Read-only review agents (e.g., `/pr-review-help`) | `sonnet` |

Rules: set `model` explicitly on every spawn; call-site value overrides frontmatter. `CLAUDE_CODE_SUBAGENT_MODEL=opus` is only a legacy safety net. If a Sonnet-tier agent underperforms, escalate to `opus` and document why.

## Phase Transition Autonomy (Quick Reference)

**Always do:** local CR review; commit/push after clean local review; create PR after push; enter 60s GitHub polling; fix valid reviewer findings; follow CR→BugBot→Greptile→self-review fallback timing; launch Phase B after Phase A; launch Phase C after `merge_ready` with merge authorization; verify AC after merge gate; respawn exhaustion with valid handoff.

**Ask first only:** merging (ask before Phase C launch, or pass prior authorization in the prompt); respawning a crashed/no-handoff subagent.

> **Anti-pattern:** If you find yourself composing "Should I...?" or "Want me to...?" for any "Always do" row, stop — the answer is always yes. Execute immediately.

## Token/Turn Exhaustion Protocol (MANDATORY)

Subagents have a 32K output token limit. Near exhaustion: write the token-exhaustion handoff to `~/.claude/session-state.json` (schema in `handoff-files.md`), report what was done/remaining, and exit cleanly. Parent reads state and launches a replacement automatically.

**NEVER:** Ask "should I continue?", silently die without writing handoff state, or try to finish "just one more thing."

## Task Decomposition (Token Safety)

The 32K limit is binding. Give each subagent one phase with explicit exit criteria. Detailed procedures live in `.claude/agents/phase-{a,b,c}-*.md`; fallback: `.claude/reference/phase-decomposition.md`.

- **Phase A: Fix + Push** (heaviest) — fix findings, commit once, push once, reply to threads, write handoff, EXIT (parent cleanup detailed in Orchestration rules below).
- **Phase B: Review Loop** (lighter) — poll/trigger reviewer, fix new findings, update handoff, EXIT.
- **Phase C: Verify + Wrap** (lightest) — verify merge gate + AC, then run `/wrap` to squash-merge, sync main, and report `merged`. Do not duplicate `/wrap` logic.

**Orchestration:** parent launches Phase A (parallel across PRs allowed); Phase A complete → cleanup per `phase-protocols.md` then Phase B; Phase B `merge_ready` → get merge authorization, then launch Phase C. Keep 3-4 active CR-polled PRs max; at 7+ CR reviews/hour expect Greptile fallback.

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
