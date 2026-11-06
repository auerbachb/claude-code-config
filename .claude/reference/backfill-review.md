# Backfill review of unreviewed merges (issue #1900)

The no-review override (`no-review-override.md`, issue #1899) merges a PR when no AI reviewer answered within its window and logs it in `~/.claude/unreviewed-merges.json`. `.claude/scripts/backfill-review.sh` goes back over those merges during a quiet window, using **free** reviewer capacity only, and turns each real bug into a GitHub issue.

## Review method — and why

A merged PR cannot be re-reviewed in place, so the runner reviews the **merged diff**: it checks out the merge commit in a throwaway detached worktree (`git -c core.hooksPath=/dev/null worktree add --detach`, so no repo hook runs), points a temporary local branch at the merge commit's first parent, and runs `local-review.sh --tool <cli> --scope committed --base <that branch>` from inside the worktree. That is exactly "merge commit vs its parent" — the squash diff GitHub merged — and it needs no change to `local-review.sh`. Nothing from the reviewed tree is built, installed, or executed; only the vendor CLI reads it. The worktree and the branch are removed after every row.

Rejected: **a review-only draft PR replaying the diff.** Opening a PR invites the GitHub-side reviewers, and those are the paid ones (BugBot, Greptile, CodeRabbit on-demand receipts) — plus PR noise and gate side effects. The local CLIs already carry the false-clean checks of `local-review.sh` and run on their own quotas, independent of the Apps (`ai-review-chain-roles-decision.md` §Repo variance).

## Free reviewers only

The channel allowlist is hard-coded — `coderabbit` and `codeant` CLIs. `--channels` / `BACKFILL_REVIEW_CHANNELS` can only narrow it; any other name is a usage error (exit 2). The runner never comments on a PR, never posts a trigger (`@cursor review`, `@greptileai`, `@coderabbitai`), and never calls `gh api`; its only PR write is the label swap. An unattended run never holds an owner approval for a paid review, so there is no paid path to gate. The runner does not consult `cr-review-hourly.sh` or `review-daily-cap.sh` — those pace GitHub-App reviews, a separate meter.

## Capacity and fail-closed behavior

- Rows are taken fewest failed attempts first, then oldest merge (`merged_at`, then PR number).
- Per row, channels are tried in order. A **verified** run (local-review.sh exit 0 or 1, `verified_run: true`) is used. Anything else — error record, 403/daily cap, rate limit, idle or max-duration timeout, CLI not installed — drops that channel for the rest of the run, because the CLIs' caps are daily/hourly and a retry would only burn the next slot.
- With no channel left the run stops (`stop=capacity_exhausted`, exit 0); the row being reviewed and every later one stay `pending`. Exhaustion is never a skip.
- `--max-reviews` (default 3, the CodeRabbit CLI's hourly allowance) bounds CLI attempts per run, failed ones included.
- With the window enforced, a new review starts only when the window has at least `2 × --timeout` seconds left (local-review.sh's wall-clock cap). The reserve is checked at the top of each row and again just before each CLI attempt, after the merge lookup, fetches, worktree setup, and any failed channel have spent part of the window. `--now` pins the run's starting instant; later checks advance it by elapsed run time.
- Also left `pending`: an origin/main fetch failure (whole run), a failed merge-commit lookup or fetch, a first parent still missing after a fetch by SHA (a shallow checkout; only a successful answer naming no usable commit is `skipped`), a worktree setup failure, a capture the normalizer cannot parse, a verified run that reported more findings than parsed, a failed marker lookup, `issue-dedup.sh` exit 4, a failed `issue-file.sh` create, and a ledger write failure.
- **Per-row attempt cap.** Some rows fail *after* their review ran, so the failure cost a review attempt: an unparseable capture, `parsed < reported`, or a failed verdict, marker, dedup, or create step. Such a row records `backfill.attempts` and `backfill.last_failure` and stays `pending`, so it sorts behind fresh rows on the next run. When it reaches `--max-row-attempts` (default 3), it is `skipped` with `skip_reason: gave up after N failed review attempts; last: …`. It is never marked reviewed and keeps `merged-unreviewed`. Capacity exhaustion, a closed window, and failures before the review (lookups, fetches, worktree setup) spend no review budget and are not counted.
- A single run lock keeps two runs from reviewing (and filing for) the same rows. It is `flock(2)` on `~/.claude/backfill-review.flock`, held by a small holder child on a descriptor only that child has open (Python descriptors are not inherited). No helper child of the runner (`gh`, `git`, a hung CLI) can keep the lock after the runner dies. The holder polls `getppid()`, so a reused PID cannot fool it. It exits within 0.2 s of the runner's death, or immediately from the EXIT trap. There is no stale-PID takeover to race on. A held or unlockable lock is `stop=lock_held`, exit 0. The log line names the last holder recorded in the lock file and whether that process is still alive.

## What counts as a real bug, and verification against main

`lib/backfill_review.py normalize` parses the raw capture: CodeRabbit NDJSON `finding` records (`fileName`, `severity`, line from "at line N" in `codegenInstructions`, the untrusted-data preamble stripped) and CodeAnt `.issues[]` (`relevant_file`, `start_line`, `label`, `issue_content`). A finding is a bug when CodeRabbit says `major`/`critical`, or the CodeAnt label matches bug/security/critical/major. Everything else is recorded as `dropped: below bug severity`; a finding with no path or no text is `dropped: no file anchor or no text`.

`origin/main` is fetched once per run and its SHA pinned. Each bug's path is first resolved on main — the same path, else its rename target from `git diff -M --name-status <merge> <main>` (recorded as `main_path`) — then checked mechanically:

| Verdict | Test | Action |
|---|---|---|
| `still_present` | the file is unchanged since the merge, or the flagged line's text still appears on main (at `main_path`) | file |
| `changed` | the file changed and the flagged line is gone | file, with a "confirm it still applies" note |
| `changed`, `main_path: null` | the path is gone and no rename was detected (deleted, or moved past rename detection) | file, with a "locate the code and confirm" note |

The runner biases toward filing (`autofile-dedup.md` §cost asymmetry): it cannot judge semantics, so a changed or vanished region is filed with the note, never silently dropped — a rename must never turn a real bug into `reviewed-clean`.

## Filing and dedup

Each filed finding gets a fingerprint (repo, PR, path, and the flagged line — the first line of the finding text only when no line is given; the tool and the reviewer's wording are left out because a re-review rewords and may run on the other CLI) and an exact marker `<!-- backfill-finding: owner/repo#PR:<fingerprint> -->` in the body.

Two bug findings in one row can share an anchor (same path and line), and so share a fingerprint. They are filed as **one** issue whose Problem quotes every finding's text. Each finding records that issue. The fingerprint stays location-based (no text hash), so a reworded re-review still lands on the same marker.

1. **Exact marker** — `gh issue list --state all --json number,url,body` and a local `contains` match (not the search API, whose index lags). One match → reuse that issue, no create; more than one, a failed lookup, or a listing that fills its limit (`BACKFILL_MARKER_LOOKUP_LIMIT`, default 5000 — absence is unproven) → the row stays pending. This is also the crash-recovery path: an issue that landed before a lost ledger write is found again, never filed twice.
2. **Recall** — `issue-dedup.sh` on the file name plus the finding's first line. Candidates are listed in Notes as `Possibly duplicates #N — …`; fuzzy recall never suppresses (the runner cannot do the quote judgment).
3. **Create** — `issue-file.sh --json` with the seven-section body and the `/issue-maker` footer, label `bug` (dropped by `issue-file.sh` if the repo lacks it), never `--assignee`. Background links the source PR and merge commit; Problem quotes the finding inside a `text` fence. `@` is neutralized there, so a quoted mention can never summon a reviewer. A quoted line that starts with `#` is indented one space, so a quoted `## Estimate` cannot count as a section heading in `issue-file.sh`'s order check (that check ignores fences); Notes carry the main SHA, verdict, candidates, and marker.

## Ledger outcome and label

Through `unreviewed-merge-ledger.sh backfill --status <s> --detail-json -`:

- `backfill_status`: `reviewed-clean` (no fileable bug), `issues-filed`, or `skipped` (no usable merge commit — `skip_reason` says why). `pending` rows are the only ones a run reads, so a reviewed row is never re-checked.
- `backfill`: `{channel, main_sha, merge_commit_sha, reviewed_at, findings[{fingerprint, tool, path, line, severity, verdict, disposition, issue}], issues[], label_synced}`.
- Label: on `reviewed-clean` / `issues-filed`, `gh pr edit --remove-label merged-unreviewed --add-label backfill-reviewed` (label created if missing). A failed swap records `label_synced: false`; the next run retries only the swap, never the review. `skipped` rows keep `merged-unreviewed`.

## Configuration

| Setting | Flag | Environment | Default |
|---|---|---|---|
| Quiet window (local, may cross midnight) | `--window HH:MM-HH:MM` | `BACKFILL_REVIEW_WINDOW` | `01:00-06:00` |
| Window time zone | `--tz` | `BACKFILL_REVIEW_TZ` | `America/New_York` |
| Channels, in try order | `--channels` | `BACKFILL_REVIEW_CHANNELS` | `coderabbit,codeant` |
| CLI attempts per run | `--max-reviews` | — | `3` |
| Idle bound per review | `--timeout` | — | `900` |
| Failed post-review attempts before a row is skipped | `--max-row-attempts` | `BACKFILL_MAX_ROW_ATTEMPTS` | `3` |

`--channels` drops a repeated name, so a failed channel is never retried in the same row. `--ignore-window` runs now (a manual pass); `--dry-run` lists the rows it would review and touches nothing. The ledger is cross-repo: one run handles the repo checked out at `--repo-dir`. An explicit `--repo` that differs from a GitHub origin of `--repo-dir` exits 2 (credentialed and port-qualified GitHub URLs are parsed; an unparseable GitHub origin also exits 2, and the URL is printed with any credential redacted), so findings never land in the wrong repo.

## Scheduling

The durable mechanism is a **launchd user agent** outside any Claude session — the `claude-config-sync` pattern (`install-config-sync.sh`). Not `CronCreate` (in-memory, dies with the session — `scheduling-reliability.md`), not `/schedule`'s scheduled tasks (a fresh unattended Claude session per tick, for work that needs no model — `cross-session-durability.md`), not a `/pm day` hook (only runs while a session is open). The runner checks the window itself and exits 0 outside it, so a plain interval timer is enough.

Install it once with `install-backfill-review.sh --repo-dir <checkout>` (`--interval SECONDS` overrides the default `1800`, minimum 60). The label is fixed, so one checkout is scheduled per machine: re-running for the same checkout updates the job, and a different checkout is refused (exit 1) unless `--force` replaces the installed job. It is modelled on `install-config-sync.sh` — template `com.user.claude-backfill-review.plist`, escaped placeholder rendering, `plutil -lint`, backup/rollback, then bootout → bootstrap → enable → kickstart and an exact-label `launchctl list` check — and resolves, before writing anything:

- **Checkout** — `--repo-dir` to its absolute git top level; it must have an `origin` remote that parses to a GitHub owner/name with the runner's own parser, else exit 2 (launchd has no useful working directory, so the plist carries the absolute path as its own argument).
- **Runner** — the skills-worktree copy (pinned to `main`) when it and its helpers are present, else this checkout's copy, flagged as not pinned. A worktree runner runs whatever code that worktree currently holds.
- **PATH** — the directories of `gh`, `git`, `jq`, `python3` (required: the runner exits 3 on every tick without them) and `coderabbit` / `codeant` (warned about when missing), then the base system directories, deduplicated.

`uninstall-backfill-review.sh` unloads and removes the agent and always keeps the ledger (`~/.claude/unreviewed-merges.json`), its locks, and the logs. Both scripts exit 1 on non-macOS hosts. A one-off run: `backfill-review.sh --repo-dir <checkout> --ignore-window`. Logs: `~/.claude/logs/backfill-review.log` (runner detail) and `backfill-review-stdout.log` / `-stderr.log` (launchd). Tests: `.claude/scripts/tests/install-backfill-review.test.sh`.

## Tests

`.claude/scripts/tests/backfill-review.test.sh` — offline: seeded ledger, fixture repo, stub CLIs and gh. Covers one deduped issue per planted bug, no re-review, marker recovery, outage → pending, lookup failure → pending, window handling, disabled hooks, the allowlist, no paid-reviewer call, and the rename and unresolvable-path verdicts (filed, never dropped), a runner killed while a helper sleeps leaving no lock, failing rows sinking behind a fresh one and being skipped at the cap, same-anchor findings in one issue, a repeated channel run once, a quoted heading, and the window re-check after slow setup.

## Accepted residuals (issue #1946)

Each residual fails closed: nothing is marked reviewed or filed wrongly.

- **A long `gh` outage can use up a row's attempts.** A marker or dedup lookup failure counts as an attempt, because the review it follows has already spent budget. An outage that lasts `--max-row-attempts` runs can skip rows. A skipped row keeps `merged-unreviewed`. To retry it, reset it with `unreviewed-merge-ledger.sh backfill --status pending`.
- **A same-anchor finding from a later run is not appended.** When an earlier run already filed an issue at that anchor, the exact marker reuses that issue. A different finding at the same location is recorded against it, but its text is not added, because the runner never comments on issues or PRs. That issue already sends a human to the location.
- **The lock frees up to 0.2 s after a hard kill** (the holder's poll interval). A run that starts inside that gap stops with `lock_held` and retries on the next tick.
