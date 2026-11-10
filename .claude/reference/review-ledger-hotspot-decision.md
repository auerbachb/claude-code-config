# Review ledger hotspot decision

Issue #1837. The untruncated default-branch detector after PR #2065 counted three recent changes to `review_ledger.py`, with score 3 and no recorded conflict rounds.

## Decision

KEEP the shared module. It gives the measure and cap commands one set of pricing rules and gives the scorecard the same tagged-fence parser. Keep one definition of unknown versus zero spend, the rounding and allocation rules, and the review verdict classifications.

| Counted PR | Contribution |
|---|---|
| [PR #1908](https://github.com/auerbachb/claude-code-config/pull/1908) | Added fix quality to the reply verdict marker and value report. |
| [PR #1911](https://github.com/auerbachb/claude-code-config/pull/1911) | Added review rounds and the push-to-gate timing observations. |
| [PR #2005](https://github.com/auerbachb/claude-code-config/pull/2005) | Included attributed conversation replies in the verdict ledger. |

The earlier report counted [PR #1827](https://github.com/auerbachb/claude-code-config/pull/1827) for the reply classifier, [PR #1831](https://github.com/auerbachb/claude-code-config/pull/1831) for the scorecard's shared parser, and [PR #1835](https://github.com/auerbachb/claude-code-config/pull/1835) for the daily cap adapter. All three are verified merged history; they are outside this snapshot's count.

## Consumers and boundaries

- `measure.sh --ledger` uses the shared pricing and verdict functions. The legacy measurement path does not require this import.
- `review-daily-cap.sh` prices normalized events with the same rules. Its time window and input collection still determine which events count.
- `scorecard.sh` imports the module for the tagged vendor claims block. A missing or broken import withholds that table with a caveat; the window and value sections still render.

The strongest split would extract the verdict layer and keep pricing separate. It would add an installed module and sandbox resolution surface without resolving a measured merge conflict or duplicated rule. Reconsider if a separate consumer needs the verdict engine alone, deployment or import boundaries change, or conflicts become recurrent.

## Verification

The offline audit and daily-cap suites pass under macOS Bash 3.2 and current Bash, including 133 cap assertions per shell. Private runs of the actual scorecard exercise a valid ledger, a missing ledger, and an import failure; the valid control renders the claims, and only that section is withheld in the failure cases. No runtime, pricing, review or study data changes are needed.

Record the exact Issue #1837 score/count 3 baseline. The existing 2× material-growth threshold stays in place.
