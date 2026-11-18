# GitHub REST allowance backoff (Issue #2445)

Final slice of Issue #2421. Pollers back off by themselves when the hourly GitHub REST allowance (5,000 calls, shared by every agent and tool on the machine) runs low, and wait for the reset when it hits zero.

## The helper

`.claude/scripts/lib/gh-rate-budget.sh`, sourced (`gh_rate_sleep 60`, `gh_rate_interval 60`) or run (`status`, `interval <secs>`).

- The figure comes only from GitHub, through `gh api rate_limit`, which GitHub does not charge. Nothing is estimated or counted locally, and no token or credential is read.
- `GH_RATE_RESOURCE=graphql` reads the GraphQL allowance instead (default `core`, REST). `cr-plan.sh` sets it because it reads through `gh issue view`.
- Above the threshold (`GH_RATE_LOW_AT`, default 300) nothing changes. Below it the interval doubles up to `GH_RATE_MAX_INTERVAL` (default 1800 s) and one notice is printed per reset window. At zero the poller waits for the reset GitHub reported plus 2 s, capped at an hour, never less than its normal interval.
- A used-up allowance (0 remaining) waits for the reset whatever `GH_RATE_LOW_AT` is. The once-per-window marker keeps one line per (resource, reset, level), so REST and GraphQL do not re-announce each other.
- An unreadable figure changes nothing: normal interval, no notice. A rate-limited or failed response is "no data" everywhere, never a gate verdict, "no reviews", "CI passed" or an empty list.
- State lives in `~/.claude/gh-rate-budget/` (mode 600, written by temp file and rename): `cache` (one read serves a 30 s window, `GH_RATE_CACHE_SECS`) and `announced` (the once-per-window marker). Both are safe to delete.
- Merge paths (`merge-gate.sh` with or without `--live`, `/wrap`, `/merge`, `admin-merge.sh`, `clean-behind-check.sh`) never call it and behave as before.

## Which allowance

The counter from PR #2446 separates REST (`core`) and GraphQL. Per poller:

- `cr-plan.sh --poll` reads through `gh issue view` (GraphQL only): it sets `GH_RATE_RESOURCE=graphql`.
- The review pollers (`pr-state.sh`, `merge-gate.sh` and `gh pr list`/`gh pr view` behind them) spend both: REST for reviews, inline and issue comments and check-runs, GraphQL for threads and PR metadata. They use `--interval`, which defaults to `GH_RATE_RESOURCE=both`: it reads the two allowances and takes the longer interval, so a poller backs off when either is low.

## Pollers

`gh-rate-budget.sh --interval <base-seconds>` is the form a printed Monitor command uses: seconds to sleep on stdout, the once-per-window notice on stderr, exit 0 always, `<base>` unchanged when the figure is unreadable. A caller uses it as `wide=$("$RATE_SH" --interval "$delay" || true)` and keeps `$delay` unless `$wide` is a number; with no helper on disk the cadence is unchanged.

Wired by script:

- `cr-plan.sh --poll` (GraphQL). A rate-limited comment read inside the poll window waits and retries instead of exiting 4; any other failure still exits 4.
- The `babysit-pr` Monitor loop (the `babysit-pr-monitor-loop` fence in its SKILL.md). The widened wait is computed before the review-deadline clamp, so a nearer deadline still shortens it.
- The `/pr-monitor-and-manage` Monitor loop printed by `pmm-pre-dispatch.sh --monitor-command`. The helper path is printed beside the script, like `bounded-run.sh`.

Wired by one line of prose naming the helper where the cadence is stated: `/fixpr` wait loop (`FIXPR_WAIT_POLL_SECS`), the `/pm day` Monitor loop, the `/pr-monitor-and-manage` auto-wake loop, and the Phase B review loop (`phase-b-reviewer` agent, 60 or 120 s cycle).

Not wired, and why: `bgwork-ceiling.sh` and `table-freshness.sh` ticks make no GitHub call. `polling-state-gate.sh`, `escalate-review.sh`, `merge-gate.sh` do one cycle per call and own no cadence. `wait-until.sh` runs a caller-supplied check, which may not call GitHub, so the caller owns its interval. Merge paths (`merge-gate.sh` with or without `--live`, `/wrap`, `/merge`, `admin-merge.sh`, `clean-behind-check.sh`) are never slowed, skipped or blocked.

## Live check (cannot run inside one agent)

Four pipelines for an hour, then compare with the 2026-11-16 figures:

```bash
gh api rate_limit --jq '.resources.core'        # before: note remaining and reset
# run four pipelines for one hour (for example /pm day with PIPELINE_CEILING=4)
gh api rate_limit --jq '.resources.core'        # after: consumption = before.remaining - after.remaining, plus any reset in between
GH_REST_COUNT=1 .claude/scripts/polling-state-gate.sh <PR>   # one counted cycle
.claude/scripts/lib/gh-rate-budget.sh status    # what the helper sees
```
