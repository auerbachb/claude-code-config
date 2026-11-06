# Backfill review of unreviewed merges (issue #1900)

The no-review override (`no-review-override.md`, issue #1899) merges a PR when no AI reviewer answered within its window and logs it in `~/.claude/unreviewed-merges.json`. `.claude/scripts/backfill-review.sh` goes back over those merges during a quiet window, using **free** reviewer capacity only, and turns each real bug into a GitHub issue.

## Review method — and why

A merged PR cannot be re-reviewed in place, so the runner reviews the **merged diff**: it checks out the merge commit in a throwaway detached worktree (`git -c core.hooksPath=/dev/null worktree add --detach`, so no repo hook runs), points a temporary local branch at the merge commit's first parent, and runs `local-review.sh --tool <cli> --scope committed --base <that branch>` from inside the worktree. That is exactly "merge commit vs its parent" — the squash diff GitHub merged — and it needs no change to `local-review.sh`. Nothing from the reviewed tree is built, installed, or executed; only the vendor CLI reads it. The worktree and the branch are removed after every row.

Rejected: **a review-only draft PR replaying the diff.** Opening a PR invites the GitHub-side reviewers, and those are the paid ones (BugBot, Greptile, CodeRabbit on-demand receipts) — plus PR noise and gate side effects. The local CLIs already carry the false-clean checks of `local-review.sh` and run on their own quotas, independent of the Apps (`ai-review-chain-roles-decision.md` §Repo variance).

## Free reviewers only

The channel allowlist is hard-coded — `coderabbit` and `codeant` CLIs. `--channels` / `BACKFILL_REVIEW_CHANNELS` can only narrow it; any other name is a usage error (exit 2). The runner never comments on a PR, never posts a trigger (`@cursor review`, `@greptileai`, `@coderabbitai`), and never calls `gh api`; its only PR write is the label swap. An unattended run never holds an owner approval for a paid review, so there is no paid path to gate. The runner does not consult `cr-review-hourly.sh` or `review-daily-cap.sh` — those pace GitHub-App reviews, a separate meter.

## Capacity and fail-closed behavior

- Rows are taken oldest merge first (`merged_at`, then PR number).
- Per row, channels are tried in order. A **verified** run (local-review.sh exit 0 or 1, `verified_run: true`) is used. Anything else — error record, 403/daily cap, rate limit, idle or max-duration timeout, CLI not installed — drops that channel for the rest of the run, because the CLIs' caps are daily/hourly and a retry would only burn the next slot.
- With no channel left the run stops (`stop=capacity_exhausted`, exit 0); the row being reviewed and every later one stay `pending`. Exhaustion is never a skip.
- `--max-reviews` (default 3, the CodeRabbit CLI's hourly allowance) bounds CLI attempts per run, failed ones included.
- With the window enforced and no `--now`, a new review starts only when the window has at least `2 × --timeout` seconds left (local-review.sh's wall-clock cap).
- Also left `pending`: an origin/main fetch failure (whole run), a failed merge-commit lookup or fetch, a first parent still missing after a fetch by SHA (a shallow checkout; only a successful answer naming no usable commit is `skipped`), a worktree setup failure, a capture the normalizer cannot parse, a verified run that reported more findings than parsed, a failed marker lookup, `issue-dedup.sh` exit 4, a failed `issue-file.sh` create, and a ledger write failure.
- A single run lock — `flock(2)` on `~/.claude/backfill-review.flock`, held by the runner's open file descriptor until it exits however it dies, so there is no stale-PID takeover to race on — keeps two runs from reviewing (and filing for) the same rows; a held or unlockable lock is `stop=lock_held`, exit 0.

## What counts as a real bug, and verification against main

`lib/backfill_review.py normalize` parses the raw capture: CodeRabbit NDJSON `finding` records (`fileName`, `severity`, line from "at line N" in `codegenInstructions`, the untrusted-data preamble stripped) and CodeAnt `.issues[]` (`relevant_file`, `start_line`, `label`, `issue_content`). A finding is a bug when CodeRabbit says `major`/`critical`, or the CodeAnt label matches bug/security/critical/major. Everything else is recorded as `dropped: below bug severity`; a finding with no path or no text is `dropped: no file anchor or no text`.

`origin/main` is fetched once per run and its SHA pinned. Each bug is checked mechanically:

| Verdict | Test | Action |
|---|---|---|
| `removed` | the path no longer exists on main | drop (`dropped: file gone on main`) |
| `still_present` | the file is unchanged since the merge, or the flagged line's text still appears on main | file |
| `changed` | the file changed and the flagged line is gone | file, with a "confirm it still applies" note |

The runner biases toward filing (`autofile-dedup.md` §cost asymmetry): it cannot judge semantics, so a changed region is filed with the note, never silently dropped.

## Filing and dedup

Each filed finding gets a fingerprint (repo, PR, path, and the flagged line — the first line of the finding text only when no line is given; the tool and the reviewer's wording are left out because a re-review rewords and may run on the other CLI) and an exact marker `<!-- backfill-finding: owner/repo#PR:<fingerprint> -->` in the body.

1. **Exact marker** — `gh issue list --state all --json number,url,body` and a local `contains` match (not the search API, whose index lags). One match → reuse that issue, no create; more than one, a failed lookup, or a listing that fills its limit (`BACKFILL_MARKER_LOOKUP_LIMIT`, default 5000 — absence is unproven) → the row stays pending. This is also the crash-recovery path: an issue that landed before a lost ledger write is found again, never filed twice.
2. **Recall** — `issue-dedup.sh` on the file name plus the finding's first line. Candidates are listed in Notes as `Possibly duplicates #N — …`; fuzzy recall never suppresses (the runner cannot do the quote judgment).
3. **Create** — `issue-file.sh --json` with the seven-section body and the `/issue-maker` footer, label `bug` (dropped by `issue-file.sh` if the repo lacks it), never `--assignee`. Background links the source PR and merge commit; Problem quotes the finding inside a `text` fence with `@` neutralized so a quoted mention can never summon a reviewer; Notes carry the main SHA, verdict, candidates, and marker.

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

`--ignore-window` runs now (a manual pass); `--dry-run` lists the rows it would review and touches nothing. The ledger is cross-repo: one run handles the repo checked out at `--repo-dir`. An explicit `--repo` that differs from a GitHub origin of `--repo-dir` exits 2 (credentialed and port-qualified GitHub URLs are parsed; an unparseable GitHub origin also exits 2, and the URL is printed with any credential redacted), so findings never land in the wrong repo.

## Scheduling

The durable mechanism is a **launchd user agent** outside any Claude session — the `claude-config-sync` pattern (`install-config-sync.sh`). Not `CronCreate` (in-memory, dies with the session — `scheduling-reliability.md`), not `/schedule`'s scheduled tasks (a fresh unattended Claude session per tick, for work that needs no model — `cross-session-durability.md`), not a `/pm day` hook (only runs while a session is open). The runner checks the window itself and exits 0 outside it, so a plain interval timer is enough.

The packaged installer is follow-up work (linked from the PR). Until it lands, the owner sets the agent up once by hand — `~/Library/LaunchAgents/com.user.claude-backfill-review.plist` with `ProgramArguments` = `/bin/bash`, `/Users/<you>/.claude/skills-worktree/.claude/scripts/backfill-review.sh` (the copy pinned to `main`; write the absolute path — launchd does not expand `$HOME` or `~`), `--repo-dir`, `<absolute checkout path>`; `StartInterval` `1800`; an `EnvironmentVariables` `PATH` that includes the directories of `git`, `jq`, `python3`, `gh`, `coderabbit`, and `codeant`; then `launchctl bootstrap gui/$(id -u) <plist>`. A one-off run: `backfill-review.sh --repo-dir <checkout> --ignore-window`. Log: `~/.claude/logs/backfill-review.log`.

## Tests

`.claude/scripts/tests/backfill-review.test.sh` — offline: seeded ledger, fixture repo, stub CLIs and gh. Covers one deduped issue per planted bug, no re-review, marker recovery, outage → pending, lookup failure → pending, window handling, disabled hooks, the allowlist, no paid-reviewer call, and the `removed` verdict.
