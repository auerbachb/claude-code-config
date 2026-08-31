# Review Threads & Diffs

Scripts that resolve review threads and guard the branch diff through a rebase.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
| [resolve-review-threads.sh](../resolve-review-threads.sh) | Fetch PR review threads via GraphQL, resolve them, and verify `isResolved` |
| [reply-thread.sh](../reply-thread.sh) | Post a reviewer-aware reply to a PR review thread (inline endpoint, PR-level fallback) |
| [diff-survival-check.sh](../diff-survival-check.sh) | Verify a rebase or conflict resolution did not vaporize the branch's own diff |

---

[← back to the index](../README.md)
