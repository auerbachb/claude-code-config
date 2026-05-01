## Role

<!-- Optional: who uses this config (human-editable). -->

## OKRs

No OKRs set — add objectives under this header when ready.

## Complexity triggers

<!-- Issue #362 — tune per repo. Defaults match claude-code-config calibration (≥10 merged PRs, threshold 100 → ~53% would exceed). -->

```
THRESHOLD_SCORE=100
FIRST_CR_ROUND=3
CADENCE_ROUNDS=2
FILE_WEIGHT=5
ENABLE_PR_REVIEW_HELP=0
```

- **THRESHOLD_SCORE** — minimum `complexity-score.sh` value before auto-trigger (also overridable via `COMPLEXITY_THRESHOLD_SCORE`).
- **FIRST_CR_ROUND** — first fire at this CodeRabbit round count (must be ≥ 3 so ≥ 2 completed CR rounds precede it). Uses `cycle-count.sh <PR> --cr-only`.
- **CADENCE_ROUNDS** — after the first fire, fire again every N additional CR rounds (e.g. 2 → rounds 3, 5, 7…).
- **FILE_WEIGHT** — multiplier on `changedFiles` inside the score (also `COMPLEXITY_FILE_WEIGHT`).
- **ENABLE_PR_REVIEW_HELP** — `1` / `true` / `yes` / `on` posts a fourth comment `/pr-review-help` after the three single-mention triggers.

## Team

<!-- Optional: contributor display names. -->

## Notes

<!-- Free-form. -->
