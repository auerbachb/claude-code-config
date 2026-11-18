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
human `CHANGES_REQUESTED` in the reviews list, a newly failed check-run, and a
bot finding posted only as a review body or an issue comment (those come from the
snapshot lists). A bot finding with an inline thread is not hidden: review threads
are read live on every run. The next poll after the entry expires reads the lists
live, and every `--live` merge path reads them live at once. Fixtures:
`tests/pr-snapshot.test.sh`, section "a merge path reads live".

Entry writes are serialized with `state-lock.sh` (owner token, dead-owner
recovery, guarded commit); if the lock cannot be taken in about two seconds or was
broken mid-write, nothing is written. Residual limit: a lock holder wedged past
the library's 120-second stale age could still finish a write it began before the
break; the consequence is bounded to one 60-second entry on polling paths.
