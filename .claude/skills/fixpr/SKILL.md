---
name: fixpr
description: Single-pass PR cleanup — audit every review thread + every CI check-run, fix all issues, push once, resolve all threads via GraphQL, verify CI green. Zero uncollapsed threads and zero failing checks when done.
---

Single-pass cleanup of the current branch's PR. After this completes:
1. **Zero uncollapsed review threads** in the browser (all resolved via GraphQL)
2. **Zero failing CI checks** (all fixed and passing)
3. **Every finding replied to** with what was done

---

## Step 0: Identify PR context

```bash
BRANCH=$(git branch --show-current)
PR_JSON=$(gh pr view --json number,headRefName,state,url 2>/dev/null)
```

If no PR exists for this branch, stop: "No PR found for branch `$BRANCH`."

Extract:
```bash
PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
PR_STATE=$(echo "$PR_JSON" | jq -r '.state')

if [ "$PR_STATE" != "OPEN" ]; then
  echo "PR #$PR_NUMBER is already $PR_STATE — nothing to fix."
  exit 0
fi

OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
OWNER=$(echo "$OWNER_REPO" | cut -d/ -f1)
REPO=$(echo "$OWNER_REPO" | cut -d/ -f2)
HEAD_SHA=$(gh pr view $PR_NUMBER --json commits --jq '.commits[-1].oid')

# Timestamp baseline for detecting NEW bot comments posted during/after this run.
# Step 6b uses this to catch reviews that land between Step 1's audit and Step 6's verify.
RUN_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
```

Print: `[CONTEXT] PR #$PR_NUMBER on $OWNER/$REPO (branch: $BRANCH, HEAD: ${HEAD_SHA:0:7})`

---

## Step 1: Audit — fetch all threads + all CI in one pass

### 1a. Review threads (GraphQL — authoritative for resolution status)

**Paginate** — `reviewThreads` caps at 100 per page, so PRs with more threads silently lose data. Loop until `hasNextPage` is false, accumulating all nodes before classifying.

```bash
CURSOR="null"
ALL_THREADS="[]"
while :; do
  RESP=$(gh api graphql -f query='query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            isOutdated
            comments(first: 10) {
              nodes {
                id
                databaseId
                body
                author { login }
                path
                line
                originalLine
                url
              }
            }
          }
        }
      }
    }
  }' -F owner="$OWNER" -F repo="$REPO" -F pr=$PR_NUMBER -F cursor="$CURSOR")
  ALL_THREADS=$(jq -s '.[0] + .[1].data.repository.pullRequest.reviewThreads.nodes' <(echo "$ALL_THREADS") <(echo "$RESP"))
  HAS_NEXT=$(echo "$RESP" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
  [ "$HAS_NEXT" = "true" ] || break
  CURSOR=$(echo "$RESP" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
done
```

**Note on `-F cursor`:** `-F` performs GraphQL type conversion (literal `"null"` → GraphQL `null`, `"true"` → boolean, numbers → int). `-f` would send the literal string `"null"` and break the first fetch. Same pattern applies to Step 6a.

### 1b. CI check-runs (REST — every check, not just CodeRabbit)

```bash
gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" \
  --jq '.check_runs[] | {id, name, status, conclusion, title: .output.title}'
```

### 1c. REST comment endpoints (for reply targets and comment IDs)

Fetch all three endpoints with `--paginate` so large PRs don't silently truncate review/comment data.

```bash
gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100"
gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments?per_page=100"
gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100"
```

### 1d. Print audit summary

```
[AUDIT] Review threads: N total — M unresolved, K resolved (J outdated across both categories)
[AUDIT] CI checks: X total (P passing, F failing, I in-progress)
```

List every failing check by name. List every unresolved thread with file:line and first sentence.

---

## Step 2: Classify every unresolved finding

For each unresolved thread (`isResolved: false`):

1. Read the first comment (the original finding)
2. Get `path` and `line` from comment metadata
3. Read the current file at that location
4. Classify:
   - **actionable** — code still has the issue → must fix
   - **already-fixed** — code no longer matches the finding (fixed in prior commit, thread not resolved) → resolve only
   - **outdated** — file/line no longer exists → resolve only

Print numbered list:
```
[FINDING 1] actionable — src/foo.ts:42 — "unused import" (coderabbitai[bot])
[FINDING 2] already-fixed — src/bar.ts:10 — "missing null check" (coderabbitai[bot])
[FINDING 3] outdated — src/deleted.ts:5 — file removed (greptile-apps[bot])
```

---

## Step 3: Check every CI failure

For every check-run with a blocking conclusion (`failure`, `timed_out`, `action_required`, `startup_failure`, `stale`):

1. Read the failure output:
   ```bash
   gh api "repos/$OWNER/$REPO/check-runs/{CHECK_RUN_ID}" --jq '.output.summary'
   ```
   If summary is empty, also check `.output.text` and the check-run's `details_url`.

2. Classify the failure:
   - **lint/typecheck** — read the errors, fix the code
   - **test** — read the failing test output, fix the code or test
   - **build** — read the build error, fix the code
   - **security/audit** (gitleaks, npm audit, etc.) — read the finding, fix
   - **infra/transient** (timeout, runner failure) — note it, cannot fix locally

3. Fix every non-transient failure. Read the actual error messages — do not guess.

Print per check:
```
[CI:FAIL] "lint" — 3 errors in src/foo.ts (unused var, missing type, bad import) → fixing
[CI:FAIL] "test" — 1 failure in tests/bar.test.ts:55 (expected 3, got 4) → fixing
[CI:PASS] "build" — ok
[CI:INFRA] "deploy-preview" — timed_out (transient, cannot fix locally)
```

**Do NOT skip any check.** Every check-run must be accounted for in the output.

---

## Step 4: Fix everything, push once

Combine all fixes (review findings + CI failures) into a single commit:

1. Fix all **actionable** review findings (Step 2)
2. Fix all **non-transient CI failures** (Step 3)
3. Rules:
   - **Never suppress linter errors** (`eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `noqa`) — fix the actual code
   - Verify each fix against the original comment/error — partial fixes count as unresolved
   - If a finding is ambiguous, fix it conservatively
4. Commit and push:

```bash
# Stage only the files modified during fixing (tracked from Steps 2–3)
git add <list of modified files>
git commit -m "fix: resolve all review findings and CI failures

Fixes N review findings and M CI errors."
git push
```

Print: `[PUSH] All fixes committed and pushed (SHA: $(git rev-parse --short HEAD))`

**If nothing needed fixing** (all already-fixed/outdated, CI all green), skip the commit/push.

---

## Step 5: Reply to every thread and resolve via GraphQL

For **every** unresolved thread — actionable, already-fixed, and outdated:

### 5a. Reply

Post a reply to the first comment in the thread:

- **Actionable (just fixed):** `"Fixed in \`<short-sha>\`: <one-line description>"`
- **Already fixed:** `"Addressed in a prior commit — current code no longer has this issue. Resolving."`
- **Outdated:** `"Referenced code no longer exists after refactoring. Resolving."`

Use inline reply endpoint first:
```bash
gh api "repos/$OWNER/$REPO/pulls/comments/{comment_id}/replies" -f body="<reply>"
```
On 404, fall back to:
```bash
gh pr comment $PR_NUMBER --body "<plain-text reply — do NOT include @greptileai>"
```
**CRITICAL:** Never include `@greptileai` in reply text. Every `@greptileai` mention triggers a paid Greptile re-review ($0.50–$1.00). Use plain text only; `@greptileai` is reserved exclusively for intentionally requesting a new review.

### 5b. Resolve via GraphQL

```bash
gh api graphql -f query='mutation {
  resolveReviewThread(input: {threadId: "<thread_node_id>"}) {
    thread { isResolved }
  }
}'
```

Confirm `isResolved: true`. On failure, fall back to minimizing:
```bash
gh api graphql -f query='mutation {
  minimizeComment(input: {subjectId: "<comment_node_id>", classifier: RESOLVED}) {
    minimizedComment { isMinimized }
  }
}'
```

Print per thread: `[RESOLVED] thread <id> — <summary>`

---

## Step 6: Verify — zero unresolved threads, zero new comments, CI status, review-bot completion

> **Why four checks, not just threads:** GraphQL `reviewThreads` only sees inline-comment threads. A reviewer bot can post a new review body (or a new PR-conversation comment) that carries actionable findings without ever creating a thread. Relying on thread-resolution state alone is how premature "merge-ready" declarations happen — this section exists specifically to prevent that.

### 6a. Re-fetch threads

**Paginate** — same cursor loop as Step 1a, applied to the simpler re-fetch query:

```bash
CURSOR="null"
ALL_THREADS="[]"
while :; do
  RESP=$(gh api graphql -f query='query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes { id isResolved comments(first: 1) { nodes { body author { login } } } }
        }
      }
    }
  }' -F owner="$OWNER" -F repo="$REPO" -F pr=$PR_NUMBER -F cursor="$CURSOR")
  ALL_THREADS=$(jq -s '.[0] + .[1].data.repository.pullRequest.reviewThreads.nodes' <(echo "$ALL_THREADS") <(echo "$RESP"))
  HAS_NEXT=$(echo "$RESP" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
  [ "$HAS_NEXT" = "true" ] || break
  CURSOR=$(echo "$RESP" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
done
```

Count unresolved (`isResolved: false`) across `ALL_THREADS`.

- **0 unresolved:** `[CLEAN] All threads resolved — zero uncollapsed in browser.`
- **Any remain:** Retry resolution (max 2 attempts per thread). If still stuck:
  `[STUCK] Thread <id> — cannot resolve (permission or GitHub bug): "<first line>"`

### 6b. Re-scan the three REST comment endpoints for NEW bot comments since `$RUN_STARTED_AT`

This is the critical gap that thread-resolution checks alone miss. A reviewer bot can post a new review body or PR-conversation comment that contains findings without ever creating a resolvable thread — so Step 6a would report clean while the PR is still unaddressed.

Filter each endpoint by `coderabbitai[bot]` / `greptile-apps[bot]` and by timestamp > `$RUN_STARTED_AT` (captured in Step 0):

```bash
SINCE="$RUN_STARTED_AT"
NEW_REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" \
  --jq --arg since "$SINCE" '[.[] | select((.user.login=="coderabbitai[bot]" or .user.login=="greptile-apps[bot]") and .submitted_at > $since)]')
NEW_INLINE=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments?per_page=100" \
  --jq --arg since "$SINCE" '[.[] | select((.user.login=="coderabbitai[bot]" or .user.login=="greptile-apps[bot]") and .created_at > $since)]')
NEW_CONVO=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" \
  --jq --arg since "$SINCE" '[.[] | select((.user.login=="coderabbitai[bot]" or .user.login=="greptile-apps[bot]") and .created_at > $since)]')
```

For each hit, classify the body with these explicit patterns (case-insensitive regex):

**Finding patterns** (any match → treat as finding):
- Severity words/badges: `\b(critical|major|minor|nitpick|p[0-2])\b` or `🔴|🟠|🟡`
- Actionable language: `actionable comments posted|issues? found|findings?:|potential[_ ]issue`
- Suggestion markers: a fenced block labeled `suggestion` (e.g., ` ```suggestion `) or a CR "Prompt for AI Agent" heading
- A diff/patch proposal: a fenced code block whose first line starts with `+` or `-`

**Acknowledgment patterns** (match only if NO finding pattern matches above):
- HTML marker: `<!-- <review_comment_addressed> -->`
- LGTM variants: `\b(lgtm|looks good|approved|confirmed|resolved)\b`

**Default rule:** if neither set matches, treat as a finding (safer default — under-classifying leads to the premature-merge failure mode this section exists to prevent).

**If any finding is detected:** do NOT loop in-process. Emit `NEW_FINDINGS` in Step 8, stop the run, and require a fresh `/fixpr` invocation. The new run captures a new `$RUN_STARTED_AT` and re-audits from Step 1.

Print:
```
[VERIFY-COMMENTS] reviews: 0 new | inline: 0 new | convo: 1 new (acknowledgment, non-blocking)
```
or:
```
[VERIFY-COMMENTS] reviews: 1 new (CR, Major finding @ SKILL.md:98) → exit NEW_FINDINGS, re-run /fixpr
```

### 6c. Re-check CI (if a push was made)

If Step 4 pushed, get the new HEAD SHA and poll check-runs once (wait up to 60s for checks to start):

```bash
NEW_SHA=$(git rev-parse HEAD)
gh api --paginate "repos/$OWNER/$REPO/commits/$NEW_SHA/check-runs?per_page=100" \
  --jq '.check_runs[] | {name, status, conclusion}'
```

- Report status of every check: `[CI] lint: queued | test: in_progress | build: success`
- If checks haven't started yet, note: "CI triggered — checks not yet started. Run `/fixpr` again after CI completes if needed."
- Do NOT poll in a loop — this is a single-pass tool.

### 6d. Verify review-bot commit statuses

CodeRabbit (and Greptile, if triggered) report review completion via commit statuses, not check-runs. A `pending` status means the bot is still analyzing the current HEAD — declaring CLEAN while `pending` is the exact failure mode Step 6 is designed to prevent.

```bash
TARGET_SHA="${NEW_SHA:-$HEAD_SHA}"
gh api "repos/$OWNER/$REPO/commits/$TARGET_SHA/statuses" \
  --jq '[.[] | select(.context=="CodeRabbit" or .context=="Greptile") | {context, state, description, updated_at}]
        | group_by(.context) | map(sort_by(.updated_at) | last)'
```

For each bot present on the PR:
- `state: success` → review completed on this SHA. Clean pass signal.
- `state: pending` → review still running. **Do NOT declare CLEAN.** Emit `REVIEW_PENDING` (see Step 8) and instruct re-run.
- `state: failure` / `error` with "rate limit" in `description` → CR rate-limited, fall back to Greptile per `cr-github-review.md`.
- No CodeRabbit / Greptile status context at all after a push → the bot hasn't started. Re-run `/fixpr` after it does.

Print:
```
[VERIFY-BOTS] CodeRabbit: success (21:43:01Z) | Greptile: n/a
```
or:
```
[VERIFY-BOTS] CodeRabbit: pending (21:38:21Z) → REVIEW_PENDING, stopping
```

---

## Step 7: Check merge blockers

Verify nothing else blocks the merge button. Run:

```bash
gh pr view $PR_NUMBER --json mergeStateStatus,mergeable,reviewDecision,statusCheckRollup
```

Check each field:

| Field | Blocking value | Action |
|-------|---------------|--------|
| `mergeable` | `CONFLICTING` | Rebase onto main: `git fetch origin main && git rebase origin/main`. If conflicts, fix them, `git rebase --continue`, force-push. |
| `mergeable` | `UNKNOWN` | GitHub is still computing — note it, re-run `/fixpr` later. |
| `mergeStateStatus` | `BEHIND` | Branch is behind main — rebase and force-push: `git fetch origin main && git rebase origin/main && git push --force-with-lease` |
| `mergeStateStatus` | `BLOCKED` | Required status checks failing or required reviews missing — already handled by Steps 3-6, but report any remaining blockers. |
| `mergeStateStatus` | `UNSTABLE` | A non-required check is pending or failing — most commonly the CR/Greptile review on the new SHA. If Step 6d emitted `REVIEW_PENDING`, stop with that status — do NOT declare CLEAN. Re-run `/fixpr` after the review completes. |
| `reviewDecision` | `CHANGES_REQUESTED` | A human reviewer requested changes — report to user (cannot auto-resolve human review requests). |

Print:
```
[MERGE] mergeable: MERGEABLE, mergeStateStatus: CLEAN, reviewDecision: APPROVED → no blockers
```
or:
```
[MERGE] mergeable: CONFLICTING → rebasing onto main...
[MERGE] rebase complete, force-pushed (SHA: <new-sha>)
```

**After any rebase + force-push:** Wait for CI to start, then note: "CI re-triggered after rebase. Run `/fixpr` again after CI completes to verify."

---

## Step 8: Final summary

```
=== fixpr complete ===
PR:              #$PR_NUMBER ($BRANCH)
Threads:         N total, M were unresolved
  - Fixed:       X findings in code
  - Resolved:    Y threads via GraphQL
  - Stuck:       Z threads (0 = clean)
CI checks:       P total, Q were failing
  - Fixed:       R failures in code
  - Transient:   S (cannot fix locally)
Merge state:     mergeable=$MERGEABLE, status=$MERGE_STATE, review=$REVIEW_DECISION
  - Rebased:     yes/no
  - Conflicts:   none | resolved | unresolvable
Push:            <sha> (or "no push needed")
Status:          CLEAN | THREADS_STUCK | REVIEW_PENDING | CI_PENDING | CI_FAILING | CONFLICTS | NEEDS_HUMAN_REVIEW | NEW_FINDINGS
```

**Status definitions:**
- `CLEAN` — **all four conditions met simultaneously:** zero unresolved threads (Step 6a), zero new bot comments since `$RUN_STARTED_AT` that classify as findings (Step 6b), every CR/Greptile commit status is `success` on the current HEAD (Step 6d), and no merge blockers (Step 7). Missing any one of the four disqualifies `CLEAN` — use the more specific status below.
- `THREADS_STUCK` — some threads could not be resolved via GraphQL (report which)
- `REVIEW_PENDING` — Step 6d found a CR/Greptile commit status still in `pending` on the current HEAD. The bot has not finished reviewing the latest push. Re-run `/fixpr` after the status flips to `success`. Do NOT declare CLEAN.
- `NEW_FINDINGS` — Step 6b found new bot comments (review body, inline, or PR-conversation) posted after `$RUN_STARTED_AT` that classify as findings. Stop the run. Re-run `/fixpr` (a fresh invocation captures a new `$RUN_STARTED_AT` and re-audits from Step 1, including the new findings).
- `CI_PENDING` — push/rebase was made, CI not yet complete (re-run `/fixpr` after CI)
- `CI_FAILING` — transient CI failures that cannot be fixed locally (report which)
- `CONFLICTS` — merge conflicts could not be auto-resolved (needs manual intervention)
- `NEEDS_HUMAN_REVIEW` — a human reviewer requested changes (cannot auto-resolve)
