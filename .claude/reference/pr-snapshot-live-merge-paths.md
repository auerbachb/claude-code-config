# Which gate runs read live (issue #2444)

`lib/pr-snapshot.sh` lets the scripts of one poll cycle share reviews, comments,
statuses, check-runs and the HEAD commit for at most 60 seconds. A gate run that
is the last check before a merge must not act on a shared read, so it passes
`merge-gate.sh <PR> --live`, which pins `PR_SNAPSHOT_TTL=0` and
`SLOW_READ_CACHE_TTL=0` for itself and every script it starts (`pr-state.sh`,
`check-runs-snapshot.sh`, `ci-status.sh`, `reviewer-of.sh`, `required-checks.sh`).
A TTL of 0 stores nothing and reuses nothing; nothing the caller sets raises it.

Forced live:

| Path | How |
|---|---|
| `/wrap` (every gate capture, including the post-AC re-run; Phase C runs `/wrap`) | `--live` in the `wrap-capture-gate` block |
| `/wrap` recovery loop (`wrap-merge-gate-recovery.md` gate refresh) | `--live` |
| `/merge` (both gate runs) | `--live` |
| `phase-c-merger` gate verification (both reviewer branches; its `ac-gate` re-run uses "the same invocation") | `--live` |
| `admin-merge.sh`, `clean-behind-check.sh` | export both TTLs as 0 in the script itself |

Left on the snapshot (polling only, never the last check before a merge):
`polling-state-gate.sh`, `escalate-review.sh`, `/babysit-pr` and
`/pr-monitor-and-manage` ticks, and `/fixpr` waits. Those dispatch `/wrap`, which
re-reads live.

What a stale snapshot can hide on a polling run, for at most 60 seconds: a new
human `CHANGES_REQUESTED` in the reviews list and a newly failed check-run. A new
bot finding is not hidden: review threads are read live on every run. Fixtures:
`tests/pr-snapshot.test.sh`, section "a merge path reads live".
