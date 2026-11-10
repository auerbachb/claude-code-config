# Review audit reference hotspot decision

Issue #1949, assessed 2026-11-08 against default-branch commit `17b1211594f3`.

## Decision

KEEP `review-stack-audit.md` as one on-demand reference. Name the three current engines in its introduction and make the marker, measurement, and scorecard sections discoverable in the catalog. Record the measured hotspot baseline so routine churn does not reopen the decision without material growth.

## What changed together

The untruncated detector run after PR #2057 covers the window starting 2026-10-25. It matched this path to Issue #1949 with four counted PRs, score 4, and zero recorded conflict rounds. The first three were named when the issue was filed; the fallback attribution fix arrived later.

| Merged PR | Change to the shared contract |
|---|---|
| [PR #1845](https://github.com/auerbachb/claude-code-config/pull/1845) | Required the reply verdict marker and recorded its interpretation, enforcement date, and limits for earlier findings. |
| [PR #1908](https://github.com/auerbachb/claude-code-config/pull/1908) | Added fix quality to the same marker, preserving unknown values and defining the scorecard denominator. |
| [PR #1911](https://github.com/auerbachb/claude-code-config/pull/1911) | Added review rounds and push-to-gate timing to the measured snapshot and scorecard. |
| [PR #2005](https://github.com/auerbachb/claude-code-config/pull/2005) | Extended verdict attribution to qualifying PR-level fallback replies and recorded the matching constraints. |

[PR #1951](https://github.com/auerbachb/claude-code-config/pull/1951) also touched the reference as part of an 82-file sweep. The detector excludes that sweep under its existing 20-file threshold; it does not add a fifth counted touch. This historical attribution does not decide whether any review app should be installed or measured.

## Why keep the reference together

The marker and attribution rules define which finding verdicts reach the ledger. Fix quality summarizes those replies; velocity adds distinct observations about review rounds and timing to the same snapshot. The scorecard presents both with their missing-data and comparability limits. Separating these into independent files would add cross-reference and synchronization work at exactly the boundaries those four PRs changed together. No distinct ownership or conflict cost in this sample justifies that trade.

The audited revision has 612 lines, but it is read on demand. The skill remains the operative entry point, and the engines each have a command-line help interface. Existing headings let readers jump to the marker, value fields, or scorecard. A clearer catalog entry addresses discoverability without moving the definitions or asking readers to reconcile duplicate contracts.

The observed score/count 4 is stored for this exact path and Issue #1949. The existing multiplier 2 remains in force: a closed zero-conflict row at score 7 is suppressed and score 8 surfaces as material growth. This records a decision at the observed size; it does not disable future assessment.

## When to reconsider

Revisit if the reference accumulates repeated conflict or maintenance cost, a separate caller consistently needs one section without its neighboring definitions, or a measured loading reduction justifies a clear ownership boundary. A split proposal should retain one definition for each field and verify that existing skill, rule, script, and report references still reach it.

This assessment does not rerun the study, overwrite a snapshot, change review or billing settings, or alter audit behavior. The existing study caveat still applies: the real-defect counts are a floor for work before the marker mandate, and the scorecard does not file drift issues or change rules.
