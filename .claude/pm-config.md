# PM Config

## Role

<!-- Optional: who uses this config (human-editable). -->

## OKRs

No OKRs set — add objectives under this header when ready.

## Complexity triggers

<!-- Issue #362 — tune per repo. Defaults match claude-code-config calibration (25 merged PRs, threshold 100 → 72% would exceed). -->

```ini
THRESHOLD_SCORE=100
FIRST_CR_ROUND=3
CADENCE_ROUNDS=2
FILE_WEIGHT=5
ENABLE_PR_REVIEW_HELP=0
```

- **THRESHOLD_SCORE** — minimum `complexity-score.sh` value before auto-trigger; must be a **non-negative integer**. Repo file sets the default; **`COMPLEXITY_THRESHOLD_SCORE` env overrides** when set.
- **FIRST_CR_ROUND** — first fire at this CodeRabbit round count (must be **≥ 3**; scripts error out otherwise — needs ≥ 2 completed CR rounds before first fire). Uses `cycle-count.sh <PR> --cr-only`. **`COMPLEXITY_FIRST_CR_ROUND` env overrides** when set.
- **CADENCE_ROUNDS** — after the first fire, fire again every N additional CR rounds (e.g. 2 → rounds 3, 5, 7…); must be **≥ 1**. **`COMPLEXITY_CADENCE_ROUNDS` env overrides** when set.
- **FILE_WEIGHT** — multiplier on `changedFiles` inside the score; must be a **positive integer** (0 and non-positive values are rejected). **`COMPLEXITY_FILE_WEIGHT` env overrides** when set.
- **ENABLE_PR_REVIEW_HELP** — `1` / `true` / `yes` / `on` posts a fourth comment `/pr-review-help` after the three single-mention triggers.

## Team

<!-- Optional: contributor display names. -->

## Notes

<!-- Free-form. -->
