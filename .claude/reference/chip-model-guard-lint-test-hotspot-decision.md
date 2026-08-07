<!-- churn-hotspot: .github/scripts/tests/chip-model-guard-lint.test.sh -->
# Hotspot Decision — chip-model-guard-lint.test.sh

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-07
**Issue:** #1044
**Reporter:** `/wrap` post-merge churn report (PR #1043)

## Churn summary

`churn-hotspots.sh` flagged `.github/scripts/tests/chip-model-guard-lint.test.sh` as
touched by 5 distinct merged PRs since 2026-07-23: PR #736, PR #775, PR #799, PR #812,
PR #842.

| PR | Issue | What changed |
|----|-------|-------------|
| PR #736 | #731 | Created the file: 100-line initial suite with `make_fixture()` (5 literal emitters), bare `expect()` harness, baseline cases for chip-launching mutations and skill-file mutations |
| PR #775 | #770 | Added resolver emitter class: extracted `LITERAL_EMITTERS`/`RESOLVER_EMITTERS`/`ALL_EMITTERS` arrays, updated `make_fixture()` to iterate `ALL_EMITTERS`, added 3+ cases for harness-audit emitter presence and resolver-without-model-fleet.sh |
| PR #799 | #791 | Hardened the harness: added `mutate()` no-op guard (cksum before/after; returns 90 on no-op), `append_line()` helper, failure-propagating `expect()` guard (`if ! ( cd ... && "$@" )`); converted all bare `sed -i.bak` calls to `mutate`; added Effort-line tests and versioned-name ban tests |
| PR #812 | #802 | Added co-occurrence tests: `decouple_wave_placement()` to handle wave's two placement-satisfying lines; 3 new cases distinguishing the too-loose direction, the PR#799 rewording (must still pass), and non-contractual "first before **Model:**" (must fail) |
| PR #842 | #837 | Added family-comparison tests: 3 revert-fails cases (family-comparison rule, version-qualifier rule, family self-report in Match branch) and 3 semantic-inversion cases; `mutate()` verified each case is not a no-op |

## Diagnosis

This is **amendment-synchronized test churn** — a direct mirror of the churn already
diagnosed in the lint script itself (`chip-model-guard-lint-hotspot-decision.md`, Issue
#1042).

Each of the 5 PRs added a new requirement to the chip model-guard contract in
`chip-launching.md` and enforced it via a new check in `chip-model-guard-lint.sh`.
The test file is the paired verification half of that contract: every new check demands
a `mutate`-hardened negative case (the check catches a violation) and, where the
positive shape changed, an updated positive case (a valid form still passes).

**The per-PR churn drivers confirmed by diff trace:**

- **PR #736** (#731) created the file as the initial regression suite. 5 literal
  emitters hardcoded in `make_fixture()`. Bare `( cd "$dir" && "$@" )` in `expect()`,
  no failure propagation.
- **PR #775** (#770) added the sixth canonical emitter (`harness-audit`) and the
  resolver class. Tests expanded in lock-step: three new cases verify the emitter's
  chip-launching reference, decision-record reference, and presence as a skill file;
  one more verifies the resolver class constraint (no model-fleet.sh → fail).
- **PR #799** (#791) added `**Effort:**` checks and the versioned-name ban to the
  lint script. Tests expanded with 10+ new cases covering the Effort line in each
  contract document and the versioned-name corpus scan. This PR also introduced the
  `mutate()` no-op guard — a harness improvement discovered while authoring those
  cases (Issue #791 hit a silent no-op mutation before the guard existed). The
  harness improvement was bundled with the contract expansion because it fixed a
  structural testing gap revealed during that PR's authoring.
- **PR #812** (#802) added bilateral co-occurrence regex to the lint's placement
  check. The test expansion is unusually detailed: one case proves the new strict
  direction rejects the too-loose example from the issue body; one proves the PR#799
  rewording still passes under the new check; one proves non-contractual "first before
  **Model:**" is rejected. Three cases for one check is justified: the co-occurrence
  logic has two failure modes (too loose and too brittle), and the fixture for wave
  required `decouple_wave_placement()` because wave has two lines satisfying the
  check and removing only one is insufficient to make the lint fail.
- **PR #842** (#837) added family-level comparison semantics. Six cases cover the
  three preamble sentences independently (so each sentence can regress silently) plus
  three semantic inversions that keep keywords intact while reversing the rule —
  exactly the failure mode a keyword-presence check cannot detect.

**conflict_rounds == 0 across all 5 PRs.** Every touch is an additive case group;
no PR required a merge conflict resolution or rewrote prior cases.

## PR #1072 cross-check

PR #1072 (Issue #1042) extracted shared `require_file()`/`require_pattern()`
boilerplate from `chip-model-guard-lint.sh` and three sibling lint scripts into
`.github/scripts/lib/lint-common.sh`. The extraction was a zero-behavior-change
refactor of the lint script. The test file was **not touched** by PR #1072 and its
behavior did not change: the extraction is transparent to the test runner because
the test invokes `chip-model-guard-lint.sh` as a black box. Confirmed by the
PR #1072 diff, which lists no changes to `chip-model-guard-lint.test.sh`.
Issue #1042 is now CLOSED.

## Decision: KEEP (no operative change)

**KEEP** `.github/scripts/tests/chip-model-guard-lint.test.sh` unchanged. Make no
operative change to the test file.

The 5-PR churn is contract-amendment churn that cannot be avoided without abandoning
paired testing. The test file is the verification half of one evolving contract; it
cannot grow independently of the lint script or the contract documents it guards.

**Harness extraction is deferred, not urgent.** The `expect()`/`mutate()`/`make_fixture()`
harness is near-identical in structure to sibling test files
(`skill-catalog-lint.test.sh`, `env-template-allowlist-lint.test.sh`,
`merge-authority-lint.test.sh`). However, the `mutate()` no-op guard exists only in
this file, and the sibling `expect()` call signatures differ. An extraction would
require API reconciliation adding more complexity than the current per-file duplication
costs, and it would not reduce the contract-amendment churn driver. Record as a
deferred follow-up.

## Rejected alternatives

**Split by contract section** (§chip-launching, §emitter skills, §decision record,
§corpus scan): Rejected. The `make_fixture()`/`expect()`/`mutate()` harness is shared
across all sections. A split would require duplicating or extracting the harness.
More importantly, amendment-synchronized cases must be co-located to be read together;
fragmenting PR #799's Effort cases from PR #775's emitter cases destroys the
amendment sequence as a readable history. This distinguishes the file from
`escalate-review-test-hotspot-decision.md`, whose split was warranted because that
file's churn came from independent-regression concerns, not a synchronized amendment
log.

**Concern-split following `escalate-review-test-hotspot-decision.md`:** Not
applicable here. The split precedent applied because the two concern groups in that
file were independently maintained and grew from different root causes. Here every
PR touches the file for the same root cause: a new chip-model-guard contract
requirement. The concern groups do not have independent growth trajectories.

## Deferred follow-up

If future churn shifts to repeated edits of the `mutate()` or `expect()` harness
boilerplate across this file and its siblings — rather than new semantic test cases —
extract a shared `.github/scripts/tests/lib/lint-test-helpers.sh` and propagate the
`mutate()` no-op guard to all sibling test files. That extraction would reduce harness
drift without requiring API reconciliation today. Re-open as a new hotspot report when
`conflict_rounds > 0` or when three or more PRs touch only the harness.

## Future reconsideration

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0`. A rising PR count on this contract-driven test file is not a
re-filing trigger; only a conflict (indicating that two amendments are stepping on each
other's fixtures) would indicate a structural problem.

## Related

- Issue #1044 — this hotspot ticket
- Issue #1042 — companion `chip-model-guard-lint.sh` hotspot; CLOSED via PR #1072
- Issue #1011 — companion `chip-model-guard-decision.md` doc hotspot; CLOSED
- `chip-model-guard-lint-hotspot-decision.md` — sibling lint script adjudication (KEEP + extract, Issue #1042)
- `chip-model-guard-doc-hotspot-decision.md` — sibling doc adjudication (KEEP, Issue #1011)
- `.github/scripts/tests/chip-model-guard-lint.test.sh` — the adjudicated file
- `.github/scripts/chip-model-guard-lint.sh` — the lint script this file tests
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
