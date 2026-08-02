# .claude/scripts/

> **This is an index only.** Each entry gives the script name and a one-sentence purpose. For flags, exit codes, and full contract details, run `.claude/scripts/<name> --help` or read the script header.
>
> **Adding a new script?** Add one row in the matching category below. Put the full contract (usage, flags, exit codes) in the script header and `--help` output — not here.

Manually-invoked utility scripts. See [scripts/ vs hooks/](#scripts-vs-hooks) for the distinction.

## PR State & Polling

Scripts that read PR state, track comment watermarks, and determine reviewer ownership.

| Script | Purpose |
|--------|---------|
| `pr-state.sh` | Gather full PR state (threads, CI, comments, merge state) into a JSON snapshot |
| `infer-pr.sh` | Resolve a PR reference from an explicit URL/number or from session-state candidates |
| `poll-watermarks.sh` | Track high-water IDs for the three PR comment endpoints to detect new bot findings |
| `polling-state-gate.sh` | CR polling procedural gate — registers PR in session-state and runs merge-gate.sh each cycle |
| `pr-preflight.sh` | Flip a draft PR to ready and trigger the four AI reviewers when absent |
| `pr-authorship.sh` | Hard authorship gate — verify the authenticated user authored a PR before any automated write |
| `pr-issue-ref.sh` | Extract the linked issue number from a PR body via GitHub's issue-closing keywords |
| `reviewer-of.sh` | Determine which reviewer (cr/bugbot/greptile) owns a PR; reads session-state then GitHub history |
| `reviewer-activity.sh` | Detect whether each AI reviewer has posted activity on a specific pushed SHA |

## Review & Escalation

Scripts that manage the CR→BugBot→Greptile reviewer chain, budgets, and round gating.

| Script | Purpose |
|--------|---------|
| `escalate-review.sh` | Run the CR→BugBot→Greptile escalation gate; emits a single deterministic `STATUS=` verdict — see `--help` |
| `local-review.sh` | Run a local review CLI (CodeRabbit/CodeAnt) with every false-clean check applied; emits the compact result contract |
| `cr-review-hourly.sh` | Track CodeRabbit's rolling hourly review cap and per-PR explicit trigger count |
| `cr-plan.sh` | Detect a substantive CodeRabbit implementation-plan comment on a GitHub issue |
| `greptile-budget.sh` | Guard the daily Greptile review budget counter in session-state |
| `maybe-trigger-ai-review.sh` | Post supplemental AI reviewer triggers when complexity and CR-round gates pass |
| `complexity-score.sh` | Compute a PR complexity score from additions, deletions, and changed-file count |
| `cycle-count.sh` | Reconstruct per-PR review-then-fix cycle count for round gating |

## Merge Gate & Sequencing

Scripts that verify merge readiness and sequence a PR fleet to avoid conflict rounds.

| Script | Purpose |
|--------|---------|
| `merge-gate.sh` | Verify the full merge gate (reviewer approval, CI, threads, mergeStateStatus) |
| `clean-behind-check.sh` | Decide whether a BEHIND PR is safe for /admin-merge (hunk-level overlap check) vs a rebase |
| `admin-merge.sh` | Generate or execute the solo-owner branch-protection bypass |
| `merge-sequence.sh` | Overlap-aware merge dispatch planner to avoid conflict rounds across a PR fleet |
| `ci-status.sh` | Summarize CI check-run health for a commit or PR |
| `check-runs-dedup.sh` | Collapse a check-run list to one verdict per check (newest check suite wins) |
| `ac-checkboxes.sh` | Parse and update the PR body's Test plan checkboxes |
| `dismiss-stale-bot-changes.sh` | Dismiss stale bot CHANGES_REQUESTED reviews on old SHAs after a push |

## Review Threads & Diffs

Scripts that resolve review threads and guard the branch diff through a rebase.

| Script | Purpose |
|--------|---------|
| `resolve-review-threads.sh` | Fetch PR review threads via GraphQL, resolve them, and verify `isResolved` |
| `reply-thread.sh` | Post a reviewer-aware reply to a PR review thread (inline endpoint, PR-level fallback) |
| `diff-survival-check.sh` | Verify a rebase or conflict resolution did not vaporize the branch's own diff |

## Session State & Locking

Scripts that read and write `~/.claude/session-state.json` and per-PR handoff files.

| Script | Purpose |
|--------|---------|
| `session-state.sh` | Canonical read/write helper for `~/.claude/session-state.json` (atomic, scoped, field-typed) |
| `state-lock.sh` | *(library — source, do not execute)* Portable mkdir-based advisory lock for session-state writes |
| `session-state-audit.sh` | Audit and guarded repair of `~/.claude/session-state.json` |
| `handoff-state.sh` | Locked read/write helper for per-repo handoff files (`~/.claude/handoffs/`) |
| `handoff-migrate.sh` | One-time migration of flat handoff files to per-repo scoped paths |

## Scheduling & Monitoring

Scripts that manage the background-silence ceiling, launchd watchdog, and time helpers.

| Script | Purpose |
|--------|---------|
| `bgwork-ceiling.sh` | Hard ceiling on chat silence while background work (subagents, watchers) runs |
| `statusline.sh` | Render the Claude Code status line — one stdout line of `ET time · branch · N agents · M watchers`; reads the session JSON on stdin, always exits 0 |
| `install-silence-watchdog.sh` | Install the macOS launchd watchdog that monitors Claude heartbeat files |
| `uninstall-silence-watchdog.sh` | Uninstall the macOS launchd silence watchdog |
| `silence-watchdog.sh` | External launchd watchdog that checks heartbeat files when Claude is stalled (macOS only) |
| `off-peak-minute.sh` | Deterministic per-repo off-peak cron minute selector for CronCreate jobs |
| `gh-window.sh` | GitHub date-window builder (ET-anchored, macOS + GNU dual-syntax) |
| `workday.sh` | US business-day calculator (ET-anchored, macOS + GNU date) |

## Backlog & PM

Scripts that surface stale issues, duplicate candidates, forgotten PRs, and backlog metrics.

| Script | Purpose |
|--------|---------|
| `backlog-staleness.sh` | Detect stale backlog issues (solved by merged PR, inactive, superseded, potential duplicate) |
| `backlog-health.sh` | Aggregate backlog health metrics wrapping `backlog-staleness.sh` |
| `churn-hotspots.sh` | Detect files touched by many distinct merged PRs as refactor candidates |
| `issue-dedup.sh` | Score open issues against keywords to find duplicate candidates before filing |
| `forgotten-pr-triage.sh` | Detect and classify open PRs that have gone quiet past a staleness threshold |
| `pm-config-get.sh` | Extract a named section from `.claude/pm-config.md` |

## Skills & Telemetry

Scripts that audit, report, and sync skill and script usage telemetry.

| Script | Purpose |
|--------|---------|
| `skill-usage-report.sh` | Read `~/.claude/skill-usage.log` and print usage tables and dead-skill candidates |
| `skill-usage-snapshot.sh` | Push/restore skill telemetry to/from the repo's dedicated `skill-telemetry` branch |
| `skill-usage-merge.sh` | Merge another machine's skill-usage telemetry into the live log files |
| `audit-skill-usage.sh` | Legacy monthly skill-usage audit against `.claude/data/skill-usage.json` |
| `skill-conventions-audit.sh` | Static audit that `.claude/skills/*/SKILL.md` files match repo conventions |
| `script-usage-report.sh` | Summarize script adherence telemetry from `~/.claude/script-usage.log` |

## Trust, Worktree & Repo

Scripts that repair trust flags, detect stale worktrees, and sync main.

| Script | Purpose |
|--------|---------|
| `repair-trust-single.sh` | Fix trust flags for one project in `~/.claude.json` |
| `repair-trust-all.sh` | Fix trust flags for all projects in `~/.claude.json` |
| `repair-worktrees.sh` | Detect stale git worktrees (merged/deleted branch) and optionally remove them |
| `dirty-main-guard.sh` | Detect and quarantine dirty tracked state on the root repo's main branch |
| `repo-bootstrap.sh` | Check and optionally install required repo configuration (CR workflow, branch protection) |
| `repo-root.sh` | Resolve the absolute path of the root (main) worktree |
| `stale-cleanup.sh` | Detect and optionally remove stale worktrees and branches (out-of-band, safe) |
| `main-sync.sh` | Sync a repo's local main branch with `origin/main` |

## Utilities

Miscellaneous helpers used by skills and hooks.

| Script | Purpose |
|--------|---------|
| `model-fleet.sh` | Resolve the current Claude model fleet from `.claude/model-fleet.json` |
| `verify-exit-report-block.sh` | Verify stdin contains a parseable EXIT_REPORT with all required fields |
| `graphite-repo-init.sh` | Run `gt repo init` to create `.git/.graphite_repo_config` for Graphite CLI |
| `hhg-state.sh` | Extract a 2-letter USPS state code from HHG-formatted text |

## Python helpers

Called by other scripts; run `python3 .claude/scripts/<name>.py --help` for usage.

| Script | Purpose |
|--------|---------|
| `cr-plan-filter.py` | Substantive-plan filter for CodeRabbit issue comments (called by `cr-plan.sh`) |
| `memory-audit.py` | Memory-store audit engine behind `/memory-clean` |

## scripts/ vs hooks/

- **`scripts/`** — manual utilities, run on demand
- **`hooks/`** — auto-triggered by Claude Code lifecycle events (Stop, PostToolUse, etc.)

The `trust-flag-repair.sh` hook in `hooks/` runs automatically after every agent response. These scripts are for manual diagnosis and one-off repairs (e.g., after new worktree/project entries, cloning/moving projects, or config recreation).

## tests/

All tests live in `tests/` and run offline (no network required). Run from the repo root:
`bash .claude/scripts/tests/<name>.test.sh`

| Test | What it covers |
|------|----------------|
| `admin-merge.test.sh` | Tests for `admin-merge.sh` |
| `backlog-health.test.sh` | Tests for `backlog-health.sh` |
| `backlog-staleness.test.sh` | Tests for `backlog-staleness.sh` |
| `bgwork-ceiling.test.sh` | Tests for `bgwork-ceiling.sh` |
| `check-runs-dedup.test.sh` | Tests for `check-runs-dedup.sh` |
| `churn-hotspots.test.sh` | Tests for `churn-hotspots.sh` |
| `ci-status.test.sh` | Tests for `ci-status.sh` |
| `clean-behind-check.test.sh` | Tests for `clean-behind-check.sh` |
| `compaction-resume-polling-state-gate.test.sh` | Tests `polling-state-gate.sh --verify-state` after synthetic post-compaction recovery |
| `cr-plan.test.sh` | Tests for `cr-plan.sh` |
| `diff-survival-check.test.sh` | Tests for `diff-survival-check.sh` |
| `dirty-main-guard.test.sh` | Tests for `dirty-main-guard.sh` |
| `escalate-review.test.sh` | Tests for `escalate-review.sh` |
| `forgotten-pr-triage.test.sh` | Tests for `forgotten-pr-triage.sh` |
| `handoff-scoping.test.sh` | Tests per-repo handoff path scoping in `handoff-state.sh` |
| `handoff-state.test.sh` | Tests for `handoff-state.sh` |
| `infer-pr.test.sh` | Tests for `infer-pr.sh` |
| `issue-dedup.test.sh` | Tests for `issue-dedup.sh` |
| `merge-gate-authorship.test.sh` | Tests the authorship guard in `merge-gate.sh` |
| `merge-gate-ci-dedup.test.sh` | Tests CI check-run deduplication in `merge-gate.sh` |
| `merge-gate-greptile-comment.test.sh` | Tests Greptile comment handling in `merge-gate.sh` |
| `merge-gate-stale-approval.test.sh` | Tests stale-approval rejection in `merge-gate.sh` |
| `merge-sequence.test.sh` | Tests for `merge-sequence.sh` |
| `model-fleet.test.sh` | Tests for `model-fleet.sh` |
| `poll-watermarks.test.sh` | Tests for `poll-watermarks.sh` |
| `polling-state-gate-multirepo.test.sh` | Tests multi-repo isolation in `polling-state-gate.sh` |
| `polling-state-gate.test.sh` | Tests for `polling-state-gate.sh` |
| `pr-authorship.test.sh` | Tests for `pr-authorship.sh` |
| `pr-preflight.test.sh` | Tests for `pr-preflight.sh` |
| `pr-state-classify.test.sh` | Tests the `classify` jq function inside `pr-state.sh --since` |
| `pr-state-infer-candidates.test.sh` | Tests `pr-state.sh --infer-candidates` |
| `reply-thread.test.sh` | Tests for `reply-thread.sh` |
| `session-state-audit.test.sh` | Tests for `session-state-audit.sh` |
| `session-state-migration.test.sh` | Tests the legacy-flat → per-repo migration in `session-state.sh` |
| `session-state.test.sh` | Tests for `session-state.sh` |
| `skill-conventions-audit.test.sh` | Tests for `skill-conventions-audit.sh` |
| `skill-usage-merge.test.sh` | Tests for `skill-usage-merge.sh` |
| `stale-cleanup.test.sh` | Tests for `stale-cleanup.sh` |
| `state-lock.test.sh` | Tests for `state-lock.sh` |
| `statusline.test.sh` | Tests for `statusline.sh` |
