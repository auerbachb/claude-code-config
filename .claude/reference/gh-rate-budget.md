# GitHub REST allowance backoff (Issue #2445)

Final slice of Issue #2421. Pollers back off by themselves when the hourly GitHub REST allowance (5,000 calls, shared by every agent and tool on the machine) runs low, and wait for the reset when it hits zero.

## The helper

`.claude/scripts/lib/gh-rate-budget.sh`, sourced (`gh_rate_sleep 60`, `gh_rate_interval 60`) or run (`status`, `interval <secs>`).

- The figure comes only from GitHub, through `gh api rate_limit`, which GitHub does not charge. Nothing is estimated or counted locally, and no token or credential is read.
- `GH_RATE_RESOURCE=graphql` reads the GraphQL allowance instead (default `core`, REST). `cr-plan.sh` sets it because it reads through `gh issue view`.
- Above the threshold (`GH_RATE_LOW_AT`, default 300) nothing changes. Below it the interval doubles up to `GH_RATE_MAX_INTERVAL` (default 1800 s) and one notice is printed per reset window. At zero the poller waits for the reset GitHub reported plus 2 s, capped at an hour, never less than its normal interval.
- An unreadable figure changes nothing: normal interval, no notice. A rate-limited or failed response is "no data" everywhere, never a gate verdict, "no reviews", "CI passed" or an empty list.
- State lives in `~/.claude/gh-rate-budget/` (mode 600, written by temp file and rename): `cache` (one read serves a 30 s window, `GH_RATE_CACHE_SECS`) and `announced` (the once-per-window marker). Both are safe to delete.
- Merge paths (`merge-gate.sh` with or without `--live`, `/wrap`, `/merge`, `admin-merge.sh`, `clean-behind-check.sh`) never call it and behave as before.

## Pollers

Wired (real scripts): `cr-plan.sh --poll`. A rate-limited comment read inside the poll window now waits and retries instead of exiting 4; any other failure still exits 4.

Not wired, skill prose or printed Monitor commands that pinned tests execute with a fake `sleep`; they need the helper named in their loop as follow-ups: the `babysit-pr` Monitor loop, the `/pr-monitor-and-manage` Monitor loop printed by `pmm-pre-dispatch.sh --monitor-command`, `/fixpr` waits, the `/pm day` tick. In each, replace `sleep "$delay"` with `gh_rate_sleep "$delay"` after sourcing the helper. `polling-state-gate.sh` and `escalate-review.sh` do one cycle per call and own no cadence.

## Live check (cannot run inside one agent)

Four pipelines for an hour, then compare with the 2026-11-16 figures:

```bash
gh api rate_limit --jq '.resources.core'        # before: note remaining and reset
# run four pipelines for one hour (for example /pm day with PIPELINE_CEILING=4)
gh api rate_limit --jq '.resources.core'        # after: consumption = before.remaining - after.remaining, plus any reset in between
GH_REST_COUNT=1 .claude/scripts/polling-state-gate.sh <PR>   # one counted cycle
.claude/scripts/lib/gh-rate-budget.sh status    # what the helper sees
```
