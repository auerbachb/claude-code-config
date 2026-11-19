<!-- go-on-routing:begin -->
Route `review:respond`.

**Trigger:** the lane reaches Step 5, a `token_exhaustion` entry whose `needs` is `continue_polling` (Step 5, then Step 6) or `continue_fixes` (Step 5, then Step 7, even when Step 5 exits `1`), or Step 8 returns to Step 6 or Step 7.

**Prerequisites:** the `token-exhaustion` or `unplanned` kind module routed the lane here, and the lane preflight resolved every review module. `review:prepare` ran: its helpers are resolved and Step 0b's authorship guard passed.

**Next:** `review:merge` after Step 7. Step 7 loops back to Step 6 in this module.
<!-- go-on-routing:end -->

## Step 5: Determine reviewer ownership

Resolve reviewer ownership via the shared helper (reads `.prs["<N>"].reviewer` from `~/.claude/session-state.json` first, falls back to a paginated live-history scan on all three comment endpoints):

```bash
REVIEWER=$("$REVIEWER_OF_SH" "$PR_NUM")
REVIEWER_EXIT=$?
```

Branch on exit code:
- `0` → `$REVIEWER` is one of `cr` / `bugbot` / `greptile`. Use it for Step 6.
- `1` → `unknown` printed; no bot has reviewed yet. Treat as **CR** (the default primary reviewer) and proceed to Step 6 to wait for the first review.
- `2` → `[BLOCKED]` — script/gh error; surface stderr.
- `3` → `[BLOCKED]` — PR #$PR_NUM not found (closed, merged, or invalid).
- `5` → `[BLOCKED]` — `~/.claude/session-state.json` is malformed, wrong shape, or the helper hit a runtime failure (e.g. a racing read between the validation guard and the jq lookup). Surface the helper's stderr, stop polling, and repair or remove the state file before retrying `/go-on`. Do **not** fall through to a live-history scan — sticky reviewer assignments live in session-state, and bypassing them risks mis-routing an already-escalated PR back to CR.

Output: `Reviewer: CR` / `Reviewer: BugBot` / `Reviewer: Greptile`.

---

## Step 6: Check for review response

> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read the cached JSON bundle. The inline `gh api` calls below are legacy check-run and rate-limit spot-checks retained because they target commit-level endpoints (`/commits/{SHA}/check-runs`, `/commits/{SHA}/statuses`) not covered by `pr-state.sh`. For review, inline comment, and conversation endpoint lookups, use `pr-state.sh` exclusively.

### If PR is on CR:

Check the commit status for CodeRabbit:
```bash
SHA=$(gh pr view $PR_NUM --json commits --jq '.commits[-1].oid')
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "CodeRabbit") | {status: .status, conclusion: .conclusion, title: .output.title}'
```

Also check the statuses endpoint as fallback:
```bash
gh api "repos/{owner}/{repo}/commits/$SHA/statuses" \
  --jq '.[] | select(.context | test("CodeRabbit"; "i")) | {state: .state, description: .description}'
```

**Rate limit detection:** If check-run shows `conclusion: "failure"` with title containing "rate limit" (case-insensitive), OR status shows `description` containing "rate limit" — CodeRabbit reports this status as non-blocking `state: "success"`, so do not gate on `state`:
- `[ACTION]` — CR is rate-limited. Do NOT hand-roll a fallback: run `escalate-review.sh "$PR_NUM"` and branch on its `STATUS=`. It now returns `no_reviewer` where it used to hand off to BugBot or Greptile (issue #1897): paid reviews need the owner's explicit approval in chat, so post NO `@cursor review` and NO `@greptileai`, keep `reviewer: cr`, report "paid review requires owner approval", and keep polling — CodeRabbit's free allowance may return, and the no-review override (issue #1899), unless `NO_REVIEW_OVERRIDE_MINUTES=off`, turns it into `gate_met` once its window passes. If CodeRabbit offers to pay for a review now, decline it (`.claude/reference/cr-rate-limits.md`). A paid review the owner approves is one grant for this PR and HEAD, posted only through `paid-review-grant.sh --trigger` (issue #1898; `.claude/reference/paid-review-approval.md`).

**Review completion:** If check-run shows `status: "completed"` with `conclusion: "success"`:
- CR has finished reviewing. Check for findings (Step 7).

**Review pending:** If no completion signal and no rate-limit signal:
- `[ACTION]` — CR review is still pending. Polling every 60 seconds (12-minute timeout). A clean CR check-run completion short-circuits the timeout wait — but the merge gate still requires an explicit `APPROVED` review on the current HEAD SHA (per `cr-merge-gate.md` Step 1); completion alone does not satisfy it.
- Poll all 3 endpoints each cycle for new comments from `coderabbitai[bot]`.
- Check for rate-limit signals on every poll cycle. Rate-limit signals override the timeout — escalate immediately regardless of elapsed minutes.
- After 12 minutes with no review content and no rate-limit signal: `[ACTION]` — CR timed out. Run `escalate-review.sh "$PR_NUM"` and follow its verdict; `no_reviewer` means the no-reviewer path above, never a paid trigger (issue #1897).

### If PR is on BugBot:

BugBot (`cursor[bot]`) is a PAID reviewer: a PR is here only if it was sticky on BugBot before issue #1897 or the owner approved a BugBot review in chat. Nothing re-invites it on a push; merge gate requires **1 clean BugBot review** on the current HEAD SHA (BugBot's completion signals are reliable).

Check for BugBot reviews on the current HEAD:
```bash
SHA=$(gh pr view $PR_NUM --json commits --jq '.commits[-1].oid')
gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUM/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]" and .commit_id == "'"$SHA"'")]'
gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUM/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]")]'
gh api --paginate "repos/{owner}/{repo}/issues/$PR_NUM/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]")]'
```

Also check the BugBot check-run for the completion signal:
```bash
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "Cursor Bugbot") | {status, conclusion}'
```

- BugBot has posted findings on `$SHA` → `[DONE]` — BugBot review received. Process findings (Step 7). After fixes are pushed, a re-review is a new paid review — only with the owner's approval in chat; otherwise wait for the no-review override. Any reviewer verdict on the new HEAD (a late CodeRabbit review included) disables that override (`.claude/reference/no-review-override.md`), so once one lands, stop waiting and report the blocker: the BugBot gate needs an owner-approved re-review.
- BugBot has posted a clean review (check-run `completed` with no finding comments) on `$SHA` → `[DONE]` — merge gate met (1 clean pass is sufficient for the BugBot path). Proceed to merge verification.
- No BugBot response AND <10 min since push → `[ACTION]` — Polling for BugBot (10-min timeout from push). Poll every 60 s.
- No BugBot response AND ≥10 min since push → BugBot timed out. Do NOT trigger Greptile and do NOT retry `@cursor review` — both are paid and need the owner's approval in chat (issue #1897). Report the blocker and keep polling for the no-review override.
- Stay on BugBot — do not switch back to CR. Ignore late CR reviews.

### If PR is on Greptile:

Check for Greptile comments:
```bash
gh api --paginate "repos/{owner}/{repo}/pulls/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
gh api --paginate "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
gh api --paginate "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
```

- If Greptile has posted findings: `[DONE]` — Greptile review received. Process findings (Step 7).
- If no Greptile response: `[ACTION]` — Polling for Greptile (10-minute timeout). Polling cadence stays 60 s; exit immediately when the review lands, do not keep polling to 10 min.
  - If no response after 10 minutes: `[BLOCKED]` — Greptile timed out. Performing self-review as fallback. Note: self-review does NOT satisfy merge gate.

---

## Step 7: Check for unresolved findings

Fetch review threads, 100 per page. While `pageInfo.hasNextPage` is `true`, repeat with `-F after=<endCursor>` and collect every page's `nodes` into one array:
```bash
gh api graphql -F after=null -f query='query($after: String) {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {N}) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          comments(first: 100) {
            totalCount
            pageInfo { endCursor }
            nodes {
              body
              author { login }
              createdAt
            }
          }
        }
      }
    }
  }
}'
```

Count unresolved threads from reviewers by piping the collected thread nodes (one JSON array) through this filter. It selects each unresolved thread once when a returned comment is from a review bot — `coderabbitai`, `cursor`, `codeant-ai`, `greptile-apps`, or the retired `graphite-app` (GraphQL's `author.login` drops the REST `[bot]` suffix) — **or** when the thread has more comments than were returned:

<!-- test-anchor: go-on-bot-thread-count -->
```bash
jq -c '["coderabbitai","cursor","codeant-ai","greptile-apps","graphite-app"] as $bots
  | [ .[]
      | select(.isResolved == false)
      | ((.comments.nodes // []) | length) as $got
      | ((.comments.totalCount // $got) > $got) as $truncated
      | select($truncated
               or any((.comments.nodes // [])[]; (.author.login // "") as $l | $bots | index($l) != null))
      | {id, truncated: $truncated} ]
  | {count: length, threads: .}'
```

**Comment bound (issue #1953).** The query reads the first 100 comments of each thread, so a bot comment after the 100th is not in the returned nodes. That can only over-count: a thread with more comments than were returned counts regardless of author, flagged `truncated: true` — read its remaining comments, starting from that thread's `comments.pageInfo.endCursor` (`node(id: "<thread id>") { ... on PullRequestReviewThread { comments(first: 100, after: <cursor>) { pageInfo { hasNextPage endCursor } nodes { body author { login } } } } }`, repeated until `hasNextPage` is `false`) before deciding whether it holds a finding. The Step 8 merge gate (`merge-gate.sh`) paginates every thread and blocks unresolved ones regardless of author (on `ci-only` / `ci+codeant-one-round` a non-severe finding deferred by a human reply's follow-up-issue link is exempt — `review-policy.md`), so this count never decides a merge.

Also check for issue-level review comments that may not have threads. Use the shared `pr-state.sh` helper — it fetches all three endpoints in one call, filters to the review bots (`coderabbitai[bot]`, `cursor[bot]` (BugBot), `codeant-ai[bot]`, `greptile-apps[bot]`), and pre-classifies each comment with `classification.class` (`finding` vs `acknowledgment`). The classifier only runs when `--since <iso>` is passed — pass the PR's `createdAt` to include every bot comment on the PR. The helper writes the JSON bundle to a tempfile and prints its **path** on stdout — capture the path, then read with `jq < "$BUNDLE"`:

```bash
PR_CREATED=$(gh pr view "$PR_NUM" --json createdAt --jq '.createdAt')
BUNDLE=$("$PR_STATE_SH" --pr "$PR_NUM" --since "$PR_CREATED")
jq '.new_since_baseline.conversation | map(select(.classification.class == "finding"))' < "$BUNDLE"
```

- If there are unresolved findings: `[ACTION]` — Processing N unresolved findings.
  1. Read each finding carefully
  2. Verify against actual code before fixing
  3. Fix ALL valid findings in a single commit
  4. Push once
  5. Reply to every finding confirming the fix — each thread, and each issue-level comment that has no thread. Use the shared helper with the finding's comment ID — it tries the inline `/replies` endpoint first, falls back to a PR-level comment on 404 (the path an issue-level comment's ID always takes), and applies reviewer-specific `@mention` rules (prepends `@coderabbitai` for CR; strips `@cursor`/`@greptileai`/`@codeant-ai`/`@graphite-app` for BugBot/Greptile/CodeAnt/the retired Graphite):

     ```bash
     # $REVIEWER: cr | bugbot | greptile | codeant | graphite (determined from the finding's author;
     # graphite = the retired graphite-app[bot], kept until its App is uninstalled)
     # $VERDICT: fixed | deferred | declined; $DEFECT: real | not — mandatory (issue #1842)
     # $FIX: as-given | adapted | wrong | none — mandatory (issue #1843; scored only when $DEFECT is real)
     # $REPLY must match $VERDICT: "Fixed in `<sha>`: <what changed>" for fixed,
     # the follow-up issue link for deferred, the reason for declined
     "$REPLY_THREAD_SH" <comment_id> --reviewer "$REVIEWER" \
       --body "$REPLY" --pr N \
       --verdict "$VERDICT" --defect "$DEFECT" --fix "$FIX"
     ```

     Never post "Fixed in" for a deferred or declined finding — that reply claims a resolution that did not happen. The verdict flags stamp the `review-verdict` marker the review-cost ledger reads. `--defect real` only when the finding named a behaviour the code would actually have gotten wrong; `not` for style, duplication, or a reviewer misreading. `--fix` is required with `--defect real` (issue #1843): `as-given` (suggestion applied as proposed), `adapted` (right direction, code rewritten), `wrong` (proposed fix incorrect), `none` (no fix suggested). Mapping: `review-stack-audit.md` §The marker.

     Exit code `0` means the reply posted (by either the inline endpoint or the PR-level fallback); the fallback path also emits a note to stderr. Non-zero means a genuine failure to post. See `reply-thread.sh --help` for the full contract, including PR-number-unresolvable-without-`--pr` or both-endpoints-404 (exit 3) and inline-404-then-fallback-non-404 (exit 4).

  6. Resolve the exact thread IDs you read and replied to. Write one handled thread ID per line to a temporary `$TOUCHED_THREADS` file. Include active-reviewer threads, retired Graphite threads, and human-opened threads containing a bot finding. Skip the call when there were no handled threads. The helper paginates. If resolution fails, its minimize fallback requires a bot-authored opening comment. Human-opened threads stay unresolved.

     ```bash
     "$RESOLVE_REVIEW_THREADS_SH" "$PR_NUM" --thread-ids-file "$TOUCHED_THREADS"
     ```

     A thread already resolved prints `[ALREADY-RESOLVED] <id> <url> (no mutation)` and counts as success. Exit 1 means at least one requested thread is still unresolved after both mutations, is missing from this PR, or was not found — surface the `[STUCK]` lines to the user and stop. Exit 2 with `ERROR: refused N non-thread ID(s)` means the set held a non-thread ID (a review-comment node ID or numeric `databaseId`); nothing was mutated. Exit 2 without that line is a usage error (malformed arguments, invalid PR number, conflicting options) — fix the invocation. Replace it with the thread ID the `ERROR:` line hints (thread IDs come from `reviewThreads.nodes[].id`, usually `PRRT_…`) and re-run the helper — never fall back to an inline `resolveReviewThread` mutation. Do not proceed with a non-zero exit.

  7. After fixing, go back to **Step 6** to wait for the next review.
- If no unresolved findings: `[DONE]` — No unresolved findings.
