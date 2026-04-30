# GraphQL — PR Review Thread Resolution

Full mutations and queries for resolving PR review threads via the GitHub GraphQL API. Referenced from `.claude/rules/cr-github-review.md` "Processing CR Feedback".

## Resolve a pull request review thread (preferred)

```bash
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "<thread_node_id>"}) { thread { isResolved } } }'
```

## Minimize a non-thread comment (fallback)

```bash
gh api graphql -f query='mutation { minimizeComment(input: {subjectId: "<node_id>", classifier: RESOLVED}) { minimizedComment { isMinimized } } }'
```

## Fetch all review threads on a PR (to get thread IDs)

```bash
gh api graphql -f query='query { repository(owner: "{owner}", name: "{repo}") { pullRequest(number: {N}) { reviewThreads(first: 100) { nodes { id isResolved comments(first: 1) { nodes { body author { login } } } } } } } }'
```

Use the returned `nodes[].id` as `threadId` in `resolveReviewThread`. Check `isResolved` before requesting a new review — unresolved threads signal outstanding work.

## Verify addressed threads after replying

When a workflow replies to review threads, keep the thread node IDs it touched and re-query
`pullRequest.reviewThreads` after the reply/resolve pass. Every touched ID must be present and
must report `isResolved: true`; otherwise retry `resolveReviewThread`, then fall back to
`minimizeComment(classifier: RESOLVED)` on the first comment node ID. Report the final
`addressed / resolved / dangling` counts and list dangling thread URLs.

GitHub only auto-resolves a thread when the **exact** diff hunk lines change. After a fix that
moves logic to a nearby line (or a decline/OBE reply), the thread often stays open until an
explicit `resolveReviewThread` runs on that thread id.

**After a new commit on the PR** (for example `/fixpr` Step 3 push), run the same resolve pass
again on the touched thread id set, then verify with a **second** GraphQL fetch so completion is
not declared on stale `isResolved` state:

```bash
bash .claude/scripts/resolve-review-threads.sh "$PR" --thread-ids-file touched.txt --max-attempts 2
bash .claude/scripts/resolve-review-threads.sh "$PR" --thread-ids-file touched.txt --verify-only
```

`--verify-only` performs no mutations; it exits non-zero if any expected id is missing or still
`isResolved: false`. With an **empty** thread-id file, it prints `[VERIFY] addressed=0 resolved=0 dangling=0` and exits 0 (CI-only pushes with no review threads).
