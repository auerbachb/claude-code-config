# CR vs BugBot vs Greptile Reply Format Comparison

| | CodeRabbit | BugBot (Cursor) | Greptile |
|--|-----------|----------------|----------|
| Reply format | Include `@coderabbitai` (teaches knowledge base) | **No @mention** — plain text only | **No @mention** — plain text only |
| Learns from replies | Yes | TBD | No — only from 👍/👎 reactions |
| @mention cost | Within hourly quota | May trigger re-review | $0.50-$1.00 per triggered review |
| Bot login | `coderabbitai[bot]` | `cursor[bot]` | `greptile-apps[bot]` |

## Reply Format for BugBot Threads

- Inline comments: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="Fixed in \`SHA\`: <what changed>"`
- Issue/PR-level comments: `gh pr comment N --body "Fixed in \`SHA\`: <what changed>"`
- **Never** include `@cursor` in reply bodies — it may trigger a re-review.

## Reply Format for Greptile Threads

- Inline comments: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="Fixed in \`SHA\`: <what changed>"`
- Issue/PR-level comments: `gh pr comment N --body "Fixed in \`SHA\`: <what changed>"`
- **Never** include `@greptileai` in reply bodies. The only valid use of `@greptileai` is posting a standalone comment to intentionally request a new review (P0 re-review trigger).
