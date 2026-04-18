---
name: fixpr
description: Single-pass PR cleanup — audit every review thread + every CI check-run, fix all issues, push once, resolve all threads via GraphQL, verify CI green. Zero uncollapsed threads and zero failing checks when done.
---

Single-pass cleanup of the current branch's PR. After this completes:

1. **Zero uncollapsed review threads** in the browser (all resolved via GraphQL)
2. **Zero failing CI checks** (all fixed and passing)
3. **Every finding replied to** with what was done

## How this skill is structured

All mechanical GitHub API work — pagination, GraphQL queries, comment classification — lives in the shared script `.claude/scripts/pr-state.sh`. This file tells the AI layer how to invoke the script and what to do with its output (the JSON bundle).

| Step | Kind | Done by |
|------|------|---------|
| 0. Gather PR state | Mechanical | `pr-state.sh` writes `/tmp/pr-state-<PR>-<epoch>.json` |
| 1. Classify review findings | Judgment | AI reads JSON + source files |
| 2. Classify CI failures | Judgment | AI reads `check-runs/<id>.output.summary` |
| 3. Fix & push | Judgment | AI edits files, commits, pushes |
| 4. Reply & resolve | Mechanical | `gh api` calls against IDs from the JSON |
| 5. Verify | Mechanical | Re-run `pr-state.sh --since $RUN_STARTED_AT` |
| 6. Merge blockers | Judgment | AI reads `.merge_state` from the JSON |
| 7. Final summary | Judgment | AI emits the status |

Execute the steps sequentially. Do NOT poll in a loop — this is a single-pass tool. When a verify pass finds unfinished work, exit with a status code and instruct the user to re-run `/fixpr`.

---

## Step 0: Run the initial audit

Locate `pr-state.sh`. Prefer the global install; fall back to the in-repo copy when developing the skill itself. The legacy `audit.sh` wrapper is kept for back-compat — call it only if `pr-state.sh` cannot be found.

```bash
SCRIPT=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/pr-state.sh" \
  "$HOME/.claude/scripts/pr-state.sh" \
  ".claude/scripts/pr-state.sh" \
  "$HOME/.claude/skills/fixpr/audit.sh" \
  ".claude/skills/fixpr/audit.sh"; do
  if [[ -x "$candidate" ]]; then
    SCRIPT="$candidate"
    break
  fi
done
if [[ -z "$SCRIPT" ]]; then
  echo "ERROR: pr-state.sh not found (checked ~/.claude/scripts/, ~/.claude/skills-worktree/.claude/scripts/, and in-repo .claude/scripts/)" >&2
  exit 1
fi

AUDIT=$("$SCRIPT")
```

If `pr-state.sh` itself exits non-zero it prints the reason to stderr (no PR, closed PR, detached HEAD, etc.). Stop and report. Exit codes: `0` OK, `2` usage error, `3` no branch and no `--pr`, `4` PR closed/not found, `5` gh/network error.

Pull the values that the later steps need out of the JSON once:

```bash
PR_NUMBER=$(jq -r '.pr.number' "$AUDIT")
OWNER=$(jq -r '.pr.owner' "$AUDIT")
REPO=$(jq -r '.pr.repo' "$AUDIT")
BRANCH=$(jq -r '.pr.branch' "$AUDIT")
HEAD_SHA=$(jq -r '.pr.head_sha' "$AUDIT")
RUN_STARTED_AT=$(jq -r '.run_started_at' "$AUDIT")
```

Print the context and a one-line audit summary:

```bash
jq -r '
  "[CONTEXT] PR #\(.pr.number) on \(.pr.owner)/\(.pr.repo) (branch: \(.pr.branch), HEAD: \(.pr.head_sha[0:7]))",
  "[AUDIT] Threads: \(.threads.total) total — \(.threads.unresolved_count) unresolved, \(.threads.resolved_count) resolved",
  "[AUDIT] CI checks: \(.check_runs.total) total (\(.check_runs.passing) passing, \(.check_runs.failing) failing, \(.check_runs.in_progress) in-progress)"
' "$AUDIT"

jq -r '.threads.unresolved[] | "  unresolved: \(.comments.nodes[0].path // "?"):\(.comments.nodes[0].line // "?") — \(.comments.nodes[0].body | split("\n")[0] | .[:120])"' "$AUDIT"
jq -r '.check_runs.failing_runs[] | "  failing: \(.name) — \(.title // "no title")"' "$AUDIT"
```

---

## Step 1: Classify every unresolved finding (judgment)

For each entry in `.threads.unresolved`:

1. Read the first comment (`.comments.nodes[0].body`) plus its `path` + `line`
2. Read the current file at that location
3. Classify:
   - **actionable** — code still has the issue → must fix
   - **already-fixed** — code no longer matches the finding → resolve only
   - **outdated** — file/line no longer exists → resolve only

Print the numbered list:

```text
[FINDING 1] actionable — src/foo.ts:42 — "unused import" (coderabbitai[bot])
[FINDING 2] already-fixed — src/bar.ts:10 — "missing null check" (coderabbitai[bot])
[FINDING 3] outdated — src/deleted.ts:5 — file removed (greptile-apps[bot])
```

---

## Step 2: Classify every CI failure (judgment)

For each entry in `.check_runs.failing_runs` (blocking conclusions: `failure`, `timed_out`, `action_required`, `startup_failure`, `stale`):

1. Fetch the detailed output:
   ```bash
   gh api "repos/$OWNER/$REPO/check-runs/<id>" --jq '.output.summary, .output.text'
   ```
   If both are empty, follow `.html_url` to the run log.
2. Classify:
   - **lint / typecheck** — read the errors, fix the code
   - **test** — read the failing output, fix the code or test
   - **build** — read the build error, fix the code
   - **security / audit** (gitleaks, npm audit, etc.) — read the finding, fix
   - **infra / transient** (timeout, runner failure) — note it, cannot fix locally

Print per check:

```text
[CI:FAIL] "lint" — 3 errors in src/foo.ts → fixing
[CI:INFRA] "deploy-preview" — timed_out (transient)
```

**Every entry in `.check_runs.failing_runs` must be accounted for — do not skip any.**

---

## Step 3: Fix everything, push once

Combine actionable findings + non-transient CI failures into a single commit.

Rules:

- **Never suppress linter errors** (`eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `noqa`) — fix the actual code.
- Verify each fix against the original message — partial fixes count as unresolved.
- If ambiguous, fix conservatively.

```bash
git add <modified files>
git commit -m "fix: resolve all review findings and CI failures

Fixes N review findings and M CI errors."
git push
```

Print: `[PUSH] committed and pushed (SHA: $(git rev-parse --short HEAD))`.

If nothing needed fixing (all already-fixed/outdated, CI all green), skip the commit/push.

---

## Step 4: Reply and resolve every thread

For every entry in `.threads.unresolved` — actionable, already-fixed, or outdated:

### 4a. Reply

Pull the IDs from the JSON:

```bash
# index <i> in each call — iterate 0..unresolved_count-1
DBID=$(jq -r ".threads.unresolved[$i].comments.nodes[0].databaseId" "$AUDIT")
```

Reply text by classification:

- **actionable:** `"Fixed in \`<short-sha>\`: <one-line description>"`
- **already-fixed:** `"Addressed in a prior commit — current code no longer has this issue. Resolving."`
- **outdated:** `"Referenced code no longer exists after refactoring. Resolving."`

Post the reply via the shared helper — it handles inline-first, PR-comment-fallback, and reviewer-specific `@mention` rules automatically:

```bash
# $REVIEWER: cr | bugbot | greptile (from the audit classification)
.claude/scripts/reply-thread.sh "$DBID" --reviewer "$REVIEWER" \
  --body "$REPLY" --pr "$PR_NUMBER"
```

The script strips any `@greptileai` tokens from the body in greptile mode and any `@cursor` tokens in bugbot mode — so even a stray mention in `$REPLY` cannot trigger a paid Greptile re-review ($0.50–$1.00). `@greptileai` is reserved exclusively for intentionally requesting a new review. See `.claude/scripts/reply-thread.sh --help` for the full exit-code contract.

### 4b. Resolve via shared helper

After all replies are posted, resolve every unresolved bot-authored thread with one call:

```bash
bash .claude/scripts/resolve-review-threads.sh "$PR_NUMBER"
```

The script fetches unresolved threads via GraphQL (paginated), filters to `coderabbitai`, `cursor`, and `greptile-apps` authors by default, runs `resolveReviewThread`, and falls back to `minimizeComment(classifier: RESOLVED)` on failure. Exit codes: `0` all resolved, `1` at least one failed both mutations (block on Step 5 — do NOT treat as clean), `3` PR not found, `4` gh error. It prints `[RESOLVED]` / `[MINIMIZED]` / `[FAILED]` per thread.

---

## Step 5: Verify

Run the audit script again with `--since $RUN_STARTED_AT`. This picks up the new HEAD SHA (post-push) **and** pre-classifies any bot comment that landed between Step 0 and now:

```bash
VERIFY=$("$SCRIPT" --since "$RUN_STARTED_AT")
```

### 5a. Threads

```bash
UNRESOLVED=$(jq -r '.threads.unresolved_count' "$VERIFY")
```

- `0` → `[CLEAN] All threads resolved — zero uncollapsed in browser.`
- otherwise → retry resolution (max 2 attempts per thread). Remaining stuck threads emit `[STUCK] thread <id> — cannot resolve`.

### 5b. New bot comments since `$RUN_STARTED_AT`

`audit.sh` has already classified every bot comment posted after `$RUN_STARTED_AT`. Read the rollup:

```bash
jq -r '
  "[VERIFY-COMMENTS] new findings: \(.new_since_baseline.finding_count), acknowledgments: \(.new_since_baseline.acknowledgment_count)",
  (.new_since_baseline.reviews[], .new_since_baseline.inline[], .new_since_baseline.conversation[]
   | select(.classification.class == "finding")
   | "  finding: \(.url) — \(.classification.reason)")
' "$VERIFY"
```

**Classification rules** (these live in `pr-state.sh`; the list below is the contract — keep the two in sync if either changes). Patterns are checked in this order; first match wins:

1. **Explicit-resolution overrides** (checked first — these signals mean CR has already marked the thread addressed, so they win even if the body still contains finding language from a quoted earlier review):
   - HTML marker `<!-- <review_comment_addressed> -->` → `acknowledgment`
   - `actionable comments posted: 0` → `acknowledgment`. This specific zero-count pattern MUST be checked before the general `actionable comments posted` pattern below — otherwise the general finding pattern would swallow the zero case.
2. **Finding patterns**:
   - Severity keywords `\b(critical|major|minor|nitpick|p[0-2])\b` or badges `🔴|🟠|🟡`
   - Actionable phrases: `actionable comments posted` (non-zero), `issues? found`, `findings?:`, `potential[_ ]issue`
   - Fix markers: a fenced ```` ```suggestion ```` block, or a `Prompt for AI Agent` heading
3. **Weak-ack fallbacks** (only if no finding matched):
   - LGTM variants: `lgtm`, `looks good`, `approved`, `confirmed`, `resolved`
4. **Default** (no pattern matched) → `finding`. The safer default — under-classifying here is the failure mode this whole skill exists to prevent.

**If `finding_count > 0`:** do NOT loop. Emit `NEW_FINDINGS` in Step 7 and stop. Re-running `/fixpr` captures a new `$RUN_STARTED_AT` and re-audits from Step 0, picking up the new findings.

### 5c. CI (if a push was made)

The verify audit's `.check_runs` reflects the new HEAD.

```bash
jq -r '.check_runs.all[] | "[CI] \(.name): \(.status)\(if .conclusion then " — \(.conclusion)" else "" end)"' "$VERIFY"

FAILING=$(jq -r '.check_runs.failing' "$VERIFY")
IN_PROGRESS=$(jq -r '.check_runs.in_progress' "$VERIFY")
```

Decide from those two counts:

- `IN_PROGRESS > 0` → emit `CI_PENDING` in Step 7. Re-run `/fixpr` after CI finishes.
- `IN_PROGRESS == 0 && FAILING > 0` → read each entry in `.check_runs.failing_runs` from the VERIFY audit. Classify:
  - **deterministic** (lint/typecheck/test/build/security reports a real error) → emit `CI_FAILING` in Step 7 and stop. Re-run `/fixpr` so Steps 2–3 can retry the fix on the newly-visible error.
  - **transient** (runner timeout, startup failure, flaky external dep) → emit `CI_FAILING` in Step 7, note the specific checks, and continue to Step 6 — local fixes aren't possible and the user decides whether to retry.
- `IN_PROGRESS == 0 && FAILING == 0` → CI clean on this SHA.

Do NOT poll.

### 5d. Review-bot commit statuses on the current HEAD

CR and Greptile report review completion via commit *statuses*, not check-runs. `pending` means the bot is still analyzing the current HEAD — declaring CLEAN while pending is the exact failure mode this verify step was built to prevent.

```bash
jq -r '
  .bot_statuses | to_entries[] | "[VERIFY-BOTS] \(.key): \(.value.state) (\(.value.updated_at))"
' "$VERIFY"
```

For each bot present:

- `state: success` → review completed on this SHA. Clean-pass signal.
- `state: pending` → bot still running. **Do NOT declare CLEAN.** Emit `REVIEW_PENDING` and stop.
- `state: failure` / `error` with "rate limit" in `description` → CR rate-limited, fall back to Greptile per `cr-github-review.md`.
- No CR/Greptile entry in `.bot_statuses` after a push → bot hasn't started. Re-run `/fixpr` after it does.

---

## Step 6: Check merge blockers

```bash
jq -r '.merge_state | "[MERGE] mergeable=\(.mergeable), status=\(.mergeStateStatus), review=\(.reviewDecision)"' "$VERIFY"
```

| Field | Blocking value | Action |
|-------|---------------|--------|
| `mergeable` | `CONFLICTING` | Rebase onto main: `git fetch origin main && git rebase origin/main`. Fix conflicts, continue, force-push. |
| `mergeable` | `UNKNOWN` | GitHub still computing — note and re-run `/fixpr` later. |
| `mergeStateStatus` | `BEHIND` | Rebase onto main: `git fetch origin main && git rebase origin/main`. If conflicts arise mid-rebase (replaying commits individually can conflict even when a three-way merge wouldn't), resolve them the same way as `CONFLICTING` above, then `git rebase --continue`. Force-push. Wait for CI to re-run before verifying merge gate. |
| `mergeStateStatus` | `BLOCKED` | Required checks/reviews missing — already covered by 5c/5d, but report any residual. |
| `mergeStateStatus` | `UNSTABLE` | A non-required check pending/failing — typically CR/Greptile on the new SHA. If 5d emitted `REVIEW_PENDING`, stop with that status. |
| `reviewDecision` | `CHANGES_REQUESTED` | A human reviewer requested changes — report; cannot auto-resolve. |

After any rebase + force-push: `[MERGE] rebase complete, force-pushed (SHA: <new-sha>) — CI re-triggered. Re-run /fixpr after CI completes.`

---

## Step 7: Final summary

```text
=== fixpr complete ===
PR:              #$PR_NUMBER ($BRANCH)
Threads:         N total, M were unresolved
  - Fixed:       X findings in code
  - Resolved:    Y threads via GraphQL
  - Stuck:       Z threads (0 = clean)
CI checks:       P total, Q were failing
  - Fixed:       R failures in code
  - Transient:   S (cannot fix locally)
Merge state:     mergeable=..., status=..., review=...
Push:            <sha> or "no push needed"
Status:          CLEAN | THREADS_STUCK | REVIEW_PENDING | CI_PENDING | CI_FAILING | CONFLICTS | BEHIND | NEEDS_HUMAN_REVIEW | NEW_FINDINGS
```

**Status definitions:**

- `CLEAN` — **all four conditions simultaneously:** zero unresolved threads (5a), `new_since_baseline.finding_count == 0` (5b), every entry in `bot_statuses` is `success` on the current HEAD (5d), no merge blockers (6). Missing any one disqualifies `CLEAN` — pick the more specific status below.
- `THREADS_STUCK` — some threads could not be resolved via GraphQL (report which).
- `REVIEW_PENDING` — 5d found a CR/Greptile status still `pending` on the current HEAD. Re-run `/fixpr` after it flips to `success`. Do NOT declare CLEAN.
- `NEW_FINDINGS` — 5b's `finding_count > 0`. Stop the run. A fresh `/fixpr` captures a new `$RUN_STARTED_AT` and re-audits from Step 0.
- `CI_PENDING` — push was made, CI not yet complete. Re-run `/fixpr` after CI.
- `CI_FAILING` — transient CI failures that cannot be fixed locally (report which).
- `CONFLICTS` — merge conflicts could not be auto-resolved (needs manual intervention).
- `BEHIND` — branch behind base, auto-rebased and force-pushed; now waiting for CI re-run. Re-run `/fixpr` after CI completes.
- `NEEDS_HUMAN_REVIEW` — a human reviewer requested changes (cannot auto-resolve).
