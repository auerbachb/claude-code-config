# `merge-gate-ci-dedup.test.sh` hotspot — concern-based split decision

Reference for Issue #1106. Not auto-loaded.

## Churn diagnosis

`.claude/scripts/tests/merge-gate-ci-dedup.test.sh` was touched by 3 distinct
merged PRs since 2026-07-24: PRs #840, #849, and #965.

At the split point the file contained 17 CI-dedup assertions (tests 1–6) and
21 BugBot merge-gate assertions (tests 7–(q)), totalling 38 assertions across
325 lines. The shared gh stub and `cr()`/`bundle()` fixture helpers were the
only structural connection between the two concern groups.

## Per-PR attribution (evidence — traced from real diffs)

| PR | Commit | Primary concern | What changed in this file |
|----|--------|----------------|--------------------------|
| PR #840 | 8507f00 | CI-dedup / stale-approval (issue #836) | 6 lines added to gh stub: `git/commits/` endpoint returning `2026-07-21T09:59:00Z` so the new stale-approval guard treats CI-dedup check-runs as fresh |
| PR #849 | 28f176d | BugBot merge-gate (issue #844) | Added `run_gate_bugbot()` helper; BugBot missing-entry helpers (`has_bugbot_no_review_entry`, `has_bugbot_findings_entry`, `has_bugbot_ts_unavail_entry`); scenarios 7–10/(m)/(n) (25 → 29 assertions, all BugBot-only) |
| PR #965 | fa6db69 | BugBot merge-gate publisher scoping (issue #962) | Added `has_bugbot_app_mismatch_entry()` helper; scenarios (o)/(p)/(q); updated `cursor` slug in scenarios 7/8/(m) (29 → 38 assertions, all BugBot-only additions) |

PR #840 touched only the shared gh stub — necessary for the CI-dedup tests to
function correctly after the stale-approval guard was introduced. PRs #849 and
#965 added exclusively BugBot content to a file named for CI deduplication.

## Measured concern split (baseline: 38 assertions)

| Concern | Runner | Tests | Assertions |
|---------|--------|-------|-----------|
| CI check-run dedup + CodeAnt supplemental gate | `run_gate()` — `--reviewer cr` | 1–6 | 17 |
| BugBot reviewer merge-gate | `run_gate_bugbot()` — `--reviewer bugbot` | 7–(q) | 21 |

The two groups call entirely different code paths in `merge-gate.sh`. No BugBot
test exercises the CI-dedup deduplication logic, and no CI-dedup test exercises
the BugBot reviewer path.

## Decision: SPLIT by concern

Replace the monolith with two independently runnable suites and one shared fixture helper.

### Split map

| From | To | Content |
|------|----|---------|
| `merge-gate-ci-dedup.test.sh` (old, 325 lines) | `tests/lib/merge-gate-test-fixtures.sh` | gh stub, `cr()`, `bundle()`, assertion harness |
| `merge-gate-ci-dedup.test.sh` (old, 325 lines) | `merge-gate-ci-dedup.test.sh` (new) | Tests 1–6 (CI-dedup + CodeAnt, 17 assertions) |
| `merge-gate-ci-dedup.test.sh` (old, 325 lines) | `merge-gate-bugbot.test.sh` (new) | Tests 7–(q) (BugBot paths, 21 assertions) |

The shared fixture file does not end in `.test.sh`, so the existing non-recursive
test glob in `hook-scripts.yml` does not execute it directly. Both concern suites
are auto-discovered via `*.test.sh`.

### Preserved invariants

- All 38 assertions remain represented across the two suites (17 + 21).
- Each suite runs independently: `bash .claude/scripts/tests/merge-gate-ci-dedup.test.sh`
  and `bash .claude/scripts/tests/merge-gate-bugbot.test.sh`.
- `merge-gate.sh` is unchanged; this refactor changes no gate behavior.
- Scenario labels are preserved so issue and review history remain searchable.

## Rationale — why SPLIT rather than KEEP

**The `merge-gate-*.test.sh` family already splits by concern.** The repo
contains `merge-gate-authorship.test.sh`, `merge-gate-codeant-inplace-review.test.sh`,
`merge-gate-greptile-comment.test.sh`, `merge-gate-review-substance.test.sh`,
`merge-gate-stale-approval.test.sh`, and `merge-gate-sticky-cr-approval.test.sh`.
BugBot gate behavior belongs in a file named for BugBot, not for CI deduplication.

**The `escalate-review-test-hotspot-decision.md` precedent (Issue #966) is a
direct structural match.** Independent regression scenarios accumulated in one
file because they reused the same gh stub. The correct fix was SPLIT + shared
fixture lib. The two situations are identical: same root cause (shared harness),
same solution (extract the harness, split by concern).

**PRs #849 and #965 drove 13 of 21 BugBot assertions into a CI-dedup named file
with zero overlap to the dedup code path.** Future BugBot hardening would
continue this pattern unless the boundary is drawn now. Future CI-dedup changes
have a clean home in `merge-gate-ci-dedup.test.sh`.

**The shared infrastructure is the ONLY connection between the two concerns.**
Both suites use the same gh stub because `merge-gate.sh` calls the same GitHub
API endpoints regardless of reviewer path — not because the two concerns share
subject matter. Extracting the harness into `tests/lib/merge-gate-test-fixtures.sh`
resolves the coupling without forcing cross-concern test edits.

**No split warranted on PR #840 alone.** PR #840's 6-line change to the gh stub
was supportive infrastructure for the CI-dedup tests, not a mixed-concern
addition. The split is warranted because PRs #849 and #965 independently added
BugBot content that has no dedup relationship.

## Future ownership

New CI check-run dedup regressions belong in `merge-gate-ci-dedup.test.sh`.
New BugBot merge-gate regressions belong in `merge-gate-bugbot.test.sh`.
Reusable fixture setup (gh stub endpoints, `cr()`, `bundle()`, harness) belongs
in `tests/lib/merge-gate-test-fixtures.sh`. Concern logic must not move into the
helper merely to reduce line counts.

## Convergence note

Re-file this hotspot only when `conflict_rounds > 0` on either split file.
A rising PR count on a living test suite that tracks external contract evolution
is not a re-filing trigger.

## Related

- `.claude/scripts/tests/merge-gate-ci-dedup.test.sh` — CI check-run dedup suite (post-split)
- `.claude/scripts/tests/merge-gate-bugbot.test.sh` — BugBot reviewer suite (new)
- `.claude/scripts/tests/lib/merge-gate-test-fixtures.sh` — shared harness
- `.claude/scripts/merge-gate.sh` — script under test (unchanged)
- `.claude/reference/escalate-review-test-hotspot-decision.md` — structural SPLIT precedent (Issue #966)
- Issue #1106 — this hotspot (test suite)
- Issue #675 — CI check-run dedup (PR #686, tested in suite 1–6)
- Issue #844 — BugBot silent-pass acceptance (PR #849, tested in suite 7–(q))
- Issue #962 — BugBot publisher scoping (PR #965, tested in suite (o)–(q))
