# Fix PR workflow history

On-demand history and rationale for the [/fixpr workflow](../skills/fixpr/SKILL.md).
Line numbers refer to the source at `93d75e2b4d7ee63db36f994130bbd877dd0c1f1c`.
The original lines are quoted with their surrounding wording where a line also contained an instruction.

## Source lines 57–59

````text
CodeRabbit caps **~8 GitHub PR reviews per hour** per account; **each push** consumes one. **Multi-round PRs** exhaust that budget fast if you fix-and-push repeatedly.

**Coalesce locally first:** Before opening `/fixpr` on minor iterations, run the dual-CLI local review (**`"$LOCAL_REVIEW_SH" --tool coderabbit --scope uncommitted`** + **`--tool codeant --scope uncommitted`**) per `cr-local-review.md` on uncommitted changes when feasible — catch issues **before** they cost a GitHub review. The wrapper returns one compact line per CLI; the raw capture stays at its `log_path`.
````

## Source lines 65

````text
> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read bounded `jq` projections of the cached JSON bundle; select specific finding IDs/bodies only for diagnosis or replies. Inline `gh api` calls for these three endpoints are permitted only inside `reviewer-activity.sh` and `fixpr-reviewer-triggers.sh` (Step 3b delegates), which need a custom post-push timestamp filter, and Step 5d's projected all-author invitation check: `pr-state.sh` keeps reviewer-bot comments, so it cannot detect a human's paid-review invitation. Every other polling or review-state lookup MUST go through `pr-state.sh`.
````

## Source lines 67–68

````text
All mechanical GitHub API work — pagination, GraphQL queries, comment classification — lives in the shared `pr-state.sh` script. This file tells the AI layer how to invoke the script and what to do with its output (the JSON bundle).

````

## Source lines 71

````text
| 0a. Resolve target PR (arg or infer) | Judgment + Mechanical | AI thread scan + `pr-state.sh --infer-candidates` (no-arg inference, issue #447) |
````

## Source lines 77

````text
| 3b. Trigger missing AI reviewers | Mechanical | wait 2 minutes, then `fixpr-reviewer-triggers.sh` on the pushed SHA: no review policy → post triggers for missing free bots, `@cursor review` only by spending an owner grant for that SHA (paid — #1897, #1898); tier-aware repo → only what `review-triggers-allowed.sh` allows (#1749) |
````

## Source lines 79–80

````text
| 4c. Post-push thread verify (if Step 3 pushed) | Mechanical | Re-fetch threads on new HEAD; explicitly resolve any touched thread still `isResolved: false` (fixes unchanged-line orphans), then `--verify-only` |
| 4d. Review-wait loop (issue #454) | Mechanical | Poll `pr-state.sh` on the pushed SHA every 30–60s, capped at 20 min; early-exit on full bot+CI verdict; new findings → next sweep |
````

## Source lines 87

````text
**Environment knobs (issue #454):**
````

## Source lines 91

````text
| `FIXPR_WAIT_CAP_SECS` | `1200` | Hard cap per wait iteration (20 min = P93 of bot-response times from a 30-PR sample) |
````

## Source lines 93

````text
| `FIXPR_MAX_ITERATIONS` | `5` | Outer cap on fix-sweep + wait iterations (matches `/wrap` recovery cap, issue #452) |
````

## Source lines 136

````text
`/fixpr` may be invoked **with** a PR (`/fixpr <url>` or `/fixpr <N>`) or **with no argument**. Resolve the target into `$PR_NUMBER_ARG` *before* calling `pr-state.sh`, so a no-argument re-run is a fast convenience instead of a dead end (issue #447). The session-state half of this inference is shared verbatim with `/wrap` (issue #448) via `pr-state.sh --infer-candidates` — do not re-implement it.
````

## Source lines 157

````text
- **Thread scan (AI layer).** Read back through *this* conversation for the most recent `/fixpr <url-or-number>` and `/wrap <url-or-number>` invocations and any PR the thread just operated on (pushed to, audited). Extract PR numbers from the `pull/<N>` pattern. Record them **in order, most-recently-mentioned first** — thread recency is the strongest signal (the issue's motivating case: a `/fixpr <url>` ran moments ago, then a bare `/fixpr`).
````

## Source lines 167

````text
(`--infer-candidates` is a pure read of `~/.claude/session-state.json`; a global `pr-state.sh` too old to know the flag exits non-zero and the `|| echo "[]"` fallback degrades gracefully to thread-only inference.)
````

## Source lines 175–176

````text
| **Genuinely ambiguous** (two+ tied on recency, e.g. two thread PRs mentioned equally recently or session candidates tied on `last_action_at`) | Do **not** guess. Print `[CONTEXT] No PR argument and no branch PR; multiple candidates:` followed by the candidate list with sources, and ask the user which PR they meant — same behavior as before #447. Leave `PR_NUMBER_ARG` empty. |
| **No candidates at all** | Leave `PR_NUMBER_ARG` empty and fall through to branch auto-detection below — `pr-state.sh` with no `--pr` either finds the branch's PR or exits `3`/`4` and you report it (unchanged pre-#447 behavior). |
````

## Source lines 178

````text
`[INFERRED]` log formats (print exactly one, before the `[CONTEXT]`/audit output below — it is the user's only catch point for a misfire):
````

## Source lines 192

````text
> **Authorship guard (issue #733, `safety.md`) — gate before Step 0c.** `/fixpr` pushes commits, force-pushes rebases, posts review triggers, and resolves threads — all writes. Once `$PR_NUMBER_ARG` is resolved, confirm you authored it:
````

## Source lines 200

````text
Run the shared pre-flight **before** the audit so the PR is out of draft and each conditionally-triggered reviewer (CodeAnt, CodeRabbit, Cursor) gets a recorded per-reviewer status on the current SHA — engaged (already present or triggered), skipped (excluded by the PR's review tier — on `ci-only`, all three — tier-deferred, rate-capped, or awaiting owner approval for BugBot), or trigger-failed — before any finding-classification work begins. This is the same `pr-preflight.sh` invoked by `/babysit-pr` and `/pr-monitor-and-manage`, so the behavior is identical across all three skills — do **not** re-implement the draft flip or trigger logic inline.
````

## Source lines 226

````text
`pr-preflight.sh` is idempotent and rate-cap safe: it marks the PR ready only when **you** authored it, never overrides someone else's intentional draft, never triggers Greptile, posts `@cursor review` only by spending an owner grant for HEAD (paid — #1897, #1898), and skips `@coderabbitai full review` (still posting the other free reviewers) when `cr-review-hourly.sh` reports the cap hit. On a PR that is already ready with every reviewer already engaged **on the current HEAD SHA** or skipped (BugBot without owner approval and no grant, a tier-excluded reviewer) it prints `Pre-flight clean — proceeding` and does nothing — so a clean pre-flight does **not** mean any reviewer was engaged (on `ci-only`, none is). Since #576 engagement is judged against HEAD rather than PR-wide history, a reviewer whose only artifact is on a superseded commit — the normal state after `/fixpr`'s own rebase + force-push — is re-triggered instead of being counted as present. Keep `$PREFLIGHT_SUMMARY_JSON` for the Step 7 "Pre-flight" line.
````

## Source lines 240

````text
If `pr-state.sh` itself exits non-zero it prints the reason to stderr (no PR, closed PR, detached HEAD, etc.). Stop and report. Exit codes: `0` OK, `2` usage error, `3` no branch and no `--pr`, `4` PR closed/not found, `5` gh/network error. With Step 0a in place, exit `3` (no branch and no `--pr`) only reaches you when inference also found **no** candidate — that is the genuine "which PR did you mean?" case.
````

## Source lines 248–257

````text
# Combined form for handoff scoping. Step 3a's path resolution reads
# ${OWNER_REPO:-}; leaving it unset skips handoff-state.sh entirely and takes
# Step 3a's own hard-coded literal flat path, which the phase agents never read
# back (issue #1302) — that is this skill's last-ditch fallback, not a helper
# fall-through. Since issue #1366 the helper resolves an omitted --owner-repo
# from $CLAUDE_SESSION_REPO, then the cwd's `origin`, and when neither yields an
# owner/repo it "exits 2 having written nothing.  It does NOT fall back to the
# flat path" (handoff-state.sh header) — reaching that path through the helper
# takes an explicit --legacy-flat. Set OWNER_REPO here so both branches stay
# scoped.
````

## Source lines 292

````text
Do not ask the user before deciding. GitHub is the audit surface and chat is the decision surface: every thread touched by `/fixpr` must end resolved on GitHub, whether the decision was fix or decline.
````

## Source lines 393

````text
Only run when Step 3 made a push (`DID_PUSH=1`). Runs **after** `git push` and **before** Step 3b (reviewer triggers) so GitHub does not keep `reviewDecision: CHANGES_REQUESTED` from an obsolete bot review on an older commit.
````

## Source lines 413–420

````text
# Resolve the canonical handoff path (issue #655: scoped per repo when owner_repo is known).
# OWNER_REPO is set in Step 0b from the pr-state.sh bundle; the `gh repo view
# --json nameWithOwner` form works too for a standalone invocation.
# With --owner-repo: ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json
# The literal flat path below is only a fallback for when handoff-state.sh cannot
# be resolved at all — it is NOT what omitting --owner-repo does. Since issue
# #1366 an omitted scope derives owner/repo from the cwd, or exits 2 writing
# nothing; reaching the flat path through the helper needs --legacy-flat.
````

## Source lines 434–442

````text
      # --owner-repo scopes the handoff append to the same file --handoff-file
      # names. Step 0b sets OWNER_REPO on every /fixpr run, so this is the
      # branch taken here. Without the flag dismiss-stale-bot-changes.sh
      # "[d]efaults to the `gh repo view` value" (its own header), which for a
      # /fixpr worktree need not match the PR being dismissed — so the IDs can
      # land in a different repo's scoped file, the split-brain that issue #1302
      # is about. Omission does not reach the flat path: that branch fires only
      # when --handoff-file already IS the flat path, and declares itself
      # --legacy-flat (issue #1366).
````

## Source lines 457

````text
The script only dismisses **`CHANGES_REQUESTED`** reviews where **`commit_id` ≠ current PR HEAD** and the author is a **Bot** on the literal allowlist (`coderabbitai[bot]`, `cursor[bot]`, `greptile-apps[bot]`, `codeant-ai[bot]`, plus the retired `graphite-app[bot]` so a leftover review still clears). Human reviews are never dismissed. Logged lines look like `[DISMISS-STALE] dismissed stale bot CHANGES_REQUESTED review_id=…`.
````

## Source lines 465

````text
Use the `$PUSHED_AT` captured immediately before `git push` in Step 3. Capturing it before the push avoids a race where a fast bot starts between push completion and the timestamp capture. After the push completes, wait exactly 2 minutes before checking reviewer status so CodeRabbit / CodeAnt auto-triggers have time to post activity (BugBot is covered separately — post `@cursor review` once per push, but not again on a HEAD it has already refused for spend; see `bugbot.md` and memory `feedback_bugbot_auto_trigger_unreliable.md`):
````

## Source lines 473

````text
Then run the extracted trigger script once, with the SHA you just pushed (issue #1749 — it was inline bash here, which no test could run against a fixture policy). It detects which reviewers already auto-triggered on the pushed SHA (`reviewer-activity.sh`) and posts one dedicated PR-level comment per missing reviewer — never batched; combined-mention comments fail to trigger reliably:
````

## Source lines 492–493

````text
- **No `## Review policy` (`legacy`)** — the pre-#1749 Step 3b, unchanged: `@coderabbitai full review` for a missing CodeRabbit unless 2 were posted on the PR in the trailing hour (a successful post records the slot via `cr-review-hourly.sh --record-explicit`), then `@codeant-ai review`, each only when missing on the pushed SHA, then BugBot — posted **only** by spending an owner grant for the pushed SHA through `paid-review-grant.sh --trigger` (#1898); otherwise the step prints `BugBot not invited — paid review requires owner approval` (issue #1897: paid, owner approval only). The earlier BugBot skips still apply first and keep their wording: when `bugbot-tier-excluded.sh` excludes it, then when `bugbot-refused-head.sh` says BugBot already refused the pushed SHA, then — **last** — when the account daily cap (`review-daily-cap.sh`, #1812) answers a validated `over`; that skip appends `BugBot skipped: daily cap ($X of $Y today)` once per HEAD under the PR body's `## Review notes`.
- **A tier-aware repo** — only what `review-triggers-allowed.sh` allows on the pushed SHA: CodeAnt once per PR, BugBot only by spending an owner grant at its `approval_required` step (#1897, #1898), CodeRabbit only as the CodeAnt-unavailable fallback. Each post is claimed first and released if it fails; the BugBot refusal and daily-cap guards run inside the helper, and a daily-cap skip still writes the PR-body note. CI is usually still running two minutes after a push, so this step often posts **nothing** on such a repo — expected: `pr-preflight.sh` (Step 0c, every `/babysit-pr` and `/pr-monitor-and-manage` tick) and `maybe-trigger-ai-review.sh` ask again once CI is green.
````

## Source lines 495

````text
Cost/rate-limit note: `@codeant-ai review` may consume CodeAnt’s review budget, so it is skipped when auto-trigger activity is already present on the new SHA. BugBot is per-seat but **spend-metered** — the stack's largest cost line, refusing 64% of PRs (#1199/#1204) — and no nudge clears a usage limit; it auto-runs on push, so a refusal can land before this step even executes, which is why the refusal check is asked about `$PUSHED_SHA`. Greptile is intentionally NOT part of this proactive trigger set; it remains last-resort only per `greptile.md`.
````

## Source lines 497

````text
**Composition with issue #362:** `cr-github-review.md` runs `maybe-trigger-ai-review.sh` on each poll tick when there is **no** `/fixpr` trigger (no new findings, CI green, not `BEHIND`/`CONFLICTING`). That path fires single-mention comments — `@codeant-ai review`, `@cursor review` — for **complexity + CR round count**, not because of a push, and asks the same review-tier helper on a tier-aware repo. This differs from Step 3b, which additionally posts `@coderabbitai full review` (subject to the 2/hour cap) when CodeRabbit has not yet auto-triggered on the new SHA. State for the #362 path is tracked in `session-state.json` so it does not batch with Step 3b on the same cause.
````

## Source lines 533

````text
**`--verdict` and `--defect` are mandatory on every reply** — they stamp the hidden `<!-- review-verdict: … -->` marker the review-cost ledger reads, and only the marker can record `defect=real`. Set them per entry: **fix** and **already-fixed** → `--verdict fixed`; **decline-high-confidence**, **surface-low-confidence**, and **outdated** → `--verdict declined` (usually `--defect not`); a finding deferred to a follow-up issue → `--verdict deferred`. `--defect real` only when the finding named a behaviour the code would actually have gotten wrong; `--defect not` for style, duplication, or a reviewer misreading. `--fix` is required with `--defect real` (issue #1843): `as-given` (suggestion applied as proposed), `adapted` (right direction, code rewritten), `wrong` (proposed fix incorrect), `none` (no fix suggested). Set `$FIX` on every entry (it is ignored unless `--defect real`). Leave `--agent` at its default. Rationale and the mandate's landing date: `.claude/reference/review-stack-audit.md` §The marker.
````

## Source lines 535

````text
The script strips any `@greptileai` tokens from the body in greptile mode and any `@cursor` tokens in bugbot mode — so even a stray mention in `$REPLY` cannot trigger a paid Greptile re-review ($0.50–$1.00). `@greptileai` is reserved exclusively for intentionally requesting a new review. See `reply-thread.sh --help` for the full exit-code contract.
````

## Source lines 553

````text
**Unchanged-line threads:** GitHub only auto-resolves a review thread when the **exact** commented line changes. If `/fixpr` fixed the issue by editing nearby code (or declined/OBE), the thread can stay `isResolved: false` after Step 4b until the script runs `resolveReviewThread` / `minimizeComment` on that thread id. The explicit `--thread-ids-file` set forces resolution for **every** addressed thread, not only those GitHub auto-closed.
````

## Source lines 555

````text
The script re-fetches `pullRequest.reviewThreads` via GraphQL after each mutation pass and again before exit. For any touched thread still reporting `isResolved: false`, it retries `resolveReviewThread` and falls back to `minimizeComment(classifier: RESOLVED)`. Exit codes: `0` means every touched thread was verified resolved; `1` means at least one dangling thread remains and `/fixpr` must not declare success; `3` PR not found; `4` gh error. It prints `[VERIFY] addressed=N resolved=M dangling=K` plus `[STUCK]` lines with URLs/reasons for every dangling thread.
````

## Source lines 561

````text
Run **only when Step 3 pushed** (`DID_PUSH=1`). A new commit can reopen threads that were resolved on the prior HEAD (or leave unchanged-line threads still open until an explicit resolve sees the post-push graph).
````

## Source lines 596

````text
- `DID_PUSH=0` (idempotent path) → run **one** snapshot tick first on the current HEAD (`WATCH_SHA=$HEAD_SHA`, `WAIT_BASELINE=$RUN_STARTED_AT`) using the same `pr-state.sh` + jq predicate as the loop below, **without incrementing `FIXPR_WAIT_ITER`**. If `bots_pending`, `ci_pending`, and `ci_failing` are all empty and `new_findings == 0`, set `FIXPR_WAIT_FINAL=clean` and **skip the wait loop entirely — zero wait, zero iterations, no push** — proceed to Step 5. If bots or CI are still pending on the current SHA (e.g. `/wrap` delegated here mid-review), fall through to the wait loop (which increments `FIXPR_WAIT_ITER` once at entry).
````

## Source lines 598

````text
**Per-tick snapshot — reuse `pr-state.sh`, do not re-invent endpoint polling.** Set `WATCH_SHA` / `WAIT_BASELINE` from the entry path above (`PUSHED_SHA`/`PUSHED_AT` when `DID_PUSH=1`, else `HEAD_SHA`/`RUN_STARTED_AT`). Each tick fetches one fresh bundle (all 3 comment endpoints + check-runs + commit statuses, `per_page=100`, classification since baseline — the same primitives as `cr-github-review.md`):
````

## Source lines 683

````text
**Running this block as a worktree-isolated subagent.** The block above is a multi-line loop, which the harness's worktree-isolation guard refuses when pasted directly — it classifies by command shape, and the refusal names git operations that are not in it (issue #1470). Write the block to a file in the session scratchpad and run `bash <file>`: a single plain call is an allowed shape, and everything inside it then runs in a child process the guard does not gate.
````

## Source lines 685

````text
**Include the persistence helper in the child file.** Copy the **entire** `fixpr-persist-wait-evidence` loader block (it sources the canonical wait functions) into that same file before the pre-check/loop, and pass `HANDOFF_STATE_SH` plus the verified `OWNER_REPO` alongside the inputs below. Neither a parent-shell function nor unexported helper/scope variables exist in `bash <file>`. Keep `WAIT_BASELINE` and the entry-path inputs (`DID_PUSH`, `HEAD_SHA`, `PUSHED_SHA`, `PUSHED_AT`) available there too; the snapshots assign `TICK` and `WAIT_STATE` inside the child. Missing helper/scope or failed evidence writes must stop, never fabricate a clean wait.
````

## Source lines 687

````text
**`bash <file>` is a FRESH shell — it inherits nothing you set in earlier steps.** `PR_NUMBER`, `WATCH_SHA`, `SCRIPT`, `RUN_STARTED_AT`, `FIXPR_WAIT_ITER`, `FIXPR_MAX_ITERATIONS`, `FIXPR_WAIT_CAP_SECS`, `FIXPR_WAIT_POLL_SECS` and `FIXPR_TOTAL_WAIT_SECS` are plain shell variables, so every one of them arrives empty. Under `set -u` that aborts; without it the loop watches an empty PR, compares against an empty cap, and reports a verdict it never measured. So write their current values into the top of the file (or pass them on the command line as `PR_NUMBER=… WATCH_SHA=… bash <file>`) — and read the outcome back out of the child, which cannot assign your variables: have the file print `WAIT_OUTCOME` and `ELAPSED` on its last line and capture that, rather than expecting the assignments above to survive. That includes the accumulator: `FIXPR_TOTAL_WAIT_SECS=$((FIXPR_TOTAL_WAIT_SECS + ELAPSED))` runs in the child and is discarded with it, so the CALLER must re-apply it to the `ELAPSED` it captured — otherwise every summary that quotes total wait under-reports it by exactly the time this loop spent.
````

## Source lines 689

````text
Do **not** try to flatten this onto `wait-until.sh` — that wrapper answers met/not-met, while this loop is a five-way classifier (`clean` / `new-findings` / `ci-failing` / `head-moved` / `cap-exhausted`) whose outcome routes the rest of the skill. Catalog of refused vs allowed shapes: `.claude/reference/worktree-isolation-command-shapes.md`.
````

## Source lines 700

````text
| `new-findings`, `ci-failing`, or `head-moved` | If `FIXPR_WAIT_ITER < FIXPR_MAX_ITERATIONS` → start the **next sweep at Step 0** (fresh `$RUN_STARTED_AT` picks up the new findings; the sweep fixes, pushes once, and re-enters this wait on the new SHA). Else at outer cap, set `FIXPR_WAIT_FINAL` and Status **per outcome** — do not blanket-label everything `new-findings-pending`: `new-findings` → `FIXPR_WAIT_FINAL=new-findings-pending`, Status `NEW_FINDINGS`; `ci-failing` → `FIXPR_WAIT_FINAL=cap-exhausted`, Status `CI_FAILING`; `head-moved` → `FIXPR_WAIT_FINAL=cap-exhausted`, Status note external push in summary (re-run `/fixpr`). |
````

## Source lines 717

````text
The Step 4b resolver (and, when `DID_PUSH=1`, Step 4c’s resolve + `--verify-only` passes) re-fetched `pullRequest.reviewThreads` via GraphQL, retried `resolveReviewThread`, used `minimizeComment(classifier: RESOLVED)` as fallback, and printed addressed/resolved/dangling counts. Re-state the **latest** `[VERIFY]` line(s) here from `THREAD_RESOLUTION_OUTPUT` plus `POST_PUSH_THREAD_OUTPUT` / `POST_PUSH_VERIFY_OUTPUT` when Step 4c ran; do not recompute from `.threads.unresolved_count` alone because `/fixpr` must verify the specific threads it replied to.
````

## Source lines 740

````text
**Classification rules** live in `.claude/scripts/lib/pr-state-classify.jq` (the block comment above `def classify:` is the authoritative contract — do NOT duplicate it here). `pr-state.sh --since` supplies the endpoint arrays and timestamp bindings, then exposes the result through the unchanged `new_since_baseline` bundle fields. Key ordering invariants: tier-1 explicit-resolution overrides (addressed/withdrawn markers, zero-actionable phrases, rate-limit notices, BugBot usage-limit notices, full-review-triggered ack, clean-pass phrases, error stub, auto-reply ack) are checked first and win even if finding language appears in quoted context. Finding patterns (severity, badges, actionable phrases, suggestion blocks) come next. Weak-ack fallbacks (lgtm variants) follow. The CR walkthrough summary override, Greptile clean-pass summary and CodeAnt's prose-only boilerplate (#1748) come LAST — their late placement is load-bearing (a walkthrough can carry N>0 finding count; hoisting it would produce false-clean verdicts). Default → finding (under-classifying is the failure mode).
````

## Source lines 742

````text
**If `finding_count > 0`:** findings landed between the Step 4d wait exit and this verify. If `FIXPR_WAIT_ITER < FIXPR_MAX_ITERATIONS`, start the next sweep at Step 0 (a fresh `$RUN_STARTED_AT` re-audits and picks them up). At the outer cap: set `FIXPR_WAIT_FINAL=new-findings-pending`, emit `NEW_FINDINGS` in Step 7, and stop — re-running `/fixpr` resets the iteration budget.
````

## Source lines 795

````text
CR and Greptile report review completion via commit *statuses*, while CodeAnt and Cursor may report via check-runs. `pending` means a bot is still analyzing the current HEAD — declaring CLEAN while pending is the exact failure mode this verify step was built to prevent.
````

## Source lines 805

````text
- **CodeRabbit specifically** (by status `context` / bot name) with `description` containing "rate limit" (case-insensitive) → CR rate-limited, fall back to Greptile per `cr-github-review.md`. CodeRabbit reports this as non-blocking `state: "success"` — check this **before** the `state: success` clean-pass rule below, not just on `failure`/`error`. Other bots are not subject to this rule — a Greptile or other status whose text happens to contain "rate limit" is not CR rate-limiting and falls through to the rules below.
````

## Source lines 808–809

````text
- No activity from CodeRabbit, CodeAnt, or Cursor after a pushed fix commit → the Step 3b trigger check should already have posted the reviewer-specific comment (on a tier-aware repo, only once CI is green and the tier allows it). Emit `REVIEW_PENDING` and re-run `/fixpr` after the reviewer responds. Exception: a CodeRabbit or CodeAnt that Step 3b logged as `skipping … — review tier …` (kind `excluded`) was never invited, so its silence is not `REVIEW_PENDING`; only a `deferring …` one is still awaited.
- **BugBot silence** (#1953): await `REVIEW_PENDING` only for a verified current-HEAD invitation or unused matching owner grant. Step 3b deferral or a daily-cap skip alone is not an invitation. Require the portable `bugbot-invitation.sh` reader; missing tooling or unknown/unreadable evidence remains awaited. On no-push reruns, ignore inherited `PUSHED_AT`/`PUSHED_SHA` and retain qualifying invitations posted before the rerun. Keep `BUGBOT_INVITATION_RESULT` and its `evidence_path` in Step 5 recovery evidence, never as future authorization. The reader only reads/checks grants; it never triggers or consumes. Window, bounds and diagnostic details: `bugbot-invitation.sh --help`.
````

## Source lines 852

````text
A conflict resolution with no markers still satisfies git even when it silently kept the other side and dropped the entire change the PR exists to deliver. Nothing else in this workflow catches that: status is clean, CI is green, review sees a PR that no longer contains its own fix. Wrap **every** rebase below — interactive and safe-only alike — in this pair:
````

## Source lines 869–871

````text
- **`2`** — named files lost their changes. **Do not force-push, do not trigger reviewers, do not run Step 3a/3b/4d.** Report the named files and return `Status: CONFLICTS` / `FIXPR_WRAP_STATUS: CONFLICTS` — a vaporized diff is an *unresolved* conflict, not a push.
- **`4`** — unresolved conflicts remain, the snapshot is for another branch, or verdict `unverifiable`. On `unverifiable` the snapshot's baseline commit *is* the commit being checked, so the comparison proves nothing: **do not force-push** — report the resolution as UNVERIFIED and treat it as unresolved.
- **`5`** — no snapshot exists (the rebase was started by an earlier session). Run `"$GUARD" snapshot --if-absent`, then `verify`. **This only reconstructs a real baseline while the rebase is still in progress** — mid-rebase the guard reads the rebase's `orig-head` rather than the half-replayed HEAD. If the rebase has **already finished**, no baseline can be reconstructed after the fact: `verify` returns `unverifiable` (exit 4) rather than a false pass. Do not push on that verdict — say the resolution could not be verified and let a human decide.
````

## Source lines 873

````text
The guard **never repairs anything**; recovery (`git rebase --abort`, or resetting to `ORIG_HEAD`) stays a deliberate human step. In **safe-only mode** (`BABYSIT_SAFE_CONFLICT_MODE=1`) a non-zero verify is surfaced upstream exactly like a complex hunk — emit the `CONFLICT_COMPLEX_REPORT_JSON:` line (use the guard's `--json` object as the value) plus `FIXPR_WRAP_STATUS: CONFLICTS`, so `/babysit-pr` T4 terminates `hard-blocked` with the lost-file report instead of counting a vaporized push as forward progress. Full contract: `.claude/reference/diff-survival-guard.md`.
````

## Source lines 879

````text
| `mergeStateStatus` | `BEHIND` | **First run `"$CLEAN_BEHIND_SH" "$PR_NUMBER"` (issues #631, #667).** Exit 0 (`safe_to_offer`: gate green except BEHIND, not CONFLICTING, AC verified, no touching or overlapping changed lines between the base delta and the PR — rules: the `clean-behind-check.sh` header) → **stop looping rebases and run `"$ADMIN_MERGE_SH" "$PR_NUMBER" --auto-plain --ac-verified`** (issue #754) — but **only after completing `cr-merge-gate.md` Step 2** (verify every Test Plan checkbox against the source at this SHA; ticked boxes are the proxy `clean-behind-check.sh` already checked, not verification). Any criterion that fails → fix it, do not merge; the script refuses without `--ac-verified`. Exit 0 → merged; relay its `AUTO_PLAIN_MERGED` evidence block. **No `AskUserQuestion`** — the plain shape modifies no branch protection, so it needs no user turn. Exit 8 → the shape needs a protection change (or an auto attempt already ran): **offer `/admin-merge` as a user choice** (AskUserQuestion, or print the command when running non-interactively) and **never auto-run** it. Exit 1 → not safe after re-validation (e.g. main advanced); fall through to the rebase path below. The `churn.advisory` field is context, not a gate (sensitivity configurable via `--churn-threshold N` or `CHURN_THRESHOLD` env var, default 1). Exit 1 (not safe — especially a base-delta↔PR-file overlap, or any residual blocker) → **capture the Step 6a snapshot (`diff-survival-check.sh snapshot`), then** rebase onto main: `git fetch origin main && git rebase origin/main`. If conflicts arise mid-rebase (replaying commits individually can conflict even when a three-way merge wouldn't), resolve them the same way as `CONFLICTING` above (including optional **`/merge-conflict`**), then `git rebase --continue`. **Run the Step 6a `verify` gate; force-push only on `GUARD_RC == 0`** — a non-zero verdict blocks the push and returns `Status: CONFLICTS`. When `FIXPR_WAIT_ITER < FIXPR_MAX_ITERATIONS`, treat the force-push as push-equivalent: set `PUSHED_SHA=$(git rev-parse HEAD)`, `PUSHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")`, `DID_PUSH=1`, run **Step 3a** (dismiss stale bot reviews), **Step 3b** (reviewer triggers + 120s wait), then **Step 4d** on the new SHA. Do **not** jump straight to Step 4d without 3a/3b — bots are never kicked on the rebased SHA otherwise. |
````

## Source lines 914

````text
Render the **Pre-flight** line from the per-reviewer `.status` values in `$PREFLIGHT_SUMMARY_JSON` (Step 0c), never from `.clean` alone, which is also true when the review tier excluded every reviewer (issue #1839). Print `$PREFLIGHT_LINE` verbatim:
````

## Source lines 918–921

````text
# Head: "clean — already ready" or the draft action. Then "all N reviewers
# engaged" only when every reviewer is already-present; otherwise "K of N
# reviewers engaged" plus each other status naming its reviewers, e.g.
# "clean — already ready, 0 of 3 reviewers engaged; review tier excludes codeant, coderabbit, cursor".
````

## Source lines 961

````text
Legacy repos (no `## Review policy`) never produce `skipped-tier-excluded`, so a fully engaged legacy PR still reads `all N reviewers engaged`. N is counted from the summary (three since Graphite's retirement), never a literal.
````

## Source lines 963

````text
`/wrap` recovery may delegate here; parents grep **`FIXPR_WRAP_STATUS:`** and **`FIXPR_WAIT_SUMMARY:`** (and echo **`Status:`**) into heartbeats without re-parsing prose. `FIXPR_WAIT_SUMMARY` is the issue #454 contract: `/wrap` trusts this verdict — the bots and CI were already waited on here, so `/wrap` re-runs `merge-gate.sh` immediately with no polling of its own. `final=clean` when the last wait exited on a full bot+CI verdict (or the idempotent no-push path was already clean — `iterations=0`); `final=cap-exhausted` when the last wait hit `FIXPR_WAIT_CAP_SECS`; `final=new-findings-pending` when the outer iteration cap exhausted with findings still arriving.
````
