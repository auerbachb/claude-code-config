# Finished-worktree sweep cadence

`workspace-sweep.sh` is a cadence adapter around the merged Issue #1961
`stale-cleanup.sh --apply-finished --root DIR --json` contract. It never calls
plain `--apply`, age cleanup, remote branch deletion, or `git clean`. The helper
owns authorship, merged/closed PR, pushed/clean state, environment files, locks,
caller protection and live-session evidence. Unknown liveness retains a tree.
Managed Codex/Cursor worktrees and unbound desktop sessions remain protected.
Detached HEAD worktrees remain out of scope, as do non-worktree artifacts
(Issue #1963). Phase A worktrees already removed need no special treatment;
remaining Phase B/C branches qualify only under the same finished-class checks.

## Callers

- The parent orchestration checkout runs `--trigger post-merge --repo-dir DIR`
  only after verifying Phase C's `merged` outcome against GitHub.
- A `/pm day` tick runs `--trigger pm-day --repo-dir DIR --min-interval SECONDS`
  after its generation/activity/stop gate passes. Default interval is 3600;
  `CLAUDE_WORKSPACE_SWEEP_INTERVAL_S` overrides it. This never repeats Step 1,
  `/pm-clean`, or age confirmations. `/wrap` does not remove its own checkout.
- The opt-in LaunchAgent runs `--trigger daily --configured`. The installer
  defaults to 03:00 local time; `--hour 0..23` changes it. launchd coalesces
  sleep-missed calendar runs on wake; shutdown-missed runs are not replayed.
  This is scheduled daily, not guaranteed once every 24 hours.

The runner invokes cleanup with the explicitly selected checkout as cwd, so
Git's main checkout and the calling parent stay protected. All safety evidence
is still a bounded snapshot; no filesystem/session atomicity is promised.

## Repository selection

`~/.claude/workspace-sweep-repos`, when present, overrides default discovery:
write one literal absolute Git checkout path per line, comments beginning `#`.
No shell expansion, tilde expansion or command execution occurs. Entries are
validated with Git and deduplicated by the common Git directory. Invalid or
moved paths are logged and do not prevent other repositories from running.

Without that file, `~/.claude/workspace-sweep/repos.json` supplies registered
paths. Existing scoped session-state `root_repo` paths also seed discovery;
recent timestamped PR activity qualifies, otherwise registered linked worktrees
are required. A SessionStart metadata-only background call and each explicit run
register the current checkout. Entries qualify when seen within 14 days, or
when Git lists linked `.claude/worktrees` worktrees. This includes repositories
never driven through PM, such as sales-kit, after their first registration.
Already-open sessions without stored paths or linked worktrees need one explicit
`workspace-sweep.sh --register-repo /absolute/checkout` or an explicit list.
Repository identity keys are never interpreted as filesystem paths.

## State, bounds and output

The runner uses an owner-only 0700 state directory and 0600 regular files;
reads/locks refuse symlinks and hardlinks. A per-common-directory OS lock
serializes overlapping triggers, with automatic release on process death.
PM ticks inside the interval skip without a cleanup subprocess. Post-merge
and daily runs bypass the interval and update its shared attempted timestamp.
Missing, malformed or future timestamps permit a run. Complete or incomplete
cleanup verdicts (exit 0/1/2 with validated JSON) advance the timestamp; an
unavailable interface, failed startup or busy lock does not.

Each attempted repository appends one JSONL record to
`~/.claude/workspace-sweep/runs.jsonl`: epoch, checkout, trigger, actual removed
worktree count, skipped-with-reason count, reason classes, and actionable errors.
A missing/invalid final cleanup report leaves counts explicitly null because
partial removals cannot be proved zero.
Removal counts use `worktree_removed`, so branch-retention failure cannot hide a
successful worktree removal. Skips deduplicate by path. Interval-suppressed
no-ops do not claim a run. Successful cleanup and routine retention stay silent;
unknown desktop liveness also stays silent and remains recorded. Failed probes,
API uncertainty and removal failures print one actionable line per repository.
Daily actionable output lands in the LaunchAgent stdout log.

Git discovery is bounded to 15 seconds per command, cleanup to 300 seconds;
timeouts kill the entire owned process group. Command output parsing is capped
at 16 MiB. No credentials, provider usage, or review invocations are involved.
Each executed cleanup retains private byte-for-byte stdout/stderr up to the
16 MiB per-stream bound, explicitly marking oversize captures, and its exit
code under a unique `workspace-sweep/run-*` directory, including refused-path
listings. Timeouts retain available partial output before reporting unknown.
Later clean runs do not overwrite failure evidence. These captures
and the append-only log have no automatic expiry; manual maintenance is separate.
Reason metadata is retained in the run log. The underlying cleanup retains its own safety gates on every invocation.

## Installation

`install-workspace-sweep.sh --dry-run` validates tools and prints escaped plist
XML plus the exact manual command, without creating directories/files, changing
launchd, logging telemetry, or sweeping. Normal install selects the complete
skills-worktree runner when available, builds an absolute tool PATH, validates
with `plutil` when installed, backs up an existing plist, then uses
bootout/bootstrap/enable/kickstart/list. A failed bootstrap restores the previous
plist and attempts its bootstrap. Different runner paths require `--force`.
Uninstall verifies the job is unloaded before removing its plist and retains
registry, state, logs and backup. No installer runs automatically from setup.
