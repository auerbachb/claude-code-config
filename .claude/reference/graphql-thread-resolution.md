# GraphQL — PR Review Thread Resolution

Full mutations and queries for resolving PR review threads via the GitHub GraphQL API. Referenced from `.claude/rules/cr-github-review.md` "Resolving Comment Threads on GitHub".

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
