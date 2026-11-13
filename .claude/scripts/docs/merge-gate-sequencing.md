# Merge Gate & Sequencing

<!-- catalog:category id=merge-gate-sequencing order=30 -->
<!-- catalog:covers Scripts that verify merge readiness and sequence a PR fleet to avoid conflict rounds -->

Scripts that verify merge readiness and sequence a PR fleet to avoid conflict rounds.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin -->
| [ac-checkboxes.sh](../ac-checkboxes.sh) | Parse and update the PR body's Test plan checkboxes |
| [ac-gate.sh](../ac-gate.sh) | CI gate: require checked AC lists and enforce the Post-merge verification exemption |
| [admin-merge.sh](../admin-merge.sh) | Generate or execute the solo-owner branch-protection bypass |
| [backfill-review.sh](../backfill-review.sh) | Review merges logged by the no-review override with the FREE local CLIs only, file deduped issues for real bugs, mark each ledger row reviewed |
| [check-runs-dedup.sh](../check-runs-dedup.sh) | Collapse a check-run list to one verdict per check (newest check suite wins) |
| [ci-status.sh](../ci-status.sh) | Summarize CI check-run health for a commit or PR |
| [clean-behind-check.sh](../clean-behind-check.sh) | Decide whether a BEHIND PR is safe for /admin-merge (hunk-level overlap check) vs a rebase |
| [dismiss-stale-bot-changes.sh](../dismiss-stale-bot-changes.sh) | Dismiss stale bot CHANGES_REQUESTED reviews on old SHAs after a push |
| [merge-gate.sh](../merge-gate.sh) | Verify the full merge gate (reviewer approval, CI, threads, mergeStateStatus) |
| [merge-sequence.sh](../merge-sequence.sh) | Overlap-aware merge dispatch planner to avoid conflict rounds across a PR fleet |
| [no-review-override.sh](../no-review-override.sh) | Decide whether the merge gate may waive missing AI-review coverage after the no-review window |
| [rerun-cancelled-required-ci.sh](../rerun-cancelled-required-ci.sh) | Re-run one verified cancelled required Actions job per PR HEAD. |
| [review-coverage-measure.sh](../review-coverage-measure.sh) | Classify merged PRs by real AI review coverage at merge HEAD, reusing review-substance.sh |
| [review-substance.sh](../review-substance.sh) | Decide whether a bot's `APPROVED` on a SHA is real review coverage or a hollow rubber stamp |
| [review-tier.sh](../review-tier.sh) | Resolve a PR's review tier (ci-only / ci+codeant-one-round / full / legacy) from pm-config |
| [unreviewed-merge-ledger.sh](../unreviewed-merge-ledger.sh) | Record, list, and mark backfill status of merges made without an AI review |
<!-- catalog:rows:end -->

---

[← back to the index](../README.md)
