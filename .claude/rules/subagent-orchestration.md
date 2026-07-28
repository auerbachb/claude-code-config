# Subagent Context

> **Always:** Spawn subagents via custom agent definitions in `.claude/agents/` (see "How to Spawn Subagents" below). Use `mode: "bypassPermissions"` on every Agent tool call. Set `model` explicitly at every call site per the Model Selection policy (see below). Use phase decomposition (A/B/C). Timestamp every message (see `monitor-mode.md`). Write handoff files on phase completion (see `handoff-files.md`). Print Structured Exit Report before every subagent exit (see `phase-protocols.md`). Only fall back to manually passing all rule files if `.claude/agents/` is unavailable in the current repo.
> **Ask first:** Respawning a crashed/no-handoff subagent — tell the user what happened first; exhaustion with valid handoff auto-respawns ("Always do").
> **Never:** Summarize rules for subagents. Spawn subagents without `mode: "bypassPermissions"`. Spawn without an explicit `model` parameter. Fire-and-forget subagents.

## How to Spawn Subagents

Use `.claude/agents/` definitions; they embed phase rules. Every Agent call must include:
1. `mode: "bypassPermissions"`.
2. `subagent_type`: `phase-a-fixer`, `phase-b-reviewer`, `phase-c-merger`, or `pm-worker`.
3. Explicit `model` (see "Model Selection").
4. Runtime context: PR/issue/branch, repo, handoff path, HEAD SHA, reviewer, and optional pre-fetched findings.
5. The verbatim `SAFETY:` block from `safety.md`.
6. The verbatim `MINDSET:` block from `safety.md` (try CLI before handoff — see "Capability Discovery").
7. The verbatim `SKILLS:` block from `skill-first.md` for `phase-a-fixer`, `phase-b-reviewer`, and `pm-worker` — **skip it for `phase-c-merger`** (no `Skill` tool; see `skill-first.md` "Reaching Subagents").

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

Fleet: **Fable 5, Opus 5, Sonnet 5, Haiku 4.5**. Fable 5 has no bare alias and is **never a spawn default** — reserve it for interactive step-ups where a human watches the spend. Alias resolution and per-phase rationale: `.claude/agents/README.md` §Model Selection.

Rules: set `model` explicitly on every spawn (call-site overrides frontmatter; `CLAUDE_CODE_SUBAGENT_MODEL` is only a legacy safety net). If a Sonnet-tier agent underperforms, escalate to `opus` and document why.

## Phase Transition Autonomy (Quick Reference)

**Always do:** local CR review; commit/push after clean local review; create PR after push; enter 60s GitHub polling; fix valid reviewer findings; follow CR→BugBot→Greptile→self-review fallback timing; launch Phase B after Phase A; launch Phase C after `merge_ready` (auto — no merge-approval pause); verify AC after merge gate; respawn exhaustion with valid handoff.

**Ask first only:** respawning a crashed/no-handoff subagent.

> **Anti-pattern:** composing "Should I...?" for any "Always do" row — the answer is always yes (CLAUDE.md); execute immediately.

## Token/Turn Exhaustion Protocol (MANDATORY)

Subagents have a 32K output token limit. Near exhaustion: write the token-exhaustion handoff to `~/.claude/session-state.json` (schema: `handoff-files.md`), report done/remaining, exit cleanly; the parent auto-launches a replacement.

**NEVER:** ask "should I continue?", die without handoff state, or try to finish "just one more thing."

## Task Decomposition (Token Safety)

The 32K limit is binding. Give each subagent one phase with explicit exit criteria. Procedures: `.claude/agents/phase-{a,b,c}-*.md`; fallback: `.claude/reference/phase-decomposition.md`.

- **Phase A: Fix + Push** (heaviest) — fix findings, commit once, push once, reply to threads, write handoff, EXIT (parent cleanup: Orchestration below).
- **Phase B: Review Loop** (lighter) — poll/trigger reviewer, fix new findings, update handoff, EXIT.
- **Phase C: Verify + Wrap** (lightest) — verify merge gate + AC, then `/wrap` to squash-merge, sync main, report `merged`. Do not duplicate `/wrap` logic; its session-sweep output is **advisory only — never block a merge on a sweep finding**.

**Orchestration:** parent launches Phase A (parallel across PRs allowed); Phase A complete → cleanup per `phase-protocols.md` then Phase B; Phase B `merge_ready` → launch Phase C within 60s (auto `/wrap`, silent merge). Keep 3-4 active CR-polled PRs max; at 7+ CR reviews/hour expect Greptile fallback. **This ceiling counts only PRs you authored (`@me`)** — a collaborator's or bot's PRs never enter it or gate your own work (shared-budget contention is context, never a gate). The same 3-4 ceiling is the inline A→B→C pipeline cap for `/pm` and `/subagent` — queue issues beyond it (mechanics + slot semantics: `.claude/skills/subagent/SKILL.md` Step 7).

## Subagent Review Protocol

Review protocol lives in the canonical sources — `cr-github-review.md` (polling, CI, threads), `cr-merge-gate.md` (gate, AC), `bugbot.md`, `greptile.md`, `cr-local-review.md` (local loop) — do NOT duplicate them.

**Three reminders for subagents:**
1. **AUTONOMY:** every phase transition is automatic — do NOT ask "should I?" (table above).
2. **EXIT REPORT:** print a Structured Exit Report as final output (`phase-protocols.md`).
3. **HANDOFF FILE:** write/update/read `~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json` (resolve path: `handoff-state.sh --owner-repo <owner/repo> --path N`) per `handoff-files.md`.
