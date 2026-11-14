# Review request timing (`REVIEW_REQUEST`)

Issue #2195. Decides WHEN the agent asks an AI reviewer for a review on a PR HEAD. Reviewers that start on push spend their allowance on commits whose CI then fails (13 of 86 first reviews in one repo, 2026-11-10). The default waits for CI.

## Setting

In the live ```` ```ini ```` block under `## Review policy` in the repo's base-branch `.claude/pm-config.md` (same reading rule as `REVIEW_ESCALATION`):

```ini
REVIEW_REQUEST=after-ci
REVIEW_REQUEST_CHECKS=rule-lint,hook-tests-py39
```

- `REVIEW_REQUEST` — `after-ci` (default when absent) or `on-push` (today's behaviour, no CI gate). Any other value reads as `never` with one stderr warning: an unclear request switch fails toward not requesting.
- `REVIEW_REQUEST_CHECKS` — comma list of check-run names that must be green first. Absent or empty means every non-reviewer check.

`review-tier.sh --json` reports both as `review_request` and `review_request_checks`. `review-request-gate.sh` makes the decision; `maybe-trigger-ai-review.sh` calls it.

## Rules (`after-ci`)

1. Reviewer checks (CodeRabbit, CodeAnt, BugBot/Cursor, Greptile, Graphite, matched by app slug or name) never count as CI.
2. A blocking conclusion on a counted check (`failure`, `timed_out`, `cancelled`, `action_required`, `startup_failure`, `stale`) means no request on that HEAD, whatever else runs.
3. Named checks: every retained execution of each name must pass; a green same-named job from another workflow or event cannot hide a pending or failing job. A name with no run yet is pending until 900 seconds have passed since the later of the HEAD commit time and the first poll that saw that HEAD (`review_request_seen_epoch` in session state). After that it is ignored and listed in `ignored_checks`, so a check that never reports cannot hold the request forever. Once names are given, unnamed checks are not awaited: that is the point of the list.
4. No names: every non-reviewer run must be completed and non-blocking. No runs at all waits until the same 900-second grace passes, then requests (a repo with no CI).
5. One request per HEAD. The first request claims the HEAD (`review_request_head_sha` in session state, written by compare-and-set before the post, released if the post fails). Once recorded, no path posts a second review request for that HEAD, including the complexity cadence. A new push is a new HEAD and eligible again.
6. A `ci-only` tier requests nothing: the tier path already excludes every reviewer.
7. The request is `@codeant-ai review` or `@coderabbitai review` (the free reviewer chosen per §Reviewer choice; tiered repos and `on-push` always ask CodeAnt), posted by `maybe-trigger-ai-review.sh`. Paid reviewers stay owner-approval only (`safety.md` §Paid AI Reviews); this setting adds no path that posts `@cursor review` or `@greptileai`.
8. An unreadable or incomplete check list, exact-HEAD workflow inventory, required-context answer, commit time or tier answer holds the request for that tick (fail closed). The next tick asks again.
9. Base-branch required contexts must exist and pass, including their required publishing app. Their absence never expires after the optional-name grace, even when `REVIEW_REQUEST_CHECKS` selects other names. This uses the merge gate's existing branch-protection/branch-object fallback semantics; a protected branch that exposes no requirements carries the same visibility warning.

The complexity cadence (`#362`) in the legacy path (no `## Review policy` table) decides only what it governed before, after the first request: on a HEAD with a recorded request it posts no second CodeAnt request. Its first request for a HEAD is not gated by the cadence: when the request gate says `request`, the first request posts even while the cadence is below its round or score gate. `on-push` keeps the cadence exactly as it was. `@cursor review` stays owner-approval only and is unchanged.

A tiered repo (a `## Review policy` table) still defers to its complexity skip for the first request; only the legacy path has this change so far.

The shared `check-runs-snapshot.sh` reads every page of checks and Actions workflows for the exact HEAD. Actions jobs are joined to their authoritative workflow execution. The explicit latest-run policy allows the latest push/pull-request execution within the same workflow ID, trigger event, branch and PR/base identity to supersede only completed older executions (including PR-body rechecks). Every unfinished execution remains visible. A previously reported job name remains pending when its replacement has not reported that name yet; the named-check grace period cannot erase this evidence. The pending name ends when the replacement reports it or the workflow completes. The API does not expose pull-request action subtypes here; this policy does not infer edited versus reopened. Other triggers (for example manual dispatches whose inputs are unavailable) remain independent. Push and pull-request workflows remain separate, as do different workflows with identical job names. Matrix siblings survive. Manual reruns keep their original run ID, so retry ordering uses GitHub's `run_started_at` (which resets on rerun), not the original ID; missing chronology and unsettled retries remain visible. Missing identity or truncated pagination holds the request rather than guessing. An unenriched Actions list passed directly to dedup cannot prove supersession.

Each selected workflow also contributes its own status row (included in CI totals, but never allowed to satisfy a required check-run name; its check-run ID is null and its workflow ID remains separate), so a queued workflow with no jobs or aggregate check yet remains pending. All-workflow mode waits for this inventory as well as jobs; an explicit optional-name list still selects only those jobs, with required contexts checked independently. A true rerun that completes green becomes eligible; a different workflow's success cannot erase a failure. `ci-status.sh`, `pr-state.sh`, `review-triggers-allowed.sh` and `merge-gate.sh` consume the same snapshot. These reads do not reserve a merge window or change branch protections. API fields follow the [official workflow-run endpoint](https://docs.github.com/en/rest/actions/workflow-runs) and [GitHub REST schema](https://github.com/github/rest-api-description/blob/main/descriptions/api.github.com/api.github.com.yaml).

The snapshot adds one paginated workflow-inventory read per live check fetch; it does not poll or retry internally. Cached/enriched stdin remains reusable without another API call. A workflow scheduled after the snapshot can still appear later; GitHub protection remains authoritative at merge time.

## Dashboard checklist (manual, not done by the harness)

Until a reviewer's automatic trigger is off, it still fires on push, and this setting only stops the agent adding a second request. Switch each off per repo. A browser-capable agent can do this with the owner's logged-in session; the owner approves each change.

1. CodeRabbit: in `.coderabbit.yaml` set `reviews.auto_review.enabled: false`, or turn off automatic review in the CodeRabbit dashboard settings for the repo. Keep manual `@coderabbitai` requests working.
2. CodeAnt: in the CodeAnt dashboard, turn off review on every push for the repo. Keep manual `@codeant-ai review`.
3. BugBot (Cursor dashboard): turn off automatic runs. It is paid; it must not start from a push.
4. Greptile dashboard: turn off auto-trigger. The dashboard bypasses the rules in `greptile.md`.
5. Graphite: retired 2026-11-03 (#1889); nothing to switch.

Verify afterwards: on a draft PR here, push a commit whose CI fails. No reviewer comment or review should appear. Fix CI, push again, and exactly one request (`@codeant-ai review` or `@coderabbitai review`) should appear once the named checks are green.

## Scope

This doc covers the setting and the decision. Rolling it out to other repos and measuring the effect is issue #2196.

## Tests

- `tests/test_check_run_workflows.py` — distinct workflows, push/PR identity, genuine reruns, matrix siblings, queued workflows, partial metadata and pagination.
- `.claude/scripts/tests/review-request-gate.test.sh` — every decision state (pending, failed, green, reviewer checks, named checks, grace, once per HEAD, on-push, never, bad input).
- `.claude/scripts/tests/review-tier.test.sh` — parsing: defaults, `on-push`, named checks, malformed value, stray key outside a live block.
- `.claude/scripts/tests/maybe-trigger-tier-triggers.test.sh` — legacy path: pending holds, failed holds, green requests once, second poll on the same HEAD does not, a new push requests again.

## Availability (issue #2256)

Account-wide, not per PR: CodeRabbit's allowance is per developer, so one PR's limit notice applies to every repo.

- **Record:** `session-state.json` `.review_availability.{coderabbit,codeant}` holds `next_available_epoch`, `notice_at`, `window_seconds`, `notice_excerpt`, `source_repo`, `source_pr`, `read_at`. Written by `review-availability.sh record` from the PR's issue comments every time `no-review-override.sh` runs. A parsed retry window records a return time; an explicit untimed refusal records `refusal_kind: "untimed"` with null return/window fields for ranking only. A parsed zero-minute window keeps the existing clear/no-record behavior; it is not an unknown reset. A newer notice on file is not overwritten by an older one.
- **Expected response (settings):** `REVIEW_EXPECTED_RESPONSE_CODEANT_MIN` (default 4) and `REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN` (default 5), minutes, from the 2026-11-11 baseline. Invalid values fall back to the default.
- **Skip (before posting a request):** `decide` skips the request on this HEAD only when no free reviewer is eligible: each one either has a usable, future record whose next-available time plus its expected response is later than now plus the no-review window, or (CodeRabbit only) has its hourly budget spent. The reason is `no_reviewer_available_until <ISO>`, recorded on the PR as `review_request_skips[<head sha>]` (`mark-skip`), keyed by HEAD so a late write for an older HEAD never replaces the current one. It is written only on a path that would otherwise have posted the request, so a tier or cadence that posts nothing records nothing.
- **Override:** `no-review-override.sh` applies at once while the recorded skip is for the current HEAD and the same answer still holds (`check-skip`). Its gate JSON carries the reason as `reason` and `skip_reason`; the unreviewed-merge ledger row carries `skip_reason`. Every other hard stop is unchanged.
- **Fail toward asking:** no record, a past record, an unreadable state file, a malformed value, or a missing helper all request as today.
- **Gap:** a skip needs a parsed retry window for CodeAnt (and for CodeRabbit unless its hourly budget is spent). CodeAnt has no documented limit wording with a time (`cr-rate-limits.md` does not list one), so until one is observed the skip cannot fire.
- **Tests:** `.claude/scripts/tests/review-availability.test.sh`, `.claude/scripts/tests/no-review-override-availability.test.sh`.

## Reviewer choice (issue #2257)

Each request due on a HEAD asks exactly one free reviewer, never a paid one. `review-availability.sh choose` evaluates both free reviewers:

- **Availability:** the later of the limit-notice return time, the end of the queue of requests recently sent to that reviewer (`.review_requests`, account-wide, one hour; each request holds it for its expected response time, and a limited reviewer's queue drains only after its limit returns), and now. Its answer is that availability plus its expected response time.
- **Eligibility:** a reviewer is ineligible only when a limit notice keeps it out of the no-review window (its return time plus its expected response time lands past the window), or, for CodeRabbit, while `cr-review-hourly.sh --check` reports its hourly budget spent (CodeAnt has no cap). Without a limit notice, the queue and expected response time only rank eligible reviewers; they never make one ineligible.
- **Choice:** the earliest answer wins; a tie goes to the reviewer with fewer requests in the last hour. Neither eligible: the #2256 skip, unchanged. Two PRs going green together alternate reviewers because the first request holds its reviewer's queue.
- **Posted body:** `@codeant-ai review` or `@coderabbitai review` (never `full review`). The CodeRabbit budget is counted only after the post succeeds (`cr-review-hourly.sh --consume`), so a failed post or a lost claim spends nothing.
- **Record:** `record-request` appends the request to `.review_requests` and writes `.prs["<N>"].review_request_choices[<head sha>]` with the reviewer, reason, and the expected response times and reviewer estimates. `maybe-trigger-ai-review.sh --json` reports `request_reviewer`.
- `REVIEW_REQUEST=on-push` keeps `@codeant-ai review` as the request; the choice applies to `after-ci` only.
- **Tiered repos:** a repo with a review tier always asks CodeAnt through the tier's CodeAnt step; the choice applies to the legacy path only.
- **Estimates never skip:** only a real limit notice (its return time plus the expected response time past the window), or a spent CodeRabbit hourly budget, makes a reviewer ineligible; without a limit notice, the request queue and expected response time only rank eligible reviewers, so a busy moment never skips review.
- **Known limits:** two ticks racing can both ask the same reviewer or both pass CodeRabbit's last hourly slot; the cost is one extra free request, which CodeRabbit answers with its limit notice.
- **Tests:** `.claude/scripts/tests/review-availability-choose.test.sh`, `.claude/scripts/tests/maybe-trigger-reviewer-choice.test.sh`.

### Untimed explicit refusals

An explicit free-reviewer refusal such as CodeRabbit’s `Review rate limited.` is retained account-wide with its notice time and source PR, even without a readable retry window. For one hour from that notice, the chooser prefers another eligible free reviewer over the refused reviewer, including when that other reviewer has queued requests. This is a bounded ranking preference, **not** a reset estimate: no next-available timestamp is invented, and ageing reports an aged refusal rather than proof of availability.

Untimed refusals never make a reviewer ineligible or justify an immediate no-review override. If both reviewers have unknown resets, the helper still asks a free reviewer using the existing queue order. Existing timed limits, hourly caps, one request per HEAD, CI gates and paid-review rules remain unchanged. The request path refreshes the current PR’s notices before choosing; failed metadata reads retain stored evidence. A failed record/recovery write disables skip decisions for that tick, including the hourly-budget fallback, so stale timing cannot suppress a request. A substantive completed formal review after the refusal event can clear an untimed refusal, including when that review predates first discovery of the notice; blank approvals, command acknowledgments, skipped analyses and old findings cannot. The latest qualifying review timestamp survives in the account-wide recovery record, preventing a later-discovered untimed notice from before that recovery from restoring the preference. A newer genuine refusal still applies; legacy timed-notice eligibility stays unchanged. Strict substantive evidence can establish recovery while a timed record is active, even before its discovery time, without clearing that timed record before its legacy discovery fence. Blank legacy timed approvals never establish recovery. Strict successful-review evidence also records a pure recovery watermark when no availability record exists, so subsequently discovered older untimed notices cannot revive refusal ranking; this watermark supplies no availability deadline or skip eligibility. Ordinary, fractional-second and UTC-offset event timestamps use the existing canonical timestamp parser, never retrieval time. Malformed stored records are preserved rather than treated as absence. Substantive length conservatively excludes HTML/Markdown formatting and entity references and normalizes Unicode separators, format and control characters, so blank formatted bodies cannot recover.
