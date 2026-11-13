# Review coverage of merged code, November 2026 (issue #2313)

How each PR the repo owner merged into `main` in the 14 days to 2026-11-13 cleared AI review at its merge HEAD, and what share of merged PRs and changed files had a counted approval. Measured by `.claude/scripts/review-coverage-measure.sh`. Method and cross-checks below; the script's `--help` is the reference for the flags.

## Result

Population: **246 merged PRs, 1,890 changed files**, merged 2026-10-31 to 2026-11-13 (the latest merge was 20:43 UTC on 2026-11-13). Zero PRs unknown: every API read succeeded.

| Class | PRs | Share of PRs | Changed files | Share of files |
|---|---|---|---|---|
| real (counted approval on merge HEAD) | 235 | 95.5% | 1,780 | 94.2% |
| override (no counted approval, no verdict on HEAD; inferred) | 5 | 2.0% | 20 | 1.1% |
| discounted (empty or hollow approval beside a non-approval verdict on HEAD) | 6 | 2.4% | 90 | 4.8% |
| other (non-approval verdict or other-bot activity on HEAD, no approval) | 0 | 0% | 0 | 0% |
| unknown | 0 | 0% | 0 | 0% |

Per reviewer, PRs at merge HEAD:

- CodeRabbit (`coderabbitai[bot]`): **0 counted approvals**. 54 PRs carried a non-approval verdict on HEAD (a COMMENTED review with a body, or a top-level inline finding). 192 PRs had no CodeRabbit verdict.
- CodeAnt (`codeant-ai[bot]`): 235 counted approvals; 5 approvals discounted with no other verdict; 6 approvals discounted beside a CodeAnt verdict on HEAD.

Lacking a counted approval: 11 of 246 PRs (4.5%) and 110 of 1,890 files (5.8%).

## Decision

Threshold, fixed before the numbers were read: more than **20%** of merged PRs, or of changed files, without a real review means a follow-up is warranted.

**Decision under the pre-registered definition: not warranted.** Both shares are far below 20%, so no follow-up issue is filed.

**Caveat the owner should decide on.** Every one of the 235 counted approvals is an empty-bodied CodeAnt approval. What makes the gate count them is a CodeAnt status comment naming HEAD (235 of 235); 173 of them also carry a finished CodeAnt run record on HEAD, and 4 carry an inline comment on HEAD. Under a stricter reading that counts an approval only with one of those two extra signals, 173 of 246 PRs (70.3%) and 1,347 of 1,890 files (71.3%) would be covered. That leaves about 29% of PRs and 29% of files lacking coverage, over the threshold, so the decision flips. This measurement applies the existing gate definition, as the issue requires, so it does not adopt the stricter reading. If the owner wants the range re-review, that is the follow-up to request; it is not filed here.

## What "real" means here, and its limits

- The classification reuses `review-substance.sh` (the #875 substance check behind `merge-gate.sh`) unchanged. Its output is the gate's own `counts_as_coverage` verdict per reviewer.
- This separates **empty from non-empty** approvals only. In this window every counted approval is empty, so the 95.5% is the share the gate counts on footprint evidence. It is not a measure of review depth. Do not read it as "thoroughly reviewed."
- Two inputs were not supplied to the substance check: the HEAD push timestamp (so the temporal-inversion and seconds-after-push checks did not run) and resolved thread IDs. Both can only discount approvals the gate would also discount, so **the real shares are upper bounds**.
- `override` is inferred from GitHub data, not read from the gate's recorded JSON. A PR is `override` when no counted approval exists on HEAD and no verdict exists on HEAD other than a hollow approval or a refusal. This is the override's own definition (`.claude/reference/no-review-override.md`).

## Cross-checks

- **Ledger.** `unreviewed-merge-ledger.sh list` holds 5 entries for this repo (ledger start 2026-11-11). All 5 are classified `override`, and no `override` PR is missing from the ledger. The earliest override merge in the window is on 2026-11-11, so no pre-ledger override was found.
- **Labels.** `merged-unreviewed` is on 2 PRs and `backfill-reviewed` on 3; all 5 are `override` PRs. No labelled PR falls outside the override class.
- **Sanity anchor.** PR #2303 classifies as `override` with its CodeAnt approval discounted (empty body, no other evidence on HEAD). Matches the issue's expectation.

## Unexplained: the six discounted PRs

PRs #1881, #1928, #1972, #2017, #2219, and #2231 each had a non-approval verdict on HEAD (a COMMENTED review with a body, or an inline finding) and only an empty or hollow CodeAnt approval. The gate's override rules do not waive a verdict on HEAD, and none of these six has a ledger entry, so the path that let them merge is not recorded in any artefact this measurement reads. This report does not guess it. The owner can check the merge history of these six PRs directly.

## Method

1. Population: `gh pr list --state merged --author <owner> --base main --search "merged:>=2026-10-30"`, limit 1,000. The run refuses if the limit is reached, so no page is silently missing. Only PRs whose base is `main` are counted.
2. Per PR: `pulls/N/reviews`, `pulls/N/comments`, `issues/N/comments`, paginated. Read-only GET, cached in a scratch directory. A failed or rate-limited read is `unknown`, never "no review". The run refuses to start when core quota is below 1,000.
3. Only evidence posted at or before the merge time counts. Items posted after the merge are dropped before the substance check runs.
4. Classes are assigned in order: `real`, then `discounted`, `other`, `override`. Empty-body COMMENTED reviews and reply comments inside existing threads are not verdicts, mirroring `no-review-override.sh` (issue #2268). A PR where another bot (Cursor, Greptile) reviewed or commented on HEAD before the merge is `other`, never `override`; it is named in the per-PR `foreign` field and counted in `foreign_reviewer_prs`. Those bots are presence-checked, not scored. The reviewer set is an explicit allowlist (Cursor, Greptile), taken from `no-review-override.sh`. Any other bot (Graphite's stack comment, `github-actions[bot]`) is not a reviewer. A PR-conversation comment counts only when its body names HEAD, since it carries no commit id.

Correction made during the run: the first pass counted empty-body CodeRabbit COMMENTED reviews as verdicts, which moved PR #2290 to `discounted`. The gate's own rule (#2268) discounts those, so the classifier now matches it, and PR #2290 is `override`, consistent with the ledger.

Second correction (CodeAnt review of the measurement, #2313): the fixes were base-branch scoping, cutting comments on `updated_at`, exact-integer threshold comparison, per-run temp files, a required `--cache-dir` for offline runs without `--repo`, and a foreign-bot `other` class. Re-run offline from the same response cache, every figure above is unchanged and the decision is still not warranted. The population is 246 PRs, all into `main`; no PR was excluded by the base filter. The foreign-bot class moves no PR into or out of `override` here: the six PRs with Cursor or Greptile activity are already `real` or `discounted` on CodeAnt. Check-runs are not read by this script, so a PR whose only evidence is a check-run would still be `override`.

Third correction (review round 3): the foreign-bot test was widened from any `[bot]` login to an explicit allowlist with a HEAD-reference rule for PR-conversation comments. Re-run from the same cache, every figure is still unchanged, including the ledger cross-check (5 ledger entries, 5 overrides, all in the ledger). The per-run scratch files and the aggregate-from-own-list change affect only concurrent runs, which were not exercised here.

## Reproduce

```bash
.claude/scripts/review-coverage-measure.sh --since 2026-10-30   # ~740 read-only REST calls, cached
.claude/scripts/review-coverage-measure.sh --from-cache         # offline re-run from the cache
```

Per-PR classes land in `<cache-dir>/classified.jsonl`. Aggregates print as JSON on stdout. The cache holds GitHub payloads, so it stays out of the repo.

## Numbers measured versus judgment

- **Measured:** population counts, class counts, per-reviewer tallies, shares, the ledger and label cross-check, the empty-body count, and the stricter-footprint sensitivity.
- **Judgment:** the 20% line (fixed in advance from the issue), reading the stricter footprint as the sensible definition (not adopted here), and the decision that the existing gate definition governs.
