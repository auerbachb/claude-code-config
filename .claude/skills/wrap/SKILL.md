---
name: wrap
description: End-of-session command — verify no unresolved findings, squash merge, sync main, detect follow-ups, and extract lessons.
---

Wrap up the current PR and session. This is the "we're done here" command that handles final verification through merge, root-main sync, follow-up detection, and lessons.

`/wrap` does **not** delete the running worktree or its branch — leaving the thread alive so it can keep working. Stale worktrees and stale local/remote branches are reaped out-of-band by `/pm-update`, which calls `.claude/scripts/stale-cleanup.sh`.

## When to use /wrap vs /merge

- Use **/wrap** at end-of-session. Handles merge + root-main sync + follow-up detection + lessons.
- Use **/merge** for a quick mid-session merge when you'll keep working. Skips follow-up detection and lessons.
- /wrap includes everything /merge does, plus follow-ups and lessons. Don't run both.

## Execution Model

`/wrap` is a set-and-forget command. Once invoked, it runs all 4 phases end-to-end without mid-run confirmation prompts. It stops early only for explicit stop conditions (for example: no PR on current branch, unresolved findings, failed merge gate, CI failure, AC verification failure, or rebase detected).

> **Always:** Execute all phases end-to-end; proceed immediately between phases when no blocker exists.
> **Ask first:** Never — all phases are autonomous once /wrap is invoked.
> **Never:** Stop to ask "should I continue?" between phases; insert confirmation prompts for non-blocker transitions. Delete the running worktree or its branch — that's `/pm-update`'s job, not /wrap's.

### Phase Transition Autonomy

| Transition | Action | Classification |
|------------|--------|----------------|
| Phase 1 complete (no unresolved findings) | Begin Phase 2 | **Always do** |
| Phase 2 complete | Begin Phase 3 | **Always do** |
| Phase 3 follow-ups processed | Begin Phase 4 | **Always do** |
| Phase 4 lessons complete (or skipped as trivial) | Output final report | **Always do** |
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

Run the shared merge-gate verifier, which implements the authoritative gate from `.claude/rules/cr-merge-gate.md` (CR 1 explicit APPROVED review on current HEAD / BugBot 1-clean / Greptile severity, plus CI and BEHIND checks):

```bash
PR_NUM=$(gh pr view --json number --jq .number)
GATE_JSON=$(.claude/scripts/merge-gate.sh "$PR_NUM")
GATE_EXIT=$?
```

- Exit `0` → gate met, proceed.
- Exit `1` → gate NOT met. Stop and report the `missing` array from the JSON output verbatim (e.g., "need 1 explicit CR APPROVED review on HEAD", "branch is BEHIND base", "CI has 2 failing check-run(s): ...").
- Exit `3` → PR not found; skip to Phase 3 as described above.
- Exit `2`/`4` → script or gh error; surface the stderr message.

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

- **Rebase/force-push safety** — the CR gate requires an explicit `APPROVED` review on the **current** HEAD SHA, so any rebase invalidates the gate (the approval's `commit_id` no longer matches).
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

Do NOT use `--delete-branch`. The current worktree is still checked out on the feature branch — git refuses to delete a branch held by a worktree, and `/wrap` no longer touches the worktree at all. The branch is cleaned up out-of-band by `/pm-update` once it ages past the stale threshold (see `.claude/scripts/stale-cleanup.sh`).

### Step 2.5: Sync root repo main (aggressive reset)

After merging, aggressively align the root repo's local `main` with `origin/main` so subsequent sessions branch from the latest code with zero drift. The sequence is:

1. **Quarantine any dirty state** on root main via `dirty-main-guard.sh --quarantine` (creates a `recovery/dirty-main-*` branch if needed — nothing is lost).
2. **Aggressively reset** root main to `origin/main` via `main-sync.sh --reset`. This fetches origin, aborts loudly if local main has unpushed commits (belt-and-suspenders for bypasses of the `#323` pre-commit hook), and otherwise `git reset --hard origin/main`.

**Capture both status lines for the final report in Phase 4.**

```bash
# /wrap runs from inside a worktree. dirty-main-guard.sh resolves the root
# repo itself via repo-root.sh — no --repo flag needed. main-sync.sh does
# accept --repo, so we pass the resolved root explicitly.
ROOT_REPO=$(.claude/scripts/repo-root.sh 2>/dev/null || true)
MAIN_SYNC_STATUS=""
QUARANTINE_STATUS=""
if [ -z "$ROOT_REPO" ] || [ ! -d "$ROOT_REPO" ]; then
  MAIN_SYNC_STATUS="failed: could not determine root repo path"
else
  # Quarantine first so the reset below never clobbers uncommitted work.
  # --check is read-only (exit 0 clean / 1 dirty); --quarantine is non-
  # destructive (preserves state to a recovery branch). A non-zero exit
  # from either is captured for the report but does not short-circuit —
  # main-sync.sh --reset has its own guards.
  if .claude/scripts/dirty-main-guard.sh --check >/dev/null 2>&1; then
    QUARANTINE_STATUS="clean"
  else
    QUARANTINE_STATUS=$(.claude/scripts/dirty-main-guard.sh --quarantine 2>&1 || true)
  fi
  # --reset: fetch → abort-if-ahead → reset --hard origin/main. Exits 0
  # success / 1 skipped / 2 failed / 4 aborted (unpushed commits on main).
  MAIN_SYNC_STATUS=$(bash .claude/scripts/main-sync.sh --reset --repo "$ROOT_REPO" 2>&1 || true)
fi
echo "Main quarantine: $QUARANTINE_STATUS"
echo "Main sync: $MAIN_SYNC_STATUS"
```

See `.claude/scripts/main-sync.sh --help` and `.claude/scripts/dirty-main-guard.sh --help` for the full contracts.

**If `MAIN_SYNC_STATUS` starts with `aborted:`** (local main has unpushed commits that didn't come from origin), do NOT attempt recovery automatically. Surface the full status line in the final report so the user can run `git log origin/main..main` against the root repo and decide. The PR merge itself has already succeeded — main-sync failure does not un-merge anything.

Store `MAIN_SYNC_STATUS` and `QUARANTINE_STATUS` for the final report at the end of Phase 4.

## Phase 3: Follow-Up Detection and Creation

Detect related work that needs attention for feature completeness, then **auto-create GitHub issues** for each follow-up (with deduplication and HHG two-ticket pattern awareness).

### Step 3.1: Detect follow-up items

1. Extract the linked issue number from the PR body via `pr-issue-ref.sh` (matches all nine GitHub closing keywords — `close`/`closes`/`closed`/`fix`/`fixes`/`fixed`/`resolve`/`resolves`/`resolved`, case-insensitive) and fetch its title and body. Distinguish exit `1` (no link — expected) from exits `2`/`3`/`4` (real errors) so genuine failures surface:
   ```bash
   PR_NUMBER=$(gh pr view --json number --jq '.number')
   PR_TITLE=$(gh pr view --json title --jq '.title')
   ISSUE_N=""
   if RAW_REF=$(.claude/scripts/pr-issue-ref.sh "$PR_NUMBER" 2>&1); then
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

**Non-HHG PRs still get generic follow-up creation** — any items collected in Step 3.1 that are not overridden by the HHG path go through the dedup + create flow above.

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
- **Cycle count** — review-then-fix rounds on the PR, via `CYCLES=$(.claude/scripts/cycle-count.sh "$PR_NUM")`
- **Thread length** — count the number of user + assistant messages in the current session. "Short" = fewer than 15 total messages.
- **PR size** — number of files changed (`gh pr view N --json files --jq '.files | length'`)

**Trivial threshold:** cycle count = 0 AND conversation is short (you've been in this session for <15 messages) AND <5 files changed.

### Step 4.2: Run lessons (or skip)

**If trivial:** Output "Clean session — no lessons to capture." and skip to Step 4.3 (final report).

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

After lessons (or skip): emit the final report below — do not ask.

### Step 4.3: Final report

```
## Wrap-Up Complete

- **PR #{N}** merged ({title})
- **Main quarantine** {QUARANTINE_STATUS from Step 2.5 — e.g. "clean" (literal output of `dirty-main-guard.sh --check` on a clean main), "quarantined: recovery/dirty-main-20260424-003012 (uncommitted)", or "no-op: main is clean" (only produced if `--quarantine` ran on an already-clean tree)}
- **Main branch** {MAIN_SYNC_STATUS from Step 2.5 — e.g. "reset abc1234 → def5678", "up to date (abc1234)", "aborted: local main has 1 unpushed commit(s) — inspect: git log origin/main..main, resolve manually before re-running", or "failed: ..."}
- **Follow-ups:** {summary or "none"}
- **Lessons:** {summary or "clean session"}
```

The worktree and feature branch are intentionally left in place. They are reaped out-of-band by `/pm-update`'s stale-cleanup pass once they age past the threshold (default 7 days, configurable via `STALE_DAYS`). See `.claude/scripts/stale-cleanup.sh --help`.
