# Finished-worktree sweep cadence

`workspace-sweep.sh` is a cadence adapter around the merged Issue #1961
`stale-cleanup.sh --apply-finished --root DIR --json` contract. It never calls
plain `--apply`, age cleanup, remote branch deletion, or `git clean`. The helper
owns authorship, merged PR (a PR closed without merging is kept as `closed_unmerged_pr`; `/pm-clean` lists it for confirmation, Issue #2281), pushed/clean state, environment files, locks,
caller protection and live-session evidence. Unknown liveness retains a tree.
Managed Codex/Cursor worktrees and unbound desktop sessions remain protected.
Detached HEAD worktrees remain protected. The artifact pass below handles
scoped handoffs, unheld branches, orphan metadata and attributable scratch.
Phase A worktrees already removed need no special treatment;
remaining Phase B/C branches qualify only under the same finished-class checks.

## Callers

- The parent orchestration checkout runs `--trigger post-merge --repo-dir DIR`
  only after verifying Phase C's `merged` outcome against GitHub.
- A `/pm day` tick runs `--trigger pm-day --repo-dir DIR --min-interval SECONDS`
  after its generation and activity checks pass and no stop is requested. Default interval is 3600;
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
Malformed repository/session discovery state is actionable, never an empty
successful sweep. Missing files may still bootstrap an unregistered installation.

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
timeouts kill the entire owned process group. SIGTERM and interruption also
kill/reap the owned command group before exit 130. Command output parsing is
capped at 16 MiB. No credentials, provider usage, or review invocations are involved.
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
bootout/bootstrap/enable/kickstart/list. Failure at any of the four activation
steps unloads the new job, verifies removal, then restores and bootstraps the
previous plist (or removes the new plist on first install). Rollback failures
are reported explicitly; an unload failure retains the plist and backup.
Different runner paths require `--force`.
Uninstall verifies the job is unloaded before removing its plist and retains
registry, state, logs and backup. No installer runs automatically from setup.

## Finished artifacts

After the finished-worktree pass, the cadence runs `lib/workspace_artifacts.py`
under the repository lock. It reuses repository identity, terminal PR/authorship,
pushed-work, process census and guarded branch-deletion checks. There is no
age-only branch deletion, remote ref deletion, `git clean`, forced worktree
removal or recursive source-directory removal.

- Scoped handoffs require a terminal PR and exact embedded PR/repository/HEAD
  identity, rechecked under `handoff-state.sh`'s existing lock. Open, malformed,
  symlinked and mismatched records remain. Legacy flat files are not attributed
  across repositories automatically.
- Unheld local branches require a terminal owner-authored PR, no newer/unpushed
  work, a fresh expected tip and Git's checkout/ref-transaction guards. Protected
  branches and any branch held by a worktree remain.
- Missing-path registrations require unlocked, clean index metadata, no operation
  in progress, terminal/pushed evidence and a complete fresh census. A live
  manually moved checkout pointing at the registration protects it. Removal uses
  only `git worktree remove`; refusal lists the path without force.
- Orphan checkouts without registrations are reported and retained with
  `orphan_checkout_work_state_unverifiable`: dirty/unpushed state cannot be proved.
  Missing bookkeeping never grants recursive source-deletion permission. This is
  the final safety policy, not a planned forced-deletion fallback.
- Old scratch needs `.claude-workspace-artifact.json` with `schema_version:"1.0"`,
  `owner_repo`, `pr_number` and `owner_pid`. The PR must be terminal, the owner PID
  gone, a complete cwd census inactive, and directory/contents older than seven
  days. Unknown ownership or liveness retains data. Scratch containing `.git`,
  `.env`/`.env.*`, links, foreign-owned entries or special files remains. Inventory
  is rechecked before individual unlinks and empty-directory removal.

Scratch discovery covers `~/.claude/scratch`, canonical `/tmp/claude-*` and the
platform's native temporary directory. `WORKSPACE_SWEEP_SCRATCH_ROOTS_JSON` is an
explicit JSON array of absolute roots for isolated fixtures. Unattributed legacy
session logs and scratch remain report-only. Registered Codex/Cursor/external
worktrees retain the same finished-class rules and unknown-desktop protection.

Each pass handles at most100 artifact candidates. A persisted rotating cursor
prevents starvation behind retained entries. Raw artifact captures remain separate
from worktree captures; partial/unknown outcomes never claim zero removals.

`workspace-sweep.sh --repo-dir /absolute/checkout --report` (or `--configured
--report`) reads the latest retained run per repository without registration or
cleanup. Counts reflect actual removals; byte counts are logical file bytes, not
physical filesystem blocks. Old records without measurements stay unknown, and
invalid/truncated input is marked incomplete. Bytes count only after successful
worktree removal or actual artifact unlinks.

## Registering session scratch

When a tool knows its long-lived session's PID and associated PR, it can bind an
existing ephemeral scratch directory explicitly:

```bash
workspace-sweep.sh --repo-dir "$REPO" --register-scratch "$SCRATCH" \
  --pr "$PR" --owner-pid "$SESSION_OWNER_PID"
```

The PID must be a currently running ancestor owned by this user; never substitute
a guessed or already-dead PID. Registration refuses arbitrary directories outside
the scratch roots, worktree metadata, environment files and conflicting ownership.
It creates a private ownership record and a locked private discovery index, so
nested native session scratch can be found without recursively guessing ownership
from directory names. Repeating the same binding is safe; a different binding is
never overwritten. The index is published before the marker: interruption leaves
an indexed but unknown artifact, never deletion permission. Explicit retry can
finish an absent marker; conflicting or malformed markers remain for inspection.
Missing retired paths are pruned only from the current repository's discovery
entries, without touching any source directory.

This mode does not start a sweep. Agents without reliable session ownership leave
scratch unregistered and report-only. A running wrapped session remains protected.

Reclaimed logical bytes use the final pre-removal stat snapshot, so they are an
estimate of file sizes rather than a measurement of freed physical blocks. An
uncertain mutation leaves total removals/bytes unknown and separately preserves
known lower bounds and raw evidence; it never turns an unproved outcome into zero.
Git ref/registration control-metadata savings are not estimated.

Cleanup rechecks the allowed scratch roots independently of discovery entries. A
forged index cannot expand that namespace, and a native per-user `claude-UID`
container is never registered as one session. Only an attributable session subtree
may qualify; nested ownership records prevent one artifact from absorbing another.

Handoff cleanup additionally requires explicit Phase C completion with a matching
repo/PR/HEAD completion disposition (`verified`, or justified `retained` scope),
a recorded worktree, and a complete inactive-owner census. Pending or legacy
handoffs without that evidence stay put, including merged PRs still recovering
issue closure. Registered checkouts must still pass clean/pushed/terminal checks;
managed desktop bindings remain unknown. A completed already-reaped checkout can
release its metadata only after the same liveness checks. Completion writers publish the guarded
disposition before Phase C is marked finished; ordinary wrap deletes its own
scoped handoff after successful reconciliation.

Artifact handoff deletion also supplies the selected file's SHA256 revision to
handoff-state. The helper verifies it under the writer lock in addition to
PR/repo/HEAD, so a resumed owner changing completion state at the same HEAD
cannot lose its newer handoff. Unknown or changed content is retained.
