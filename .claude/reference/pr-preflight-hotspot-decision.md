# PR preflight hotspot decision

Issue #1655. Keep `.claude/scripts/pr-preflight.sh` as one entry point. The original untruncated detector run from 2026-08-22 on main at `570c06c1` counted three merges and no recorded conflict re-resolutions.

| Counted PR | Why preflight changed |
|---|---|
| #1244 | Added substantive evidence checks before treating a review as engagement on the current commit. |
| #1549 | Fixed the portable `--help` extraction. It did not change the review path. |
| #1635 | Scoped CodeAnt clean-run evidence to the review it redeemed. |

The 2026-10-26 to 2026-11-09 scan on main at `ea8929cb` did not return the script even at score threshold 1, because the detector still requires two distinct PRs. The one eligible change, #2043, corrected the skip reported when escalation is off. The paid authorization rollout (#1938 and #1948) and Graphite removal (#1951) touched 50, 29 and 82 files respectively, above the detector's 20-file sweep cutoff. Those changes explain why a raw file history looks busier than the hotspot report.

Preflight already delegates review evidence to `review-substance.sh`, tier decisions to `review-triggers-allowed.sh`, and spending authorization to `paid-review-grant.sh`. The draft check, current-commit evidence, dedupe and trigger results still belong to one invocation. `/fixpr`, `/babysit-pr`, and `/pr-monitor-and-manage` parse its `PREFLIGHT_SUMMARY:` line. The historical changes do not identify a separate component that would benefit from moving, and the focused suites passed 234 assertions on each Bash version. Revisit an extraction if the same section repeatedly changes on its own or begins causing merge conflicts.

The current scan is below the detector's two-PR minimum, so the ledger uses its minimum representable baseline, score and count 2, following the #1503 precedent. This does not count a second PR or carry forward the historical score of 3. A future qualifying zero-conflict score of 4 surfaces the decision again; a qualifying hotspot with recorded conflict cost bypasses the baseline.
