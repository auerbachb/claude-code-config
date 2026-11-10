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
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/$name}" \
    "${HOME:+$HOME/.claude/scripts/$name}" \
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
MERGE_TARGET_ROOT_SH=$(resolve_script merge-target-root.sh || true)
PAID_GRANT_SH=$(resolve_script paid-review-grant.sh || true)  # optional: owner-approved paid reviews (#1898)
[[ -n "$PR_AUTHORSHIP_SH" ]] || { echo "ERROR: pr-authorship.sh not found (checked all three paths) — merge authorship gate unavailable" >&2; exit 1; }
[[ -n "$MERGE_GATE_SH" ]] || { echo "ERROR: merge-gate.sh not found (checked all three paths) — merge gate unavailable" >&2; exit 1; }
[[ -n "$AC_CHECKBOXES_SH" ]] || { echo "ERROR: ac-checkboxes.sh not found (checked all three paths) — acceptance verification unavailable" >&2; exit 1; }
```

## When to use /merge vs /wrap

- Use **/merge** for a quick mid-session merge when you'll continue working in the same session. It handles AC verification, CI check, and squash-merge — nothing else.
- Use **/wrap** for end-of-session cleanup. /wrap is a superset: runs the same merge flow PLUS detects follow-up issues, extracts session lessons, and syncs root `main`.
- If you're done for the session, use /wrap. If you're merging and immediately starting the next issue, use /merge.
- Note: /merge aborts if invoked from inside a worktree (see Step 1) — use /wrap in that case because it can run from the active worktree and leaves stale worktree/branch cleanup to `/pm-clean`.

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
  echo "Running inside a worktree. Use /wrap instead — it merges safely from the worktree and leaves cleanup to /pm-clean."
  exit 1
fi
```

If running in a worktree, stop here and use the message from the Worktree check above.

### Bind the physical clone before merge work

Use the absolute invocation/worktree path from this chat's workspace context, an explicit caller path, or a validated delegated handoff that matches this PR, repository, HEAD and holder. Set `MERGE_SOURCE_PATH` from that trusted context; never recover it from a later `pwd` or a shared per-repository/per-PR `.root_repo` hint. A remote identity cannot distinguish two clones of the same repository. Resolve `MERGE_PR_URL` from the identified PR's native `url` field, using that exact PR/repository rather than a later current-branch lookup.

<!-- test-anchor: merge-merge-root-binding -->

```bash
MERGE_BOUND_ROOT=""
MERGE_BOUND_PR_URL="${MERGE_PR_URL:-}"
MERGE_ROOT_BINDING_STATUS="failed: explicit clone binding unavailable"
if [[ -n "$MERGE_TARGET_ROOT_SH" ]]; then
  MERGE_BIND_RC=0
  MERGE_BOUND_ROOT=$("$MERGE_TARGET_ROOT_SH" --repo-path "${MERGE_SOURCE_PATH:-}" \
    --pr-url "${MERGE_BOUND_PR_URL:-}" 2>/dev/null) || MERGE_BIND_RC=$?
  if [[ "$MERGE_BIND_RC" -eq 0 && -n "$MERGE_BOUND_ROOT" ]]; then
    MERGE_ROOT_BINDING_STATUS="bound"
  else
    MERGE_BOUND_ROOT=""
    MERGE_ROOT_BINDING_STATUS="failed: explicit clone binding invalid or unreadable (rc=$MERGE_BIND_RC)"
  fi
fi
```

Carry `MERGE_BOUND_ROOT` and `MERGE_BOUND_PR_URL` unchanged across later tool calls and delegated `/fixpr` work; persist them in the validated run handoff when handing off this invocation. On resume without that binding, keep local mutations skipped. Never repopulate it from whatever clone the tool happens to enter. Binding failure does not undo or bypass the remote merge gate; it makes post-merge local cleanup/sync report a failure without mutating a guessed clone.

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

If `missing` says branch protection `reviewDecision` is not `APPROVED` and `.code_owner_bots` lists `coderabbitai[bot]` or `greptile-apps[bot]`, do not ask the PR author to approve. Trigger only a listed bot that can satisfy the code-owner requirement: `coderabbitai[bot]` listed → `@coderabbitai full review` unless the PR's review tier excludes CodeRabbit (`review-triggers-allowed.sh <PR>` in `tiered` mode not allowing `coderabbit`, as `ci-only`/`ci+codeant-one-round` do — then report the blocker), then wait for a fresh current-HEAD approval. When `greptile-apps[bot]` is the bot the requirement needs, a Greptile re-review (`@greptileai`) is paid — post it only under an owner grant, through `"$PAID_GRANT_SH" --trigger <PR> --vendor greptile` (issues #1897, #1898; `.claude/reference/paid-review-approval.md`); without one — or with `PAID_GRANT_SH` empty (`ERROR: paid-review-grant.sh not found (checked all three paths)`) — stop and report the blocker.

Reviewer assignment is resolved automatically from `~/.claude/session-state.json` and live history. Pass `--reviewer cr|bugbot|greptile` to `merge-gate.sh` to override — those three are `merge-gate.sh`'s complete set (it rejects anything else with exit `2`), and it is a different flag from `reply-thread.sh`'s `--reviewer cr|bugbot|greptile|codeant|graphite` (graphite kept only while the retired App still posts).

### Step 3: Verify acceptance criteria

Before acceptance verification, bind `AC_VERIFIED_HEAD` to the Step 2 gate’s `head_sha` and carry it into Step 5.

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

1. If `CI_STATUS_SH` resolved, inspect the CI split with `"$CI_STATUS_SH" "$PR_NUM" --format summary` (exit `3` = blocking failures, exit `1` = incomplete). For the JSON with failing check-run IDs, drop `--format summary`. If it is empty, emit `DEGRADED: ci-status.sh not found (checked all three paths) — detailed CI diagnosis unavailable, continuing with merge-gate evidence` and use the gate's `missing` entry plus GitHub check logs; the failed gate still blocks merging.
2. Read a specific failure's output: `gh api "repos/{owner}/{repo}/check-runs/{CHECK_RUN_ID}" --jq '.output.summary'`
3. Fix the issue (lint errors, type errors, test failures, etc.)
4. Commit, push, and wait for CI to re-run
5. Re-run `"$MERGE_GATE_SH" "$PR_NUM"` to confirm CI is green before proceeding

**Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, or any suppression comment to work around CI.** Fix the actual code.

### Step 5: Squash merge

**Merge execution:** After Steps 2–3 pass, run `gh pr merge --squash` with no pre-merge prompt — per `CLAUDE.md` "PR MERGE AUTHORIZATION" and `cr-merge-gate.md` Step 3. Gate/CI/AC/worktree failures still stop as above. `/merge` skips `/wrap`'s follow-ups and lessons only.

The reviewed path runs `gh pr merge "$PR_NUM" --repo "$CURRENT_REPO" --squash` after the unused-snapshot check below.

**No-review override (issue #1899).** When `.no_review_override.applied == true`, replace the plain merge above. First **re-run `merge-gate.sh` into the gate JSON** after AC verification. Bind `CURRENT_REPO` to the repository from the verified PR URL. Require a met override and the refreshed merge state permitted in [wrap Step 2.4](../wrap/SKILL.md#step-24-squash-merge). Execute its `wrap-no-review-override-merge` boundary with the full refreshed JSON. Once GitHub confirms the merge, execute `wrap-record-no-review-merge` and relay its report suffix. Before a reviewed merge, run the unused-snapshot discard check from the same step. If recording fails, retain the snapshot and retry through /wrap's already-merged entry. See [the ledger contract](../../reference/no-review-override.md).

Do NOT use `--delete-branch`. That flag attempts local branch deletion immediately, which fails when run from a worktree (the branch is still checked out). Handle branch cleanup in Step 5a below.

### Step 5a: Delete the branches

The branch metadata comes from the exact bound PR URL, never a current-branch lookup after a cwd change. Require its native state to be `MERGED`. Run local checkout/deletion and the existing remote deletion only in the physical root bound above, in the same Bash call as the guard; a changed cwd skips cleanup. A skipped cleanup leaves the branch for `/pm-clean`.

<!-- test-anchor: merge-bound-branch-cleanup -->

```bash
MERGE_CLEANUP_ROOT=""
if [[ -n "$MERGE_TARGET_ROOT_SH" && -n "${MERGE_BOUND_ROOT:-}" && -n "${MERGE_BOUND_PR_URL:-}" ]]; then
  MERGE_CLEANUP_ROOT=$("$MERGE_TARGET_ROOT_SH" --repo-path "$MERGE_BOUND_ROOT" \
    --pr-url "$MERGE_BOUND_PR_URL" 2>/dev/null) || MERGE_CLEANUP_ROOT=""
fi
if [[ -n "$MERGE_CLEANUP_ROOT" && "$MERGE_CLEANUP_ROOT" == "${MERGE_BOUND_ROOT:-}" \
      && "$(pwd -P)" == "$MERGE_CLEANUP_ROOT" ]]; then
  MERGED_BRANCH_JSON=$(gh pr view "$MERGE_BOUND_PR_URL" --json state,headRefName,baseRefName 2>/dev/null) || MERGED_BRANCH_JSON=""
  if printf '%s' "$MERGED_BRANCH_JSON" | jq -e '
    type == "object" and .state == "MERGED" and
    (.headRefName | type == "string" and length > 0) and
    (.baseRefName | type == "string" and length > 0)
  ' >/dev/null 2>&1; then
    BRANCH_NAME=$(printf '%s' "$MERGED_BRANCH_JSON" | jq -r '.headRefName')
    BASE_BRANCH=$(printf '%s' "$MERGED_BRANCH_JSON" | jq -r '.baseRefName')
    CURRENT_BRANCH=$(git branch --show-current)
    CLEANUP_CHECKOUT_OK=1
    if [[ "$CURRENT_BRANCH" == "$BRANCH_NAME" ]]; then
      git checkout "$BASE_BRANCH" -- || CLEANUP_CHECKOUT_OK=0
    fi
    if [[ "$CLEANUP_CHECKOUT_OK" -eq 1 && -n "$BRANCH_NAME" && "$BRANCH_NAME" != "$BASE_BRANCH" ]]; then
      git branch -D -- "$BRANCH_NAME" || echo "Warning: local branch deletion failed — skipping"
      git push origin --delete "$BRANCH_NAME" || echo "Warning: remote branch deletion failed — skipping"
    fi
  else
    echo "Warning: bound PR is not confirmed merged — branch cleanup skipped"
  fi
else
  echo "Warning: physical cwd differs from bound clone or binding invalid — branch cleanup skipped"
fi
```

### Step 5b: Sync local main

After merging, update the local `main` so subsequent sessions branch from the latest code. **Capture the result for the completion report in Step 6.**

<!-- test-anchor: merge-bound-main-sync -->

```bash
MERGE_SYNC_ROOT=""
if [[ -n "$MERGE_TARGET_ROOT_SH" && -n "${MERGE_BOUND_ROOT:-}" && -n "${MERGE_BOUND_PR_URL:-}" ]]; then
  MERGE_SYNC_ROOT=$("$MERGE_TARGET_ROOT_SH" --repo-path "$MERGE_BOUND_ROOT" \
    --pr-url "$MERGE_BOUND_PR_URL" 2>/dev/null) || MERGE_SYNC_ROOT=""
  [[ "$MERGE_SYNC_ROOT" == "$MERGE_BOUND_ROOT" ]] || MERGE_SYNC_ROOT=""
fi
if [[ -z "$MERGE_SYNC_ROOT" ]]; then
  MAIN_SYNC_STATUS="failed: bound clone unavailable or identity changed; local mutation skipped"
elif [[ -z "$MAIN_SYNC_SH" ]]; then
  MAIN_SYNC_STATUS="DEGRADED: main-sync.sh not found (checked all three paths) — post-merge main sync unavailable"
else
  MAIN_SYNC_RC=0
  MAIN_SYNC_STATUS=$("$MAIN_SYNC_SH" --repo "$MERGE_SYNC_ROOT" 2>&1) || MAIN_SYNC_RC=$?
  if [[ "$MAIN_SYNC_RC" -ne 0 ]] && ! [[ "$MAIN_SYNC_STATUS" == aborted:* || "$MAIN_SYNC_STATUS" == skipped:* ]]; then
    MAIN_SYNC_STATUS="failed(rc=$MAIN_SYNC_RC): $MAIN_SYNC_STATUS"
  fi
fi
echo "Main sync: $MAIN_SYNC_STATUS"
```

`/merge` only runs outside worktrees. A cwd change may skip Step 5a, so Step 5b revalidates and passes the original physical root explicitly; it never relies on that checkout or current cwd. The helper's internal checkout-main guard handles edge cases. The `post-merge-pull.sh` hook also fires as a safety net, but this explicit step captures the result for reporting. See `main-sync.sh --help` for the full contract.

### Step 6: Report completion

Tell the user:
- PR number and title
- Merge SHA
- Main branch {MAIN_SYNC_STATUS from Step 5b — e.g. "updated abc1234 → def5678", "up to date (abc1234)", or "failed: ..."}
- Branch deleted
