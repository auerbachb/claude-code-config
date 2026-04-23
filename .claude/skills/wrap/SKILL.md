---
name: wrap
description: End-of-session command — verify no unresolved findings, squash merge, detect follow-ups, extract lessons, sync work-log, and clean up the worktree.
---

Wrap up the current PR and session. This is the "we're done here" command that handles everything from final verification through worktree cleanup.

## When to use /wrap vs /merge

- Use **/wrap** at end-of-session. Handles merge + follow-up detection + lessons + work-log sync + worktree cleanup in one command.
- Use **/merge** for a quick mid-session merge when you'll keep working. Skips the cleanup steps and only runs outside worktrees.
- /wrap includes everything /merge does, plus the cleanup. Don't run both.

## Execution Model

`/wrap` is a set-and-forget command. Once invoked, it runs all 5 phases end-to-end without mid-run confirmation prompts. It stops early only for explicit stop conditions (for example: no PR on current branch, unresolved findings, failed merge gate, CI failure, AC verification failure, or rebase detected).

> **Always:** Execute all phases end-to-end; proceed immediately between phases when no blocker exists.
> **Ask first:** Never — all phases are autonomous once /wrap is invoked.
> **Never:** Stop to ask "should I continue?" between phases; insert confirmation prompts for non-blocker transitions.

### Phase Transition Autonomy

| Transition | Action | Classification |
|------------|--------|----------------|
| Phase 1 complete (no unresolved findings) | Begin Phase 2 | **Always do** |
| Phase 2 complete | Begin Phase 3 | **Always do** |
| Phase 3 follow-ups processed | Begin Phase 4 | **Always do** |
| Phase 4 lessons complete (or skipped as trivial) | Begin Phase 5 | **Always do** |
| Phase 5 cleanup complete | Output Step 5.4 final report | **Always do** |
| Unresolved reviewer findings detected (Phase 1) | Stop and report | **Stop and report** |
| Merge gate not met (Phase 2.1) | Stop and report | **Stop and report** |
| AC checkbox verification fails (Phase 2.2) | Stop and report | **Stop and report** |
| SHA changed / rebase / CI failure / BEHIND (Phase 2.3) | Stop and report | **Stop and report** |

> **Anti-pattern:** If you find yourself composing "Should I proceed?" or presenting a confirmation button, the answer is always yes — execute immediately.

## Phase 1: Pre-Merge Verification — Check for Unresolved Findings

Before merging, verify that all reviewer feedback has been addressed.

### Step 1.1: Identify the PR

```bash
gh pr view --json number,title,headRefName,body,state --jq '{number, title, headRefName, body, state}'
```

If no PR exists on the current branch, stop: "No PR found for the current branch."
If the PR is already merged or closed, skip to Phase 3 (follow-up detection).

### Step 1.2: Scan for unresolved review findings

Use the shared `pr-state.sh` helper to fetch and pre-classify review activity from all three endpoints in one call. It filters to `coderabbitai[bot]`, `greptile-apps[bot]`, and `cursor[bot]` (BugBot) and tags each comment with `classification.class` (`finding` vs `acknowledgment`). The classifier only runs when `--since <iso>` is passed — pass the PR's `createdAt` to include every bot comment on the PR. The helper writes the JSON bundle to a tempfile and prints its **path** on stdout — capture the path, then read with `jq < "$BUNDLE"`:

```bash
PR_NUM=$(gh pr view --json number --jq .number)
PR_CREATED=$(gh pr view "$PR_NUM" --json createdAt --jq '.createdAt')
BUNDLE=$(.claude/scripts/pr-state.sh --pr "$PR_NUM" --since "$PR_CREATED")
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

**If unresolved findings exist:** Report them to the user and stop. List each unresolved finding with its location and what it says. Do NOT proceed to merge.

**If all findings are addressed:** Continue to Phase 2.

If no unresolved findings: proceed immediately to Phase 2 — do not ask.

## Phase 2: Merge

### Step 2.1: Verify the merge gate

Run the shared merge-gate verifier, which implements the authoritative gate from `.claude/rules/cr-merge-gate.md` (CR 2-clean / BugBot 1-clean / Greptile severity, plus CI and BEHIND checks):

```bash
PR_NUM=$(gh pr view --json number --jq .number)
GATE_JSON=$(.claude/scripts/merge-gate.sh "$PR_NUM")
GATE_EXIT=$?
```

- Exit `0` → gate met, proceed.
- Exit `1` → gate NOT met. Stop and report the `missing` array from the JSON output verbatim (e.g., "need 2 clean CR reviews on HEAD", "branch is BEHIND base", "CI has 2 failing check-run(s): ...").
- Exit `3` → PR not found; skip to Phase 3 as described above.
- Exit `2`/`4` → script or gh error; surface the stderr message.

Also extract and store the feature branch name and base branch for use in Phase 5 cleanup:

```bash
BRANCH_NAME=$(gh pr view --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view --json baseRefName --jq '.baseRefName')
```

### Step 2.2: Verify acceptance criteria

Use the shared `ac-checkboxes.sh` helper to parse and tick Test Plan items:

```bash
# 1. Extract items (JSON: [{index, checked, text}, ...])
ITEMS=$(.claude/scripts/ac-checkboxes.sh "$PR_NUM" --extract)
AC_EXIT=$?
```

For each item with `checked == false`:

1. Read the criterion
2. Identify and read the relevant source files
3. Confirm the criterion is satisfied by the current code

Tick passing items by index (or use `--all-pass` if every unchecked item passed):

```bash
# Example: items 0, 2, 3 passed
.claude/scripts/ac-checkboxes.sh "$PR_NUM" --tick "0,2,3"
# Or: every unchecked item passed
.claude/scripts/ac-checkboxes.sh "$PR_NUM" --all-pass
```

Exit codes from the extract/tick calls:
- `0` OK — proceed.
- `1` no Test Plan section — stop: "PR has no Test Plan section — cannot verify acceptance criteria."
- `3` PR not found — stop.
- `2`/`4` script/gh error — surface stderr and stop.

If any item fails verification, do NOT tick it — stop and report the failure. Do NOT merge with unchecked boxes.

### Step 2.3: Pre-merge safety & CI (handled by Step 2.1)

`.claude/scripts/merge-gate.sh` already verifies:

- **Rebase/force-push safety** — the CR 2-clean-pass check requires reviews on the **current** HEAD, so any rebase invalidates the gate.
- **BEHIND base branch** — gate fails with "branch is BEHIND base" in `missing`; rebase + force-push and wait for fresh review before retrying.
- **CI** — all check-runs must be completed with non-blocking conclusions; failures surface as "CI has N failing check-run(s): ..." in `missing`.

If Step 2.1 exited `0`, these are already satisfied. If `missing` reported CI failures, **do NOT merge**. Inspect the CI split and read the specific failure:

```bash
.claude/scripts/ci-status.sh "$PR_NUM"             # JSON with blocking[].name + in_progress_runs[].name
.claude/scripts/ci-status.sh "$PR_NUM" --format summary
gh api "repos/{owner}/{repo}/check-runs/{CHECK_RUN_ID}" --jq '.output.summary'
```

`ci-status.sh` exits `3` on blocking failures (fix), `1` on incomplete runs (wait), `0` when CI is clean. Fix the code, commit, push, wait for CI to re-run, and re-invoke `.claude/scripts/merge-gate.sh`.

**Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, or any suppression comment to work around CI.** Fix the actual code.

### Step 2.4: Squash merge

```bash
gh pr merge --squash
```

Do NOT use `--delete-branch` here. That flag attempts local branch deletion while the worktree is still active, which fails because git refuses to delete a branch checked out in any worktree. Branch cleanup is handled explicitly in Phase 5 after the worktree is removed.

### Step 2.5: Sync root repo main

After merging, update the root repo's local `main` so subsequent sessions branch from the latest code. **Capture the result for the final report in Step 5.4.**

```bash
# .claude/scripts/main-sync.sh --repo <path> writes the status line to
# stdout and exits 0 OK / 1 skipped (uncommitted) / 2 failed
# (checkout/pull). /wrap runs from inside a worktree, so we resolve the
# root repo explicitly and pass it via --repo. A non-zero exit from the
# helper is not a hard error here — the status line is captured for the
# final report regardless.
ROOT_REPO=$(.claude/scripts/repo-root.sh 2>/dev/null || true)
MAIN_SYNC_STATUS=""
if [ -z "$ROOT_REPO" ] || [ ! -d "$ROOT_REPO" ]; then
  MAIN_SYNC_STATUS="failed: could not determine root repo path"
else
  MAIN_SYNC_STATUS=$(bash .claude/scripts/main-sync.sh --repo "$ROOT_REPO" 2>&1 || true)
fi
echo "Main sync: $MAIN_SYNC_STATUS"
```

See `.claude/scripts/main-sync.sh --help` for the full contract.

Store `MAIN_SYNC_STATUS` for the final report — this value MUST appear in Step 5.4 output.

### Step 2.6: Log to work-log

If a work-log directory was detected at session start:

1. Reconstruct the cycle count from PR history:
   ```bash
   CYCLES=$(.claude/scripts/cycle-count.sh "$PR_NUM")
   ```
   The script counts one cycle per review followed by at least one commit before the next review (or merge). Clean passes and confirmation reviews do not count. Default mode includes all reviewers; see `.claude/scripts/cycle-count.sh --help` for flags.

2. Append to today's session log:
   ```
   - {time} ET — PR #{N} merged (Issue #{M}): {1-line summary} [opened: {open_time}, merged: {merge_time}, cycles: {count}]
   ```

After work-log entry: proceed immediately to Phase 3 — do not ask.

## Phase 3: Follow-Up Detection and Creation

Detect related work that needs attention for feature completeness, then **auto-create GitHub issues** for each follow-up (with deduplication and HHG two-ticket pattern awareness).

### Step 3.1: Detect follow-up items

1. Extract the linked issue number from the PR body (`Closes #N` pattern) and fetch its title and body:
   ```bash
   ISSUE_N=$(gh pr view --json body --jq '.body' | grep -oiE 'closes #[0-9]+' | head -1 | grep -oE '[0-9]+')
   ISSUE_TITLE=$(gh issue view "$ISSUE_N" --json title --jq '.title' 2>/dev/null || echo "")
   ISSUE_BODY=$(gh issue view "$ISSUE_N" --json body --jq '.body' 2>/dev/null || echo "")
   PR_TITLE=$(gh pr view --json title --jq '.title')
   PR_NUMBER=$(gh pr view --json number --jq '.number')
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

Collect each detected follow-up as a `{title, body, keywords}` record. `keywords` is a short phrase (2-5 words) used for the dedup search.

### Step 3.2: HHG two-ticket pattern detection

If the PR title, linked issue title, or linked issue body contains "HHG" (case-insensitive), **override** any generic follow-ups with exactly **two** HHG follow-ups (scraping + ETL). This codifies the pattern from `feedback_split_hhg_issues.md` — HHG work always splits into one scraping ticket and one ETL ticket.

```bash
HHG_MATCH=$(printf '%s\n%s\n%s\n' "$PR_TITLE" "$ISSUE_TITLE" "$ISSUE_BODY" | grep -iE 'HHG' || true)
if [ -n "$HHG_MATCH" ]; then
  # Extract a 2-letter US state code from PR title, issue title, or issue
  # body. `.claude/scripts/hhg-state.sh` restricts to the 50 USPS codes so
  # unrelated 2-letter tokens (e.g. "CI", "PR") don't match, prefers a state
  # adjacent to "HHG", and falls back to the first state match elsewhere.
  # Exits 0 when a state is found (code on stdout), 1 when none match — the
  # `|| true` keeps the pipeline from tripping `set -e` on the no-match path.
  COMBINED=$(printf '%s %s %s' "$PR_TITLE" "$ISSUE_TITLE" "$ISSUE_BODY")
  STATE=$(.claude/scripts/hhg-state.sh "$COMBINED" || true)
  if [ -z "$STATE" ]; then
    STATE=""
    echo "WARNING: HHG PR detected but no state code found in PR title, issue title, or issue body — skipping HHG auto-creation. Create the scraping and ETL issues manually once you know the state."
  fi
fi
```

**If `STATE` is empty (no state code found), skip HHG auto-creation entirely** — do NOT create issues with placeholder titles like `UNKNOWN HHG — ...` (they are confusing in the tracker and require manual renaming). Report the skip in Step 3.4 so the user knows to create the issues manually.

The two HHG follow-up titles are:
1. `{STATE} HHG — Export carriers and run scraper`
2. `{STATE} HHG — Seed product codes and load scrape results to Neon`

**Create the scraping issue first**, capture its number as `SCRAPE_NUM`, then create the ETL issue with `Depends on #${SCRAPE_NUM}` in its body so the dependency is explicit and the ETL task cannot be orphaned. If the scraping issue was deduped to an existing open issue, use that existing number as `SCRAPE_NUM`.

Each body should reference the source PR (`Follow-up from PR #{PR_NUMBER}`) and include any scraping/ETL context from the parent issue body. The ETL issue body must also include a `Depends on #${SCRAPE_NUM}` line.

**HHG override trade-off:** The HHG pair replaces any generic follow-ups detected in Step 3.1 to keep the two-ticket pattern clean. If an HHG PR also has unrelated follow-ups (e.g., a docs TODO), they are silently dropped — maintainers should create those manually. If this becomes a pain point, extend Step 3.3 to run the HHG pair and any non-scraping/non-ETL generic items through dedup+create together instead of replacing the generic list wholesale.

### Step 3.3: Dedup check and create

For each follow-up item (the HHG pair or the generic list):

1. **Dedup check** — search for an existing open issue with matching keywords in the title. **Guard against empty keywords**: an empty search string returns every open issue and would silently block creation of the follow-up.
   ```bash
   if [ -z "$KEYWORDS" ]; then
     DUP_NUM=""  # no keywords → skip dedup, always create
   else
     DUP_NUM=$(gh issue list --search "${KEYWORDS} in:title" --state open --json number,title --jq '.[0].number // empty')
   fi
   ```
   If `DUP_NUM` is non-empty, skip creation and record the item as `skipped (dup of #{DUP_NUM})` in the report.

2. **Create the issue** (only if no duplicate found). Check the exit status and validate the parsed number before logging — if creation fails or the URL doesn't parse, record the failure in the report and continue with the next item. **Guard the `Linked source` line** — only include it when `ISSUE_N` is non-empty, otherwise the body will render a broken `#` reference on GitHub:
   ```bash
   LINKED_SOURCE=""
   if [ -n "$ISSUE_N" ]; then
     LINKED_SOURCE=$'\n\n'"Linked source: #${ISSUE_N}"
   fi
   if NEW_URL=$(gh issue create \
     --title "{derived title}" \
     --body "Follow-up from PR #${PR_NUMBER}.

   {context from detection}${LINKED_SOURCE}" 2>&1); then
     NEW_NUM=$(echo "$NEW_URL" | grep -oE '[0-9]+$')
     if [ -z "$NEW_NUM" ]; then
       echo "WARNING: created issue but could not parse number from: $NEW_URL"
       # record as failure and continue
     fi
   else
     echo "WARNING: gh issue create failed: $NEW_URL"
     # record as failure and continue — do not abort Phase 3
   fi
   ```

3. **Log to work-log** — if a work-log directory was detected at session start, append a timestamped line to today's session log for each created issue using the **canonical** format from `work-log.md` (use the same path logic as Phase 2.6):
   ```
   - {time} ET — Issue #{NEW_NUM} created: {title}
   ```
   Do not add a PR suffix to the log line — the PR linkage belongs in the issue body and the Step 3.4 report, not in the canonical work-log format. Skip logging entirely if no work-log directory exists.

**Non-HHG PRs still get generic follow-up creation** — any items collected in Step 3.1 that are not overridden by the HHG path go through the dedup + create + log flow above.

### Step 3.4: Report follow-ups

Present the results:

```
## Follow-ups

### Created
- Issue #{NEW_NUM}: {title}
- Issue #{NEW_NUM}: {title}

### Skipped (duplicates)
- "{title}" — already tracked in #{DUP_NUM}
```

If nothing was detected: "No follow-up items detected."
If HHG was detected but no state code was found (so auto-creation was skipped): append "⚠️ HHG detected but no state code found in PR/issue — auto-creation skipped. Create the scraping and ETL issues manually once you know the state."

After follow-up report: proceed immediately to Phase 4 — do not ask.

## Phase 4: Lessons Learned (Depth-Adaptive)

Determine the session depth to decide how thoroughly to reflect.

### Step 4.1: Assess session complexity

Calculate a complexity signal:
- **Cycle count** from Phase 2 (review-then-fix rounds)
- **Thread length** — count the number of user + assistant messages in the current session. "Short" = fewer than 15 total messages.
- **PR size** — number of files changed (`gh pr view N --json files --jq '.files | length'`)

**Trivial threshold:** cycle count = 0 AND conversation is short (you've been in this session for <15 messages) AND <5 files changed.

### Step 4.2: Run lessons (or skip)

**If trivial:** Output "Clean session — no lessons to capture." and skip to Phase 5.

**If non-trivial:** Reflect on the session:

1. What was the task? What was accomplished?
2. What went wrong or was harder than expected?
3. What patterns emerged (good or bad)?
4. Any surprises — tools behaving unexpectedly, edge cases, workflow friction?
5. Any workarounds that should be codified?

For each actionable, novel lesson:
- Check `MEMORY.md` for duplicates — update existing memories rather than creating new ones
- Write memory files with proper frontmatter (`feedback`, `project`, or `user` type)
- Add pointers to `MEMORY.md`

Present the summary:
```
## Session Lessons

### Saved to memory:
1. **<title>** — <summary> (saved as <type>)

### Observations (not saved):
- <things noted but not actionable>
```

After lessons (or skip): proceed immediately to Phase 5 — do not ask.

## Phase 5: Worktree Cleanup

### Step 5.1: Sync work-log to root repo

If a work-log was updated in Phase 2, sync it before removing the worktree:

```bash
ROOT_REPO=$(.claude/scripts/repo-root.sh 2>/dev/null || true)
if [ -z "$ROOT_REPO" ] || [ ! -d "$ROOT_REPO" ]; then
  echo "WARNING: could not resolve root repo — skipping work-log sync" >&2
else
  WORKTREE=$(pwd)
  # Compare and append any missing entries to root repo copy
  diff "$WORKTREE/$WORK_LOG_PATH/session-log-YYYY-MM-DD.md" "$ROOT_REPO/$WORK_LOG_PATH/session-log-YYYY-MM-DD.md"
fi
```

If the root repo's copy is missing entries, append them (do not overwrite the entire file).

### Step 5.2: Remove the worktree

Use `ExitWorktree` with `action: "remove"` to delete the worktree directory. This must happen **before** local branch deletion — git refuses to delete a branch that is currently checked out in any worktree.

If `ExitWorktree` reports uncommitted changes, discard them — by this point all meaningful work has been merged.

### Step 5.3: Delete the local branch

After the worktree is removed, the branch is no longer checked out anywhere and can be safely deleted. Run on the root repo:

```bash
CURRENT_ROOT_BRANCH=$(git -C "$ROOT_REPO" branch --show-current)
if [ "$CURRENT_ROOT_BRANCH" = "$BRANCH_NAME" ]; then
  git -C "$ROOT_REPO" checkout "$BASE_BRANCH" || echo "Warning: could not checkout $BASE_BRANCH before deleting $BRANCH_NAME"
fi
git -C "$ROOT_REPO" branch -D "$BRANCH_NAME" || echo "Warning: local branch deletion failed (may already be deleted) — skipping"
```

Use `-D` (force) rather than `-d` — squash merges rewrite history so the branch commits are not reachable from `main`, and `-d` will always fail post-squash.

If this fails (branch already deleted or never existed locally), treat as non-fatal.

The remote branch is deleted by GitHub's auto-delete-on-merge setting. If that is not enabled, delete it manually — treat failure as non-fatal (branch may already be deleted, or permissions/network may prevent it):

```bash
git -C "$ROOT_REPO" push origin --delete "$BRANCH_NAME" || echo "Warning: remote branch deletion failed (may already be deleted) — skipping"
```

### Step 5.4: Final report

```
## Wrap-Up Complete

- **PR #{N}** merged ({title})
- **Main branch** {MAIN_SYNC_STATUS from Step 2.5 — e.g. "updated abc1234 → def5678", "up to date (abc1234)", or "failed: ..."}
- **Branch** deleted
- **Work-log** updated (if applicable)
- **Follow-ups:** {summary or "none"}
- **Lessons:** {summary or "clean session"}
- **Worktree** removed
```
