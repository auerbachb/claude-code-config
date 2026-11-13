# Subagent Context

> **Always:** Spawn subagents via custom agent definitions in `.claude/agents/` (see "How to Spawn Subagents" below). Use `mode: "bypassPermissions"` on every Agent tool call. Set `model` explicitly at every call site per the Model Selection policy (see below). Use phase decomposition (A/B/C). Timestamp every message (see `monitor-mode.md`). Write handoff files on phase completion (see `handoff-files.md`). Print Structured Exit Report before every subagent exit (see `phase-protocols.md`). Arm the silence ceiling in the same step as the spawn (`scheduling-reliability.md`).
> **Ask first:** Respawning a crashed/no-handoff subagent — tell the user what happened first; exhaustion with valid handoff auto-respawns ("Always do"). A subagent killed by an account usage limit is neither: it parks and wakes, unasked (`subagent-thread-limit-park.md`).
> **Never:** Summarize rules for subagents. Spawn subagents without `mode: "bypassPermissions"`. Spawn without an explicit `model` parameter. Fire-and-forget subagents.

## How to Spawn Subagents

Use `.claude/agents/` definitions. Custom `subagent_type` agents automatically inherit the project CLAUDE.md hierarchy + `.claude/rules/*.md` — no manual rule injection needed. Every Agent call must include:
1. `mode: "bypassPermissions"`.
2. `subagent_type`: `phase-a-fixer`, `phase-b-reviewer`, `phase-c-merger`, `pm-worker`, or `researcher`. **Precondition:** resolution requires the `name:` frontmatter field and a session started (or restarted) after the file exists — see `.claude/agents/README.md`.
3. Explicit `model` (see "Model Selection").
4. Runtime context: PR/issue/branch, repo, handoff path, HEAD SHA, reviewer, optional pre-fetched findings.
5. The verbatim `SAFETY:` block from `safety.md` — kept as a deliberate safety-critical restatement even though it is inherited.
6. The verbatim `MINDSET:` block from `safety.md` — same rationale (try CLI/browser before handoff — see "Capability Discovery") — and `QUESTIONS:` from `human-queue.md`.
7. Same step, but not part of the call: arm the silence ceiling — `bgwork-ceiling.sh --arm-command` → `Monitor` (`persistent: true`).

See `.claude/agents/README.md` for the full placeholder reference and spawning examples.

### Fallback: Explore/Plan and Non-Custom Spawns

Any spawn that does NOT use a `.claude/agents/` definition — built-in Explore/Plan, a bare `general-purpose` call, or a custom type the session has not registered (`Agent type '<name>' not found`) — gets the verbatim SAFETY/MINDSET/QUESTIONS/SKILLS blocks pasted manually, plus the role-specific procedure from `.claude/reference/phase-decomposition.md`. **Never paste the full CLAUDE.md + rules corpus.** Causes and rationale: `.claude/reference/phase-decomposition.md` §Non-custom spawns.

## Model Selection

**Cost-first selection (every spawn).** Resolve `model-route.sh` and execute
`.claude/reference/task-model-routing.md`'s dispatch block for each task/phase.
Choose the cheapest available capable tier; preserve explicit owner choices,
tool/context support, permissions and launch/reserve/budget gates. Persist the
request and decision through scoped state helpers before dispatch; failed writes
launch nothing. Pass the returned alias explicitly; frontmatter is only a cheap
fallback.

Keep cheap retries while producing useful evidence. Slow work, one failed test
or an arbitrary retry count never upgrades a worker. Diagnose equivalent failures
or poor-patch review/CI churn before task-local escalation. Preserve discoveries,
local checks, batched changed pushes, independent review and merge gates. Store
actual cost or unknown; routine retries stay silent.

**Effort is not settable on a spawn** — subagents inherit the parent's effort level; never write an effort instruction into a spawn prompt. **Set model at spawn, never mid-session** — session-scoped caches make tier switches costly (`token-efficiency-audit-2026-07.md` §FU-4).

## Phase Transition Autonomy (Quick Reference)

**Always do:** park + arm the wake on a limit-killed subagent (never ask); local CR review; commit/push after clean local review; create PR after push; enter 60s GitHub polling; fix valid reviewer findings; follow the escalation gate's verdict; launch Phase B after Phase A; launch Phase C after `merge_ready` (auto — no merge-approval pause); verify AC after merge gate; respawn exhaustion with valid handoff.

**Ask first only:** respawning a crashed/no-handoff subagent.

## Token/Turn Exhaustion Protocol (MANDATORY)

Near token exhaustion: write the handoff per `handoff-files.md` and exit; parent auto-launches a replacement.

**NEVER:** ask "should I continue?", die without handoff state, or try to finish "just one more thing."

## Task Decomposition

Give each subagent one phase with explicit exit criteria. **A/B/C decomposition:** procedures in `.claude/agents/phase-{a,b,c}-*.md`; step details: `.claude/reference/phase-decomposition.md`; rationale: `.claude/reference/too-big-recalibration-2026-07.md`.

**Phase C:** Do not duplicate `/wrap` logic; its session-sweep output is **advisory only — never block a merge on a sweep finding**.

**Orchestration:**

- **Transitions:** parent launches Phase A (parallel across PRs allowed); A complete → cleanup per `phase-protocols.md`, then B; B `merge_ready` → launch C within 60s (C verifies gate + AC before `/wrap`).
- **Ceiling:** `PIPELINE_CEILING` (default 4) CR-polled PRs, never over the repo-wide `active_work_cap` (`min()` governs, never raises — `active-work-cap.md`); past CR's hourly cap expect `no_reviewer`. Refill when below — `CLAUDE.md` "KEEP THE PIPELINE FULL".
- **Scope:** counts only PRs you authored (`@me`); a collaborator's or bot's PRs never enter it (contention is context, never a gate).
- **Overflow:** past-ceiling work **queues inline, never becomes a thread chip** (slots: `.claude/skills/subagent/SKILL.md` Step 7).

## Subagent Review Protocol

Review protocol lives in its canonical sources — `cr-local-review.md`, `cr-github-review.md`, `cr-merge-gate.md`, `bugbot.md`, `greptile.md`. Do NOT duplicate them.
