# CR vs Greptile Reply Format Comparison

| | CodeRabbit | Greptile |
|--|-----------|----------|
| Reply format | Include `@coderabbitai` (teaches knowledge base) | **No @mention** — plain text only |
| Learns from replies | Yes | No — only from 👍/👎 reactions |
| @mention cost | Within hourly quota | $0.50-$1.00 per triggered review |

## Reply Format for Greptile Threads

- Inline comments: `gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="Fixed in \`SHA\`: <what changed>"`
- Issue/PR-level comments: `gh pr comment N --body "Fixed in \`SHA\`: <what changed>"`
- **Never** include `@greptileai` in reply bodies. The only valid use of `@greptileai` is posting a standalone comment to intentionally request a new review (P0 re-review trigger).
