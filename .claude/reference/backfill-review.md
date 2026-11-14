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

## Range mode (issue #2324)

`backfill-review.sh --range` reviews `main` in stretches instead of one logged merge at a time. One committed-range review covers many small PRs, which fits the reviewers' rate limits better than one request per small diff. The per-PR mode above is unchanged; with no `--range` the script behaves as before. Range mode uses the free channels only, never opens a PR, triggers no GitHub reviewer, posts no comment, and does not read the ledger or touch labels.

**Start.** The marker is `~/.claude/backfill-range-marker.json` (override `BACKFILL_RANGE_MARKER`; never in a worktree). Its shape: `{schema_version: 1, repos: {"owner/name": {last_reviewed_commit, updated_at, last_range: {first, last, commits, files, bound, channel}, uncovered: [{commit, files, largest_cap, recorded_at, reason}], skipped_empty: [{first, last, commits, files: 0, recorded_at, reason}]}}}`. Written atomically (a temp file in the same directory, then rename), and only after a verified run whose findings were all parsed and filed. On a first run with no marker, give `--from <commit>`, or use the default: the parent of the oldest first-parent commit on `main` within `--default-days` (default 14; env `BACKFILL_RANGE_DEFAULT_DAYS`). The run prints the start and its source. A default window that reaches the repository's first commit stops with `range_no_start` rather than starting there silently. `--from` over an existing marker is a usage error.

**Refusals.** An unreadable or malformed marker stops with `range_marker_unreadable`, a marker commit missing from the checkout with `range_marker_unknown_commit`, and a marker that is not on the first-parent chain of the pinned `origin/main` with `range_marker_not_ancestor`. All three exit 6 and leave the marker untouched. Nothing falls back to an arbitrary commit.

**First-parent start.** The walk follows first parents, so the start (the marker, or `--from`) must sit on the first-parent chain of the pinned `origin/main`. A second-parent commit is an ancestor too, but walking from it would review mainline commits that predate it, so it is refused. A marker refusal stops with `range_marker_not_ancestor` (exit 6); a `--from` refusal is a usage error (exit 2) naming the first-parent chain. Nothing is written in either case.

**Bounds.** A stretch is cut by distinct changed files, not time. A file is counted once per stretch, using `git diff --no-renames --name-only -z <start> <commit>` and counting the NUL-terminated paths. The NUL form keeps a name with spaces or a newline as one path; a rename counts as two files.

| Reviewer | Bound | Source |
|---|---|---|
| CodeAnt CLI | 15 | `local-review-cli-failure-modes.md` "The 15-file cap" (`meta.max_files`; files past it are skipped and reported clean) |
| CodeRabbit CLI | 150 | `pricing-matrix.md`, CLI row: "150 files/review" |

`--range-bound N` (env `BACKFILL_RANGE_BOUND`) lowers the bound for every reviewer. A larger value is ignored. Each channel gets its own cut, so a fallback channel reviews the same stretch within its own bound. A commit that is over a lowered bound on its own is reviewed alone, in full, and recorded like any other stretch. It is not partial: the bound only sets the cut, and the channel's own hard cap (below) is what decides whether the reviewer can take it. A stretch larger than the channel's own cap (CodeAnt 15, CodeRabbit 150; never lowered by `--range-bound`) is never handed to that channel: it is refused, the channel is dropped for the run, and the next channel gets a re-cut. A single commit over CodeAnt's 15 but within CodeRabbit's 150 is therefore reviewed by CodeRabbit only; if CodeRabbit is unavailable, the run stops with `capacity_exhausted` and the marker stays put.

**Uncovered (a single commit over every cap).** A single commit whose distinct changed-file count exceeds the largest hard cap (150, CodeRabbit's) fits no reviewer. It is never sent to one, and the run does not stall on it. The run appends `{commit, files, largest_cap, recorded_at, reason}` to `repos[<repo>].uncovered` and advances `last_reviewed_commit` past it in one atomic write, then prints `backfill-review: uncovered commit <sha> files=N largest_cap=M; ...` on stdout and logs the same line to `~/.claude/logs/backfill-review.log`. It is never counted as reviewed, clean, or covered: `reviewed` and `clean` do not move, and `last_range` is not written for it. If the uncovered record cannot be written, the marker is left unchanged and the run stops with `range_uncovered_write_failed` (exit 5). An unavailable reviewer is not this case: a 16-file commit with CodeRabbit down still stops with `capacity_exhausted` and no advance.

**Covered in full, or uncovered.** Every stretch a reviewer runs on is covered in full: the reviewer is only ever handed a stretch within its own hard cap, so it always sees every file. There is no partial record. `uncovered` means no reviewer ran at all, and it is the case where the marker moves past code no reviewer saw while that code is still on main. (A net-empty stretch also passes unreviewed commits, but none of their changes remain; see below.) A human who wants to look at those commits reads `uncovered` in the marker file and reviews each listed SHA by hand. 

**Net-empty stretch (issue #2338).** A stretch whose net diff from the marker has zero changed files (a change followed by its exact revert, for example) leaves the tree at its last commit identical to the tree at the marker, so nothing from it remains on main. The run passes it without a reviewer: in one atomic write it appends `{first, last, commits, files: 0, recorded_at, reason}` to `repos[<repo>].skipped_empty` and advances `last_reviewed_commit` to the stretch's last commit. `last_range` is not written, and the stretch is never counted as reviewed, clean, or covered. The walk then continues from that commit, so an over-bound commit after the pair is handled by the cap and `uncovered` rules as usual. A net-empty stretch at the tip of `main` advances the marker to `main`. If the `skipped_empty` record cannot be written, the marker is left unchanged and the run stops with `range_skipped_empty_write_failed` (exit 5). A non-empty net diff is ordinary: a revert of a commit that landed before the marker removes files from the marker's tree, so it is reviewed normally.

**Review.** The reviewed tree is a throwaway detached worktree at the stretch's last commit (`core.hooksPath=/dev/null`). The base is a temporary branch at the marker. `local-review.sh --tool <ch> --scope committed --base <branch>` runs as in the per-PR mode, and nothing from the tree is built or executed. A run that is not verified drops that channel and retries the same stretch on the next channel. With no channel left the run stops with `capacity_exhausted`.

**Filing.** Findings go through the same normalize, verify-against-`main`, dedup, and `issue-file.sh` path as per-PR mode. The verification compares the flagged file on `main` with its content at the stretch's last commit. Each issue names the first and last commit of the stretch and the introducing PR: the last commit in the stretch that touched the flagged path, read from its squash subject. This is path-level and approximate. If no PR number can be read, the issue says so.

**Fingerprint.** Range findings use the location only: repo, path, and flagged line, with no PR number and no range. A re-review of an overlapping stretch lands on the same issue, through the exact marker `<!-- backfill-range-finding: owner/repo:<fp> -->`. That marker cannot collide with the per-PR `<!-- backfill-finding: owner/repo#PR:<fp> -->`. The cost is that one flaw found by both the per-PR pass and a range pass files two issues. The per-PR fingerprint keeps the PR number, so the two passes never share a marker.

**What "covered" means.** A commit is covered when the marker has passed it after a verified run: a free reviewer ran a committed-range review over its net diff, every finding it reported was parsed, and each bug was filed or matched an existing issue. It does not mean clean. A bug introduced and fixed inside one stretch is invisible, because only the net diff is reviewed. A failed, rate-limited, timed-out, or capacity-exhausted run covers nothing, and the marker stays where it is.

**Stop reasons.** `done` (the marker reached `main`), `window_closed`, `max_reviews`, `capacity_exhausted`, `range_failed`, `range_findings_unparsed`, `range_filing_failed`, `range_setup_failed`, `range_marker_write_failed` (exit 5), `range_uncovered_write_failed` (exit 5), `range_skipped_empty_write_failed` (exit 5), `range_internal_error` (exit 5, a git enumeration failure), `dry_run`, and the three marker refusals above (exit 6). Every stop prints the summary line. The exit code is 0 for these stops, except the two exit-5 faults and the exit-6 refusals listed above, and usage errors (exit 2: `--from` without `--range`, `--from` over an existing marker, a `--from` that is not a commit, a bad `--range-bound` or `--default-days`).

**Dry run.** `--range --dry-run` lists each stretch it would review as `first..last commits=N files=M bound=B channel=C`, each uncovered commit as `would record uncovered commit <sha> files=N largest_cap=M`, and each net-empty stretch as `would skip (net-empty) first..last commits=N (nothing written)`. It writes nothing: no marker, no ledger, no issues, no labels. It reads `origin/main` (a fetch) and the marker.

**Scheduling.** `install-backfill-review.sh` does not schedule range mode. Turning it on for the overnight run is a follow-up decision, to be made after range mode has run cleanly for a while.

**Tests.** `.claude/scripts/tests/backfill-range-review.test.sh` covers the bound cut, a lowered-bound commit reviewed in full, the default start, a refused start, the marker advance after a verified run, the marker kept after failed and filing-failed runs, the two marker refusals, the `--from` usage errors, the dry run, the uncovered record (a 151-file commit is recorded and skipped, the small commit after it is reviewed; a failed record write leaves the marker unchanged; dry run lists it and writes nothing), NUL-counted file totals (a 16-file commit with a spaces-only name is refused for CodeAnt), a second-parent start refused, net-empty stretches passed without a review (a change and its revert followed by an over-bound commit, the same at the tip of main, a failed `skipped_empty` write, the dry run, and a revert of a pre-marker commit that is not skipped; issue #2338), and range-only env and flags validated only under `--range`.

## Tests

`.claude/scripts/tests/backfill-review.test.sh` — offline: seeded ledger, fixture repo, stub CLIs and gh. Covers one deduped issue per planted bug, no re-review, marker recovery, outage → pending, lookup failure → pending, window handling, disabled hooks, the allowlist, no paid-reviewer call, and the rename and unresolvable-path verdicts (filed, never dropped), a runner killed while a helper sleeps leaving no lock, failing rows sinking behind a fresh one and being skipped at the cap, same-anchor findings in one issue, a repeated channel run once, a quoted heading, and the window re-check after slow setup.

## Accepted residuals (issue #1946)

Each residual fails closed: nothing is marked reviewed or filed wrongly.

- **A long `gh` outage can use up a row's attempts.** A marker or dedup lookup failure counts as an attempt, because the review it follows has already spent budget. An outage that lasts `--max-row-attempts` runs can skip rows. A skipped row keeps `merged-unreviewed`. To retry it, reset it with `unreviewed-merge-ledger.sh backfill --status pending`.
- **A same-anchor finding from a later run is not appended.** When an earlier run already filed an issue at that anchor, the exact marker reuses that issue. A different finding at the same location is recorded against it, but its text is not added, because the runner never comments on issues or PRs. That issue already sends a human to the location.
- **The lock frees up to 0.2 s after a hard kill** (the holder's poll interval). A run that starts inside that gap stops with `lock_held` and retries on the next tick.
