# session-state.sh hotspot — diagnosis and KEEP decision

Reference for Issue #952 (`.claude/scripts/session-state.sh` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single-script implementation; no operative code changes

The 11-PR churn (PRs #630, #654, #659, #662, #694, #721, #728, #855, #931, #937, #989) is a
**completed foundational build-out**, not ongoing independent evolution of co-located concerns.
Three distinct churn classes are present: foundational mechanism additions (6 PRs), incremental
corner-case refinements (3 PRs), and peripheral touches (2 PRs). The mechanism is now stable.

The concerns most likely to evolve independently are **already extracted**:
- Lock lifecycle → `state-lock.sh` (PRs #662, #937 integrated that extraction)
- Case normalization → `lib/repo-normalizer.sh` (PR #728 extracted it; 4 callers share it)

The remaining inline concerns — field-type contract and legacy migration engine — have exactly
**one caller**: `session-state.sh` itself. Extracting them into `lib/` modules would add sourcing
overhead and test-harness complexity (callers copying the script must also copy lib/ siblings)
with no shared-code benefit and no reduction in future churn from mechanism additions.

The extract-not-split pattern (merge-gate.sh precedent) applies when INTERNAL DUPLICATION exists
across independently-evolving code paths. No such duplication exists here — each concern has
unique code with no repetition across paths in the same file.

## 1. Churn measurement

Issue #952 records 11 distinct PRs touching `.claude/scripts/session-state.sh` since 2026-07-19:

| PR | Issue | Title | Concern |
|----|-------|-------|---------|
| #630 | #625 | enforce field-type contract (top-level) | Field-type contract |
| #654 | #640 | extend field-type contract to per-PR nested | Field-type contract |
| #659 | #638 | scope per-repo + legacy migration | Repo scoping / migration |
| #662 | #639 | serialize writes with portable mkdir lock | Lock lifecycle (now in state-lock.sh) |
| #694 | #687 | `--session-view`: scope /pm to invoking repo | Scope filtering |
| #721 | #712 | exclude `_unknown` from session-view other-repo claims | Scope filtering |
| #728 | #704 | lowercase repo scope key via shared normalizer | Case normalization (now in lib/repo-normalizer.sh) |
| #855 | #853 | fix false/null coercion in --set probe (consistency with handoff-state.sh) | Peripheral alignment |
| #931 | #779 | add CLAUDE_SCRIPT_USAGE_LOG telemetry opt-out | Peripheral feature |
| #937 | #930 | real mutual exclusion on Linux (state-lock.sh primary) | Lock lifecycle (extracted) |
| #989 | #964 | adjudicate session-state-schema.json hotspot (docs only) | Documentation |

### Churn class breakdown

| Class | PRs | Count |
|-------|-----|-------|
| Foundational mechanism additions | #630, #654, #659, #662, #694 | 5 |
| Incremental corner-case refinements | #721, #728, #937 | 3 |
| Peripheral touches (alignment, telemetry, docs) | #855, #931, #989 | 3 |

**Conflict-round evidence:** none documented. All 11 PRs addressed distinct, non-overlapping
sections of the file. No merge conflict or churn-collision was recorded in the PR histories.

## 2. Concerns and their current owners

| Concern | Lines in session-state.sh | Canonical owner | Other callers |
|---------|---------------------------|-----------------|---------------|
| CLI contract + arg parsing | ~110 lines (764–875) | session-state.sh | 45+ callers via exec |
| Field-type contract | ~130 lines (395–762) | session-state.sh | **None** — single caller |
| Repo scoping + migration | ~135 lines (579–915) | session-state.sh | **None** — single caller |
| Lock lifecycle | ~5 lines (integration) | `state-lock.sh` | polling-state-gate.sh, handoff-state.sh |
| Case normalization | ~3 lines (integration) | `lib/repo-normalizer.sh` | session-state.sh, handoff-state.sh, handoff-migrate.sh, polling-state-gate.sh |
| --set write path | ~180 lines (1118–1395) | session-state.sh | **None** — single caller |
| --get / --session-view read path | ~155 lines (920–1076) | session-state.sh | **None** — single caller |

The two extractable concerns identified by the CR plan (field-type contract, migration engine)
each have **exactly one caller** — session-state.sh itself. `repo-normalizer.sh` was extracted
because four scripts share it; `state-lock.sh` was extracted because the lock machinery has its
own evolution surface (Linux portability, stale-detection, retry budgets). Neither rationale
applies to field-type or migration code.

## 3. Options considered

### Option A: KEEP as-is (chosen)

No code changes. Write this decision record so future PRs can trace the reasoning.

**Rationale:**
- Churn is completed build-out; ongoing maintenance rate is expected to be low
- Lock and normalization — the concerns with independent evolution — are already extracted
- No internal duplication: each concern's code is unique, not repeated across paths
- Field-type and migration code has exactly one caller; no shared-lib benefit exists
- Test suites (session-state.test.sh, session-state-migration.test.sh) call the script directly
  without copying it, so no harness complexity is added

### Option B: Extract field-type contract → lib/session-state-schema.sh

Not chosen.

The functions (`load_field_types`, `known_field_type`, `known_nested_field_type`,
`top_level_key_of`, `pr_number_of`, `pr_nested_key_of`, `pr_whole_entry_write_number_of`)
are the internal implementation of the field-type guard. They call no external resources and
have no callers outside session-state.sh. Extracting them would:
- Add a lib/ sourcing block (3–5 lines) with a new not-found/load-fail exit path
- Require any future script that copies session-state.sh in a stub directory to also copy
  lib/session-state-schema.sh (today no test does this, but it becomes a maintenance trap)
- Not prevent any class of churn — a new schema field still requires editing both the jq schema
  file and the callers in session-state.sh's --set and --get blocks

The last field-type PR was #654 (issue #640), closed 2026-07-21. No open issue references the
field-type contract for further changes. The concern is stable.

### Option C: Extract migration engine → lib/session-state-migrate.sh

Not chosen.

The migration helpers (`build_path_map`, `MIGRATE_JQ`, `has_unmigratable_legacy`,
`warn_if_unmigratable`, `migrate_jq_args`) are tightly coupled to the main write path: every
`--set` call runs `migrate_jq_args` and embeds `$MIGRATE_JQ` into the atomic write pipeline.
Extracting them would:
- Not reduce the number of lines in the main write path (the pipeline references persist)
- Require `migrate_jq_args` to export `MIGRATE_JQ` as a variable or function return, adding
  an inter-module coupling that doesn't exist today
- Not prevent churn from new per-repo scope edge cases (those require editing the main `scope_path`
  and the `--session-view` blocks, neither of which would move)

The last migration PR was #728 (issue #704), closed 2026-07-22. No open issue references the
migration engine for further changes. The concern is stable.

### Option D: Full split into multiple sibling scripts

Rejected. The script has 45+ callers depending on a single `session-state.sh <flags>` invocation.
A split would break all of them and require re-architecting the test suites. The merge-gate.sh
precedent (PR #1010, 16 churn PRs) also rejected this option for the same reason.

## 4. What was explicitly preserved

- CLI contract: `--get`, `--set`, `--session-view`, `--repo-key`, `--migrate`, `--dry-run`,
  `--all-repos`, `--raw-path`, `--repo <key>` — all flags, all documented modes
- Exit codes: 0 (OK), 2 (usage), 3 (missing file on `--get`), 4 (type violation or parse error),
  5 (write failed), 6 (lock timeout)
- Migration-on-write behavior: every `--set` applies the legacy→scoped migration atomically
- Lock semantics: `state_lock_acquire` before read, held through the atomic mv
- Field-type contract: schema-driven validation from `session-state-schema.json`
- Telemetry opt-out: `CLAUDE_SCRIPT_USAGE_LOG=0` skips the usage log

## 5. Reconsideration criteria

Reconsider extraction if:
- A second script needs to call `build_path_map` or the field-type helpers independently (making
  them truly shared code)
- A new mechanism addition requires editing both field-type and migration blocks in the same PR,
  showing genuine co-location collision rather than independent phased build-out
- Measured conflict rounds appear (not just touch count) — two writers editing the same lines in
  the same PR window is the signal, not PR frequency alone

Reconsider split if:
- A consumer needs only one mode (`--get` without `--set` locking overhead) and performance
  measurement confirms the current design is the bottleneck

## Related

- Issue #638 — repo-scoping redesign (the primary migration churn driver)
- Issue #625, #640 — field-type contract (primary type-guard churn driver)
- Issue #639, #930 — lock lifecycle (already extracted to state-lock.sh)
- Issue #704 — case normalization (already extracted to lib/repo-normalizer.sh)
- `.claude/reference/merge-gate-hotspot-decision.md` (#936) — precedent for extract-not-split
  when internal DUPLICATION exists (the rationale that does NOT apply here)
- `.claude/reference/state-file-contracts-hotspot-decision.md` (#1012) — precedent for KEEP when
  the file is a canonical mechanism owner and churn tracks coordinated contract delivery
- `.claude/reference/session-state-schema-hotspot-decision.md` (#964) — KEEP decision for the
  sibling JSON schema file
- `.claude/reference/session-state-convergence-audit.md` (#651) — post-merge convergence audit
  confirming all four foundational PRs compose coherently
- `.claude/scripts/tests/session-state.test.sh` — field-type contract regression suite
- `.claude/scripts/tests/session-state-migration.test.sh` — migration regression suite
