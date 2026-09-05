# Review & Escalation

<!-- catalog:category id=review-escalation order=20 -->
<!-- catalog:covers Scripts that manage the CR→BugBot→Greptile reviewer chain, budgets, and round gating -->

Scripts that manage the CR→BugBot→Greptile reviewer chain, budgets, and round gating.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin -->
| [bugbot-refused-head.sh](../bugbot-refused-head.sh) | One shared answer for every `@cursor review` trigger path: has BugBot already refused this HEAD for a Cursor usage/spend limit? |
| [complexity-score.sh](../complexity-score.sh) | Compute a PR complexity score from additions, deletions, and changed-file count |
| [cr-plan.sh](../cr-plan.sh) | Detect a substantive CodeRabbit implementation-plan comment on a GitHub issue |
| [cr-review-hourly.sh](../cr-review-hourly.sh) | Track CodeRabbit's rolling hourly review cap and per-PR explicit trigger count |
| [cycle-count.sh](../cycle-count.sh) | Reconstruct per-PR review-then-fix cycle count for round gating |
| [escalate-review.sh](../escalate-review.sh) | Run the CR→BugBot→Greptile escalation gate; emits a single deterministic `STATUS=` verdict — see `--help` |
| [greptile-budget.sh](../greptile-budget.sh) | Guard the daily Greptile review budget counter in session-state |
| [local-review.sh](../local-review.sh) | Run a local review CLI (CodeRabbit/CodeAnt) with every false-clean check applied; emits the compact result contract |
| [maybe-trigger-ai-review.sh](../maybe-trigger-ai-review.sh) | Post supplemental AI reviewer triggers when complexity and CR-round gates pass |
<!-- catalog:rows:end -->

---

[← back to the index](../README.md)
