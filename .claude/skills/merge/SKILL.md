---
name: merge
description: Squash merge the current PR. Verifies merge gate and acceptance criteria before merging.
---

Squash merge the current PR. This is the "we're done here" command.

## Portable helper resolution

Resolve all required helpers before Step 1. A missing helper blocks the merge rather than silently weakening its gate.

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
PR_AUTHORSHIP_SH=$(resolve_script pr-authorship.sh || true)
MERGE_GATE_SH=$(resolve_script merge-gate.sh || true)
AC_CHECKBOXES_SH=$(resolve_script ac-checkboxes.sh || true)
CI_STATUS_SH=$(resolve_script ci-status.sh || true)
MAIN_SYNC_SH=$(resolve_script main-sync.sh || true)
[[ -n "$PR_AUTHORSHIP_SH" ]] || { echo "ERROR: pr-authorship.sh not found (checked all three paths) — merge authorship gate unavailable" >&2; exit 1; }
[[ -n "$MERGE_GATE_SH" ]] || { echo "ERROR: merge-gate.sh not found (checked all three paths) — merge gate unavailable" >&2; exit 1; }
[[ -n "$AC_CHECKBOXES_SH" ]] || { echo "ERROR: ac-checkboxes.sh not found (checked all three paths) — acceptance verification unavailable" >&2; exit 1; }
[[ -n "$CI_STATUS_SH" ]] || { echo "ERROR: ci-status.sh not found (checked all three paths) — CI diagnosis unavailable" >&2; exit 1; }
[[ -n "$MAIN_SYNC_SH" ]] || { echo "ERROR: main-sync.sh not found (checked all three paths) — post-merge main sync unavailable" >&2; exit 1; }
```

## When to use /merge vs /wrap

- Use **/merge** for a quick mid-session merge when you'll continue working in the same session. It handles AC verification, CI check, and squash-merge — nothing else.
- Use **/wrap** for end-of-session cleanup. /wrap is a superset: runs the same merge flow PLUS detects follow-up issues, extracts session lessons, and syncs root `main`.
- If you're done for the session, use /wrap. If you're merging and immediately starting the next issue, use /merge.
- Note: /merge aborts if invoked from inside a worktree (see Step 1) — use /wrap in that case because it can run from the active worktree and leaves stale worktree/branch cleanup to `/pm-update`.

## Steps

### Step 1: Identify the PR

```bash
gh pr view --json number,title,headRefName,body,state --jq '{number, title, headRefName, body, state}'
```

If no PR exists on the current branch, stop and tell the user: "No PR found for the current branch. Push and create a PR first."

If the PR is already merged or closed, stop and tell the user.

> **Authorship guard (issue #733, `safety.md`).** A merge is a write, so `/merge` acts only on PRs **you** authored. Confirm before merging:
> ```bash
> "$PR_AUTHORSHIP_SH" "$PR_NUM"   # exit 0 = yours
> ```
> If it is not yours (exit 1) or undetermined (exit 4), **refuse** with one line — "PR #$PR_NUM is authored by someone else — the authorship guard blocks automated merges; name this PR explicitly to override" — unless the user named this specific PR in chat this session (per-PR override; say you are operating under it, and pass `--allow-nonauthor` to `merge-gate.sh`). `merge-gate.sh` also blocks a confirmed foreign author as a fail-safe.

**Worktree check:** If running inside a git worktree where the feature branch is checked out, `git branch -D` will fail even after checking out away — git refuses to delete a branch checked out in any worktree. Detect this and abort early:

```bash
if [ "$(git rev-parse --git-common-dir)" != "$(git rev-parse --git-dir)" ]; then
  echo "Running inside a worktree. Use /wrap instead — it merges safely from the worktree and leaves cleanup to /pm-update."
  exit 1
fi
```

If running in a worktree, stop here and use the message from the Worktree check above.

### Step 2: Verify the merge gate

> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read the cached JSON bundle. This skill delegates to `merge-gate.sh`, which calls `pr-state.sh` internally — do not add inline `gh api` calls to these three endpoints.

Run the shared merge-gate verifier, which implements the authoritative gate from `.claude/rules/cr-merge-gate.md` (CR 1 explicit APPROVED review on current HEAD / BugBot 1-clean / Greptile severity, plus CI and BEHIND checks):

```bash
PR_NUM=$(gh pr view --json number --jq .number)
GATE_JSON=$("$MERGE_GATE_SH" "$PR_NUM")
GATE_EXIT=$?
```

- Exit `0` → gate met, proceed.
- Exit `1` → gate NOT met. Stop and report the `missing` array from the JSON output verbatim (e.g., "need 1 explicit CR APPROVED review on HEAD", "Greptile has P0 finding", "branch is BEHIND base").
- Exit `3` → PR not found (already merged/closed). Stop.
- Exit `2`/`4` → script or gh error; surface the stderr message to the user.

If `missing` says branch protection `reviewDecision` is not `APPROVED` and `.code_owner_bots` lists `coderabbitai[bot]` or `greptile-apps[bot]`, do not ask the PR author to approve. Trigger the matching bot re-review (`@coderabbitai full review` or `@greptileai`) and wait for a fresh current-HEAD approval.

Reviewer assignment is resolved automatically from `~/.claude/session-state.json` and live history. Pass `--reviewer cr|bugbot|greptile` to override.

### Step 3: Verify acceptance criteria

Use the shared `ac-checkboxes.sh` helper to parse and tick Test Plan items. All Test Plan checkboxes must be checked off before proceeding. If any fail verification, stop and report — do NOT merge with unchecked boxes.

```bash
# 1. Extract items (JSON array of {index, checked, text})
ITEMS=$("$AC_CHECKBOXES_SH" "$PR_NUM" --extract)
AC_EXIT=$?
```

Exit codes from `--extract`:
- `0` → `$ITEMS` is a JSON array. Verify each unchecked item against the code, then tick the ones that pass.
- `1` → no Test Plan section. Stop and tell the user: "PR has no Test Plan section — cannot verify acceptance criteria."
- `3` → PR not found. Stop.
- `2` → internal script error. Surface stderr (`[script-error]`) and stop.

After verification, tick passing items — and **capture the tick exit code**:

```bash
"$AC_CHECKBOXES_SH" "$PR_NUM" --tick "0,2,3"  # or --all-pass
TICK_EXIT=$?
```

Exit codes from `--tick`/`--all-pass`:
- `0` → body updated (or noop — nothing to tick). Proceed.
- `4` → `gh pr edit` failed. Surface stderr (`[gh-error]`) and stop — do NOT merge.
- `2` / other non-zero → internal script error. Surface stderr and stop.

If any item fails verification, do NOT tick it — stop and report the failure. Do NOT merge with any unchecked AC.

### Step 4: CI verification (handled by Step 2)

`merge-gate.sh` already verifies CI as part of the gate — a gate-passing PR has all check-runs complete with no blocking conclusions. If Step 2 exited `0`, CI is green and you can proceed to merge.

If Step 2 reported `missing` entries about CI ("CI has N failing check-run(s): ..." or "CI has N incomplete check-run(s): ..."), **do NOT merge**. Instead:

1. Inspect the CI split: `"$CI_STATUS_SH" "$PR_NUM" --format summary` (exit `3` = blocking failures, exit `1` = incomplete). For the JSON with failing check-run IDs, drop `--format summary`.
2. Read a specific failure's output: `gh api "repos/{owner}/{repo}/check-runs/{CHECK_RUN_ID}" --jq '.output.summary'`
3. Fix the issue (lint errors, type errors, test failures, etc.)
4. Commit, push, and wait for CI to re-run
5. Re-run `"$MERGE_GATE_SH" "$PR_NUM"` to confirm CI is green before proceeding

**Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, or any suppression comment to work around CI.** Fix the actual code.

### Step 5: Squash merge

**Merge execution:** After Steps 2–3 pass, run `gh pr merge --squash` with no pre-merge prompt — per `CLAUDE.md` "PR MERGE AUTHORIZATION" and `cr-merge-gate.md` Step 3. Gate/CI/AC/worktree failures still stop as above. `/merge` skips `/wrap`'s follow-ups and lessons only.

```bash
gh pr merge --squash
```

Do NOT use `--delete-branch`. That flag attempts local branch deletion immediately, which fails when run from a worktree (the branch is still checked out). Handle branch cleanup in Step 5a below.

### Step 5a: Delete the branches

```bash
BRANCH_NAME=$(gh pr view --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view --json baseRefName --jq '.baseRefName')
```

**Local branch** — must use `-D` (force), not `-d`. Squash merges rewrite history so the branch commits are not reachable from `main` and `-d` always fails post-squash.

If currently on the feature branch, check out the base branch first (can't delete the branch you're on):

```bash
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" = "$BRANCH_NAME" ]; then
  git checkout "$BASE_BRANCH"
fi
git branch -D "$BRANCH_NAME" || echo "Warning: local branch deletion failed (may already be deleted) — skipping"
```

**Remote branch** — treat failure as non-fatal (branch may already be deleted by GitHub's auto-delete-on-merge, by `/wrap` if run previously, or due to permissions/network):

```bash
git push origin --delete "$BRANCH_NAME" || echo "Warning: remote branch deletion failed (may already be deleted) — skipping"
```

### Step 5b: Sync local main

After merging, update the local `main` so subsequent sessions branch from the latest code. **Capture the result for the completion report in Step 6.**

```bash
# .claude/scripts/main-sync.sh writes the status line to stdout and exits
# 0 OK / 1 skipped (uncommitted) / 2 failed (checkout/pull). All three
# outcomes are captured here for the completion report — a non-zero exit
# is not a hard error for /merge, just a report-worthy condition.
MAIN_SYNC_STATUS=$("$MAIN_SYNC_SH" 2>&1 || true)
echo "Main sync: $MAIN_SYNC_STATUS"
```

Note: `/merge` only runs outside worktrees (Step 1 aborts in worktrees), so we should be on `main` after Step 5a's checkout. The helper's internal checkout-main guard handles edge cases. The `post-merge-pull.sh` hook also fires as a safety net, but this explicit step captures the result for reporting. See `main-sync.sh --help` for the full contract.

### Step 6: Report completion

Tell the user:
- PR number and title
- Merge SHA
- Main branch {MAIN_SYNC_STATUS from Step 5b — e.g. "updated abc1234 → def5678", "up to date (abc1234)", or "failed: ..."}
- Branch deleted
