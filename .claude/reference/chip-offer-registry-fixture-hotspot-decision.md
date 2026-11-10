# Chip offer registry fixture hotspot decision

Issue #1652. Keep `.claude/scripts/tests/chip-offer-registry.test.sh` as one offline suite. The original untruncated detector scan from 2026-08-22 on main at `570c06c1` counted four merges and no recorded conflict re-resolutions.

| Counted PR | Why the fixture changed |
|---|---|
| #1267 | Covered atomic reservations, single-count offers and explicit retraction. |
| #1497 | Added a guard against drift between the documented and accepted emitter names. |
| #1615 | Checked that the canonical emitters include an executable reservation call, including `/harness-audit`. |
| #1625 | Gave each test run an isolated temporary home so concurrent suites could not share state. |

PR #1645 touched 239 paths to generate script catalog rows. Its fixture header change is excluded by the detector's 20-path sweep cutoff. No commit touched the fixture in the 2026-10-26 to 2026-11-09 window on main at `3f7de0f3`; the untruncated scan did not return the fixture even at score threshold 1.

The emitter checks and the reservation tests exercise the same caller contract. The behavior cases share one isolated home and the same reservation state and lock setup. Splitting the emitter checks would add a second suite for two historical changes with no recent recurrence; splitting the behavior cases would duplicate their setup. Both Bash versions passed all 42 assertions. Revisit if the emitter checks start changing independently or conflict re-resolutions make the shared suite costly.

The current window has zero touches, below the detector's two-PR minimum. The ledger uses the minimum representable baseline, score and count 2, following #1503. It does not count two recent PRs or preserve the original score of 4. A qualifying future zero-conflict score of 4 surfaces the decision again; a qualifying hotspot with recorded conflict cost bypasses the baseline.
