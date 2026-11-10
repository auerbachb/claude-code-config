# No-review override test hotspot decision

Issue #1958. The untruncated default-branch detector run after PR #2056 counted three changes to the suite, with score 3 and zero recorded conflict rounds. PR #1930 created the file and was excluded from the count.

## Decision

KEEP `merge-gate-no-review-override.test.sh` together. It exercises how a single merge decision depends on the review verdict, timing, and the resulting ledger entry. Keep the existing layered GitHub fake and private ledger; fix two fixture isolation problems in place.

| Merged PR | Contribution |
|---|---|
| [PR #1942](https://github.com/auerbachb/claude-code-config/pull/1942) | Updated the TP1 ledger transition to the new backfill status. |
| [PR #1943](https://github.com/auerbachb/claude-code-config/pull/1943) | Added controls distinguishing review rate limits from verdicts on the current head. |
| [PR #1952](https://github.com/auerbachb/claude-code-config/pull/1952) | Checked hollow and substantive approvals on all reviewer paths, including evaluator failure. |

A split would duplicate the wrapper over the shared GitHub fake and separate ledger assertions from the gate outcomes they depend on. The neighboring suites use different wrapper contracts. Reconsider if a separate consumer needs this wrapper or measured conflicts start to justify a split.

## Fixture corrections

The clean TP1/TP2 baseline passes on macOS Bash 3.2 and current Bash. Inherited fake GitHub inputs can make the same scenarios fail. Clear the creation time, branch metadata, protected flag, required contexts and legacy statuses at each reset. The rest of the fixture contract is unchanged.

The nine-minute timestamp used to be sampled before TP1. A private control using the same bundle with its timestamp aged past ten minutes caused TP2 to allow the override. Sample the nine-minute timestamp immediately before TP2. The actual gate still evaluates its ten-minute window, and the case still verifies refusal and no ledger write.

No runtime or review policy changes are needed. The exact Issue #1958 baseline is score/count 3; the existing 2× material-growth rule still applies.
