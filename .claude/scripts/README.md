# .claude/scripts/

> **This is an index only.** Each category doc gives the script name and a one-sentence purpose. For flags, exit codes, and full contract details, run `.claude/scripts/<name> --help` or read the script header.
>
> **Adding a new script?** Add one row in the matching category doc under [`docs/`](docs/) — not here. Put the full contract (usage, flags, exit codes) in the script header and `--help` output. `.github/scripts/scripts-catalog-lint.sh` fails CI if a script or test has no row, so the row is not optional.

Manually-invoked utility scripts. See [scripts/ vs hooks/](#scripts-vs-hooks) for the distinction.

## Categories

| Category | Covers |
|----------|--------|
| [PR State & Polling](docs/pr-state-polling.md) | Scripts that read PR state, track comment watermarks, and determine reviewer ownership |
| [Review & Escalation](docs/review-escalation.md) | Scripts that manage the CR→BugBot→Greptile reviewer chain, budgets, and round gating |
| [Merge Gate & Sequencing](docs/merge-gate-sequencing.md) | Scripts that verify merge readiness and sequence a PR fleet to avoid conflict rounds |
| [Release Cadence](docs/release-cadence.md) | Scripts that decide when a merge is worth a TestFlight build and follow the build to a terminal state |
| [Review Threads & Diffs](docs/review-threads-diffs.md) | Scripts that resolve review threads and guard the branch diff through a rebase |
| [Session State & Locking](docs/session-state-locking.md) | Scripts that read and write `~/.claude/session-state.json` and per-PR handoff files |
| [Scheduling & Monitoring](docs/scheduling-monitoring.md) | Scripts that manage the background-silence ceiling, launchd watchdog, and time helpers |
| [Backlog & PM](docs/backlog-pm.md) | Scripts that surface stale issues, duplicate candidates, forgotten PRs, and backlog metrics |
| [Token Measurement](docs/token-measurement.md) | Scripts that capture per-repo token spend and usage baselines |
| [Skills & Telemetry](docs/skills-telemetry.md) | Scripts that audit, report, and sync skill and script usage telemetry |
| [Trust, Worktree & Repo](docs/trust-worktree-repo.md) | Scripts that repair trust flags, detect stale worktrees, and sync main |
| [Utilities](docs/utilities.md) | Miscellaneous helpers used by skills and hooks, plus the Python helpers |
| [Tests](docs/tests.md) | Every test under `tests/`, all offline (no network required) |

Every entry in those docs is a relative link to the file itself, so a name is one click from its source on github.com and in any editor.

## scripts/ vs hooks/

- **`scripts/`** — manual utilities, run on demand
- **`hooks/`** — auto-triggered by Claude Code lifecycle events (Stop, PostToolUse, etc.)

The `trust-flag-repair.sh` hook in `hooks/` runs automatically after every agent response. These scripts are for manual diagnosis and one-off repairs (e.g., after new worktree/project entries, cloning/moving projects, or config recreation).

## Not indexed here

`lib/` holds sourced helper libraries and `jq` programs rather than invocable scripts, and `tests/lib/` and `tests/fixtures/` hold test support files. None of them are catalog entries, and the catalog lint does not require rows for them.
