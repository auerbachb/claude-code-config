---
name: fixpr
description: Single-pass PR cleanup — audit every review thread + every CI check-run, fix all issues, push once, resolve all threads via GraphQL, verify CI green. Zero uncollapsed threads and zero failing checks when done.
---

Single-pass cleanup of the current branch's PR. After this completes:

1. **Zero uncollapsed review threads** in the browser (all resolved via GraphQL)
2. **Zero failing CI checks** (all fixed and passing)
3. **Every finding replied to** with what was done

### Batching before burning CR quota (Issue #28)

CodeRabbit caps **~8 GitHub PR reviews per hour** per account; **each push** consumes one. **Multi-round PRs** exhaust that budget fast if you fix-and-push repeatedly.

**Coalesce locally first:** Before opening `/fixpr` on minor iterations, run **`coderabbit review --prompt-only`** per `cr-local-review.md` on uncommitted changes when feasible — catch issues **before** they cost a GitHub review.

**Coalesce inside `/fixpr`:** Steps 1–3 intentionally gather **every** unresolved finding + every failing CI check, then fix **all** actionable items and **`git push` once**. Never push once per finding. One `/fixpr` cycle should produce **at most one** consume-side CR review per completed push (tracked below).

## How this skill is structured

All mechanical GitHub API work — pagination, GraphQL queries, comment classification — lives in the shared script `.claude/scripts/pr-state.sh`. This file tells the AI layer how to invoke the script and what to do with its output (the JSON bundle).

| Step | Kind | Done by |
|------|------|---------|
| 0. Gather PR state | Mechanical | `pr-state.sh` writes `/tmp/pr-state-<PR>-<epoch>.json` |
| 1. Classify review findings | Judgment | AI reads JSON + source files |
| 2. Classify CI failures | Judgment | AI reads `check-runs/<id>.output.summary` |
| 3. Fix & push | Judgment | AI edits files, commits, pushes |
| 3b. Trigger missing AI reviewers | Mechanical | wait 2 minutes, detect CR/Graphite/CodeAnt activity on the new SHA, post triggers for missing bots, always post `@cursor review` |
| 4. Reply & resolve | Mechanical | `gh api` calls against IDs from the JSON |
| 4c. Post-push thread verify (if Step 3 pushed) | Mechanical | Re-fetch threads on new HEAD; explicitly resolve any touched thread still `isResolved: false` (fixes unchanged-line orphans), then `--verify-only` |
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
3. Auto-decide the disposition:
   - **fix** — code still has the issue, or the conservative change is safe → must fix
   - **decline-high-confidence** — finding is invalid, obsolete, or intentionally not applicable with confidence >= 50% → reply with rationale and resolve silently
   - **surface-low-confidence** — confidence < 50% because this is a genuine design/product/user-preference decision → still reply and resolve on GitHub, then list it in the final chat summary with rationale and override prompt
   - **already-fixed** — code no longer matches the finding → resolve only
   - **outdated** — file/line no longer exists → resolve only

Do not ask the user before deciding. GitHub is the audit surface and chat is the decision surface: every thread touched by `/fixpr` must end resolved on GitHub, whether the decision was fix or decline.

Print the numbered list:

```text
[FINDING 1] fix — src/foo.ts:42 — "unused import" (coderabbitai[bot]) — confidence 90%
[FINDING 2] decline-high-confidence — src/bar.ts:10 — "missing null check" (coderabbitai[bot]) — confidence 80%
[FINDING 3] surface-low-confidence — src/baz.ts:55 — "change retry policy" (cursor[bot]) — confidence 40%
[FINDING 4] outdated — src/deleted.ts:5 — file removed (greptile-apps[bot])
```

Keep running counters for final chat output:

- `FIXED_COUNT`: findings classified `fix` and changed in code
- `DECLINED_SILENT_COUNT`: findings classified `decline-high-confidence`, `already-fixed`, or `outdated`
- `SURFACED_COUNT`: findings classified `surface-low-confidence`

For every `surface-low-confidence` item, capture file, finding, decision, rationale, alternative considered, and the override prompt for Step 7.

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
PUSHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
git push
DID_PUSH=1
```

Print: `[PUSH] committed and pushed (SHA: $(git rev-parse --short HEAD))`.

If nothing needed fixing (all already-fixed/outdated, CI all green), skip the commit/push and set `DID_PUSH=0` (do not run Step 4c).

**Record hourly CR consumption** after a successful push (atomic budget guard):

```bash
CR_HOURLY_SCRIPT=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/cr-review-hourly.sh" \
  "$HOME/.claude/scripts/cr-review-hourly.sh" \
  ".claude/scripts/cr-review-hourly.sh"; do
  if [[ -x "$candidate" ]]; then
    CR_HOURLY_SCRIPT="$candidate"
    break
  fi
done
if [[ -n "$CR_HOURLY_SCRIPT" ]]; then
  if ! CR_SNAPSHOT="$("$CR_HOURLY_SCRIPT" --consume)"; then
    echo "[CR-HOURLY] WARNING: hourly CR budget appears exhausted — $CR_SNAPSHOT"
    echo "[CR-HOURLY] Prefer local coderabbit review + cooldown before more pushes; see cr-github-review.md"
  else
    echo "[CR-HOURLY] recorded push-level review event — $CR_SNAPSHOT"
  fi
else
  echo "[CR-HOURLY] cr-review-hourly.sh not found — skip consumption tracking"
fi
```

---

## Step 3b: Trigger missing AI reviewers after a push

Only run this step when Step 3 made a push. If Step 3 skipped the commit/push, skip this step too.

Re-resolve the hourly helper path (Step 3 may not have run in the same shell):

```bash
CR_HOURLY_SCRIPT=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/cr-review-hourly.sh" \
  "$HOME/.claude/scripts/cr-review-hourly.sh" \
  ".claude/scripts/cr-review-hourly.sh"; do
  if [[ -x "$candidate" ]]; then
    CR_HOURLY_SCRIPT="$candidate"
    break
  fi
done
```

Use the `$PUSHED_AT` captured immediately before `git push` in Step 3. Capturing it before the push avoids a race where a fast bot starts between push completion and the timestamp capture. After the push completes, wait exactly 2 minutes before checking reviewer status so CodeRabbit / Graphite / CodeAnt auto-triggers have time to post activity (BugBot is covered separately — always trigger `@cursor review` unconditionally; see `bugbot.md` and memory `feedback_bugbot_auto_trigger_unreliable.md`):

```bash
PUSHED_SHA=$(git rev-parse HEAD)
echo "[REVIEWERS] waiting 120s for auto-triggered reviewers on ${PUSHED_SHA:0:7}"
sleep 120
```

Detect activity from the 3 conditionally triggered reviewers (CodeRabbit, Graphite, CodeAnt) on the pushed SHA. Check all three PR comment endpoints plus check-runs for activity after `$PUSHED_AT`. Conversation-level comments do not expose a `commit_id`, so they only count as activity on the pushed SHA when the body mentions the full SHA or short SHA; otherwise, use SHA-scoped reviews, inline comments, or check-runs to avoid treating a late summary from the previous SHA as coverage for the new one:

```bash
REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" | jq -s 'add // []')
INLINE=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments?per_page=100" | jq -s 'add // []')
CONVO=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" | jq -s 'add // []')
CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$PUSHED_SHA/check-runs?per_page=100" --jq '.check_runs[]' | jq -s '.')

REVIEWER_ACTIVITY=$(jq -n \
  --arg pushed_at "$PUSHED_AT" \
  --arg sha "$PUSHED_SHA" \
  --argjson reviews "$REVIEWS" \
  --argjson inline "$INLINE" \
  --argjson convo "$CONVO" \
  --argjson checks "$CHECK_RUNS" \
  '
  def recent($ts): ($ts // "") >= $pushed_at;
  def matches_any($value; $needles):
    ($value // "" | ascii_downcase) as $haystack
    | any($needles[]; (. | ascii_downcase) as $needle | $haystack | contains($needle));
  def check_by($names):
    any($checks[]?;
      (((.name // "") as $name
        | (.app.slug // "") as $slug
        | (.app.name // "") as $app
        | (matches_any($name; $names) or matches_any($slug; $names) or matches_any($app; $names))))
      and recent(.started_at // .created_at // .completed_at));
  def convo_by($login):
    any($convo[]?;
      .user.login == $login
      and recent(.created_at)
      and (((.body // "") | contains($sha)) or ((.body // "") | contains($sha[0:7]))));
  {
    coderabbit:
      (any($reviews[]?; .user.login == "coderabbitai[bot]" and .commit_id == $sha and recent(.submitted_at))
       or any($inline[]?; .user.login == "coderabbitai[bot]" and ((.commit_id // .original_commit_id // "") == $sha) and recent(.created_at))
       or convo_by("coderabbitai[bot]")
       or check_by(["CodeRabbit", "coderabbitai"])),
    graphite:
      (any($reviews[]?; .user.login == "graphite-app[bot]" and .commit_id == $sha and recent(.submitted_at))
       or any($inline[]?; .user.login == "graphite-app[bot]" and ((.commit_id // .original_commit_id // "") == $sha) and recent(.created_at))
       or convo_by("graphite-app[bot]")
       or check_by(["Graphite", "graphite-app"])),
    codeant:
      (any($reviews[]?; .user.login == "codeant-ai[bot]" and .commit_id == $sha and recent(.submitted_at))
       or any($inline[]?; .user.login == "codeant-ai[bot]" and ((.commit_id // .original_commit_id // "") == $sha) and recent(.created_at))
       or convo_by("codeant-ai[bot]")
       or check_by(["CodeAnt", "codeant-ai"])),
  }')
```

For each of **coderabbit**, **graphite**, **codeant** whose value is `false`, post exactly one dedicated PR-level trigger comment. Do not batch mentions; combined-mention comments fail to trigger reliably. Post these comments sequentially in this order, skipping reviewers that already auto-triggered. CodeRabbit is additionally capped at 2 manual `@coderabbitai full review` triggers per PR in the trailing hour:

```bash
jq -r 'to_entries[] | "[REVIEWERS] \(.key): \(if .value then "auto-triggered" else "missing" end)"' <<<"$REVIEWER_ACTIVITY"

CR_TRIGGER_COUNT_LAST_HOUR=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" | jq -s '
  (add // [])
  | map(select(
      (.body // "") == "@coderabbitai full review"
      and ((.created_at // "") >= (now - 3600 | strftime("%Y-%m-%dT%H:%M:%SZ")))
    ))
  | length
')

if [[ "$(jq -r '.coderabbit' <<<"$REVIEWER_ACTIVITY")" != "true" ]]; then
  if [[ "$CR_TRIGGER_COUNT_LAST_HOUR" -lt 2 ]]; then
    if gh pr comment "$PR_NUMBER" --body "@coderabbitai full review"; then
      # Persist explicit trigger only when the comment actually posted (avoid ghost timestamps on gh failure)
      if [[ -n "$CR_HOURLY_SCRIPT" ]]; then
        "$CR_HOURLY_SCRIPT" --record-explicit "$PR_NUMBER" || true
      fi
    else
      echo "[REVIEWERS] FAILED to post @coderabbitai full review — check gh auth scopes; not recording explicit trigger" >&2
    fi
  else
    echo "[REVIEWERS] coderabbit trigger budget exhausted (>=2 in the last hour); skipping manual trigger"
    if [[ -n "$CR_HOURLY_SCRIPT" ]]; then
      echo "[REVIEWERS] Surface to user: this PR has hit 2 explicit @coderabbitai full review posts in the last hour — CodeRabbit may be rate-limited; wait for reviews or use local CR (cr-local-review.md)."
    fi
  fi
fi
if [[ "$(jq -r '.graphite' <<<"$REVIEWER_ACTIVITY")" != "true" ]]; then
  gh pr comment "$PR_NUMBER" --body "@graphite-app re-review"
fi
if [[ "$(jq -r '.codeant' <<<"$REVIEWER_ACTIVITY")" != "true" ]]; then
  gh pr comment "$PR_NUMBER" --body "@codeant-ai review"
fi
gh pr comment "$PR_NUMBER" --body "@cursor review"
```

Cost/rate-limit note: `@codeant-ai review` may consume CodeAnt’s review budget, so skip it when auto-trigger activity is already present on the new SHA. **`@cursor review` is always posted** after a `/fixpr` push (composes with CI and issue #370’s four-reviewer triggers); BugBot is per-seat with no per-call charges — duplicates are acceptable. Greptile is intentionally NOT part of this proactive trigger set; it remains last-resort only per `greptile.md`.

---

## Step 4: Reply and resolve every thread

For every entry in `.threads.unresolved` — fix, decline-high-confidence, surface-low-confidence, already-fixed, or outdated:

### 4a. Reply

Pull the IDs from the JSON:

```bash
# index <i> in each call — iterate 0..unresolved_count-1
DBID=$(jq -r ".threads.unresolved[$i].comments.nodes[0].databaseId" "$AUDIT")
```

Reply text by classification:

- **fix:** `"Fixed in \`<short-sha>\`: <one-line description>"`
- **decline-high-confidence:** `"Reviewed and intentionally declined: <one-line rationale>. Resolving so GitHub stays an audit surface."`
- **surface-low-confidence:** `"Reviewed and resolved on GitHub; surfacing the decision in chat because confidence is <50%: <one-line rationale>."`
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

After all replies are posted, resolve and verify exactly the threads `/fixpr` touched. Build the expected-resolved set from the GraphQL thread IDs for every item replied to in 4a (same set you will re-verify in Step 4c after a push):

```bash
TOUCHED_THREADS=$(mktemp -t fixpr-touched-threads.XXXXXX)
# append one GraphQL thread node id per unresolved thread from the Step 0 audit
jq -r '.threads.unresolved[].id' "$AUDIT" > "$TOUCHED_THREADS"

THREAD_RESOLUTION_OUTPUT=$(bash .claude/scripts/resolve-review-threads.sh "$PR_NUMBER" \
  --thread-ids-file "$TOUCHED_THREADS" --max-attempts 2 2>&1)
echo "$THREAD_RESOLUTION_OUTPUT"
```

**Unchanged-line threads:** GitHub only auto-resolves a review thread when the **exact** commented line changes. If `/fixpr` fixed the issue by editing nearby code (or declined/OBE), the thread can stay `isResolved: false` after Step 4b until the script runs `resolveReviewThread` / `minimizeComment` on that thread id. The explicit `--thread-ids-file` set forces resolution for **every** addressed thread, not only those GitHub auto-closed.

The script re-fetches `pullRequest.reviewThreads` via GraphQL after each mutation pass and again before exit. For any touched thread still reporting `isResolved: false`, it retries `resolveReviewThread` and falls back to `minimizeComment(classifier: RESOLVED)`. Exit codes: `0` means every touched thread was verified resolved; `1` means at least one dangling thread remains and `/fixpr` must not declare success; `3` PR not found; `4` gh error. It prints `[VERIFY] addressed=N resolved=M dangling=K` plus `[STUCK]` lines with URLs/reasons for every dangling thread.

Keep `$TOUCHED_THREADS` until after Step 4c (same path as Step 4b).

### 4c. Post-push: re-resolve and verify touched threads on the new HEAD

Run **only when Step 3 pushed** (`DID_PUSH=1`). A new commit can reopen threads that were resolved on the prior HEAD (or leave unchanged-line threads still open until an explicit resolve sees the post-push graph).

1. Run the same resolve pass again against the **same** `TOUCHED_THREADS` file (fresh GraphQL fetch on current HEAD).
2. Run a read-only verification pass so completion is blocked until a **second** GraphQL read shows every addressed id as `isResolved: true`.

```bash
POST_PUSH_RESOLVE_FAILED=0
POST_PUSH_VERIFY_FAILED=0
POST_PUSH_THREAD_OUTPUT=""
POST_PUSH_VERIFY_OUTPUT=""
if [[ "${DID_PUSH:-0}" -eq 1 ]]; then
  POST_PUSH_THREAD_OUTPUT=$(bash .claude/scripts/resolve-review-threads.sh "$PR_NUMBER" \
    --thread-ids-file "$TOUCHED_THREADS" --max-attempts 2 2>&1) || POST_PUSH_RESOLVE_FAILED=1
  echo "$POST_PUSH_THREAD_OUTPUT"
  POST_PUSH_VERIFY_OUTPUT=$(bash .claude/scripts/resolve-review-threads.sh "$PR_NUMBER" \
    --thread-ids-file "$TOUCHED_THREADS" --verify-only 2>&1) || POST_PUSH_VERIFY_FAILED=1
  echo "$POST_PUSH_VERIFY_OUTPUT"
fi
```

Treat non-zero exit from either sub-step as `THREADS_STUCK` in Step 7 (do not declare `CLEAN`). On success, both lines print `[VERIFY] addressed=N resolved=N dangling=0`.

When `TOUCHED_THREADS` is empty (no threads from Step 0’s `.threads.unresolved`, e.g. CI-only fix with a push), `--verify-only` still runs but is a **no-op**: it prints `[VERIFY] addressed=0 resolved=0 dangling=0` and exits 0 — do not treat that as failure.

When `DID_PUSH=0`, omit Step 4c; Step 4b’s resolver output alone is authoritative for touched threads.

---

## Step 5: Verify

Run the audit script again with `--since $RUN_STARTED_AT`. This picks up the new HEAD SHA (post-push) **and** pre-classifies any bot comment that landed between Step 0 and now:

```bash
VERIFY=$("$SCRIPT" --since "$RUN_STARTED_AT")
```

### 5a. Threads

The Step 4b resolver (and, when `DID_PUSH=1`, Step 4c’s resolve + `--verify-only` passes) re-fetched `pullRequest.reviewThreads` via GraphQL, retried `resolveReviewThread`, used `minimizeComment(classifier: RESOLVED)` as fallback, and printed addressed/resolved/dangling counts. Re-state the **latest** `[VERIFY]` line(s) here from `THREAD_RESOLUTION_OUTPUT` plus `POST_PUSH_THREAD_OUTPUT` / `POST_PUSH_VERIFY_OUTPUT` when Step 4c ran; do not recompute from `.threads.unresolved_count` alone because `/fixpr` must verify the specific threads it replied to.

```bash
UNRESOLVED=$(jq -r '.threads.unresolved_count' "$VERIFY")
```

- If the resolver's dangling count is `0` and `UNRESOLVED == 0` → `[CLEAN] All threads resolved — zero uncollapsed in browser.`
- If the resolver's dangling count is `0` but unrelated reviewer threads remain unresolved → run `bash .claude/scripts/resolve-review-threads.sh "$PR_NUMBER"` once to resolve them too. `/fixpr` never leaves reviewer threads open as a paper trail.
- If the resolver reports dangling threads → emit `THREADS_STUCK` and list each `[STUCK]` URL/reason. Do not declare success.

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

1. **Explicit-resolution / clean-pass overrides** (checked first — these signals mean CR has already marked the thread addressed, posted a rate-limit notice, or posted a review-started ack, so they win even if the body still contains finding language from a quoted earlier review):
   - HTML marker `<!-- <review_comment_addressed> -->` → `acknowledgment`
   - `actionable comments posted: 0` → `acknowledgment`. This specific zero-count pattern MUST be checked before the general `actionable comments posted` pattern below — otherwise the general finding pattern would swallow the zero case.
   - `no actionable comments were generated` → `acknowledgment`
   - `rate limit exceeded` → `acknowledgment`
   - `full review triggered` → `acknowledgment`
2. **Finding patterns**:
   - Severity keywords `\b(critical|major|minor|nitpick|p[0-2])\b` or badges `🔴|🟠|🟡`
   - Actionable phrases: `actionable comments posted` (non-zero), `issues? found`, `findings?:`, `potential[_ ]issue`
   - Fix markers: a fenced ```` ```suggestion ```` block, or a `Prompt for AI Agent` heading
3. **Weak-ack fallbacks** (only if no finding matched):
   - LGTM variants: `lgtm`, `looks good`, `approved`, `confirmed`, `resolved`
4. **Default** (no pattern matched) → `finding`. The safer default — under-classifying here is the failure mode this whole skill exists to prevent.

**If `finding_count > 0`:** do NOT loop. Emit `NEW_FINDINGS` in Step 7 and stop. Re-running `/fixpr` captures a new `$RUN_STARTED_AT` and re-audits from Step 0, picking up the new findings.

### 5c. CI (if a push was made; exclude review-bot check-runs from CI pending)

The verify audit's `.check_runs` reflects the new HEAD.

```bash
jq -r '.check_runs.all[] | "[CI] \(.name): \(.status)\(if .conclusion then " — \(.conclusion)" else "" end)"' "$VERIFY"

CHECK_BUCKETS=$(jq '
  def is_review_bot:
    (.name // "" | ascii_downcase) as $name
    | (.app.slug // "" | ascii_downcase) as $slug
    | (.app.name // "" | ascii_downcase) as $app
    | ($name | contains("coderabbit")
       or contains("graphite")
       or contains("codeant")
       or contains("cursor"))
      or ($slug | contains("coderabbit")
         or contains("graphite")
         or contains("codeant")
         or contains("cursor"))
      or ($app | contains("coderabbit")
         or contains("graphite")
         or contains("codeant")
         or contains("cursor"));
  {
    ci: [.check_runs.all[] | select(is_review_bot | not)],
    review: [.check_runs.all[] | select(is_review_bot)]
  }
' "$VERIFY")
CI_CHECKS=$(jq '.ci' <<<"$CHECK_BUCKETS")
REVIEW_BOT_CHECKS=$(jq '.review' <<<"$CHECK_BUCKETS")

FAILING=$(jq '[.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure" or .conclusion == "stale")] | length' <<<"$CI_CHECKS")
IN_PROGRESS=$(jq '[.[] | select(.status != "completed")] | length' <<<"$CI_CHECKS")
REVIEW_IN_PROGRESS=$(jq '[.[] | select(.status != "completed")] | length' <<<"$REVIEW_BOT_CHECKS")
```

Decide from the non-review CI counts before review-bot pending counts:

- `IN_PROGRESS > 0` on non-review-bot checks → emit `CI_PENDING` in Step 7. Re-run `/fixpr` after CI finishes.
- `REVIEW_IN_PROGRESS > 0` with no non-review-bot CI pending/failing → defer to Step 5d and emit `REVIEW_PENDING`, not `CI_PENDING`.
- `IN_PROGRESS == 0 && FAILING > 0` → read each entry in `.check_runs.failing_runs` from the VERIFY audit. Classify:
  - **deterministic** (lint/typecheck/test/build/security reports a real error) → emit `CI_FAILING` in Step 7 and stop. Re-run `/fixpr` so Steps 2–3 can retry the fix on the newly-visible error.
  - **transient** (runner timeout, startup failure, flaky external dep) → emit `CI_FAILING` in Step 7, note the specific checks, and continue to Step 6 — local fixes aren't possible and the user decides whether to retry.
- `IN_PROGRESS == 0 && FAILING == 0` → non-review-bot CI is clean on this SHA.

Do NOT poll.

### 5d. Review-bot commit statuses on the current HEAD

CR and Greptile report review completion via commit *statuses*, while Graphite, CodeAnt, and Cursor may report via check-runs. `pending` means a bot is still analyzing the current HEAD — declaring CLEAN while pending is the exact failure mode this verify step was built to prevent.

```bash
jq -r '
  .bot_statuses | to_entries[] | "[VERIFY-BOTS] \(.key): \(.value.state) (\(.value.updated_at))"
' "$VERIFY"
```

For each bot present in `.bot_statuses` or the current-head check-runs:

- `state: success` → review completed on this SHA. Clean-pass signal.
- `state: pending` or check-run `status != "completed"` → bot still running. **Do NOT declare CLEAN.** Emit `REVIEW_PENDING` and stop.
- `state: failure` / `error` with "rate limit" in `description` → CR rate-limited, fall back to Greptile per `cr-github-review.md`.
- No activity from CodeRabbit, Graphite, CodeAnt, or Cursor after a pushed fix commit → the Step 3b trigger check should already have posted the reviewer-specific comment. Emit `REVIEW_PENDING` and re-run `/fixpr` after the reviewer responds.

---

## Step 6: Check merge blockers

```bash
jq -r '.merge_state | "[MERGE] mergeable=\(.mergeable), status=\(.mergeStateStatus), review=\(.reviewDecision)"' "$VERIFY"
```

| Field | Blocking value | Action |
|-------|---------------|--------|
| `mergeable` | `CONFLICTING` | Rebase onto main: `git fetch origin main && git rebase origin/main`. Fix conflicts (optionally run **`/merge-conflict`** — `.claude/skills/merge-conflict/SKILL.md` — to fetch main, auto-resolve *simple* hunks, stage clean files, and list *complex* hunks), continue, force-push. |
| `mergeable` | `UNKNOWN` | GitHub still computing — note and re-run `/fixpr` later. |
| `mergeStateStatus` | `BEHIND` | Rebase onto main: `git fetch origin main && git rebase origin/main`. If conflicts arise mid-rebase (replaying commits individually can conflict even when a three-way merge wouldn't), resolve them the same way as `CONFLICTING` above (including optional **`/merge-conflict`**), then `git rebase --continue`. Force-push. Wait for CI to re-run before verifying merge gate. |
| `mergeStateStatus` | `BLOCKED` | Required checks/reviews missing — already covered by 5c/5d. If CodeRabbit, Greptile, or CodeAnt is in CODEOWNERS and the last approval is stale/dismissed after a push, recover by triggering that bot (`@coderabbitai full review`, `@greptileai`, or `@codeant-ai review`) instead of escalating to the author. |
| `mergeStateStatus` | `UNSTABLE` | A non-required check pending/failing — typically CR/Greptile on the new SHA. If 5d emitted `REVIEW_PENDING`, stop with that status. |
| `reviewDecision` | `CHANGES_REQUESTED` | Changes were requested. If the requester is a bot, process findings through this skill; if a human requested changes, report it as non-automatable. |

When residual branch protection says review is missing or `reviewDecision != "APPROVED"`, run `.claude/scripts/merge-gate.sh "$PR_NUMBER"` and read `.code_owner_bots`. If it lists `coderabbitai[bot]`, `greptile-apps[bot]`, or `codeant-ai[bot]`, a current-HEAD **`APPROVED`** review from that bot satisfies GitHub's code-owner requirement. CodeAnt **check-run success** only covers the supplemental CR-path cleanliness rule in `cr-merge-gate.md`; it does **not** replace an `APPROVED` when CodeAnt is a code owner. A stale/dismissed bot approval is recoverable review debt: trigger the matching bot and re-run the gate after it responds. Do not ask the PR author for an approval GitHub will not accept.

After any rebase + force-push: `[MERGE] rebase complete, force-pushed (SHA: <new-sha>) — CI re-triggered. Re-run /fixpr after CI completes.`

---

## Step 7: Final summary

```text
=== fixpr complete ===
PR:              #$PR_NUMBER ($BRANCH)
Threads:         N total, M were unresolved
  - Addressed:   A threads replied to by /fixpr
  - Resolved:    Y addressed threads verified isResolved=true
  - Dangling:    Z addressed threads (0 = clean; list each URL below)
Decisions:       X fixed, D declined silently, K surfaced
  - Surfaced:    <file/thread URL> — finding; decision; rationale; alternative considered; "Reply if you want me to override this decision."
CI checks:       P total, Q were failing
  - Fixed:       R failures in code
  - Transient:   S (cannot fix locally)
Merge state:     mergeable=..., status=..., review=...
Push:            <sha> or "no push needed"
Status:          CLEAN | THREADS_STUCK | REVIEW_PENDING | CI_PENDING | CI_FAILING | CONFLICTS | BEHIND | NEEDS_HUMAN_REVIEW | NEW_FINDINGS
```

**Status definitions:**

- `CLEAN` — **all four conditions simultaneously:** zero unresolved threads (5a), `new_since_baseline.finding_count == 0` (5b), every present review-bot status/check-run for the current HEAD is complete/successful (5d), no merge blockers (6). Missing any one disqualifies `CLEAN` — pick the more specific status below.
- `THREADS_STUCK` — some threads could not be resolved via GraphQL (report which).
- `REVIEW_PENDING` — 5d found a review-bot status/check-run still pending on the current HEAD, or a reviewer has not responded yet after Step 3b (including the unconditional `@cursor review`). Re-run `/fixpr` after it flips to a completed state. Do NOT declare CLEAN.
- `NEW_FINDINGS` — 5b's `finding_count > 0`. Stop the run. A fresh `/fixpr` captures a new `$RUN_STARTED_AT` and re-audits from Step 0.
- `CI_PENDING` — push was made, and non-review-bot CI is not yet complete. Re-run `/fixpr` after CI.
- `CI_FAILING` — transient CI failures that cannot be fixed locally (report which).
- `CONFLICTS` — merge conflicts could not be auto-resolved (needs manual intervention).
- `BEHIND` — branch behind base, auto-rebased and force-pushed; now waiting for CI re-run. Re-run `/fixpr` after CI completes.
- `NEEDS_HUMAN_REVIEW` — a human reviewer requested changes, or no configured code-owner bot can satisfy the missing required approval. If CR/Greptile is in CODEOWNERS and only its approval is stale/dismissed, downgrade to `REVIEW_PENDING` after triggering the bot re-review.
