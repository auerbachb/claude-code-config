# Merge Gate & Sequencing

<!-- catalog:category id=merge-gate-sequencing order=30 -->
<!-- catalog:covers Scripts that verify merge readiness and sequence a PR fleet to avoid conflict rounds -->

Scripts that verify merge readiness and sequence a PR fleet to avoid conflict rounds.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin -->
| [ac-checkboxes.sh](../ac-checkboxes.sh) | Parse and update the PR body's Test plan checkboxes |
| [ac-gate.sh](../ac-gate.sh) | CI gate: fail a PR with unchecked AC boxes; enforce the Post-merge verification exemption |
| [admin-merge.sh](../admin-merge.sh) | Generate or execute the solo-owner branch-protection bypass |
| [check-runs-dedup.sh](../check-runs-dedup.sh) | Collapse a check-run list to one verdict per check (newest check suite wins) |
| [ci-status.sh](../ci-status.sh) | Summarize CI check-run health for a commit or PR |
| [clean-behind-check.sh](../clean-behind-check.sh) | Decide whether a BEHIND PR is safe for /admin-merge (hunk-level overlap check) vs a rebase |
| [dismiss-stale-bot-changes.sh](../dismiss-stale-bot-changes.sh) | Dismiss stale bot CHANGES_REQUESTED reviews on old SHAs after a push |
| [merge-gate.sh](../merge-gate.sh) | Verify the full merge gate (reviewer approval, CI, threads, mergeStateStatus) |
| [merge-sequence.sh](../merge-sequence.sh) | Overlap-aware merge dispatch planner to avoid conflict rounds across a PR fleet |
| [review-substance.sh](../review-substance.sh) | Decide whether a bot's `APPROVED` on a SHA is real review coverage or a hollow rubber stamp |
<!-- catalog:rows:end -->

---

[← back to the index](../README.md)
