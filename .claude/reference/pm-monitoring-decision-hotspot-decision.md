# PM Monitoring Decision Hotspot Decision

Reference for Issue #990 (`pm-monitoring-decision.md` churn hotspot). Not auto-loaded.

<!-- churn-hotspot: .claude/reference/pm-monitoring-decision.md -->

## Executive summary

### Verdict: **KEEP** — single-topic hub with legitimate churn; no actionable duplication

Keep `.claude/reference/pm-monitoring-decision.md` intact. Its 7 churn PRs are a tight cluster of
scheduling-substrate corrections (primitive lifecycle changes, durability clarifications, repo-scoping
validation) rippling through the canonical-owner description fields — not independent concerns
accumulating. The file is small (~1,017 words; reference files carry no enforced word budget) and its
one confirmed duplication (PM recovery restatement) was already removed by PR #985 under Issue #984.
No new duplication was found in the current file state against the canonical owners.

## 1. Trigger and diagnosis

The hotspot detector recorded 7 merged PRs touching `.claude/reference/pm-monitoring-decision.md`
since 2026-07-21: PRs #621, #653, #825, #856, #867, #982, and #985.

At diagnosis time the file is approximately 1,017 words. Reference files carry no enforced word
budget (the 2,000-word warning applies only to auto-loaded rule files in `.claude/rules/`); the file
is not at risk of a budget failure.

### Per-section churn attribution

| PR | Title | Section(s) touched | Driver |
|----|-------|-------------------|--------|
| #621 | `feat(#613)`: PM runs A→B→C subagents inline by default | `## Decision` | Orchestration capability expansion — `/pm` updated to describe inline A→B→C execution |
| #653 | `fix(#647)`: scope polling-state-gate repo check per PR | `## State contract` → `root_repo` field | Repo-scoping correction — `root_repo` top-level field clarified as a session-wide default, not a gating value |
| #825 | `fix(#808)`: correct CronCreate durability claims | `## Decision`, `## Rationale` | Scheduling durability correction — CronCreate described as session-only; `durable:true` no-op noted |
| #856 | `fix(#854)`: scope polling-state-gate PR lookups to active repo | `## State contract` → `root_repo` field | Repo-scoping precision — "Genuine" cross-repo mismatch definition extended with PR-number collision semantics |
| #867 | `feat(#827)`: replace CronCreate with session-start reconciliation | `## Decision`, `## Rationale` | Scheduling primitive migration — CronCreate removed as a recurring primitive; `/loop` and then persistent `Monitor` adopted |
| #982 | `fix(#924)`: move recurring polls to Monitor | `## Decision`, `## State contract` | Scheduling primitive finalization — full migration to persistent `Monitor`; Decision section rewritten with #914/#924 evidence |
| #985 | `docs(#984)`: record monitor-mode hotspot decision | `## Recovery protocol` | Deduplication remediation — numbered PM recovery procedure replaced with pointer to `monitor-mode.md` named sections |

### Churn classification

The 7 PRs fall into three classes:

1. **Scheduling-substrate corrections (PRs #825, #867, #982):** Three successive PRs corrected what
   recurrence and durability the available scheduling primitives could actually provide — from
   session-limited CronCreate (#825), through its full retirement (#867), to the final migration to
   persistent `Monitor` validated by negative liveness evidence (#982). These corrections necessarily
   updated the Decision and Rationale sections that document the scheduling division of responsibility.

2. **Repo-scoping corrections (PRs #653, #856):** Two PRs tightened the `root_repo` field
   description as per-PR scoping semantics were clarified under Issues #647 and #854. Each edit
   extended or replaced a single state-contract field description.

3. **Feature and deduplication edits (PRs #621, #985):** PR #621 extended the PM orchestration
   description when the A→B→C inline execution capability was added. PR #985 applied the confirmed
   deduplication from the monitor-mode hotspot audit (Issue #984) — removing a restated numbered
   recovery procedure and replacing it with section pointers.

**Recurring theme:** Every edit updates citations and state-field descriptions in response to
infrastructure changes elsewhere in the corpus. No independent new concern has accumulated inside
the file. The file's churn is edit-count-heavy rather than size-growth-heavy.

## 2. Options considered

### Option A: Split into separate concern files

Split the Decision section, State contract, and Skill integration decision into three files.

**Rejected.** The file is small (~1,017 words) and its sections form an integrated reference:
the Decision records the ownership boundary, the State contract describes what `/pm` reads and
writes under that boundary, and the Skill integration section names the callers. Splitting would
require callers (`scheduling-reliability.md`, `monitor-mode.md`, skills that cite named sections)
to update references without gaining independently-evolving content.

### Option B: Extract deterministic blocks into scripts

Following the `fixpr` hotspot pattern: extract command blocks that can run deterministically.

**Rejected.** The file contains no command blocks. Its content is ownership policy, field
semantics, and session-state framing — agent judgment, not repeatable `jq` or shell operations.
`.claude/reference/script-extraction-audit.md` is explicitly out of scope for policy-only files.

### Option C: Additional deduplication pass

Verify current state against canonical owners and remove any residual duplication.

**Evaluated.** The Recovery protocol section was examined and confirmed to be pointer-only — it
cites `monitor-mode.md` `## Post-Compaction Recovery` and `## PM Monitoring Recovery` by name
without restating their procedures. The State contract field descriptions were compared against
`scheduling-reliability.md` and the session-state schema: the file describes `/pm`'s specific reads
and writes without restating primitive-selection policy or schema field definitions. No new
lockstep duplication was found. No edits are warranted.

### Option D: KEEP without change

Record the verdict and make no content changes.

**Chosen.** The file is a single-topic hub, small, and already deduped under Issue #984.
Its churn reflects substrate evolution, not content bloat.

## 3. Ownership boundaries

| Content | Canonical owner | Non-owner action |
|---------|-----------------|------------------|
| PM/fleet monitor division of responsibility and scheduling primitive selection | `.claude/rules/scheduling-reliability.md` `## PM Monitoring Primitive` | `pm-monitoring-decision.md` is the rationale record; `scheduling-reliability.md` is the operative rule |
| Post-compaction session reconciliation and recovery heartbeat | `.claude/rules/monitor-mode.md` `## Post-Compaction Recovery` | `pm-monitoring-decision.md` `## Recovery protocol` points to this named section |
| PM orchestration rebuild and scheduler-ownership boundaries | `.claude/rules/monitor-mode.md` `## PM Monitoring Recovery` | `pm-monitoring-decision.md` `## Recovery protocol` points to this named section |
| `session-state.json` field schemas and write-lock contract | `.claude/reference/state-file-contracts.md` and `session-state.sh --help` | `pm-monitoring-decision.md` describes only the fields `/pm` reads and writes, not the full schema |
| Recurring scheduler liveness and pre-exit checklist | `.claude/rules/scheduling-reliability.md` | `pm-monitoring-decision.md` cites it by name; does not restate selection logic |
| Cross-session durability rationale | `.claude/reference/cross-session-durability.md` | `pm-monitoring-decision.md` links to it; does not duplicate rationale |
| Per-PR polling state and repo-identity validation | `.claude/scripts/polling-state-gate.sh` + `session-state.sh` | `pm-monitoring-decision.md` describes the `root_repo` field semantics as context; implementation lives in scripts |

## 4. Duplication check result

No new lockstep duplication was found in the current file. Confirmed:

- `## Recovery protocol` is pointer-only (no numbered recovery steps restated) — satisfied by PR #985.
- The `root_repo` field description documents the field's session-file semantics for PM callers
  without restating the full polling-state-gate validation logic.
- The primitive-selection summary at the top of `## Decision` names `scheduling-reliability.md`
  as the authoritative rule rather than defining a competing selection table.
- `polling_jobs[]` description explicitly marks it legacy and defers reconciliation to
  `session-scheduling-reconcile.sh` — no active CronCreate registry behavior restated.

No content changes to `.claude/reference/pm-monitoring-decision.md` are warranted.

## 5. What to preserve

- The `## Decision` section's four bullet points that define the PM/fleet-monitor division — they
  are the rationale for the canonical rule, not a competing definition of it.
- The `## Rationale` section explaining why `/pm` must not arm a recurring poll — unique context
  not found in `scheduling-reliability.md`.
- The `## State contract` fields for `monitoring_active`, `monitoring_mode`, `root_repo`, `prs`,
  `active_agents`, `polling_jobs`, `polling_failures`, `cr_quota`, `greptile_daily`, and `pmm_*`
  — `/pm`-specific reads and writes that the schema file does not organize by skill.
- The `## Recovery protocol` section's pointer-only form — any future PM recovery change should
  only update the canonical section in `monitor-mode.md`.
- The `## Skill integration decision` section listing per-skill scheduling decisions — unique
  cross-skill summary not owned by any individual skill file.

## 6. Future edits

Scheduling-policy or PM-role changes should update the canonical owners (`scheduling-reliability.md`,
`monitor-mode.md`) and leave `pm-monitoring-decision.md`'s Decision and Rationale sections as
correspondingly updated summaries. Reconsider the KEEP verdict only if:

- The file crosses a size threshold where its sections are independently cited by disjoint callers, or
- A new independently-evolving concern accumulates (state contract fields grow faster than the
  decision/rationale text, for example, justifying a standalone field reference).

Re-evaluate extraction only if a repeatable deterministic command block appears — none exists today.

## Related precedent

- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup for `monitor-mode.md`; the
  controlling decision that removed duplication from `pm-monitoring-decision.md` (Issue #984).
- `.claude/reference/scheduling-reliability-hotspot-decision.md` — KEEP + dedup for
  `scheduling-reliability.md`; same substrate-correction churn pattern (Issue #959).
- `.claude/reference/session-state-schema-hotspot-decision.md` — KEEP + targeted-dedup for the
  session-state schema; companion field-contract reference.
- `.claude/reference/churn-hotspots.md` — detector scope and observational-ticket rationale.
