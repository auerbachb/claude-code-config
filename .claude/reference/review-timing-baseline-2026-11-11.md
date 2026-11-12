# Review timing baseline, 2026-11-11

The before-picture for the review-on-request change (issue #2196, increment 3 of the chain). It was measured with `.claude/scripts/review-ci-report.sh` on 2026-11-11, before the new default is adopted in any other repo. The before-and-after comparison runs as a dated follow-up using the same command and the same selection rule.

## Privacy

This repository is public. Private repos appear only as `private repo A` to `private repo E`. The label-to-name mapping and the unredacted JSON are kept on the owner's machine, outside this repository, in the owner's review-timing folder. They are not committed, and no private name appears in this note.

## How it was measured

- Command: `REVIEW_REPOS="<active repos>" .claude/scripts/review-ci-report.sh --json --limit 25`. Default wait 10 minutes (the `NO_REVIEW_OVERRIDE_MINUTES` default in `no-review-override.md`).
- Selection: every owner repo pushed on or after 2026-10-11, per `gh repo list`. That gives eight repos: five private, three public (`claude-code-config`, `still-point`, `nest_commerce`). The tracker issue listed seven names, and `nest_commerce` is not among them, so the list was not copied from the issue.
- Window: the last 25 merged PRs per repo, by update time, read with one GraphQL request per repo.
- Requests: one full read is eight GraphQL requests. Across the whole session the measurement used 35 GraphQL requests (full reads re-run after fixes, one retry, one 10-PR diagnostic, and one raw read of the public repo for a refusal check) plus three other API calls. One repo returned HTTP 504 on the 25-PR query, twice.
- Measurement note: the figures below were computed before the final script change that stops attributing a review which names a commit outside the sample to the nearest sampled commit. In the public repo that affects three CodeRabbit reviews; other repos may differ by a similar small count. The next run shows the difference.

## Results (25 merged PRs per repo)

Figures are computed by the script. The CI column counts only commits whose check list was read in full: private repo B excludes 9 commits and private repo D excludes 17 whose check lists exceeded the 50-check read bound, and those commits are not counted as passing or failing. "Within 10 min" is the share of reviews whose response time, measured from the review request when one exists and from push otherwise, was at most 10 minutes. "On failed CI" is the share of reviews on commits whose build CI had completed and failed.

| Repo | Commits (CI done) | Commits with failed CI | CI median / p90 (min) | Force-push events |
| --- | --- | --- | --- | --- |
| claude-code-config | 88 (70) | 21 (30.0%) | 17.7 / 66.6 | 2 |
| private repo A | 50 (39) | 33 (84.6%) | 9.3 / 18.1 | 5 |
| private repo B | 45 (31) | 1 (3.2%) | 8.3 / 10.5 | 2 |
| private repo C | unread (HTTP 504 on the 25-PR query, twice) | n/a | n/a | n/a |
| private repo D | 68 (35) | 13 (37.1%) | 14.4 / 41.4 | 1 |
| still-point | 47 (42) | 30 (71.4%) | 5.7 / 45.4 | 7 |
| private repo E | 30 (29) | 0 (0.0%) | 0.2 / 0.3 | 1 |
| nest_commerce | 0 merged PRs in the window | n/a | n/a | 0 |

Per reviewer (reviews counted; refusals and CodeAnt pre-review approvals are not reviews):

| Repo | Reviewer | Reviews | Response median / p90 (min) | Within 10 min | On failed CI | First review on failed CI | Refusals | CodeAnt pre-review approvals |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude-code-config | CodeRabbit | 17 | 4.9 / 11.7 | 76.5% | 5 of 15 | 4 of 8 | 4 | n/a |
| claude-code-config | CodeAnt | 46 | 5.1 / 8.3 | 93.5% | 11 of 46 | 8 of 21 | 0 | 57 |
| private repo A | CodeAnt | 14 | 7.1 / 8.7 | 100% | 14 of 14 | 14 of 14 | 0 | 33 |
| private repo B | CodeAnt | 19 | 4.9 / 10.0 | 89.5% | 1 of 11 | 0 of 5 | 0 | 26 |
| private repo B | CodeRabbit | 6 (small) | 6.1 / 11.1 | 66.7% | 0 of 4 | 0 of 2 | 10 | n/a |
| private repo D | CodeAnt | 41 | 3.5 / 6.1 | 100% | 13 of 33 | 8 of 15 | 0 | 32 |
| private repo D | CodeRabbit | 9 (small) | 7.4 / 15.1 | 77.8% | 1 of 3 | 1 of 2 | 18 | n/a |
| private repo D | BugBot | 7 (small) | 7.3 / 8.2 | 100% | 2 of 6 | 2 of 5 | 0 | n/a |
| still-point | CodeAnt | 12 (small) | 0.5 / 5.9 | 100% | 10 of 12 | 3 of 4 | 0 | 43 |
| still-point | CodeRabbit | 8 (small) | 4.5 / 6.4 | 100% | 8 of 8 | 5 of 5 | 13 | n/a |
| still-point | BugBot | 1 (small) | 4.4 / 4.4 | 100% | 0 of 1 | 0 of 1 | 0 | n/a |
| private repo E | CodeRabbit | 1 (small) | 0.4 / 0.4 | 100% | 0 of 1 | 0 of 1 | 0 | n/a |
| private repo E | Greptile | 3 (small) | 5.0 / 5.8 | 100% | 0 of 3 | 0 of 2 | 0 | n/a |

"Small" means fewer than 10 reviews in the sample; those rows are not evidence for a conclusion. Repos and reviewers with no reviews are omitted from the table.

## Blind spots, in plain words

- Commits replaced by a force-push are not visible in this measurement, and reviews on them are not counted. The sample includes 1 to 7 force-push events per repo.
- Sample sizes are small for several reviewer rows, as marked above. Greptile and BugBot were too sparse to measure in most repos.
- There is no cost data. The review-stack audit holds billing facts; they are not joined here.
- Merged PRs are selected by last update time, then sorted by merge time. A PR merged earlier but updated later can displace one merged later.
- Re-runs that later passed are not netted out. A commit whose earlier check run failed counts as failed.
- Refusals are found by phrase in a reviewer's own bodies and comments. A body that contains a walkthrough counts as a review even when it mentions a limit: in this repo the 6 to 18 KB CodeRabbit walkthroughs mention one near the top, while the refusal notices are about 4 KB with no walkthrough. A refusal worded differently is counted as a review or not at all.
- Response times fall back to the push proxy when no review request exists, so for those reviews the figure includes any delay before the reviewer started.
- The count of inferred attributions, undated items, and truncated connections for each repo is in the local JSON, not repeated here.

## Differences from the one-off figures in the tracker issue

- The tracker issue reported that CI failed on 18% of sampled commits in this repo. This baseline measures 30.0% (21 of 70 completed commits). The windows and the counting differ: this run reads every commit of the last 10 commits per PR, not the earlier one-off sample. The difference is not explained here and is not resolved by this run.
- The one-off first-review figure for this repo (13 of 86) is not reproduced in this form. The per-reviewer rows above use a different denominator.

## Follow-up

The dated before-and-after comparison runs with the same command on the same selection rule, and is filed separately by the parent session. Unread repos must be reported as unread in that run, not as zeros. The retry and diagnostic reads in this baseline are not part of the 25-PR figures.
