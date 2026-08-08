# Phase Protocols Hotspot Decision

Reference for Issue #1126 (`.claude/rules/phase-protocols.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single rule file; **no operative changes**

Keep `.claude/rules/phase-protocols.md` intact as the canonical parent-agent contract for Phase
A/B/C completion protocols and the `/wrap → /fixpr` delegation pointer. The file is 605 words
(50 lines), well below the 2,000-word per-file warning. It has been shrinking, not growing. Its
mechanism detail is already extracted to dedicated reference docs. The three PRs in the churn
window all made small, purposeful policy edits — not additions of new scope.

## 1. Trigger and diagnosis

The churn detector reported three merged PRs touching `.claude/rules/phase-protocols.md` since
2026-07-28: PRs #804, #862, and #1125. All three are confirmed by tracing git history.

**Verified word count history** (via `git show <sha>:.claude/rules/phase-protocols.md | wc -w`):

| Point in time | Commit | Word count |
|---|---|---|
| 2026-07-02, before ratchet-headroom extract pass | 72b2fc4 | 817 |
| 2026-07-30, after PR #804 corpus compression | 609452c | 617 |
| 2026-08-01, after PR #862 chatter-cut | bb6de94 | 598 |
| 2026-08-07, after PR #1125 clean-merge one-liner | a7a2094 | 605 (current) |

Note: `instruction-set-audit-2026-07.md` recorded 801 words for this file on 2026-07-02; the
difference from the 817 figure above reflects measurement-time variation between the two passes
committed on the same date. Both measurements confirm the file was in the 800-word range before
the compression cycle and is now at 605 words, well below the 2,000-word per-file warning.

**Verified PR attributions:**

- **PR #804** (commit `609452c`, 2026-07-30): `refactor(#790): compress rule corpus 12166 → 10999
  words, reset ratchet` — part of the 17-file corpus-compression sweep for Issue #790, described
  in `too-big-recalibration-2026-07.md`. Removed 83 words (700 → 617): 18 lines changed,
  6 insertions, 12 deletions. Trimmed mechanism prose without touching any behavioral contract.

- **PR #862** (commit `bb6de94`, 2026-08-01): `feat(#851): cut agent chatter to heartbeat +
  decision points` — dropped routine "Report to user" steps from Phase A step 8, Phase B step 6,
  and Phase C step 5. Blocker, failure, and exhaustion reporting all stayed. Also fixed Phase B
  step 2 exhaustion-reporting contradiction (BugBot finding on the first push). 19 words removed
  (617 → 598): 9 lines changed, 3 insertions, 6 deletions. **Confirmed touch** — the commit
  message explicitly names `phase-protocols.md` and the git diff shows `.claude/rules/phase-protocols.md | 9 +++------`.

- **PR #1125** (commit `a7a2094`, 2026-08-07): `feat(#869): clean merges emit a one-line
  "merged PR #N"` — updated Phase C step 4 to add "A clean merge is silent." to the handoff
  cleanup note. 7 words added (598 → 605): 2 lines changed, 1 insertion, 1 deletion. Small
  propagation of the Issue #869 decision across CLAUDE.md, phase-protocols.md, and wrap/SKILL.md.

All three touches were small and purposeful. None added new scope. No touch caused merge conflicts.
The churn reflects the file's role as a shared parent-agent hub that receives propagated policy
decisions, not a growing or contested implementation block.

## 2. Options considered

### Option 1: Split into per-phase files

Create separate files for Phase A, Phase B, and Phase C completion protocols.

**Rejected.** The file is 605 words / 50 lines — far below the threshold that would justify a
split. The three phase protocols share the same structural contract (parse exit report, branch on
OUTCOME, verify outputs, launch next phase, update session-state.json). Splitting would scatter a
unified behavioral pattern across three files with no reduction in edit surface, since any
OUTCOME-shape change would touch all three files.

### Option 2: Extract the delegation contract

Move the `/wrap → /fixpr` delegation pointer into a standalone reference.

**Rejected.** The delegation note is a single sentence pointing to `wrap-fixpr-delegation.md`,
which already owns the full semantics. There is no mechanism block here whose extraction would
reduce churn. The delegation ownership is already correctly split; the pointer exists precisely
because `phase-protocols.md` authors `/wrap` invocations via Phase C, which delegates recovery
back to `/fixpr`.

### Option 3: Keep the rule file unchanged

Retain `phase-protocols.md` as-is and record a KEEP verdict.

**Chosen.** The file is small, shrinking, purposefully cross-referenced, and unchanged in its
behavioral contract. All recent edits were propagated policy decisions, not new scope. This matches
the KEEP precedent for comparable hub rule files.

## 3. Ownership boundaries

| Content | Canonical owner |
|---------|----------------|
| Parent-agent Phase A/B/C completion protocols | `.claude/rules/phase-protocols.md` |
| `/wrap → /fixpr` delegation pointer and entry conditions | `.claude/rules/phase-protocols.md` |
| `EXIT_REPORT` field schema and valid `OUTCOME` values | `.claude/reference/exit-report-format.md` |
| Full `/wrap → /fixpr` delegation semantics | `.claude/reference/wrap-fixpr-delegation.md` |
| Verification evidence requirements per phase | `.claude/reference/verification-evidence-patterns.md` |
| Child-side subagent Phase A/B/C procedures | `.claude/reference/phase-decomposition.md` |
| Structured Exit Report detailed format | `.claude/reference/exit-report-format.md` |

`phase-protocols.md` owns only the parent-agent response to a returned subagent — it does not
duplicate the child-side procedures or the schema already in the reference docs.

## 4. Remediation applied

No changes to `.claude/rules/phase-protocols.md` or any dependent file. The KEEP verdict requires
only this decision record and its catalog entry.

## 5. Preserved invariants

- `.claude/rules/phase-protocols.md` is byte-for-byte unchanged. Its `Always / Ask first / Never`
  header and every named section remain intact.
- The Phase A, Phase B, and Phase C completion protocols remain the sole canonical parent-agent
  response contract for each phase transition.
- No completion behavior moves to a script or a second path.
- The `/wrap → /fixpr` delegation pointer remains in place; `wrap-fixpr-delegation.md` remains its
  semantic owner.
- `.claude/rules/.budget-soft-cap` is untouched; the auto-loaded corpus does not change.

## 6. Verification and future edits

Verification confirms:
- `.claude/rules/phase-protocols.md` is unchanged (git diff HEAD is clean for that path).
- No changes to `CLAUDE.md`, `.claude/agents/phase-b-reviewer.md`,
  `.claude/agents/phase-c-merger.md`, `.claude/reference/phase-decomposition.md`, or
  `.claude/reference/exit-report-format.md`.
- `bash .claude/scripts/reference-catalog-lint.sh` passes after the catalog entry is added.
- `bash .github/scripts/rule-lint.sh` and `bash .github/scripts/verbatim-block-lint.sh` pass.

Future policy changes that affect phase transitions should edit `phase-protocols.md` directly.
Reconsider splitting only if independent concerns grow past the per-file size limit or gain callers
that no longer need the shared hub. Reconsider extraction only when a repeatable deterministic
operation (not agent judgment) appears. Raw touch count alone never justifies restructuring a
binding rule file.

## 7. Related precedent

- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup for `monitor-mode.md`
  (9 PRs in the hotspot window), the closest structural sibling: small, `(MANDATORY)`-tagged,
  heavily cross-referenced hub rule.
- `.claude/reference/phase-a-fixer-hotspot-decision.md` — KEEP for `phase-a-fixer.md` agent
  contract (9 merged PRs); content unchanged, churn driven by coordinated policy propagation.
- `.claude/reference/phase-b-reviewer-hotspot-decision.md` — KEEP for `phase-b-reviewer.md`
  state machine (14 merged PRs); same KEEP + coordinated-propagation verdict.
- `.claude/reference/phase-c-merger-hotspot-decision.md` — KEEP + dedup for `phase-c-merger.md`
  (9 merged PRs); analogous completion-protocol ownership boundary outcome.
- `.claude/reference/subagent-orchestration-churn-audit-2026-07.md` — KEEP + dedup for
  `subagent-orchestration.md`, the upstream spawn-policy owner that delegates completion
  handling to `phase-protocols.md`.
