<!-- go-on-routing:begin -->
Route `review:prepare`.

**Trigger:** the first review module of the `unplanned` lane, and the first of the `token_exhaustion` lane whatever step its `needs` names.

**Prerequisites:** the `token-exhaustion` or `unplanned` kind module routed the lane here, and the lane preflight resolved every review module.

**Next:** `review:publish` after Step 1b. Step 8's non-clean `BEHIND` path in `review:merge` uses this module's Step 1 exit table.
<!-- go-on-routing:end -->

## Portable helper resolution (workflow lane)

Resolve every lifecycle helper **before entering Steps 0b–10**, not before Step 0: classification needs only the stop-state helpers resolved in 0.2, and a resume that just routes to `/pause-resume` must not be blocked by a missing merge-gate helper it will never call. Inside the workflow lane a missing helper blocks rather than guessing which completed state is safe.

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/$name}" \
    "${HOME:+$HOME/.claude/scripts/$name}" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
PR_AUTHORSHIP_SH=$(resolve_script pr-authorship.sh || true)
DIFF_SURVIVAL_SH=$(resolve_script diff-survival-check.sh || true)
REVIEWER_OF_SH=$(resolve_script reviewer-of.sh || true)
PR_STATE_SH=$(resolve_script pr-state.sh || true)
REPLY_THREAD_SH=$(resolve_script reply-thread.sh || true)
RESOLVE_REVIEW_THREADS_SH=$(resolve_script resolve-review-threads.sh || true)
MERGE_GATE_SH=$(resolve_script merge-gate.sh || true)
CLEAN_BEHIND_SH=$(resolve_script clean-behind-check.sh || true)
AC_CHECKBOXES_SH=$(resolve_script ac-checkboxes.sh || true)
[[ -n "$PR_AUTHORSHIP_SH" ]] || { echo "ERROR: pr-authorship.sh not found (checked all three paths) — resume authorship gate unavailable" >&2; exit 1; }
[[ -n "$DIFF_SURVIVAL_SH" ]] || { echo "ERROR: diff-survival-check.sh not found (checked all three paths) — rebase survival gate unavailable" >&2; exit 1; }
[[ -n "$REVIEWER_OF_SH" ]] || { echo "ERROR: reviewer-of.sh not found (checked all three paths) — reviewer routing unavailable" >&2; exit 1; }
[[ -n "$PR_STATE_SH" ]] || { echo "ERROR: pr-state.sh not found (checked all three paths) — PR state unavailable" >&2; exit 1; }
[[ -n "$REPLY_THREAD_SH" ]] || { echo "ERROR: reply-thread.sh not found (checked all three paths) — review replies unavailable" >&2; exit 1; }
[[ -n "$RESOLVE_REVIEW_THREADS_SH" ]] || { echo "ERROR: resolve-review-threads.sh not found (checked all three paths) — thread resolution unavailable" >&2; exit 1; }
[[ -n "$MERGE_GATE_SH" ]] || { echo "ERROR: merge-gate.sh not found (checked all three paths) — merge gate unavailable" >&2; exit 1; }
[[ -n "$CLEAN_BEHIND_SH" ]] || { echo "ERROR: clean-behind-check.sh not found (checked all three paths) — clean-BEHIND verification unavailable" >&2; exit 1; }
[[ -n "$AC_CHECKBOXES_SH" ]] || { echo "ERROR: ac-checkboxes.sh not found (checked all three paths) — acceptance verification unavailable" >&2; exit 1; }
```

Walk through the full review lifecycle checklist in order. At each step, check if it's already been completed. Stop at the first incomplete step and execute it, then continue to the next step. Keep going until the workflow is complete or a blocking condition is hit.

---

## Step 0b: Identify context

Reached only from Step 0's `unplanned` or `token_exhaustion` dispatch — the interrupted-review-workflow lane.

```bash
BRANCH=$(git branch --show-current)
echo "Branch: $BRANCH"
```

If on `main`, stop: `nothing to resume — on main, no interrupted workflow for this checkout` (rank 4; change no state).

Check if a PR exists:
```bash
gh pr view --json number,title,headRefName,state 2>/dev/null
```

Determine the {owner}/{repo} from git remote:
```bash
gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"'
```

> **Authorship guard (issue #733, `safety.md`).** `/go-on` resumes a write workflow (push, review triggers, thread resolution, merge). Confirm you authored the PR before resuming any write step:
> ```bash
> PR_NUM=$(gh pr view --json number --jq .number 2>/dev/null)
> [ -n "$PR_NUM" ] && "$PR_AUTHORSHIP_SH" "$PR_NUM"   # exit 0 = yours
> ```
> Not yours (exit 1) or undetermined (exit 4) → `[BLOCKED]`: "PR #$PR_NUM is not yours — the authorship guard blocks automated writes; name it explicitly to override." Proceed only under an explicit per-PR user override (say you are operating under it). Read-only status inspection is fine.

---

## Step 1: Check for an inherited rebase / conflict resolution (issue #757)

**Run this before Step 1b and before any commit or push.** The incident that motivated this guard was exactly a resumed session: an interrupted rebase left a resolution with no conflict markers that was nonetheless byte-identical to main — the whole fix the PR existed to deliver had been silently dropped, and every other gate (clean status, green CI, review) passed it.

```bash
GUARD="$DIFF_SURVIVAL_SH"
REBASE_IN_PROGRESS=0
{ [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; } && REBASE_IN_PROGRESS=1
SNAPSHOT_PRESENT=$("$GUARD" status --json | jq -r '.present')
```

- **Neither** a rebase in progress nor a snapshot on disk → `[SKIP]` — no inherited resolution to verify. Go to Step 1b.
- **Otherwise** (mid-rebase, or a snapshot left by a just-completed rebase) → `[ACTION]`:

  ```bash
  "$GUARD" snapshot --if-absent   # mid-rebase this reconstructs from orig-head, not the half-replayed HEAD
  "$GUARD" verify; GUARD_RC=$?
  ```

  - `0` — `[DONE]` diff survived the resolution; continue. (`deferred` also exits 0: commits are still queued for replay — finish the rebase, then re-run before pushing.)
  - `1` — `[BLOCKED]` the branch's entire diff vanished. Report the guard's output verbatim, including its one legitimate case (main independently landed the identical change → **close the PR**, never force-push an empty branch). Do not commit, push, or "fix" anything.
  - `2` — `[BLOCKED]` name the files that lost their changes and stop. This is an **unresolved conflict**, not a resumable state — re-resolve those files (whitespace-only survival still counts as lost), then re-run.
  - `4` — two shapes, both stop-and-report:
    - `unresolved_conflicts` → `[ACTION]` finish the resolution (optionally via `/merge-conflict`), then re-run `verify` before continuing.
    - `unverifiable` → `[BLOCKED]` the snapshot's baseline commit *is* the commit being checked, so it proves nothing. This is what a **just-completed** rebase with no snapshot looks like: a baseline cannot be reconstructed after the fact (`--if-absent` only reconstructs from `orig-head` while the rebase is still in progress). Say plainly that the resolution **cannot be verified**, and let the user decide — never report it as clean.
  - `5` — no snapshot could be established at all → `[BLOCKED]`: same handling as `unverifiable`. Never proceed silently on an unverifiable resolution.

  The guard never repairs; `git rebase --abort` or resetting to `ORIG_HEAD` stays the user's call. After a verified push completes, `"$GUARD" clear` retires the snapshot.

---

## Step 1b: Check for uncommitted changes

```bash
git status --porcelain
```

- If there are uncommitted changes: `[ACTION]` — Stage and commit changes. Ask the user for a commit message if the changes are ambiguous, otherwise use a descriptive message based on the diff.
- If clean: `[DONE]` — No uncommitted changes.
