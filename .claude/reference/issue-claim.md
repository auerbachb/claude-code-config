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
| claim comment `<!-- claude-claim: {"holder":…,"login":…,"since":…} -->` | **holder** identity + the claimed-at timestamp (`created_at`); `since` (renewed markers only) carries the original pickup time | `--check`'s `mine` vs `claimed` decision |

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

Account-scoped release protects collaborators (#732), but a matching login does not prove a claim belongs to the completed task. Delayed cleanup pins the observed winning marker as described below. The helper removes only the viewer's own assignment and claim comments and preserves a collaborator's label.

## Verdicts and exit codes

| Verdict | Meaning | Exit | Caller does |
|---|---|---|---|
| `unclaimed` | no label, no claim comment | 0 | proceed |
| `mine` | claim comment holder == this holder | 0 | proceed (re-claim is a no-op, or a renewal once due — see Renewal) |
| `stale` | foreign holder, older than `CLAIM_STALE_HOURS` | 0 | **warn** and proceed; `--claim` takes it over |
| `claimed` | foreign holder, fresh | 1 | skip, naming the claim |
| `unknown` | any indeterminate `gh` result, or a renewal that could not be written or verified | 4 | skip — treat exactly as `claimed` |
| *(any)* | Renewal lost ownership or found a closed issue, or guarded release found a changed marker | 5 | stop the affected operation and report the failed ownership precondition |

Exit codes mirror `pr-authorship.sh` (`2` usage, `3` not found) so the two guards read the same way at a call site. Exit `5` also covers a guarded `--release` whose observed marker no longer matches. It keeps ordinary claim blocking (`1`) distinct from lost ownership or a failed cleanup precondition (`5`).

**Fail-closed:** GitHub read failures, unreadable issue data, and an unreadable winning claim marker produce `unknown`. A holder must be a nonempty string; control characters cannot be accepted as part of a marker or a requested holder because Bash can drop or split them. An unreadable newest marker does not become absence or hand authority to an older marker. An unparseable timestamp cannot age a claim out. A real label-only issue still uses the label timeline. An `unknown` verdict never authorizes a write or launch.

## Staleness

A thread that dies mid-task must not poison the issue forever, so a claim ages out — `CLAIM_STALE_HOURS`, default **4**. Long enough to survive a slow CR plan plus a long coding phase; short enough that a dead thread does not park an issue for a day.

Stale is **surfaced as a warning, never a block**: `--check` returns `stale` with exit **0**. The timestamp comes from the claim comment's `created_at`, falling back to the most recent `labeled` event for `in-progress` on the issue timeline — which is what makes a label applied by hand, with no claim comment, still expirable rather than permanent.

Timestamp parsing is done arithmetically in `awk` rather than by shelling out to `date -d` / `date -j`, because GNU and BSD `date` disagree on both spellings.

Staleness measures time since the claim was last **written or renewed**, not since the last activity — nothing else refreshes it. Long-running work keeps its claim by renewing (below); work that stops renewing ages out exactly as before, so stale recovery for dead threads is unchanged.

## Renewal (issue #1914)

A claim is aged from its marker's GitHub `created_at`, so before #1914 a live thread whose review and CI outlasted `CLAIM_STALE_HOURS` lost its claim: a same-holder `--claim` was a pure no-op, and another holder could read the old marker as `stale` and take over. Renewal lets the holder extend a genuinely active claim.

**Order — create, verify, then clean up.** A new marker is POSTed (via `gh api`, so the response carries its comment id); the comments and then the issue are re-read and the winner selected (newest `created_at`, ties broken by id); only once the winner is this run's marker — or another viewer-authored marker of this holder, newer than the one replaced — is the label and assignee re-asserted and are the holder's **other viewer-authored** markers deleted. One final re-read of comments and issue then follows (#1933, below). The label and the old marker stay until the new marker is verified, so there is never an unclaimed interval, and older helpers (which read the newest `created_at`) see the renewal with no change. Editing the marker in place was rejected: a PATCH does not move `created_at`, and GitHub's comment PATCH has no `If-Match` compare.

**When.** Only once the marker is older than `CLAIM_RENEW_MINUTES` (default: half the stale window, 120 min at the default 4h). A value at or past the stale window is rejected with a stderr warning and the default is used instead — otherwise another holder could read live work as stale before renewal is ever due. Inside the threshold a same-holder call posts no new marker and keeps its timestamp. It may repair a missing label or viewer assignment. This avoids repeat markers while active work still renews before staleness.

**Actions.**

| Call | Same holder, not due | Same holder, due | Anything else |
|---|---|---|---|
| `--claim` | `mine`/0, no comment written | renews | unchanged acquire / takeover / block |
| `--renew` | `mine`/0, `renewed:false`, no comment written; closed issue → `mine`/5 `not-held` | renews | verdict word + exit `5` (`not-held`), **nothing written** |

**Not-due label repair (#1933).** A not-due, authorized (payload login and comment author are the viewer) same-holder call on an **open** issue re-adds a missing `in-progress` label or viewer assignee. A failed repair warns on stderr and keeps `mine`/0. Nothing is written when both are present, for an unauthorized same-holder `--claim`, or on a closed issue. This heals a fresh marker that has lost its label, which label-filtering readers (`/wave`) would otherwise treat as unclaimed. The repair cannot revive a release in progress: the helper reads the issue before the comments, and `--release` deletes markers before it removes the label.

**Closed issues (#1933).** `--renew` on a closed issue returns verdict `mine`, reason `not-held …closed…`, exit `5`, and writes nothing, whether or not renewal is due. `not-held` is a reason, not a verdict word. A not-due `--claim` on a closed issue keeps its old `mine`/0 no-op and never re-labels.

`--renew` never acquires or takes over — a heartbeat caller can never accidentally claim an issue it does not hold. `--check` never writes.

**Protection.** Renewal requires the marker's payload `login` **and** its comment author to be the viewer. A same holder token from another account is never renewed: `--claim` keeps `mine`/0 with a `renew-not-authorized` warning, `--renew` exits `5`. Cleanup deletes only viewer-authored markers carrying this holder — never another holder's, never a collaborator's (#732).

**Outcomes.**

| Situation | Result |
|---|---|
| verified renewal | `mine`/0, `renewed:true`, reason `renewed` |
| own claim already past the stale window | renews and verifies as usual; reason `renewed-after-expiry` plus a stderr warning (another holder could have taken it in that gap) |
| label/assignee write or POST failed, re-read shows no new marker | `unknown`/4 `renew-failed`; old marker and label kept |
| POST reported failure but the marker landed | reconciled on re-read as a normal renewal — matched only by the per-run nonce (payload `run`), never by holder, so a sibling same-holder renewal's marker is never taken for this run's |
| POST failed and no marker with this run's nonce is on the re-read | `unknown`/4 `renew-failed`; nothing deleted |
| verification re-read failed | `unknown`/4 `renew-unverified`; the new marker stays, no old marker is deleted |
| a newer foreign marker won | this run's new marker is deleted (best effort), winner reported with exit `5` `superseded` |
| the replaced marker vanished or the issue closed mid-renewal (a concurrent `--release`) | this run's new marker is withdrawn, the label is not re-added, exit `5` `released` |
| issue already closed | `5` `not-held`, nothing written |
| new marker missing on re-read, no newer winner | `unknown`/4 `renew-unverified` |
| cleanup delete failed | still a renewal; stderr warns a duplicate remains — inert (the newest wins) and removed by the next renewal or release |
| label re-assert failed after the POST | `unknown`/4 `renew-failed`; the new marker stays, and the next not-due `--renew`/`--claim` re-adds the label |
| **final re-read** (#1933): issue closed, or no marker of this holder left | this run's markers withdrawn; when no marker at all remains, the label/assignee this run re-added (absent before) is removed; exit `5` `released` |
| final re-read: this run's marker present but a newer foreign marker wins | this run's markers withdrawn, label left for the winner; exit `5` `superseded` |
| final re-read: a marker of this holder wins but the label or assignee is gone | re-added once; if that fails, `unknown`/4 `renew-failed` |
| final re-read failed | warning only — the renewal was already verified and stands (`mine`/0) |

**Output.** JSON adds `renewed`, `previous_claimed_at` (the replaced marker's `created_at`), and `claimed_since` (the original pickup time). After a renewal `claimed_at` is the new marker's GitHub `created_at`, never the local clock. The renewed marker's payload carries `since` — the old marker's `since`, else its `created_at` — so the pickup time survives any number of renewals; staleness still reads `created_at` only. `estimate-log.sh` takes its start time from a valid payload `since` (exact `YYYY-MM-DDTHH:MM:SSZ`, not after the marker), else the marker's `created_at`, so a renewal never shortens the measured duration (#1927).

**Residual race.** A takeover that read the claim as stale *before* the renewal can still post after the renewal verified. Verification catches it only if it lands first; the final re-read catches it only if it lands before that. Renewing inside the stale window — the default threshold — is what keeps that window closed in practice; `renewed-after-expiry` names the case where it was already open.

**Accepted residual risk (#1933).** GitHub has no compare-and-set on comments or labels, so the helper narrows these windows but cannot close them. Each one fails toward over-blocking or toward an exit `5` / `4` that the caller already handles. None of them makes a lost or stolen claim read as `mine`.

- **Release after the final re-read** (rest of items 1 and 3). If a release removes the label after the final re-read, the renewed marker can remain without the label. If a release lands between the two final reads (comments, then issue), it is not detected. Direct `--check` still blocks other holders, and the next not-due authorized call re-adds the label. Policy: the marker is the claim, and the label follows it. A surviving marker of this holder keeps its claim; a missing one means the claim was released.
- **No retry after `unknown`/4** (rest of item 2). The marker stays without the label until the holder's next `--renew` or `--claim`. The caller convention retries at the next cadence (#1927).
- **`CLAIM_STALE_HOURS=0` skips the renew-threshold clamp** (item 4, documented, no code change). With no stale window there is nothing to compare against. Every marker with positive age reads as `stale` to a foreign holder, and an explicit positive `CLAIM_RENEW_MINUTES` is accepted without a warning. The helper does not reject the combination, because configuration is validated before action dispatch, so a rejection would also turn `--check` and `--release` into usage errors. No caller sets either variable to 0.
- **Other windows.** A write can land even though it reported an error. A sibling renewal and an in-progress release can look the same in one snapshot (old marker gone, label present); the sibling reading wins, and the final re-read corrects it if the release has finished by then.

**Mixed versions.** An older helper rejects `--renew` with usage exit `2` (callers report a degraded state), and its `--claim` keeps the old same-holder no-op. Both read renewed markers correctly, since the extra `since` field is ignored and the newest `created_at` still wins.

**Caller convention.** Long-running work renews with `--renew --holder <the holder it claimed with>` at phase transitions and at a low cadence (e.g. every 30 min, never every poll tick). Exit `5` → stop and report lost ownership; `4` → warn and retry at the next cadence; `2` → the helper predates renewal, report degraded (with its first stderr line — `2` is also a usage error). Other non-zero → as `4`. Renew only with a holder captured at claim time or handed over by a trusted caller — never one read off a GitHub marker (that may be another thread's), and never `--claim` as a check.

Wired callers (#1927):

| Caller | Holder source | Renews |
|---|---|---|
| `/subagent` | `.holder` from its Step 6.0 `--claim --json`, stored as `claim_holder` in the issue-keyed pipeline entry | before every successor launch (A→B, replacement B, B→C) and from the monitor loop when `claim_renewed_at` is ≥30 min old; Phase C's prompt carries the pair to `/wrap` |
| `/start-issue` → coding thread | `CLAIM_HOLDER`, handed over in the Form B Constraints bullet | Form B reaffirm (renews when due), then before each review/CI wait; hands the pair to `/wrap` |
| `/wrap` | only a pair its caller handed over | before each Step 2.1 `/fixpr` wait dispatch; none handed over → skip with a one-line note. Release unchanged |

## Override

`--allow-claimed` proceeds past a fresh foreign claim **and says so** on stderr.

It is only ever an explicit per-issue, per-session instruction from the user in chat ("start it anyway") — never a config default, never inferred from context, never carried forward to the next issue. The same shape as the authorship override in `.claude/rules/safety.md`. The flag is valid only with `--claim`; other modes reject it with a usage error. An override of a fresh foreign claim does not resolve unreadable ownership.

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

Running `--check` per candidate over a 30-issue backlog would be ~90 API calls. `/wave` instead makes **one** `gh issue list --label in-progress --json number` call and runs the helper only for candidates in that (usually tiny) intersection. A fresh claim almost always carries the label: acquisition writes the label before the comment. A renewal whose label re-assert failed or raced a release can briefly leave a marker without it (see *Accepted residual risk*); the holder's next call re-adds it, and a direct `--check` blocks regardless.

### The owned-resumable upgrade lives outside this script (#1431)

`/pm`'s ownership sweep treats a `stale` verdict as **owned** when resumable evidence stands behind it — a parked entry, a resume marker, a handoff file, a surviving branch. A *bare* stale claim keeps the warn-and-proceed above, unchanged.

That rule is layered on top of `issue-claim.sh`, never inside it. This script answers one question from GitHub alone — who holds the claim, and is it fresh. Teaching it about local markers and handoff files would make every caller depend on local disk state to answer a question about a shared remote claim. Mechanism: `pm-ownership-sweep.md`.

Adoption, when the sweep finds a dead owner, reuses the **existing** stale-takeover path (`--claim` re-stamping a stale claim). A *fresh* foreign claim is never adopted: taking it needs `--allow-claimed`, which stays a user instruction and is never inferred.

### Release is best-effort at merge time

`/wrap` and `admin-merge.sh` use `post-merge-bookkeeping.sh` after a confirmed merge. It captures the linked issue markers before recording pickup evidence, then tries the guarded releases. An unreadable or unproven marker is retained with a warning. Cleanup failures do not undo the completed merge; inspect current ownership before retrying.

## Relationship to neighbouring issues

- **#756** serializes *different* issues that share a file. This covers the *same* issue picked twice; no overlap filter addresses that.
- **#636** — `/wave`'s launch-time filtering, whose dedup this strengthens.
- **#732** — authorship scope. A collaborator's claim is context, never something to overwrite.
- The same-machine `git worktree list` guard in `/start-issue` stays as a backstop. It only covers one entry path, on one machine, and only after the worktree stage — it is not a substitute for a claim other threads can see.


## Observed-claim cleanup after merge (issue #2019)

`--check --json` includes `claim_comment_id`: the exact winning comment ID observed by that read, or null when no readable marker ID exists. Other modes leave this receipt field null. A delayed cleanup can pass `--release --expect-claim-id ID` (or `none` for an observed absence). This opt-in precondition is release-only; invalid usage exits 2. A changed winning identity exits 5 without releasing anything. Post-merge cleanup additionally requires a marker timestamp strictly before the verified merge timestamp, so replay cannot adopt post-merge or same-second ambiguous work. No-marker receipts retain the absence precondition. Capture every linked issue before waiting on another operation; an unreadable ownership receipt is a reason to skip cleanup, never permission to release the current account's newer claim.

The default account-owned release remains unchanged. An expected-ID release deletes only the account-owned comment IDs in its initial read, then checks for remaining markers before removing metadata. If another marker is observed, or that verification fails, it retains the label/assignee index and reports incomplete cleanup. This uses the existing claim/metadata ordering and retains the documented residual metadata race above; it does not provide an atomic issue-state close.
