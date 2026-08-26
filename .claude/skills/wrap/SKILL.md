---
name: wrap
description: End-of-session command — verify no unresolved findings, squash merge, sync main, detect per-PR follow-ups, run a full-session loose-ends sweep, and extract lessons. Nearly silent by default — a clean merge emits one line (`merged PR #N`) plus any items needing your decision; pass `--verbose` (or just ask) for the merged + follow-ups summary and the full per-phase report. Accepts an optional PR reference (`/wrap <URL>`, `/wrap #N`, `/wrap N`); with no argument it infers the PR from the current branch, then thread context, then session-state.
argument-hint: "[URL | #N | N] [--verbose]"
---

Wrap up the current PR and session. This is the "we're done here" command that handles final verification through merge, root-main sync, follow-up detection, a full-session sweep for loose ends, and lessons.

`/wrap` accepts an **optional** PR reference as its argument — a full URL, `#N`, `owner/repo#N`, or a bare number `N`. When invoked with no argument it resolves the target PR through the inference cascade in Step 1.1 (current branch → thread context → session-state). An explicit argument bypasses all inference.

`/wrap` does **not** delete the running worktree or its branch — leaving the thread alive so it can keep working. Stale worktrees and stale local/remote branches are reaped out-of-band by `/pm-update`, which calls `stale-cleanup.sh`.

## When to use /wrap vs /merge

- Use **/wrap** at end-of-session. Handles merge + root-main sync + follow-up detection + lessons.
- Use **/merge** for a quick mid-session merge when you'll keep working. Skips follow-up detection and lessons.
- /wrap includes everything /merge does, plus follow-ups and lessons. Don't run both.
- Phase C invokes this skill after gate and AC verification; keep merge, main-sync, follow-up, and cleanup behavior here so Phase C and `/wrap` cannot drift.
- **Target PR:** `/wrap` operates on the PR resolved in Step 1.1. Pass an explicit reference (`/wrap <URL>`, `/wrap #N`, `/wrap N`) to wrap a PR that is **not** on the current branch — common in orchestration threads that ran `/fixpr <URL>` against another worktree. With no argument, Step 1.1's cascade infers the PR.
- **Callers of the `/wrap #N` form:** Phase C (`phase-c-merger`), `/pr-monitor-and-manage` (merge-ready fleet PRs), and **`/pm`'s one-shot forgotten-PR triage** (issue #657) all merge an already-open PR by dispatching this workflow rather than reimplementing merge logic — the merge gate, AC verification, and squash-merge live here so every caller stays consistent.

## Execution Model

`/wrap` is a set-and-forget command. Once invoked, it runs all 4 phases end-to-end without mid-run confirmation prompts. It stops early only for explicit stop conditions (for example: no PR on current branch, **human** change requests on HEAD, recovery iteration cap, failed merge gate after recovery, **`/fixpr` delegation failure**, AC verification failure).

> **Always:** Execute all phases end-to-end; proceed immediately between phases when no blocker exists.
> **Ask first:** Never — all phases are autonomous once /wrap is invoked.
> **Never:** Stop to ask "should I continue?" between phases; insert confirmation prompts for non-blocker transitions. Delete the running worktree or its branch — that's `/pm-update`'s job, not /wrap's. Modify branch protection — suggest `/admin-merge` for any enforcement_admins bypass; `admin-merge.sh --auto-plain` (no protection change) runs automatically per #754.

### Follow-up filing is autonomous (issue #633)

Both Phase 3 passes — **Part A** (per-PR follow-ups) and **Part B** (full-session sweep) — file every novel candidate as a GitHub issue **without asking**. There is no opt-out flag and no "file as new issue?" prompt anywhere in this skill. The deal is two-sided: filing is unconditional, and **every** filed issue is durably **recorded** — the GitHub issue itself, the run-scoped `WRAP_FILED_ISSUES` registry, and `session-state.json` `wrap_sweep.filed_issues` (Step 3.13). **Recording is not narrating (issue #851):** filings do *not* print on the default path. They are listed with number, title, one-line rationale, and clickable link under `--verbose` or on request, and any filing that needs a decision — a failed `gh issue create`, or one carrying a `Possibly duplicates #{N}` caveat — surfaces immediately in either mode. Retraction (`gh issue close`) is the escape hatch, not a confirmation round-trip. The norm is stated once for all skills in `.claude/rules/issue-planning.md`.

Autonomy does not mean filing blind: every candidate goes through the body-aware duplicate check in **Step 3.0** first (issue #652). That check can only ever *redirect* a filing onto an existing issue or *annotate* it — it never drops a finding, and every filing it suppresses is named in the `--verbose` report alongside the issue it deferred to.

### Wrap-Internal Phase Transitions

> These transitions are wrap's internal Phase 1–4 system, distinct from the subagent A/B/C phases in `subagent-orchestration.md` — the two naming schemes are parallel-but-separate.

| Transition | Action | Classification |
|------------|--------|----------------|
| Phase 1 complete (findings scan finished — may have flagged bot findings) | Begin Phase 2 recovery + merge | **Always do** |
| Unresolved review threads detected (Phase 1 scan) | Record `WRAP_UNRESOLVED_THREADS`; proceed to Phase 2 Branch B, which auto-invokes `/fixpr` when threads are the sole gate blocker (issue #455) | **Auto-recover** |
| Unresolved review threads only (Phase 2.1 — `merge-gate.sh` `missing` contains only `unresolved review thread(s)` entries) | Auto-invoke `/fixpr` (Branch B), then re-fetch HEAD + re-run `merge-gate.sh` | **Auto-recover** |
| Phase 2 recovery loop exits cleanly (gate met, ready to merge) | AC check → squash merge → Phase 3 | **Always do** |
| Phase 3 per-PR follow-ups + full-session sweep processed | Begin Phase 4 | **Always do** |
| Phase 4 lessons complete (or skipped as trivial) | Output final report | **Always do** |
| Human `CHANGES_REQUESTED` on current HEAD (`human_changes_requested` non-empty in `merge-gate.sh` JSON) | Stop with reviewer names — **never** auto-dismiss | **Genuine block** |
| Recovery iteration cap or non-recoverable gate failure | Stop with full audit + last `missing` | **Stop and report** |
| AC checkbox verification fails (Phase 2.2) | Stop and report | **Stop and report** |

> **Anti-pattern:** If you find yourself composing "Should I proceed?" or presenting a confirmation button, the answer is always yes — execute immediately.

> **"Threads only" defined (issue #455):** the unresolved-review-threads auto-recovery rows above apply when unresolved review threads are the **sole** blocker — i.e. no other blocker category is present (no CI failing/incomplete, no `BEHIND`/`DIRTY`/`CONFLICTING` merge state, no stale or human `CHANGES_REQUESTED`, no missing fresh bot `APPROVED`). When any of those co-occur, the broader Step 2.1 decision tree (issue #452) owns dispatch — first matching branch wins. The single-attempt / stop-on-mixed-blocker semantics from #455 are realized here as the threads-only branch of the bounded #452 loop.

## Output modes

`/wrap` is **nearly silent by default** (issue #851, #869): it runs all four phases in full, emits exactly `merged PR #N` on a clean merge, and otherwise says nothing — only items that need an explicit decision from you. Pass `--verbose`, or simply ask ("what did you just do?", "summarize"), for the merged + follow-ups summary, the per-phase narration, and the detailed final report. This implements `CLAUDE.md` #3 for this skill.

| Mode | Flag | Effect |
|------|------|--------|
| **Silent** | *(default)* | One line on a clean run: `merged PR #N` — no follow-up list, no lessons ack, no sweep summary. Only decision-requiring items print, one terse line each (Step 4.3 **Silent default**). |
| **Verbose** | `--verbose` *(or an explicit request)* | The full report: the `## Wrapped up` merged + follow-ups block, per-cycle recovery heartbeats, the Session Lessons block, and the multi-section "Wrap-Up Complete" report (Issues filed, Filings suppressed as duplicates, Session sweep, Verdict, Lessons). Full template: `references/wrap-report-templates.md`. |

**Verbosity is additive and human-facing only.** Every phase executes **identically** in both modes; only narration differs. Suppression is never deletion — the merge, the filings, the sweep, and the lessons are all recorded (GitHub, `WRAP_FILED_ISSUES`, `session-state.json` `wrap_sweep`, memory), so an explicit request re-renders the verbose report in full from that state. Four things always print regardless of mode:

- **State-changing blockers and stop conditions** — a merge that can't proceed, `CONFLICTING`, human `CHANGES_REQUESTED`, no PR found, the recovery cap — surface as a short one-line reason even on the silent default (Step 4.3 **Blocker path**).
- **The `[INFERRED]` merge-safety checkpoint** (Step 1.1). Prints only on the inference path, never on the normal branch path.
- **The CLAUDE.md 5-minute heartbeat** during long `/fixpr` waits. Silence never extends past the heartbeat — that is what keeps a suppressed run distinguishable from a stalled one (issue #803).
- **`[COVERAGE]` when local review was degraded** (`cr-only`, `codeant-only`, or `none`). Full coverage (`both`) is suppressible.

When `/wrap` is invoked by a phase-C subagent, the machine **`EXIT_REPORT`** block (per `phase-protocols.md`) is emitted **identically regardless of verbosity**.

## Preamble: shared helpers

Define once, use throughout all phases. The `resolve_script()` function finds the first executable candidate across the three standard install locations:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}

INFER_PR=$(resolve_script infer-pr.sh || true)
DISMISS=$(resolve_script dismiss-stale-bot-changes.sh || true)
PR_STATE_SH=$(resolve_script pr-state.sh || true)
MERGE_GATE_SH=$(resolve_script merge-gate.sh || true)
AC_CHECKBOXES_SH=$(resolve_script ac-checkboxes.sh || true)
CI_STATUS_SH=$(resolve_script ci-status.sh || true)
RELEASE_DECIDE=$(resolve_script release-decide.sh || true)
RELEASE_SWEEP=$(resolve_script release-sweep.sh || true)
PR_ISSUE_REF_SH=$(resolve_script pr-issue-ref.sh || true)
ISSUE_CLAIM_SH=$(resolve_script issue-claim.sh || true)
REPO_ROOT_SH=$(resolve_script repo-root.sh || true)
DIRTY_MAIN_GUARD_SH=$(resolve_script dirty-main-guard.sh || true)
MAIN_SYNC_SH=$(resolve_script main-sync.sh || true)
HHG_STATE_SH=$(resolve_script hhg-state.sh || true)
CYCLE_COUNT_SH=$(resolve_script cycle-count.sh || true)
PR_AUTHORSHIP_SH=$(resolve_script pr-authorship.sh || true)
CR_HOURLY_SH=$(resolve_script cr-review-hourly.sh || true)

# Step 2.5 changes cwd to the root main checkout before invoking the guard.
# Preserve the repo-relative fallback as an absolute path first.
if [[ -n "$DIRTY_MAIN_GUARD_SH" && "$DIRTY_MAIN_GUARD_SH" != /* ]]; then
  DIRTY_MAIN_GUARD_SH="$(pwd)/$DIRTY_MAIN_GUARD_SH"
fi

[[ -n "$PR_STATE_SH" ]] || { echo "ERROR: pr-state.sh not found (checked all three paths) — wrap PR state unavailable" >&2; exit 1; }
[[ -n "$MERGE_GATE_SH" ]] || { echo "ERROR: merge-gate.sh not found (checked all three paths) — wrap merge gate unavailable" >&2; exit 1; }
[[ -n "$AC_CHECKBOXES_SH" ]] || { echo "ERROR: ac-checkboxes.sh not found (checked all three paths) — acceptance verification unavailable" >&2; exit 1; }
[[ -n "$CI_STATUS_SH" ]] || { echo "ERROR: ci-status.sh not found (checked all three paths) — CI diagnosis unavailable" >&2; exit 1; }
[[ -n "$PR_AUTHORSHIP_SH" ]] || { echo "ERROR: pr-authorship.sh not found (checked all three paths) — wrap authorship gate unavailable" >&2; exit 1; }
```

These are resolved before any phase work. `INFER_PR` is used in Step 1.1; `DISMISS` is used in Step 2.1 Branch A. `SESSION_STATE_SH` and `ISSUE_DEDUP` are resolved later in the steps that first need them (Steps 3.5 and 3.0 respectively).

## Phase 1: Pre-Merge Verification — Check for Unresolved Findings

Before merging, verify that all reviewer feedback has been addressed.

### Step 1.1: Identify the PR

**Parse flags first (before any PR resolution).** Scan `$ARGUMENTS` for `--verbose` (anywhere, any order), set `WRAP_VERBOSE`, and **strip it** so only the PR reference remains:

```bash
WRAP_VERBOSE=0
REST=""
for tok in ${ARGUMENTS:-}; do
  if [ "$tok" = "--verbose" ]; then WRAP_VERBOSE=1; else REST="${REST:+$REST }$tok"; fi
done
ARGUMENTS="$REST"
```

**Cascade summary** (first match wins — later sub-steps skipped):

1. **1.1a** Explicit argument — if `$ARGUMENTS` non-empty, resolve via `"$INFER_PR" --explicit "$ARGUMENTS"`; stop if helper missing or reference unparseable. Never fall through to 1.1b.
2. **1.1b** Current branch — `gh pr view` finds a PR; use it (non-inferred, no `[INFERRED]` line). Skip 1.1c–1.1e.
3. **1.1c** Thread context scan (AI judgment) — most recent `/fixpr`/`/wrap` invocations and explicit PR refs in this conversation.
4. **1.1d** Session-state — `"$INFER_PR" --root-repo "$ROOT_TOPLEVEL"`; capture real exit code (do NOT `|| true`).
5. **1.1e** Merge, deduplicate, resolve — single / unambiguous / ambiguous / no-candidates. Stop with `Multiple PRs in scope — please specify: /wrap <N>` on tie.
6. **1.1f** No-candidates stop — non-coding thread vs. lookup-failed (AI judgment; bias toward lookup-failed when uncertain).

Full sub-step bash, the `[INFERRED]` line format, the repo-scoping guard, and the authorship guard: **`references/wrap-pr-inference.md`**.

**Merge-safety:** `/wrap` implicitly authorizes the squash merge — an incorrect inference merges the **wrong** PR. Only auto-proceed when the target is unambiguous. The `[INFERRED]` line (emitted before any Phase 1 verification work) is the user's only catch point.

Once `PR_NUM` is fixed, fetch PR details:

```bash
gh pr view "$PR_NUM" --json number,title,headRefName,body,state \
  --jq '{number, title, headRefName, body, state}'
```

If already merged or closed, skip to Phase 3.

### Step 1.2: Scan for unresolved review findings

> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read the cached JSON bundle. All review-state queries in this skill read from the `$BUNDLE` returned by `pr-state.sh` — do not add inline `gh api` calls to these three endpoints.

Use the shared `pr-state.sh` helper to fetch and pre-classify review activity from all three endpoints in one call. It filters to `coderabbitai[bot]`, `greptile-apps[bot]`, and `cursor[bot]` (BugBot) and tags each comment with `classification.class` (`finding` vs `acknowledgment`). The helper writes the JSON bundle to a tempfile and prints its **path** on stdout — capture the path, then read with `jq < "$BUNDLE"`:

```bash
PR_CREATED=$(gh pr view "$PR_NUM" --json createdAt --jq '.createdAt')
BUNDLE=$("$PR_STATE_SH" --pr "$PR_NUM" --since "$PR_CREATED")
```

Read the findings across all three endpoints with a single jq pass:

```bash
jq '[.new_since_baseline.reviews[], .new_since_baseline.inline[], .new_since_baseline.conversation[]]
    | map(select(.classification.class == "finding"))' < "$BUNDLE"
```

For each finding:

1. Check if there is a reply confirming the fix
2. Check if the code at the referenced location has been updated since the comment
3. Check if the thread is resolved/outdated

**Do not stop here.** Record whether any items remain classified as `finding` as **`WRAP_PHASE1_FINDINGS`** — count + short list. Unresolved bot findings are a **trigger** for Phase 2's `/fixpr` delegation path, not a hard stop.

**Unresolved-threads detection (issue #455):**

```bash
WRAP_UNRESOLVED_THREADS=$(jq -r '.threads.unresolved_count // 0' < "$BUNDLE")
```

If `> 0`, record it. In `--verbose` mode also emit a timestamped detection heartbeat. Do **not** assert threads are the sole blocker — that is Branch B's call once the gate's full `missing` set is known. Do **not** invoke `/fixpr` from Phase 1 — the single delegation point is Step 2.1 Branch B.

Proceed immediately to Phase 2 — do not ask.

## Phase 2: Merge

### Step 2.1: Merge gate + autonomous recovery loop (issue #452)

**Authority:** `"$MERGE_GATE_SH"` JSON on stdout is the single source of truth for merge readiness. After **every** recovery action, re-fetch PR HEAD SHA and re-run `merge-gate.sh` — **no stale cache**.

```bash
WRAP_RECOVERY_MAX_ITERATIONS="${WRAP_RECOVERY_MAX_ITERATIONS:-5}"
```

**Polling ownership (issue #454):** `/wrap` has NO polling cadence — all waiting happens inside `/fixpr`'s Step 4d review-wait loop. `/wrap` delegates, trusts the returned verdict, and re-runs `merge-gate.sh` immediately.

**Per-iteration heartbeat** (verbose mode only):

```bash
if [ "$WRAP_VERBOSE" = "1" ]; then
  TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
  echo "[$TS] /wrap recovery cycle $i/$WRAP_RECOVERY_MAX_ITERATIONS — gate check"
fi
```

**The silent default keeps three non-negotiable signals:** (a) the CLAUDE.md 5-minute heartbeat during `/fixpr` waits, (b) dispatch/blocker transitions always print, and (c) a clean merge emits `merged PR #N`.

After each action, append to **`WRAP_RECOVERY_AUDIT`**: cycle number, blocker summary, action taken, result. Always built; rendered to the user only under `--verbose`.

**Merge-ready shortcut:** Run `merge-gate.sh` once before the loop. If exit `0` and no `WRAP_PHASE1_FINDINGS` and no half-applied recovery, skip straight to Step 2.2.

**Recovery loop** (`i` from `1` through `$WRAP_RECOVERY_MAX_ITERATIONS`):

1. **Terminal checks** — read PR state via `gh pr view "$PR_NUM" --json state`. `MERGED` → exit for Phase 3. `CLOSED` → stop.
2. **Refresh gate** — `GATE_JSON=$("$MERGE_GATE_SH" "$PR_NUM")`. Exit `3` → Phase 3. Exit `2`/`4` → surface stderr, stop. Exit `0` with no pending `WRAP_PHASE1_FINDINGS` → proceed to Step 2.2. Exit `0` with `WRAP_PHASE1_FINDINGS` pending → treat as Branch B dispatch (findings still unresolved despite clean gate — delegate to `/fixpr`).
3. **Exit `1` — classify and dispatch** (first matching branch wins; full per-branch detail in `references/wrap-merge-gate-recovery.md`):
   - **`human_changes_requested` non-empty** → stop; name each login.
   - **A. Stale bot `CHANGES_REQUESTED`** → invoke `"$DISMISS" "$PR_NUM"`.
   - **`mergeable == CONFLICTING`** → stop; recommend `/merge-conflict`.
   - **B. Delegate `/fixpr`** → when missing has unresolved threads, `BEHIND`, failing CI, `DIRTY`, or `WRAP_PHASE1_FINDINGS` pending. Threads-only check via structured gate signals (issue #455). Execute **full** `fixpr/SKILL.md` workflow (Steps 0–7 including Step 4d). Parse `FIXPR_WRAP_STATUS` and `FIXPR_WAIT_SUMMARY` from `=== fixpr complete ===` footer; emit control-returned heartbeat. Full handoff semantics: `.claude/reference/wrap-fixpr-delegation.md`.
   - **C. Missing fresh bot review signal** → trigger the one bot needed (CR rate-check first); delegate wait to `/fixpr`.
   - **D. CI incomplete only** → delegate wait to `/fixpr` (idempotent — no push).
   - **E. Branch-protection block** → suggest `/admin-merge <PR>`; never modify branch protection.
   - **`merge_state == UNKNOWN`** → re-run gate next iteration.
4. **End of iteration** — if no branch matched, append "unclassified blocker" + `missing` to audit.

**Loop exit:** gate exit `0` with no `WRAP_PHASE1_FINDINGS` → Step 2.2; gate exit `0` with `WRAP_PHASE1_FINDINGS` still pending → Branch B (findings unresolved despite clean gate). Iteration cap → stop with last `missing` + full `WRAP_RECOVERY_AUDIT`. Genuine block (human CR, `CONFLICTING`, rate-limit, hard `/fixpr` failure) → stop per branch above.

### Step 2.2: Verify acceptance criteria

```bash
ITEMS=$("$AC_CHECKBOXES_SH" "$PR_NUM" --extract)
AC_EXIT=$?
```

For each item with `checked == false`: read the criterion, read relevant source files, confirm the criterion is satisfied. Tick passing items:

```bash
"$AC_CHECKBOXES_SH" "$PR_NUM" --tick "0,2,3"
# Or:
"$AC_CHECKBOXES_SH" "$PR_NUM" --all-pass
```

Exit codes: `0` OK; `1` no Test Plan section — stop; `3` PR not found — stop; `2`/`4` script/gh error — stop. If any item fails verification, do NOT tick it — stop and report. Do NOT merge with unchecked boxes.

### Step 2.3: Pre-merge safety & CI (handled by Step 2.1)

After the recovery loop, Step 2.1 must have returned gate exit `0` immediately before Step 2.2. That implies SHA freshness, BEHIND/CI/unresolved threads cleared. For deeper CI forensics:

```bash
"$CI_STATUS_SH" "$PR_NUM"
"$CI_STATUS_SH" "$PR_NUM" --format summary
```

**Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, or any suppression comment to work around CI.** Fix the actual code.

### Step 2.3a: Pre-merge TestFlight label (iOS repos — issue #1169)

Repos that ship an iOS app cut TestFlight builds from a `release:ios` label on the merged PR. GitHub does **not** re-fire `pull_request: [closed]` for a label added to an already-closed PR, so this is the one release step that must run *before* the merge; everything else happens in Step 3.14. A repo with no `.claude/release-policy.json` — or with it disabled, which is the default — is inert here.

```bash
RELEASE_PREMERGE_RC=2; RELEASE_PREMERGE_OUT=""
if [ -x "$RELEASE_DECIDE" ]; then
  RELEASE_PREMERGE_RC=0
  RELEASE_PREMERGE_OUT=$("$RELEASE_DECIDE" --pr "$PR_NUM" --phase pre-merge --apply 2>&1) \
    || RELEASE_PREMERGE_RC=$?
fi
```

**Every failure path here is non-fatal and nothing is printed yet.** A missing script, a malformed policy, a `gh` error, or any non-zero exit leaves the merge untouched — release logic must never gate or delay a merge (AC4). The result is carried to Step 3.14 and reported only once the merge has actually landed, so a merge that fails after the label was applied never claims a build that did not happen. (A label left on an unmerged PR is ignored by the workflow until that PR merges — recoverable and harmless.)

### Step 2.4: Squash merge

After blockers clear (Phase 1 + Step 2.1 recovery + Step 2.2), run `gh pr merge --squash` with the resolved PR number — per `CLAUDE.md` "PR MERGE AUTHORIZATION" and `cr-merge-gate.md` Step 3. Always pass the explicit identifier so `/wrap #N` invocations merge the correct PR, not the current-branch PR.

```bash
gh pr merge "$PR_NUM" --squash
```

**Release the issue claim** once the merge succeeds — a merged PR is the terminal state that makes the issue startable again (issue #873). Step 3.1 resolves the linked issue for follow-ups, but that runs later, so resolve it here too:

```bash
MERGED_ISSUE=$([[ -n "$PR_ISSUE_REF_SH" ]] && "$PR_ISSUE_REF_SH" "$PR_NUM" 2>/dev/null || true)
[ -n "$MERGED_ISSUE" ] && [ -n "$ISSUE_CLAIM_SH" ] && "$ISSUE_CLAIM_SH" "$MERGED_ISSUE" --release || true
```

Best-effort by design: the merge has already landed, so a failed release is a warning, never a non-zero exit from `/wrap`. An unreleased claim ages out on its own within `CLAIM_STALE_HOURS`; failing an already-completed merge would be far worse. This is the only release call on the merge path — Phase C (`phase-c-merger.md`) runs `/wrap` and inherits it, so do not add a second one there.

**Append actuals log entry** — after the merge and claim-release, append one row to `~/.claude/estimate-log.jsonl`. This is best-effort: a logging failure prints one `WARN:` line and never blocks or delays anything downstream.

```bash
ESTIMATE_LOG_SH=$(resolve_script estimate-log.sh || true)
if [[ -n "$ESTIMATE_LOG_SH" ]]; then
  LOG_RC=0
  LOG_OUT=$("$ESTIMATE_LOG_SH" --append "$PR_NUM" 2>&1) || LOG_RC=$?
  if [[ $LOG_RC -ne 0 || -n "$LOG_OUT" ]]; then
    echo "WARN: estimate-log.sh --append PR #$PR_NUM exited $LOG_RC: $LOG_OUT" >&2
  fi
fi
```

The script always exits 0 when called with `--append` (issue AC). The outer `|| LOG_RC=$?` captures unexpected failures; the `WARN:` line surfaces them without blocking the merge path.

Do NOT use `--delete-branch`. The current worktree is still checked out on the feature branch — git refuses to delete a branch held by a worktree. The branch is cleaned up out-of-band by `/pm-update` via `stale-cleanup.sh`.

### Step 2.5: Sync root repo main (aggressive reset)

```bash
ROOT_REPO=$([[ -n "$REPO_ROOT_SH" ]] && "$REPO_ROOT_SH" 2>/dev/null || true)
MAIN_SYNC_STATUS=""
QUARANTINE_STATUS=""
QUARANTINE_OK=0
if [ -z "$ROOT_REPO" ] || [ ! -d "$ROOT_REPO" ]; then
  MAIN_SYNC_STATUS="failed: could not determine root repo path"
else
  if [[ -n "$DIRTY_MAIN_GUARD_SH" ]] && (cd "$ROOT_REPO" && "$DIRTY_MAIN_GUARD_SH" --check >/dev/null 2>&1); then
    QUARANTINE_STATUS="clean"
    QUARANTINE_OK=1
  elif [[ -z "$DIRTY_MAIN_GUARD_SH" ]]; then
    QUARANTINE_STATUS="DEGRADED: dirty-main-guard.sh not found (checked all three paths) — quarantine unavailable"
  else
    QUARANTINE_RC=0
    QUARANTINE_STATUS=$(cd "$ROOT_REPO" && "$DIRTY_MAIN_GUARD_SH" --quarantine 2>&1) || QUARANTINE_RC=$?
    if [[ "$QUARANTINE_RC" -eq 0 ]]; then
      QUARANTINE_OK=1
    else
      QUARANTINE_STATUS="failed(rc=$QUARANTINE_RC): $QUARANTINE_STATUS"
    fi
  fi
  MAIN_SYNC_RC=0
  if [[ "$QUARANTINE_OK" -ne 1 ]]; then
    MAIN_SYNC_RC=1
    MAIN_SYNC_STATUS="skipped: root quarantine did not complete; aggressive reset was not run"
  elif [[ -z "$MAIN_SYNC_SH" ]]; then
    MAIN_SYNC_RC=127
    MAIN_SYNC_STATUS="ERROR: main-sync.sh not found (checked all three paths) — root main sync unavailable"
  else
    MAIN_SYNC_STATUS=$("$MAIN_SYNC_SH" --reset --repo "$ROOT_REPO" 2>&1) || MAIN_SYNC_RC=$?
  fi
  if [ "$MAIN_SYNC_RC" -ne 0 ] && ! [[ "$MAIN_SYNC_STATUS" == aborted:* || "$MAIN_SYNC_STATUS" == skipped:* ]]; then
    MAIN_SYNC_STATUS="failed(rc=$MAIN_SYNC_RC): $MAIN_SYNC_STATUS"
  fi
fi
if [ "$WRAP_VERBOSE" = "1" ]; then
  echo "Main quarantine: $QUARANTINE_STATUS"
  echo "Main sync: $MAIN_SYNC_STATUS"
fi
```

See `main-sync.sh --help` and `dirty-main-guard.sh --help` for full contracts.

**If `MAIN_SYNC_STATUS` starts with `aborted:`**: surface the full status line in the final report so the user can run `git log origin/main..main` against the root repo and decide. The PR merge has already succeeded — main-sync failure does not un-merge anything.

Store `MAIN_SYNC_STATUS` and `QUARANTINE_STATUS` for the final report.

## Phase 3: Follow-Up Detection and Full-Session Sweep

Phase 3 has **two parts**, run in order:

- **Part A — Per-PR follow-up detection (Steps 3.1–3.4):** derive follow-ups from the merging PR and its linked issue, dedup, and auto-create GitHub issues.
- **Part B — Full-session sweep (Steps 3.5–3.13):** answer "is there anything I should have ticketed but didn't?" across the entire session. Eight categories: loose ends, ticket coverage, external/process state, memory persistence, PM hygiene, churn hotspots, time-sensitive items, future-self handoff.

**Shared filed-issue registry (`WRAP_FILED_ISSUES`) — initialize before Step 3.1.** Both parts file into the same run-scoped registry. Each entry is `{number, title, keywords, rationale}`. Part A appends in Step 3.3; Part B checks the registry before its own dedup search in Step 3.7.

### Step 3.0: Dedup helper setup (both parts — issue #652)

Resolve the helper once, before Step 3.1:

```bash
ISSUE_DEDUP=$(resolve_script issue-dedup.sh || true)
DEDUP_EXCLUDE=""
DEDUP_DEGRADED=""
DEDUP_ANY_DEGRADED=""
WRAP_FILED_ISSUES=""   # newline-separated JSON objects: {number, title, keywords, rationale}; both Part A and Part B append here

dedup_search() {   # sets DEDUP_JSON/DUP_NUM/DUP_STATE
  local kw="$1" rc=0
  DEDUP_JSON='[]'
  DEDUP_DEGRADED=""
  if [ -n "$ISSUE_DEDUP" ] && [ -n "$kw" ]; then
    DEDUP_JSON=$("$ISSUE_DEDUP" "$kw" ${DEDUP_EXCLUDE:+--exclude "$DEDUP_EXCLUDE"}) || rc=$?
    if [ "$rc" -gt 1 ]; then
      DEDUP_DEGRADED="helper exit $rc"
      DEDUP_ANY_DEGRADED="$DEDUP_DEGRADED"
      DEDUP_JSON=$(gh issue list --search "${kw} in:title" --state open \
        --json number,title,state --jq '[.[0] // empty]' 2>/dev/null || echo '[]')
    fi
  elif [ -n "$kw" ]; then
    DEDUP_DEGRADED="helper not installed"
    DEDUP_ANY_DEGRADED="$DEDUP_DEGRADED"
    DEDUP_JSON=$(gh issue list --search "${kw} in:title" --state open \
      --json number,title,state --jq '[.[0] // empty]' 2>/dev/null || echo '[]')
  fi
  DUP_NUM=$(printf '%s' "$DEDUP_JSON" | jq -r '.[0].number // empty')
  DUP_STATE=$(printf '%s' "$DEDUP_JSON" | jq -r '.[0].state // empty' | tr '[:lower:]' '[:upper:]')
  WEAK_DUP_NUM=""
}
```

`issue-dedup.sh <keywords>` prints ranked candidates as JSON, scoring **title and body** across open plus recently-closed issues. Exit `0` = candidates, `1` = none ("no duplicate"), `2`/`4` = failure (degrade to title-only; never treat as "no match").

**A degraded search is never a strong match.** `DEDUP_DEGRADED` resets per call so one transient failure does not force every later candidate down the degraded path. **The helper only finds candidates — it never decides.** Classification (strong / weak / none) and the four strong-match criteria are specified in **`.claude/reference/autofile-dedup.md`**. Two invariants: bias toward filing; suppression is never silent.

> **Phase C / subagent context:** Part B degrades gracefully (transcript-derived categories find little); Part A and git-data categories still run normally. Never block a Phase C merge on a Part B finding — Part B is advisory.

### Part A — Per-PR follow-up detection

### Step 3.1: Detect follow-up items

1. Extract the linked issue number from the PR body via `pr-issue-ref.sh` (matches all nine GitHub closing keywords). Distinguish exit `1` (no link — expected) from exits `2`/`3`/`4` (real errors):

   ```bash
   PR_NUMBER="$PR_NUM"
   PR_TITLE=$(gh pr view "$PR_NUMBER" --json title --jq '.title')
   ISSUE_N=""
   if [[ -n "$PR_ISSUE_REF_SH" ]] && RAW_REF=$("$PR_ISSUE_REF_SH" "$PR_NUMBER" 2>&1); then
     ISSUE_N="$RAW_REF"
   else
     REF_RC=$?
     if [ "$REF_RC" -ne 1 ]; then
       echo "Warning: pr-issue-ref.sh exit $REF_RC: $RAW_REF — skipping linked-issue lookup" >&2
     fi
   fi
   ISSUE_TITLE=""
   ISSUE_BODY=""
   if [ -n "$ISSUE_N" ]; then
     ISSUE_TITLE=$(gh issue view "$ISSUE_N" --json title --jq '.title' 2>/dev/null || echo "")
     ISSUE_BODY=$(gh issue view "$ISSUE_N" --json body --jq '.body' 2>/dev/null || echo "")
   fi
   ```

2. If a parent issue exists (check for "parent" or "epic" references in the issue body), fetch sibling issues:
   ```bash
   gh issue view {parent_N} --json body --jq .body
   ```
   Look for task lists or child issue references. Check which are still open.

3. Check for related issues mentioned in the PR or issue thread:
   ```bash
   gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" --jq '.[].body'
   ```
   Scan for issue references (`#NNN`), "follow-up", "TODO", "next step", "migration", "deploy" mentions.

4. Check if the issue itself has sub-tasks (task list checkboxes) that are unchecked.

Collect each detected follow-up as a `{title, body, keywords}` record.

### Step 3.2: HHG two-ticket pattern detection

If the PR title, linked issue title, or linked issue body contains "HHG" (case-insensitive), **override** any generic follow-ups with exactly **two** HHG follow-ups (scraping + ETL):

```bash
HHG_MATCH=$(printf '%s\n%s\n%s\n' "$PR_TITLE" "$ISSUE_TITLE" "$ISSUE_BODY" | grep -iE 'HHG' || true)
if [ -n "$HHG_MATCH" ]; then
  COMBINED=$(printf '%s %s %s' "$PR_TITLE" "$ISSUE_TITLE" "$ISSUE_BODY")
  STATE=$([[ -n "$HHG_STATE_SH" ]] && "$HHG_STATE_SH" "$COMBINED" || true)
  if [ -z "$STATE" ]; then
    STATE=""
    echo "WARNING: HHG PR detected but no state code found in PR title, issue title, or issue body — skipping HHG auto-creation. Create the scraping and ETL issues manually once you know the state."
  fi
fi
```

**If `STATE` is empty, skip HHG auto-creation entirely** — do NOT create issues with placeholder titles. Report the skip in Step 3.4.

Two HHG follow-up titles: `{STATE} HHG — Export carriers and run scraper` and `{STATE} HHG — Seed product codes and load scrape results to Neon`. Create scraping issue first (capture number as `SCRAPE_NUM`), then ETL with `Depends on #${SCRAPE_NUM}` in its body.

**HHG override trade-off:** Replaces any generic follow-ups to keep the two-ticket pattern clean.

### Step 3.3: Dedup check and create

For each follow-up item (the HHG pair or the generic list):

1. **Dedup check:**
   ```bash
   dedup_search "$KEYWORDS"   # Step 3.0 — sets DEDUP_JSON, DUP_NUM, DUP_STATE, WEAK_DUP_NUM
   ```
   Classify per `.claude/reference/autofile-dedup.md`:
   - **Strong** → comment the follow-up onto `#{DUP_NUM}`; record `"{title}" — appended to #{DUP_NUM}` for Step 4.3.
   - **Weak / ambiguous or closed** → set `WEAK_DUP_NUM="$DUP_NUM"` and file with a `Possibly duplicates #{DUP_NUM}` body line.
   - **None** → file.

2. **Create the issue** (strong match excepted):
   ```bash
   LINKED_SOURCE=""
   if [ -n "$ISSUE_N" ]; then
     LINKED_SOURCE=$'\n\n'"Linked source: #${ISSUE_N}"
   fi
   POSSIBLE_DUP=""
   if [ -n "${WEAK_DUP_NUM:-}" ]; then
     POSSIBLE_DUP=$'\n\n'"Possibly duplicates #${WEAK_DUP_NUM} — {one line on the overlap and what is unclear}."
   fi
   ISSUE_TITLE="{derived title}"
  ISSUE_BODY="Follow-up from PR #${PR_NUMBER}.${POSSIBLE_DUP}

{context from detection}${LINKED_SOURCE}

_Filed via /wrap._"
  # Surface title+body before filing (--verbose only; the silent default records without printing):
  if [ "$WRAP_VERBOSE" = "1" ]; then
    echo "Filing follow-up: $ISSUE_TITLE"
    echo "$ISSUE_BODY"
  fi
  if NEW_URL=$(gh issue create \
     --title "$ISSUE_TITLE" \
     --body "$ISSUE_BODY" 2>&1); then
     NEW_NUM=$(echo "$NEW_URL" | grep -oE '[0-9]+$')
     if [ -z "$NEW_NUM" ]; then
       echo "WARNING: created issue but could not parse number from: $NEW_URL"
     fi
     # Append {number, title, keywords, rationale: "follow-up from PR #${PR_NUMBER}"} to WRAP_FILED_ISSUES.
     # Append $NEW_NUM to DEDUP_EXCLUDE.
   else
     echo "WARNING: gh issue create failed: $NEW_URL"
   fi
   ```

### Step 3.4: Carry Part A results into the unified report

Part A does **not** print its own "Created" list — every issue it filed is in `WRAP_FILED_ISSUES` and rendered once in Step 4.3's verbose report. Carry forward: filed issues (already in registry), suppressed-as-duplicates, filed-with-caveat, and failures. Filed-with-caveat entries and creation failures are the two that also print on the silent default. If nothing detected and nothing filed, the verbose report reads "No follow-up items detected." Proceed immediately to Part B.

### Part B — Full-session sweep

Part B sweeps the **whole session** for loose ends the per-PR detection in Part A cannot see. It produces two buckets — **Auto-handled** and **Needs your decision** — and a one-line **verdict**.

**Safety boundaries (non-negotiable — issue #471):** never auto-file without recording the full body (rendered under `--verbose` or on request — issue #851); never auto-act on anything affecting shared state (live monitors, active subagents, human-owned issues/PRs, recovery branches); auto-handling limited to: stopping a **dead** session Monitor task and deleting a **stale** handoff file.

#### Step 3.5: Sweep setup & idempotency guard

```bash
SESSION_STATE_SH=$(resolve_script session-state.sh || true)

SWEEP_PRIOR_FILED=""
if [[ -n "$SESSION_STATE_SH" ]]; then
  SWEEP_PRIOR_FILED=$("$SESSION_STATE_SH" --get ".prs[\"$PR_NUMBER\"].wrap_sweep.filed_issues" 2>/dev/null || echo "")
fi
```

Initialize `SWEEP_AUTO_HANDLED` and `SWEEP_NEEDS_DECISION` (free-form bullet lists). Cap each rendered section at 3–5 bullets (overflow → "+ N more" summary); auto-filed tickets are **exempt** from the cap — every created issue's title + body is surfaced in full under `--verbose`.

#### Step 3.6: Category 1 — Session loose ends (transcript introspection)

**Model-introspection step** — no shell command can read the transcript. Review your own recent messages and tool-call history for deferral signals: `later`, `TODO`, `follow-up`, `come back to`, `worth investigating`, `for now`, `deferred`, `out of scope`, `punt`, `we should eventually`, `not in this PR`, `leaving X for a separate change`. After compaction, fall back to tool-call history and `git diff origin/main...HEAD` scan for new `TODO`/`FIXME` comments.

Collect each loose end as `{summary, context, keywords}`.

#### Step 3.7: Category 2 — Ticket coverage (dedup, then file)

For **each** loose end from Step 3.6, dedup before filing:

**Stage 1 — cross-batch (this run).** Check against `WRAP_FILED_ISSUES` first. Collapse only when same primary artifact and already-filed scope covers this finding. Record `Collapsed into #{N} (filed earlier this run) — "<summary>"` in `SWEEP_AUTO_HANDLED`.

**Stage 2 — cross-session (the repo).**

```bash
dedup_search "$KEYWORDS"   # Step 3.0
```

Classify per `.claude/reference/autofile-dedup.md` and take exactly one path:

- **Strong match** (open, same artifact, quotable criterion, `coverage ≥ 0.6`) → comment onto `#{DUP_NUM}`; if `DUP_NUM` is in `SWEEP_PRIOR_FILED`, **omit entirely** (idempotent). Record in `SWEEP_AUTO_HANDLED`.
- **Weak / closed** → set `WEAK_DUP_NUM` and file with `Possibly duplicates #{DUP_NUM}` body line; add to `SWEEP_NEEDS_DECISION`.
- **None** → file.

On filing: create immediately, **surface title + body under `--verbose`**, append to `WRAP_FILED_ISSUES` (rationale `loose end: <summary>`), append number to `DEDUP_EXCLUDE`, add to `SWEEP_AUTO_HANDLED`. Use same `gh issue create` guard as Step 3.3 (validate parsed number; on failure record and continue):

```bash
POSSIBLE_DUP=""
if [ -n "${WEAK_DUP_NUM:-}" ]; then
  POSSIBLE_DUP=$'\n\n'"Possibly duplicates #${WEAK_DUP_NUM} — <one line on the overlap and what is unclear>."
fi
if NEW_URL=$(gh issue create \
    --title "<derived title>" \
    --body "Follow-up surfaced by /wrap session sweep on PR #${PR_NUMBER}.${POSSIBLE_DUP}

<context from transcript>

_Filed via /wrap._" 2>&1); then
  NEW_NUM=$(echo "$NEW_URL" | grep -oE '[0-9]+$')
  if [ -n "$NEW_NUM" ]; then
    SWEEP_FILED="${SWEEP_FILED} ${NEW_NUM}"
    # Append {number, title, keywords, rationale} to WRAP_FILED_ISSUES.
  else
    echo "WARNING: created issue but could not parse number from: $NEW_URL"
  fi
else
  echo "WARNING: gh issue create failed: $NEW_URL"
fi
```

#### Step 3.8: Category 3 — External / process state

```bash
[ -n "$SESSION_STATE_SH" ] && POLLING_JOBS=$("$SESSION_STATE_SH" --get '.polling_jobs' 2>/dev/null || echo "null")
[ -n "$SESSION_STATE_SH" ] && ACTIVE_AGENTS=$("$SESSION_STATE_SH" --get '.active_agents' 2>/dev/null || echo "null")
```

- **Dead Monitor tasks (auto-stop).** For each watcher whose target PR is merged/closed: read the complete `.prs["$N"].babysit.monitor_task_id` + `.monitor_generation` identity pair, stop that exact task with `TaskStop` when present, then atomically set `stop_requested=true`, `active=false`, `monitor_task_id=null`, and `monitor_generation=null` via one `session-state.sh --set` batch. Clear neither identity field unless exact `TaskStop` succeeds. Record `Stopped stale Monitor task (PR #N watcher — PR already merged)` in `SWEEP_AUTO_HANDLED`. A missing/incomplete identity or failed task stop is a decision item, never a claimed successful stop.
- **Stale handoffs (auto-delete).** Scan both layout patterns (`~/.claude/handoffs/pr-*.json` and `~/.claude/handoffs/*/*/pr-*.json`). For each merged PR: resolve path with `handoff-state.sh [--owner-repo ...] --path N` and delete via `handoff-state.sh [--owner-repo ...] --delete N`. Never `rm -f` directly — that bypasses the state-lock advisory lock (issue #682). Deleting a **flat-layout** file is the one legitimate no-`--owner-repo` write here, so prefix that call with `CLAUDE_HANDOFF_FLAT_OK=1` to silence the flat-path warning (issue #1302) — never set it on the scoped deletes.
- **Surface (never auto-act).** Add to `SWEEP_NEEDS_DECISION`: live `CronCreate` jobs, any `active_agents` entries, `monitoring_active=true`, and any `recovery/dirty-main-*` branches.

#### Step 3.9: Category 4 — Memory persistence (defers to Phase 4)

Memory writes are owned by **Phase 4**. Category 4 only *flags* as `SWEEP_MEMORY_CANDIDATES` (handed to Phase 4 Step 4.2): decisions made this session worth persisting, and existing memories the session contradicted. Surface a memory item in the sweep report only if Phase 4 is skipped as trivial.

#### Step 3.10: Category 5 — PM hygiene (all touched issues/PRs)

Build the set of issues/PRs touched this session — session-state `.prs` keys, the merging PR + its linked issue, any issue/PR numbers from tool-call history. For each, check and flag drift under `SWEEP_NEEDS_DECISION` (do not auto-edit — shared state):

- **Status accuracy** — issue still open but its work merged? PR merged but linked issue not auto-closed?
- **Linkage** — PR missing `Closes #N` for work that clearly resolves an issue?
- **AC checkbox truthfulness** — Test Plan boxes checked that the code does not actually satisfy?

#### Step 3.10a: Category 5a — Churn hotspots (issue #755)

Run **after** Step 2.5's root-main sync:

```bash
CHURN_SH=$(resolve_script churn-hotspots.sh || true)
CHURN_PLAN_SH=$(resolve_script churn-hotspot-wrap-plan.sh || true)
CHURN_JSON=""; CHURN_PLAN=""; CHURN_RC=0
if [ -n "$CHURN_SH" ]; then
  CHURN_JSON=$("$CHURN_SH" --json \
      --exclude ".claude/reference/script-extraction-audit.md" \
      2>/dev/null) || CHURN_RC=$?
fi
```

Exit `1` (nothing crossed threshold) or missing detector → end category immediately, file nothing, add no report line. `existing_lookup_failed == true` → add one `SWEEP_NEEDS_DECISION` bullet: ``Churn hotspot check ran but the existing-issue lookup failed — re-run `churn-hotspots.sh --json` before filing.`` Then **end this category immediately**: do not invoke the classifier, comment, or file. The classifier independently rejects this envelope as a defense in depth.

On detector exit `0`, classify the envelope with the read-only consumer before any mutation:

```bash
if [ -z "$CHURN_PLAN_SH" ]; then
  SWEEP_NEEDS_DECISION="${SWEEP_NEEDS_DECISION}
- Churn hotspot classifier is unavailable — no hotspot issue or comment was changed; restore \`churn-hotspot-wrap-plan.sh\` and re-run /wrap."
elif ! CHURN_PLAN=$(printf '%s' "$CHURN_JSON" | "$CHURN_PLAN_SH" --pr "$PR_NUMBER" 2>/dev/null); then
  SWEEP_NEEDS_DECISION="${SWEEP_NEEDS_DECISION}
- Churn hotspot classifier failed — no hotspot issue or comment was changed; run \`churn-hotspot-wrap-plan.sh --help\` and re-run /wrap."
fi
```

An empty `CHURN_PLAN` ends the category after recording that failure. A valid plan has disjoint `comment_set`, `file_set`, `material_growth_set`, `unknown_state_set`, and `suppressed_set` arrays. It also selects the top file candidate and computes the aggregate summary. **Do not reimplement those predicates inline** — that would let the tested consumer and the mutating workflow drift.

Score formula, threshold calibration, and the capping rationale: **`.claude/reference/churn-hotspots.md`**.

**Four independent branches operate on the classifier's different sets** (do NOT select once and then branch):

- **Comment set** — every row in `CHURN_PLAN.comment_set`, uncapped. The classifier includes an open match only when its `pr_numbers` contain the PR this wrap just merged, preserving comment idempotency. For each member:

  ```bash
  gh issue comment "$EXISTING" --body "Still churning: ${PR_COUNT} distinct merged PRs have touched \`${FILE}\` since ${SINCE}${CONFLICT_CLAUSE}: ${PR_LIST}.

  _Evidence appended by /wrap after PR #${PR_NUMBER} merged._"
  ```

  Record `Appended evidence to #{EXISTING} — churn hotspot \`{file}\`` for Step 4.3.

- **File set** — **at most one new issue per run**, still. Use `CHURN_PLAN.selected_file`; the classifier sorts all eligible `file_set` rows by score, PR count, then path. Eligible hotspots remain exactly two kinds:
  1. `existing_hotspot_issue == null` — never ticketed. Files clean, exactly as before.
  2. `existing_hotspot_issue_state == "closed"` **and** `conflict_rounds > 0` — a **closed-match re-file** (issue #915). Adds the caveat line below and is reported under `SWEEP_NEEDS_DECISION`, not `SWEEP_AUTO_HANDLED`.

  A closed match with `conflict_rounds == 0` is **not eligible** — it falls to the growth-or-suppression branches below. Title: `Refactor hotspot: {file}`. Body must include the `<!-- churn-hotspot: {file} -->` marker verbatim (re-find fallback):

  ```bash
  # Set only for kind 2 — a closed exact match is a WEAK match in the
  # `autofile-dedup.md` sense, so it re-files with a caveat, never cleanly.
  CLOSED_DUP=""
  if [ -n "${CLOSED_DUP_NUM:-}" ]; then
    CLOSED_DUP=$'\n\n'"Possibly duplicates #${CLOSED_DUP_NUM} — same file, closed after review; re-filed because the churn has since cost ${CONFLICT_ROUNDS} conflict re-resolution(s)."
  fi
  if NEW_URL=$(gh issue create \
      --title "Refactor hotspot: ${FILE}" \
      --body "Filed by /wrap churn detection after PR #${PR_NUMBER} merged.${CLOSED_DUP}

  \`${FILE}\` was touched by ${PR_COUNT} distinct merged PRs since ${SINCE}${CONFLICT_CLAUSE}: ${PR_LIST}.

  This is an observational report, not a prescription — it flags a file worth a
  closer look, not a decision that it should be split.

  <!-- churn-hotspot: ${FILE} -->

  _Filed via /wrap._" 2>&1); then
    NEW_NUM=$(echo "$NEW_URL" | grep -oE '[0-9]+$')
    if [ -n "$NEW_NUM" ]; then
      SWEEP_FILED="${SWEEP_FILED} ${NEW_NUM}"
      # Append {number, title, keywords, rationale: "churn hotspot: {file}"} to WRAP_FILED_ISSUES.
      # Append $NEW_NUM to DEDUP_EXCLUDE.
      # Kind 2 only: a re-file over a closed issue is a decision, not an
      # auto-handled filing, so it must reach SWEEP_NEEDS_DECISION (Step 3.13
      # renders from that list — appending to SWEEP_FILED alone would ship the
      # re-file with no owner-visible flag).
      if [ -n "${CLOSED_DUP_NUM:-}" ]; then
        SWEEP_NEEDS_DECISION="${SWEEP_NEEDS_DECISION}
- Re-filed #${NEW_NUM} for churn hotspot \`${FILE}\` over closed #${CLOSED_DUP_NUM} — the churn has now cost ${CONFLICT_ROUNDS} conflict re-resolution(s). Confirm the re-file or close it as still-by-design."
      fi
    else
      echo "WARNING: created issue but could not parse number from: $NEW_URL"
    fi
  else
    echo "WARNING: gh issue create failed: $NEW_URL"
  fi
  ```

  `CONFLICT_CLAUSE` is empty when `conflict_rounds` is 0; otherwise ` and re-resolved conflicts {conflict_rounds} time(s)`. `CONFLICT_ROUNDS` is that hotspot's `conflict_rounds`, and `CLOSED_DUP_NUM` its `existing_hotspot_issue` — both set only on a kind-2 re-file, left unset for kind 1.

- **Material-growth set** — every row in `CHURN_PLAN.material_growth_set`. These are closed matches with zero conflict cost whose current score is at least **2×** the score recorded in `.claude/reference/churn-hotspot-baselines.json`. File nothing, but add one `SWEEP_NEEDS_DECISION` bullet naming the file, issue, current score, baseline score, and baseline date. Doubling is the material-growth threshold: it is a step-change in centrality rather than the routine linear growth expected from catalogs and junction files. The five standing no-action verdicts on Issues #816, #860, #900, #916, and #1223 remain suppressed until this gate trips.

- **Suppressed set** — every row in `CHURN_PLAN.suppressed_set`. Add **no per-file decision bullet**. These are closed matches with zero conflict cost that are below the 2× gate, plus closed matches with no valid file-and-issue baseline. A missing baseline means growth is unproven, not that growth occurred; the row remains visible through the aggregate count. When a zero-conflict hotspot issue is closed or the owner reaffirms a keep verdict, add or refresh its file-keyed baseline with the issue number, score, PR count, and decision date. A baseline records a real owner decision and must never be raised merely to silence a growth signal.

- **Unknown-state set** — every row in `CHURN_PLAN.unknown_state_set`. **Neither comment nor file**, and add one `SWEEP_NEEDS_DECISION` bullet naming the issue and file. The classifier treats any non-null issue whose state is not open/closed as unknown; only a null issue is a never-ticketed file candidate.

After all five branches, append exactly one `SWEEP_AUTO_HANDLED` entry from `CHURN_PLAN.summary`, followed by `` — run `churn-hotspots.sh` to see them.`` The verbose shape is: ``{total} churn hotspots, {conflict-cost count} with conflict cost, {decision count} surfaced for decision, {suppressed count} suppressed (closed, no conflict cost)``. This replaces N closed/no-cost decision bullets with one auditable count and does not print on the silent default. When `held_back_file_count > 0`, append the existing file-cap clause to that same entry: ``; filed the top hotspot, {N} further candidate(s) held back``. Do not create a second churn summary line.

This category's authoritative re-find is the script's **exact** title/marker match — do not run `dedup_search` here.

#### Step 3.11: Category 6 — Time-sensitive items

Scan transcript for deadline/date/day-of-week phrases: `by Thursday`, `before the release`, `next week`, `end of month`, `by EOD`, `in N days`. Convert every relative reference to an absolute date:

```bash
TODAY=$(date +%Y-%m-%d)
```

`/schedule` available → propose a `/schedule` task per item (surface the proposed command; do not auto-schedule). Unavailable → plain-text reminder with absolute date. No phrases found → **produce no output**.

Add any items to `SWEEP_NEEDS_DECISION`.

#### Step 3.12: Category 7 — Future-self handoff

**Only if the session deferred something meaningful** (Category 1, 2, 5, or 6 produced surfaced items). On a clean session, **skip entirely**. When warranted, generate **one paragraph**: task, what shipped, what was deliberately left, the single most important next step. Add as the final `SWEEP_NEEDS_DECISION` entry.

#### Step 3.13: Persist sweep state & compute verdict

```bash
if [ -n "$SESSION_STATE_SH" ]; then
  # Build from the run-scoped WRAP_FILED_ISSUES registry (includes both Part A and Part B filings),
  # not SWEEP_FILED alone (Part B only). Extract the .number field from each entry.
  ALL_FILED_JSON=$(printf '%s\n' "$WRAP_FILED_ISSUES" | jq -sc '[.[].number] | map(numbers)')
  NEW_FILED_JSON=$ALL_FILED_JSON
  PRIOR_FILED_JSON="$SWEEP_PRIOR_FILED"
  case "$PRIOR_FILED_JSON" in ""|null) PRIOR_FILED_JSON='[]' ;; esac
  FILED_JSON=$(jq -cn --argjson a "$PRIOR_FILED_JSON" --argjson b "$NEW_FILED_JSON" '($a + $b) | unique')
  AUTO_JSON=$(printf '%s\n' "$SWEEP_AUTO_HANDLED" | jq -R 'select(length>0)' | jq -cs .)
  NEEDS_JSON=$(printf '%s\n' "$SWEEP_NEEDS_DECISION" | jq -R 'select(length>0)' | jq -cs .)
  if ! "$SESSION_STATE_SH" \
    --set ".prs[\"$PR_NUMBER\"].wrap_sweep.swept_at=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
    --set ".prs[\"$PR_NUMBER\"].wrap_sweep.filed_issues=$FILED_JSON" \
    --set ".prs[\"$PR_NUMBER\"].wrap_sweep.auto_handled=$AUTO_JSON" \
    --set ".prs[\"$PR_NUMBER\"].wrap_sweep.needs_decision=$NEEDS_JSON"; then
    echo "WARNING: failed to persist wrap_sweep state — a re-run may not be idempotent; the Step 3.7 dedup search still guards against open duplicates." >&2
  fi
fi
```

**UNION** this run's filed numbers with any recorded by a prior sweep — never overwrite. A re-run with no new filings must NOT erase the earlier record.

Compute **verdict** (one of exactly two canonical strings — no improvised wording):

- `0` pending → **`Clear to archive`**
- `N > 0` pending → **`N items pending your decision before archive`**

Proceed immediately to Step 3.14 — do not ask.

#### Step 3.14: Post-merge TestFlight release (iOS repos — issue #1169)

The merge has landed, so the release decision can be reported and the deferred half executed. Three things happen, in order; all are non-fatal.

```bash
# RELEASE_DECIDE and RELEASE_SWEEP were resolved in the preamble.

# 1. Mechanisms that must fire AFTER the merge (workflow_dispatch, none).
#    Dispatching before the merge would have built the pre-merge default branch.
REL_RC=0; REL_OUT=""
if [ -x "$RELEASE_DECIDE" ]; then
  REL_OUT=$("$RELEASE_DECIDE" --pr "$PR_NUM" --phase post-merge --apply 2>&1) || REL_RC=$?
fi

# 2. ONE success line for the whole step, no matter how many phases applied or
#    how many repos the sweep touched. `/wrap`'s silent path allows exactly one
#    `merged PR #N` line, so a successful release must not add several more.
#    Failures and blockers still print one terse line each.
#
#    A blocker is reported for EVERY exit 3, including one that produced no
#    parseable output — a release that failed is exactly what must not vanish.
#    `.reason // "unknown"` alone would not cover that: jq's default fills a
#    MISSING KEY, but on non-JSON input (a crash message, a partial write) jq
#    exits non-zero and prints nothing, leaving an empty reason. So each field
#    falls back explicitly, ending at the raw output and then at the exit code.
#    Diagnostics are collapsed to one line before printing — release-decide.sh
#    stderr can be multi-line, and a blocker that spans six lines is not "one
#    terse line".
RELEASE_CUT=""
one_line() { printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-300; }

for pair in "$RELEASE_PREMERGE_RC:$RELEASE_PREMERGE_OUT" "$REL_RC:$REL_OUT"; do
  rc="${pair%%:*}"; out="${pair#*:}"
  applied=$(printf '%s' "$out" | jq -r '.applied // false' 2>/dev/null)
  repo=$(printf '%s' "$out" | jq -r '.repo // empty' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
  [ -n "$repo" ] || repo="this repo"
  [ -n "$reason" ] || reason="${out:-no output from release-decide.sh (exit $rc)}"
  if [ "$rc" = "0" ] && [ "$applied" = "true" ]; then
    RELEASE_CUT="$repo"
  elif [ "$rc" = "3" ]; then
    echo "TestFlight release blocked — $repo: $(one_line "$reason")" >&2
  fi
done

# 3. Follow in-flight builds to a terminal state and cut any pending build whose
#    window has opened — including markers left by threads that have since ended.
#    Scoped to the repo just merged: sweeping every other repo carrying release
#    state is the periodic surfaces' job (session start, each PMM tick).
#    --quiet keeps its human lines out of the silent path; attention events are
#    re-emitted below, one line each.
MERGED_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
if [ -x "$RELEASE_SWEEP" ]; then
  SWEEP_OUT=$("$RELEASE_SWEEP" ${MERGED_REPO:+--repo "$MERGED_REPO"} --json 2>/dev/null) || true
  if [ -n "${SWEEP_OUT:-}" ]; then
    # A build the sweep cut folds into the single success line rather than adding
    # one of its own.
    SWEEP_CUT=$(printf '%s' "$SWEEP_OUT" | jq -r '[.[]? | select(.kind == "build_cut")] | first | .repo // empty' 2>/dev/null)
    [ -n "$SWEEP_CUT" ] && [ -z "$RELEASE_CUT" ] && RELEASE_CUT="$SWEEP_CUT"
    printf '%s' "$SWEEP_OUT" | jq -r '.[]? | select(.needs_attention == true) | .line' 2>/dev/null >&2
  fi
fi

# 4. The single success line, emitted once, only when something actually shipped.
[ -n "$RELEASE_CUT" ] && echo "cut TestFlight build — $RELEASE_CUT (PR #$PR_NUM)"
```

Exit `3` from either phase is a blocker worth one line (a trigger that failed, or a build cut whose state could not be saved and so will not be followed). Exit `1` (pending or suppressed), `2` (inert), and `4` (environment) are all silent and all non-fatal — `/wrap` never fails a completed merge over release automation.

Mechanism, policy schema, and the per-repo trigger table: `.claude/reference/release-cadence.md`.

Proceed immediately to Phase 4 — do not ask.

## Phase 4: Lessons Learned (Depth-Adaptive)

### Step 4.1: Assess session complexity

- **Cycle count** — resolve it without conflating an unavailable/failed helper with a real zero:
  ```bash
  CYCLES=""
  CYCLE_COUNT_VALID=0
  if [[ -z "$CYCLE_COUNT_SH" ]]; then
    echo "DEGRADED: cycle-count.sh not found (checked all three paths) — cycle count unavailable" >&2
  elif CYCLES=$("$CYCLE_COUNT_SH" "$PR_NUM") && [[ "$CYCLES" =~ ^[0-9]+$ ]]; then
    CYCLE_COUNT_VALID=1
  else
    CYCLES=""
    echo "DEGRADED: cycle-count.sh failed or returned a non-numeric value — cycle count unavailable" >&2
  fi
  ```
- **Thread length** — count user + assistant messages. "Short" = fewer than 15 total.
- **PR size** — `gh pr view N --json files --jq '.files | length'`

**Trivial threshold:** `CYCLE_COUNT_VALID=1` AND cycle count = 0 AND conversation short (<15 messages) AND <5 files changed. An unknown cycle count is non-trivial.

### Step 4.2: Run lessons (or skip)

**If trivial:** set `WRAP_LESSONS_COUNT=0` and skip to Step 4.3.

**If non-trivial:** reflect on the session — task, what was accomplished, what went wrong, patterns, surprises, workarounds to codify. **Merge in `SWEEP_MEMORY_CANDIDATES`** from Phase 3 Category 4 and dedup against the lessons before writing.

For each actionable, novel lesson:
- Check `MEMORY.md` for duplicates — update existing memories rather than creating new ones
- Write memory files with proper frontmatter (`feedback`, `project`, or `user` type)
- Add pointers to `MEMORY.md`

Memory writes happen in both modes. Record `WRAP_LESSONS_COUNT`. Verbose mode prints the full `## Session Lessons` block; the silent default prints no lessons ack at all — the memory files are the record.

### Step 4.3: Final report

`/wrap` has three output paths: the **silent default**, the **verbose report**, and the **Blocker path** (prints in *both* modes).

#### Silent default

On a clean run, print exactly one line — `merged PR #N` — then nothing else: no follow-up list, no lessons ack, no sweep summary. All of it is already recorded (GitHub, `WRAP_FILED_ISSUES`, `session-state.json` `wrap_sweep`, memory) and re-renders in full under `--verbose` or on request.

Print **only** items that need an explicit decision from the user, one terse line each:

- **Blocker or stop condition** → the Blocker path below. Mandatory — silence must never swallow a stop.
- **A filing that needs your judgment** → `gh issue create` failed, or the issue was filed with a `Possibly duplicates #{N}` caveat: `Filed [#{a}](url) — possibly duplicates #{b}.` A filing with no caveat is recorded silently.
- **Sweep verdict, only when items are pending** → `{N} item(s) pending your decision — run /wrap --verbose for detail.` Omit entirely on `Clear to archive`.
- **`[COVERAGE]` degraded** and the **`[INFERRED]` checkpoint** — per the always-print list in **Output modes**.

When none of those apply, `/wrap` emits exactly one line: `merged PR #N`. (`CLAUDE.md` #3)

#### Verbose report (`--verbose`, or on explicit request)

Print this block first:

```
## Wrapped up

**Merged:** PR #{N} ({title}) — {≤3 sentences on the gist of what changed}.{ Only when main-sync was noteworthy — an `aborted:` outcome or a quarantine actually ran: " Main: {one-line status}."}

**Follow-ups:** {either "Opened [#{a}](url) — {one line}; [#{b}](url) — {one line}." listing every WRAP_FILED_ISSUES entry (≤3 sentences), or "No follow-ups opened."}{ When any filing was suppressed as a duplicate: " {M} finding(s) appended to existing issues."}

{lessons ack, one line: "{WRAP_LESSONS_COUNT} lesson(s) captured to memory." | "Clean session — no lessons."}
{sweep line — ONLY when verdict is "N items pending your decision before archive": "Session sweep: {N} item(s) pending your decision — run `/wrap --verbose` for detail." Omit on "Clear to archive".}
```

Rules: **Merged ≤3 sentences; Follow-ups ≤3 sentences.** Every opened issue is listed (number + one-line + clickable link) — an issue not listed is indistinguishable from one silently dropped. Suppressed-as-duplicate findings: never silently dropped (surface count). Sweep verdict: appears only when decisions are pending.

Then the full `## Wrap-Up Complete` multi-section template, rendering rules, section caps, and exemptions: **`references/wrap-report-templates.md`**.

#### Blocker path (both modes)

Print a **single short line** naming the reason. Under `--verbose`, also append the full `WRAP_RECOVERY_AUDIT` / `missing` detail:

- **Merge gate not met after recovery cap** → `Merge blocked: {last missing summary}. Re-run /wrap or /fixpr.`
- **`mergeable == CONFLICTING`** → `Merge blocked: merge conflicts — run /merge-conflict.`
- **Human `CHANGES_REQUESTED` on HEAD** → `Merge blocked: changes requested by {login(s)}.`
- **AC checkbox verification failure (Step 2.2)** → `Merge blocked: AC item "{text}" not yet satisfied — fix the code first.`
- **`/fixpr` delegation failure (Step 2.1 Branch B)** → `Merge blocked: /fixpr could not resolve {blocker} — {FIXPR_WRAP_STATUS}.`
- **No PR found** → the Step 1.1f message verbatim.

The blocker line is **mandatory on the silent default** — silence must never swallow a stop.

The worktree and feature branch are intentionally left in place, reaped out-of-band by `/pm-update`'s stale-cleanup pass. See `stale-cleanup.sh --help`.
