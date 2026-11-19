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
| [check-runs-snapshot.sh](../check-runs-snapshot.sh) | Read workflow-scoped check evidence without masking queued workflows |
| [ci-status.sh](../ci-status.sh) | Summarize CI check-run health for a commit or PR |
| [clean-behind-check.sh](../clean-behind-check.sh) | Decide whether a BEHIND PR is safe for /admin-merge (hunk-level overlap check) vs a rebase |
| [dismiss-stale-bot-changes.sh](../dismiss-stale-bot-changes.sh) | Dismiss stale bot CHANGES_REQUESTED reviews on old SHAs after a push |
| [merge-gate.sh](../merge-gate.sh) | Verify the full merge gate (reviewer approval, CI, threads, mergeStateStatus) |
| [merge-sequence.sh](../merge-sequence.sh) | Overlap-aware merge dispatch planner to avoid conflict rounds across a PR fleet |
| [no-review-override.sh](../no-review-override.sh) | Decide whether the merge gate may waive missing AI-review coverage after the no-review window |
| [pr-claim-check.sh](../pr-claim-check.sh) | PR-side claim gate: flags a PR opened on an issue another agent holds, or a PR that names no claim (CI runs it via pr-claim-check.yml) |
| [required-checks.sh](../required-checks.sh) | Read required contexts without interpreting an unreadable requirement as empty |
| [rerun-cancelled-required-ci.sh](../rerun-cancelled-required-ci.sh) | Re-run one verified cancelled required Actions job per PR HEAD. |
| [review-coverage-measure.sh](../review-coverage-measure.sh) | Classify merged PRs by real AI review coverage at merge HEAD, reusing review-substance.sh |
| [review-substance.sh](../review-substance.sh) | Decide whether a bot's `APPROVED` on a SHA is real review coverage or a hollow rubber stamp |
| [review-tier.sh](../review-tier.sh) | Resolve a PR's review tier (ci-only / ci+codeant-one-round / full / legacy) from pm-config |
| [unreviewed-merge-ledger.sh](../unreviewed-merge-ledger.sh) | Record, list, and mark backfill status of merges made without an AI review |
<!-- catalog:rows:end -->

## Which merge helper for which gate

Pick the helper from the last `merge-gate.sh` JSON, refreshed after acceptance verification at `AC_VERIFIED_HEAD` (issue #2432). The ledger and admin helpers check the live PR state, but they never verify review, CI, or acceptance criteria — the caller does that first.

| Gate shape | Action |
|------------|--------|
| Met, `no_review_override.applied == true`, `merge_state` `CLEAN` (or `UNSTABLE` with non-empty `no_review_override.excluded_reviewer_checks`) | Ledger `merge --pr N --repo R --gate-json -` with the full gate JSON. After GitHub confirms `MERGED`, ledger `record --pr N --repo R --from-snapshot`. |
| Met, override not applied (`applied: false` or `null`), `merge_state == CLEAN` | Ledger `merge --pr N --repo R --sha <AC_VERIFIED_HEAD>`. The same gate sent to `--gate-json` exits `9` and merges nothing. A direct `gh pr merge` skips the snapshot lock and the cleanup of unused override evidence. |
| Unmet, `BEHIND` the only `missing[]` entry, no override, AC verified (`/wrap` only) | Ledger `snapshot --pr N --repo R --discard`, then the clean-BEHIND probe (`clean-behind-check.sh`). Probe `0` → `admin-merge.sh N --auto-plain --ac-verified --defer-bookkeeping`; probe `1` → `/fixpr` rebase, then back through the gate loop; probe `2`–`4` → stop. `/merge` stops on any unmet gate. |
| Override applied and `BEHIND` | Never an admin bypass. Rebase through `/fixpr`, then run a new gate for the new HEAD. |
| Any other unmet gate, or a merge state not listed above | Do not merge. |

`UNSTABLE` is accepted only on the override row; an ordinary reviewed merge needs `CLEAN`. After any merge-command error, check the PR's native state before routing — GitHub may already have merged it.

Mechanism and ledger exit codes: [no-review-override.md](../../reference/no-review-override.md).

---

[← back to the index](../README.md)
