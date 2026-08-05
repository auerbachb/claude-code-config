<!-- churn-hotspot: .claude/scripts/tests/merge-gate-review-substance.test.sh -->
# Hotspot Decision — merge-gate-review-substance.test.sh

**Verdict:** KEEP (no structural change)
**Decided:** 2026-08-05
**Issue:** #1014
**Reporter:** `/wrap` post-merge churn report (PR #1013)

## Churn summary

`churn-hotspots.sh` flagged `.claude/scripts/tests/merge-gate-review-substance.test.sh`
as touched by 6 distinct merged PRs since 2026-08-01:

| PR | What changed |
|----|-------------|
| PR #883 | Introduced the file: core substance tests (a)–(r) for issue #875 (hollow approval detection) |
| PR #896 | Added cases (ee) for issue #894: all-decimal short SHA admission rules |
| PR #911 | Added cases (ee-897) for issue #897: tilde fence, indented block, and unclosed-opener stripping |
| PR #923 | Added cases (ee-917) for issue #917: UUID-embedded hex fragment exclusion |
| PR #951 | Added cases (ff-933) for issue #933: reviewer echo stripping (author SHA not credited) |
| PR #972 | Added cases (gg-927) for issue #927: descriptive non-SHA evidence as external coverage |

## Diagnosis

This is **purposeful regression accumulation**, not instability or scatter. Every
edit adds a new group of cases for a new correctness fix in `review-substance.sh`.
The pattern is: a real-world trace reveals a bypass of the hollow-approval guard
→ `review-substance.sh` is patched → tests are added to pin the new rule and the
false-negative guard that protects the legitimate shape the fix might have blocked.

Three structural observations support the KEEP verdict:

**1. No mechanical duplication within the file.**
The `approval()` and `convo()` fixture builders (lines 130–136) are used
exclusively by this suite. No companion test file shares them; there is nothing
to deduplicate. The per-section eval wrappers (`ee_eval`, `ff_eval`, `uuid_eval`)
are inline specializations with different schema shapes — they are not copies of
each other and extracting them would add a parameterisation layer with no
correctness benefit.

**2. No coverage gap to close.**
All six PR groups have explicit positive-and-negative test pairs. The file passes
175/175 assertions on current HEAD. The false-negative guards (the cases that
ensure a fix does not block a legitimate shape) are present for every new rule
added since PR #896.

**3. Splitting would cost context.**
The cases share `HEAD_SHA`, `COMMIT_TS`, `APPROVE_TS`, and the `gh` stub. Later
cases (e.g., (ff-933) and (gg-927)) layer on prior cases as negative controls:
case (e) is the explicit negative control for case (ff-933)(i). Splitting into
per-issue files would destroy this sequential context and require cross-file
import machinery that the current self-contained structure avoids.

### Comparison with the polling-state-gate precedent (PR #1024)

The #1024 decision extracted shared helpers because TWO companion files each
carried their own copy of `mk_repo`, `write_handoff`, and `write_polling_gh_stub`
with diverged implementations — one copy silently skipped the scoped-handoff path,
creating a real coverage gap. This file has no companion. The churn driver is
different: external contract evolution, not internal duplication.

### The ok/bad/check_eq pattern (cross-family duplication)

The `ok()`, `bad()`, and `check_eq()` helpers appear in the other six
merge-gate-*.test.sh files as well. This is real but intentional: each suite is
self-contained, the helpers are three trivial one-liners, and no divergence has
appeared between copies. A shared `tests/lib/merge-gate-helpers.sh` was
considered and declined: the correctness benefit is zero (no diverged
implementations, no coverage gap), and sourcing six files from a seventh adds
maintenance surface without buying anything.

## Decision

**KEEP** the file in its current location with no structural change.

Future PRs that fix new bypass shapes will continue to add test groups in the
same append-and-label style. That is the correct behavior for a suite guarding
the hollow-approval detection logic at the center of the merge gate. Continued
growth of this file is a sign the substance contract is being maintained, not a
problem to be engineered away.

## Expected impact

None. No files were changed. The churn pattern will continue as `review-substance.sh`
evolves — each new admitted real-world trace adds a case group. The file size
(967 lines / 175 assertions at adjudication time) is not a concern: it is all
test cases, and every case carries its own labeled reasoning.
