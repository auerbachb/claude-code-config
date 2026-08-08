<!-- churn-hotspot: .claude/skills/go-on/SKILL.md -->
# Hotspot Decision — go-on/SKILL.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-08
**Issue:** #1116
**Reporter:** `/wrap` post-merge churn report (PR #1115)

*Reference for Issue #1116 (`.claude/skills/go-on/SKILL.md` churn hotspot). Not auto-loaded.*

## Churn summary

`churn-hotspots.sh` flagged `.claude/skills/go-on/SKILL.md` as touched by 3 distinct merged PRs
since 2026-07-24: PRs #763, #806, and #904.

The skill is a 402-line, 12-step (Steps 0–10, with Step 1 and Step 1b) review-and-merge resume
workflow. It is the canonical entry point for resuming an interrupted review or merge session.

| PR | Step changed | Change class | What changed |
|----|-------------|-------------|-------------|
| PR #763 | Step 1 | Feature addition | Added diff-survival guard section (Issue #757); detects silent conflict resolutions that drop the PR's own changes. Renamed the former "Step 1: Check for uncommitted changes" to "Step 1b" to accommodate the new Step 1 prefix guard. |
| PR #806 | Step 2 | Coverage classification addition | Added trailing bullet at end of Step 2 (local CR review loop) requiring the agent to classify and print coverage (`both \| cr-only \| codeant-only \| none`) after the review loop completes (Issue #769). Also updated Step 4 PR-body label behavior. |
| PR #904 | Step 7 | Correctness fix | Corrected the exit-code description for `reply-thread.sh` to accurately reflect that exit code `0` means "reply posted (by either inline or fallback path)" and non-zero means genuine failure — fixing an incorrect description that had `1` as "fallback PR-level reply posted (still success)" which caused callers to treat a successful fallback as failure (Issue #884). |

**Measured score:** 3 PRs (at the detection threshold of 3).

## Diagnosis

The churn is low-volume, independent, and non-conflicting.

**Three independent single-concern patches across three different steps.** Each PR touched a
distinct section addressing a distinct concern: Step 1 (diff-survival guard), Step 2 (coverage
visibility), Step 7 (exit-code correctness). No two churn PRs modified the same step or the
same concern. No merge conflicts were recorded across any of the three PRs.

**Each change is correctness-driven, not structural.** PR #763 addressed a silent failure mode
where a conflict resolution drops the entire PR diff and no gate catches it. PR #806 surfaced
degraded local-review state that was previously invisible at push time. PR #904 fixed a
documented contract error in the reply-thread.sh description that caused callers to misinterpret
a successful fallback reply as a failure.

**Score is at the detection threshold.** The churn detector fires at 3 PRs. This is the minimum
threshold — it signals "worth a look," not "structural problem."

**One pre-existing observation (not a churn driver):** Step 6 contains manual CR→BugBot→Greptile
escalation logic (rate-limit detection, BugBot timeout, Greptile trigger) that duplicates the
decision tree already owned by `.claude/scripts/escalate-review.sh`. However, none of the three
churn PRs touched Step 6. This is a latent extraction candidate, not a churn source. It is
recorded in `.claude/reference/script-extraction-audit.md` for future adjudication.

## Options considered

### Option 1: SPLIT `go-on/SKILL.md` into multiple files

**Rejected.** The skill's Steps 0–10 form a single sequential transaction: check for inherited
state, run local review, push, ensure PR exists, determine reviewer, wait for review, process
findings, check merge gate, verify AC, report completion. The steps are sequentially dependent —
each step's output feeds the next. A physical split would require consumers (users who invoke
`/go-on`) to sequence multiple skills rather than one entry point, adding complexity without
removing any churn source. No independent caller depends on a sub-portion of the skill; the
entire workflow is consumed as one unit.

Precedent for rejecting splits on sequentially-coupled workflows:
- `fixpr-hotspot-decision.md` (Issue #788) — extraction justified when independently-churning
  deterministic blocks each had a distinct owner; but split rejected
- `wave-hotspot-decision.md` (Issue #961) — split rejected because callers consume Steps 0–10
  as a single contract
- `start-issue-hotspot-decision.md` (Issue #981) — split rejected because steps are sequentially
  dependent: claim gates planning, plan determines handoff

### Option 2: KEEP + record Step 6 follow-up candidate (chosen)

**Selected.** Record the decision and the one latent extraction opportunity without modifying the
skill now.

**Rationale:**
- The three churn PRs are independent correctness fixes. None of them reflect structural conflict
  or ownership ambiguity. Touching Step 1, Step 2, and Step 7 in three separate PRs is not
  evidence of an architectural problem — it is evidence of three separate bugs being fixed.
- The Step 6 bypass of `escalate-review.sh` is a genuine extraction candidate, but it is not a
  churn source. Extracting it now addresses a latent concern, not the measured churn, and
  introduces risk to a skill that is currently correct and functioning.
- Per `.claude/reference/churn-hotspots.md`, the re-open trigger is `conflict_rounds > 0`.
  No conflict rounds are recorded for this file.

### Option 3: KEEP + extract Step 6 now

**Rejected.** Step 6 is a bypass of `escalate-review.sh`, but none of the three churn PRs
touched it. Extracting it now optimizes a non-churn section and introduces the risk of
breaking the existing correct escalation behavior in the skill. The extraction is a legitimate
future candidate (recorded in `script-extraction-audit.md`), but it belongs in a dedicated PR
with its own acceptance criteria and test coverage, not bundled into a hotspot adjudication.

## Decision

**KEEP** `.claude/skills/go-on/SKILL.md` as the single canonical review-and-merge resume
workflow. Make no operative change.

The three churn PRs are independent, non-conflicting, correctness-driven patches to three
distinct steps. The score (3 PRs) is at the detection threshold. The churn does not reflect
a structural problem, ownership ambiguity, or any pattern that a split or extraction would
reduce.

Per `.claude/reference/churn-hotspots.md`, the automated re-file gate triggers only on
`conflict_rounds > 0` — rising PR count alone does not automatically re-file this hotspot.
See Reconsideration guidance below for additional human-judgment conditions.

## Preserved invariants

All 12 step headers (Step 0 through Step 10, including Step 1 and Step 1b) and their script
contracts remain unchanged by this decision:
- Step 1 diff-survival guard contract (`diff-survival-check.sh`)
- Step 1b uncommitted-changes check (`git status --porcelain`)
- Step 2 local CR review loop (`coderabbit review --agent`, coverage classification)
- Step 3 push-to-remote logic
- Step 4 PR-exists-or-create logic, including coverage label update
- Step 5 reviewer-ownership detection (`reviewer-of.sh`)
- Step 6 CR/BugBot/Greptile escalation polling (manual inline logic)
- Step 7 unresolved-findings processing (`reply-thread.sh`, `resolve-review-threads.sh`)
- Step 8 merge-gate verification (`merge-gate.sh`, `pr-state.sh`)
- Step 9 acceptance-criteria verification (`ac-checkboxes.sh`)
- Step 10 completion reporting

## Expected impact

None. No rule corpus files, scripts, or skill files were changed. The corpus word count remains
unchanged at the pre-adjudication baseline.

## Reconsideration guidance

Re-file this hotspot if:
- `conflict_rounds > 0` for `go-on/SKILL.md` — meaning two PRs required rebasing against each
  other to resolve a conflict in this file
- An independent Step 6 caller emerges that consumes the escalation logic separately from the
  rest of the `go-on` workflow (which would justify extracting Step 6 as a shared component)
- Churn volume rises substantially above threshold (6+ PRs) with no single concern dominating

The Step 6 / `escalate-review.sh` bypass is a separate future extraction candidate recorded in
`script-extraction-audit.md` and should be adjudicated independently, not as part of a future
churn-hotspot re-filing.

## Related

- PR #763 / Issue #757 — diff-survival guard: Step 1 feature addition (guard rebase/conflict
  resolutions with a diff-survival check)
- PR #806 / Issue #769 — coverage classification: Step 2 trailing-bullet addition (make
  zero-coverage local review loud at push time)
- PR #904 / Issue #884 — reply-thread.sh exit-code fix: Step 7 correctness fix (fallback
  exits 0 on success, fixing duplicate-comment regression)
- `.claude/scripts/escalate-review.sh` — canonical CR→BugBot→Greptile escalation script;
  Step 6 in `go-on/SKILL.md` duplicates its decision tree (future extraction candidate)
- `.claude/reference/script-extraction-audit.md` — records the Step 6 bypass as a future
  extraction candidate
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger
- `.claude/reference/wave-hotspot-decision.md` — KEEP precedent for canonical single-file
  workflow skills
- `.claude/reference/start-issue-hotspot-decision.md` — KEEP precedent for sequentially-coupled
  multi-step skills
- Issue [#1116](https://github.com/auerbachb/claude-code-config/issues/1116) — this adjudication
