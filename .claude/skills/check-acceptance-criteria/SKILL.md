---
name: check-acceptance-criteria
description: Verify all Test Plan checkboxes in a PR against the actual code, check off passing items, and report any failures.
argument-hint: "[PR number, default: current branch's PR]"
---

Verify acceptance criteria for PR $ARGUMENTS (or the current branch's PR if no argument given).

## Steps

### Step 1: Identify the PR

If an argument was provided, use it as the PR number. Otherwise, detect from the current branch:

```bash
gh pr view --json number,title,body --jq '{number, title, body}'
```

If no PR exists, stop and tell the user.

### Step 2: Parse the Test Plan section

Extract checkboxes via the shared helper. `ac-checkboxes.sh --extract` parses the PR body, locates the **Test plan** (or "Test Plan"/"Acceptance Criteria") section, and emits each checkbox as JSON:

```bash
ITEMS=$(.claude/scripts/ac-checkboxes.sh "$PR_NUM" --extract)
EXTRACT_EXIT=$?
```

Exit codes for `--extract`:
- `0` → `$ITEMS` is a JSON array of `{index, checked, text}` entries (zero-based index, in document order).
- `1` → no Test Plan section (or section has no checkboxes). **Blocking** — every PR must include a Test Plan section (CLAUDE.md). Report the missing section as a PR-body violation and stop with a non-zero exit; the PR is NOT merge-ready until the body is fixed.
- `2` → internal script error (usage, python parse, helper prereq). Surface stderr with a `[script-error]` tag and stop.
- `3` → PR not found (closed/merged). Stop and tell the user.

Exit code `4` (`[gh-error]`) is only reachable from `--tick`/`--all-pass` (Step 4) — `--extract` is read-only and never calls `gh pr edit`.

Handle `$EXTRACT_EXIT` explicitly before using `$ITEMS`. Exit 1 is a **blocking** failure — every PR must include a Test Plan with acceptance-criteria checkboxes (CLAUDE.md), so a missing section is a PR-body violation, not a clean pass:

```bash
case "$EXTRACT_EXIT" in
  0) : ;;  # $ITEMS is valid JSON — proceed
  1) echo "[blocked] PR #$PR_NUM is missing a Test Plan section — required per CLAUDE.md. Add the section before asking for AC verification."; exit 1 ;;
  2) echo "[script-error] ac-checkboxes.sh failed — see stderr above."; exit 2 ;;
  3) echo "PR #$PR_NUM not found (closed/merged)."; exit 3 ;;
  *) echo "Unexpected exit code from ac-checkboxes.sh: $EXTRACT_EXIT"; exit "$EXTRACT_EXIT" ;;
esac
```

### Step 3: Verify each criterion

Filter `$ITEMS` to only the unchecked entries — already-checked items don't need re-verification. `$ITEMS` is guaranteed to be valid JSON after a successful `--extract` (exit 0), so `jq` cannot fail here unless the file was truncated:

```bash
UNCHECKED=$(echo "$ITEMS" | jq '[.[] | select(.checked == false)]')
```

Then, for each object in `$UNCHECKED`:

1. **Read the criterion carefully** — understand what it's asserting
2. **Identify the relevant source files** — which files need to be checked to verify this criterion
3. **Read those files** and confirm the criterion is satisfied by the current code
4. **Record the result** — pass or fail, with a brief explanation

Some criteria may not be verifiable from code alone (e.g., "renders correctly in browser", "performance is acceptable"). For these, note: "Requires manual testing — cannot verify from code."

### Step 4: Update the PR body

Tick every item you verified via `--tick`, passing the zero-based indexes from Step 2 as a comma-separated list (no spaces between commas):

```bash
# Example: items 0, 2, 3 passed. Note: "0,2,3" — no spaces between commas.
.claude/scripts/ac-checkboxes.sh "$PR_NUM" --tick "0,2,3"
TICK_EXIT=$?
```

Or, if **every** unchecked item passed, use the convenience flag:

```bash
.claude/scripts/ac-checkboxes.sh "$PR_NUM" --all-pass
TICK_EXIT=$?
```

The script fetches the current body, flips matching `- [ ]` to `- [x]`, and writes back via `gh pr edit --body-file`. Already-checked items in the match set are skipped (idempotent).

Handle the tick exit code:
- `0` → body updated (or noop). Proceed to Step 5.
- `4` → `gh pr edit` failed. Surface stderr with `[gh-error]` and stop.
- `2` / other non-zero → internal script error. Surface stderr with `[script-error]` and stop.

Only tick items that passed verification. Never tick items that failed or require manual testing.

### Step 5: Report results

Output a summary:
- Total criteria: N
- Passed (checked off): N
- Failed: N (list each with explanation)
- Requires manual testing: N (list each)

If all items pass, say: "All acceptance criteria verified and checked off. PR is ready for merge."
If any fail, say: "N acceptance criteria failed — fix before merging." and list the failures.
