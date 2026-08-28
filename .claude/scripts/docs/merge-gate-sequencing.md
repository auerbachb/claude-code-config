# Merge Gate & Sequencing

Scripts that verify merge readiness and sequence a PR fleet to avoid conflict rounds.

| Script | Purpose |
|--------|---------|
| [merge-gate.sh](../merge-gate.sh) | Verify the full merge gate (reviewer approval, CI, threads, mergeStateStatus) |
| [clean-behind-check.sh](../clean-behind-check.sh) | Decide whether a BEHIND PR is safe for /admin-merge (hunk-level overlap check) vs a rebase |
| [admin-merge.sh](../admin-merge.sh) | Generate or execute the solo-owner branch-protection bypass |
| [merge-sequence.sh](../merge-sequence.sh) | Overlap-aware merge dispatch planner to avoid conflict rounds across a PR fleet |
| [ci-status.sh](../ci-status.sh) | Summarize CI check-run health for a commit or PR |
| [check-runs-dedup.sh](../check-runs-dedup.sh) | Collapse a check-run list to one verdict per check (newest check suite wins) |
| [ac-checkboxes.sh](../ac-checkboxes.sh) | Parse and update the PR body's Test plan checkboxes |
| [ac-gate.sh](../ac-gate.sh) | CI gate: fail a PR with unchecked AC boxes; enforce the Post-merge verification exemption |
| [dismiss-stale-bot-changes.sh](../dismiss-stale-bot-changes.sh) | Dismiss stale bot CHANGES_REQUESTED reviews on old SHAs after a push |
| [review-substance.sh](../review-substance.sh) | Decide whether a bot's `APPROVED` on a SHA is real review coverage or a hollow rubber stamp |

---

[← back to the index](../README.md)
