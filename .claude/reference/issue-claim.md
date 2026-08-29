# Issue Claims — Mechanism and Rationale (issue #873)

Detail for the claim rule in `.claude/rules/issue-planning.md`. Not auto-loaded; the rule file carries the binding behavior, this file carries the mechanism.

## The problem

Work gets picked up from several independent places — a `/pm` thread running issues inline, a click-to-launch chip, `/start-issue` in a fresh tab, or a plain "go work on #167". None of those threads can see each other; the only thing they share is GitHub.

Every entry path *did* guard itself, but on the wrong question: **"does an open PR exist for this issue?"** A PR is the *last* artifact a thread produces. Between picking an issue and opening its PR there is a plan-and-code window that routinely runs half an hour or more, and for that entire window every other thread's check comes back clean. Two threads then work the same issue in good faith, and the collision only surfaces when the second PR appears. The cost is not a merge conflict — it is two full pipelines (planning, coding, CI, reviewer quota) buying one issue's worth of progress, plus a PR to throw away.

`.claude/scripts/issue-claim.sh` stakes the claim at **pick** time instead.

## Artifacts

GitHub is the only store. There is no local claim state — a local file by definition cannot see a sibling thread, let alone another machine.

| Artifact | Carries | Read by |
|---|---|---|
| `in-progress` label | the coarse "someone is working this" bit | any issue list, `/wave`'s batch pre-filter, a human skimming the backlog |
| `@me` assignee | ownership at **account** level (#732) | `--release`'s ownership test |
| claim comment `<!-- claude-claim: {"holder":…,"login":…} -->` | **holder** identity + the claimed-at timestamp (`created_at`) | `--check`'s `mine` vs `claimed` decision |

The label is created idempotently on first use (`gh label list` existence check, then `gh label create … || true`) — the repo had no such label before this feature.

## Why a holder token, not just the login

This is the one place the implementation deliberately departs from the CodeRabbit plan, which defined `mine` as "label present **and** viewer in assignees".

The failure this feature exists to prevent is **two Claude threads belonging to the same human**. Both authenticate as the same GitHub login, so an assignee-only test answers "yes, mine" in the second tab and blocks nothing — the feature would be inert in exactly its motivating case. The claim comment therefore records a holder token, and `mine` means *this thread*, not *this account*.

`.claude/scripts/tests/issue-claim.test.sh` pins this: substituting the login-level comparison makes scenario (2) fail.

**Holder resolution:** `--holder ID` → `$CLAUDE_CLAIM_HOLDER` → `$CLAUDE_SESSION_ID` → `<hostname>:<git toplevel>`.

The default is honest about its granularity rather than hiding it: two threads sharing one checkout resolve to one holder. That is acceptable because `CLAUDE.md` mandates a worktree per thread, so the mandated workflow always yields distinct holders. A caller holding a real session id should still pass `--holder`.

## Block at holder level, release at account level

A deliberate asymmetry:

- **`--check` / `--claim` compare holders**, so a sibling thread of yours is blocked. That is the whole point.
- **`--release` compares logins**, so a terminal state reached by a *different* thread of yours — a Phase C merger, a `/wrap` run from another worktree — still clears the claim instead of leaking it.

Releasing your own account's claim is always safe. #732 protects a *collaborator's* claim, and no action here ever touches one: `--release` removes only the viewer's own assignment and only the viewer's own claim comments, and leaves a collaborator's label in place.

## Verdicts and exit codes

| Verdict | Meaning | Exit | Caller does |
|---|---|---|---|
| `unclaimed` | no label, no claim comment | 0 | proceed |
| `mine` | claim comment holder == this holder | 0 | proceed (re-claim is a no-op) |
| `stale` | foreign holder, older than `CLAIM_STALE_HOURS` | 0 | **warn** and proceed; `--claim` takes it over |
| `claimed` | foreign holder, fresh | 1 | skip, naming the claim |
| `unknown` | any indeterminate `gh` result | 4 | skip — treat exactly as `claimed` |

Exit codes mirror `pr-authorship.sh` (`2` usage, `3` not found) so the two guards read the same way at a call site.

**Fail-closed** is the rule that matters most: a `gh` failure, an unparseable issue, or a claim with no readable timestamp all resolve to a live claim, never to "startable". An `unknown` verdict never reads as permission.

## Staleness

A thread that dies mid-task must not poison the issue forever, so a claim ages out — `CLAIM_STALE_HOURS`, default **4**. Long enough to survive a slow CR plan plus a long coding phase; short enough that a dead thread does not park an issue for a day.

Stale is **surfaced as a warning, never a block**: `--check` returns `stale` with exit **0**. The timestamp comes from the claim comment's `created_at`, falling back to the most recent `labeled` event for `in-progress` on the issue timeline — which is what makes a label applied by hand, with no claim comment, still expirable rather than permanent.

Timestamp parsing is done arithmetically in `awk` rather than by shelling out to `date -d` / `date -j`, because GNU and BSD `date` disagree on both spellings.

## Override

`--allow-claimed` proceeds past a fresh foreign claim **and says so** on stderr.

It is only ever an explicit per-issue, per-session instruction from the user in chat ("start it anyway") — never a config default, never inferred from context, never carried forward to the next issue. The same shape as the authorship override in `.claude/rules/safety.md`. The flag is rejected with a usage error on `--check` and `--release`, where it would otherwise sit silently inert; a silently-inert override flag is how an override becomes a default.

## Call sites

| Path | Where |
|---|---|
| `/start-issue` | Step 2b — after reading the issue, **before** CR-plan polling and worktree creation |
| `/subagent` | Step 6.0, alongside the existing open-PR check; `--claim` before spawning Phase A |
| chip-launched thread | first action in the `prompt`, after the MODEL GUARD preamble, before any repo read |
| ad-hoc "work on #N" | `.claude/rules/issue-planning.md` step 0 |
| `/wave` | Step 2 candidate filter (see batching below) |
| `candidate-ownership.sh` | per-candidate `--check --json`, inside `/pm`'s pre-dispatch ownership sweep (1B.5 / 3.4; #1431) |
| `/wrap` | after Step 2.4's squash merge succeeds — `--release` |
| `admin-merge.sh` | after each `FINAL_MERGED == true` — `--release` |
| chip stale-hygiene trigger 4 | issue closed without a merged PR — `--release` |

### `/wave` batching

Running `--check` per candidate over a 30-issue backlog would be ~90 API calls. `/wave` instead makes **one** `gh issue list --label in-progress --json number` call and runs the helper only for candidates in that (usually tiny) intersection. Candidates outside it cannot hold a claim, because the label is written before the claim comment.

### The owned-resumable upgrade lives outside this script (#1431)

`/pm`'s ownership sweep treats a `stale` verdict as **owned** when resumable evidence stands behind it — a parked entry, a resume marker, a handoff file, a surviving branch. A *bare* stale claim keeps the warn-and-proceed above, unchanged.

That rule is layered on top of `issue-claim.sh`, never inside it. This script answers one question from GitHub alone — who holds the claim, and is it fresh. Teaching it about local markers and handoff files would make every caller depend on local disk state to answer a question about a shared remote claim. Mechanism: `pm-ownership-sweep.md`.

Adoption, when the sweep finds a dead owner, reuses the **existing** stale-takeover path (`--claim` re-stamping a stale claim). A *fresh* foreign claim is never adopted: taking it needs `--allow-claimed`, which stays a user instruction and is never inferred.

### Release is best-effort at merge time

`/wrap` and `admin-merge.sh` release **after** the merge has already succeeded. A failed release is a warning there, never a non-zero exit — an unreleased claim ages out on its own within `CLAIM_STALE_HOURS`, whereas failing an already-completed merge would be a much worse outcome.

## Relationship to neighbouring issues

- **#756** serializes *different* issues that share a file. This covers the *same* issue picked twice; no overlap filter addresses that.
- **#636** — `/wave`'s launch-time filtering, whose dedup this strengthens.
- **#732** — authorship scope. A collaborator's claim is context, never something to overwrite.
- The same-machine `git worktree list` guard in `/start-issue` stays as a backstop. It only covers one entry path, on one machine, and only after the worktree stage — it is not a substitute for a claim other threads can see.
