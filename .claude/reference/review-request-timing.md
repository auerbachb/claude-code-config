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
3. Named checks: each name's newest run decides. A name with no run yet is pending until 900 seconds have passed since the later of the HEAD commit time and the first poll that saw that HEAD (`review_request_seen_epoch` in session state). After that it is ignored and listed in `ignored_checks`, so a check that never reports cannot hold the request forever. Once names are given, unnamed checks are not awaited: that is the point of the list.
4. No names: every non-reviewer run must be completed and non-blocking. No runs at all waits until the same 900-second grace passes, then requests (a repo with no CI).
5. One request per HEAD. The first request claims the HEAD (`review_request_head_sha` in session state, written by compare-and-set before the post, released if the post fails). Once recorded, no path posts a second `@codeant-ai review` for that HEAD, including the complexity cadence. A new push is a new HEAD and eligible again.
6. A `ci-only` tier requests nothing: the tier path already excludes every reviewer.
7. The request is `@codeant-ai review`, posted by `maybe-trigger-ai-review.sh`. Paid reviewers stay owner-approval only (`safety.md` §Paid AI Reviews); this setting adds no path that posts `@cursor review` or `@greptileai`.
8. An unreadable check list, commit time or tier answer holds the request for that tick (fail closed). The next tick asks again.

The complexity cadence (`#362`) in the legacy path (no `## Review policy` table) decides only what it governed before, after the first request: on a HEAD with a recorded request it posts no second CodeAnt request. Its first request for a HEAD is not gated by the cadence: when the request gate says `request`, the first request posts even while the cadence is below its round or score gate. `on-push` keeps the cadence exactly as it was. `@cursor review` stays owner-approval only and is unchanged.

A tiered repo (a `## Review policy` table) still defers to its complexity skip for the first request; only the legacy path has this change so far.

The HEAD check-run input is read with `gh api --paginate`, then reduced by `check-runs-dedup.sh`, the same rule the merge gate uses: one verdict per check name, newest suite wins. An older failed run superseded by a newer successful suite does not hold; a failing run in the newest suite does.

## Dashboard checklist (manual, not done by the harness)

Until a reviewer's automatic trigger is off, it still fires on push, and this setting only stops the agent adding a second request. Switch each off per repo. A browser-capable agent can do this with the owner's logged-in session; the owner approves each change.

1. CodeRabbit: in `.coderabbit.yaml` set `reviews.auto_review.enabled: false`, or turn off automatic review in the CodeRabbit dashboard settings for the repo. Keep manual `@coderabbitai` requests working.
2. CodeAnt: in the CodeAnt dashboard, turn off review on every push for the repo. Keep manual `@codeant-ai review`.
3. BugBot (Cursor dashboard): turn off automatic runs. It is paid; it must not start from a push.
4. Greptile dashboard: turn off auto-trigger. The dashboard bypasses the rules in `greptile.md`.
5. Graphite: retired 2026-11-03 (#1889); nothing to switch.

Verify afterwards: on a draft PR here, push a commit whose CI fails. No reviewer comment or review should appear. Fix CI, push again, and exactly one `@codeant-ai review` should appear once the named checks are green.

## Scope

This doc covers the setting and the decision. Rolling it out to other repos and measuring the effect is issue #2196.

## Tests

- `.claude/scripts/tests/review-request-gate.test.sh` — every decision state (pending, failed, green, reviewer checks, named checks, grace, once per HEAD, on-push, never, bad input).
- `.claude/scripts/tests/review-tier.test.sh` — parsing: defaults, `on-push`, named checks, malformed value, stray key outside a live block.
- `.claude/scripts/tests/maybe-trigger-tier-triggers.test.sh` — legacy path: pending holds, failed holds, green requests once, second poll on the same HEAD does not, a new push requests again.

## Availability (issue #2256)

Account-wide, not per PR: CodeRabbit's allowance is per developer, so one PR's limit notice applies to every repo.

- **Record:** `session-state.json` `.review_availability.{coderabbit,codeant}` holds `next_available_epoch`, `notice_at`, `window_seconds`, `notice_excerpt`, `source_repo`, `source_pr`, `read_at`. Written by `review-availability.sh record` from the PR's issue comments every time `no-review-override.sh` runs. Only a parsed retry window writes; an unparseable notice writes nothing, and a newer notice on file is not overwritten by an older one.
- **Expected response (settings):** `REVIEW_EXPECTED_RESPONSE_CODEANT_MIN` (default 4) and `REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN` (default 5), minutes, from the 2026-11-11 baseline. Invalid values fall back to the default.
- **Skip (before posting a request):** `decide` skips the request on this HEAD only when every free reviewer has a usable record that is still in the future and whose next-available time plus its expected response is later than now plus the no-review window. The reason is `no_reviewer_available_until <ISO>`, recorded on the PR as `review_request_skips[<head sha>]` (`mark-skip`), keyed by HEAD so a late write for an older HEAD never replaces the current one. It is written only on a path that would otherwise have posted the request, so a tier or cadence that posts nothing records nothing.
- **Override:** `no-review-override.sh` applies at once while the recorded skip is for the current HEAD and the same answer still holds (`check-skip`). Its gate JSON carries the reason as `reason` and `skip_reason`; the unreviewed-merge ledger row carries `skip_reason`. Every other hard stop is unchanged.
- **Fail toward asking:** no record, a past record, an unreadable state file, a malformed value, or a missing helper all request as today.
- **Gap:** a skip needs a parsed retry window for both free reviewers. CodeAnt has no documented limit wording with a time (`cr-rate-limits.md` does not list one), so until one is observed the skip cannot fire.
- **Tests:** `.claude/scripts/tests/review-availability.test.sh`, `.claude/scripts/tests/no-review-override-availability.test.sh`.
