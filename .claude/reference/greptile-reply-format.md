# CR vs BugBot vs Greptile Reply Format Comparison

| | CodeRabbit | BugBot (Cursor) | Greptile |
|--|-----------|----------------|----------|
| Reply format | Include `@coderabbitai` (teaches knowledge base) | **No @mention** — plain text only | **No @mention** — plain text only |
| Learns from replies | Yes | TBD | No — only from 👍/👎 reactions |
| @mention cost | Within hourly quota | May trigger re-review | $0.50-$1.00 per triggered review |
| Bot login | `coderabbitai[bot]` | `cursor[bot]` | `greptile-apps[bot]` |

## Every reply carries the verdict marker (issue #1842)

Post every reply to a bot finding through `reply-thread.sh` with the mandatory `--verdict`/`--defect` flags (and `--fix` with `--defect real`). A raw `gh api …/replies` or `gh pr comment` call posts **no** `review-verdict` marker, so the review-cost ledger cannot record the verdict or a `defect=real` — use the helper, which also falls back to a PR-level comment on 404 and strips the reviewer's own `@mention`:

```bash
reply-thread.sh <comment_id> --reviewer bugbot|greptile|cr|codeant \
  --body "Fixed in \`SHA\`: <what changed>" --pr N \
  --verdict fixed|deferred|declined --defect real|not \
  --fix as-given|adapted|wrong|none   # required with --defect real
```

`--defect real` only when the finding named a behaviour the code would actually have gotten wrong; `not` for style, duplication, or a reviewer misreading. `--fix` is required with `--defect real` (issue #1843): `as-given` (suggestion applied as proposed), `adapted` (right direction, code rewritten), `wrong` (proposed fix incorrect), `none` (no fix suggested). The marker is an HTML comment on its own line — it carries no `@mention` and triggers no reviewer, so the plain-text rules below are unchanged. Full mapping: `review-stack-audit.md` §The marker.

## Reply Format for BugBot Threads

- Reply via `reply-thread.sh <comment_id> --reviewer bugbot … --verdict … --defect …` (above) — inline first, PR-level fallback on 404.
- **Never** include `@cursor` in reply bodies — it may trigger a re-review.

## Reply Format for Greptile Threads

- Reply via `reply-thread.sh <comment_id> --reviewer greptile … --verdict … --defect …` (above) — inline first, PR-level fallback on 404.
- **Never** include `@greptileai` in reply bodies. The only valid use of `@greptileai` is posting a standalone comment to intentionally request a new review (P0 re-review trigger).
