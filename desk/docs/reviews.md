## Reviews (issue #1756)

Reviews are pulled from GitHub, so no thread has to cooperate: a PR merged
from any tool, and any issue filed through `/issue-maker` or the desk, becomes
one `R-n` to look at. Summaries are lazy and layered, written by the desk only
when the operator asks, never at wrap time.

| Piece | What it does |
|-------|--------------|
| `sync-reviews [--since TIME] [--json]` | Adds one Review per PR you authored that merged in the window (`gh search prs --author @me --merged`) and per issue you filed in it whose body has the line `_Captured via /issue-maker._`, in any repository. Prints one line per new Review and a tally |
| `bin/pr-summary-material.sh OWNER/REPO N --level 1\|2\|3 [--path FILE]` | Read-only: prints the raw material for one PR or issue at a depth (below). `N` may be the item's key, `pr-N` or `issue-N` |
| `summary get ID [--level 1\|2]` / `summary set ID [--level 1\|2] [--file PATH]` | Reads, or caches once, a Review's level-2 summary (`items.summary_l2`, the default) or, with `--level 1`, its one line (`items.summary_l1`, migration 007, issue #1782) |
| `review ID [--comment TEXT]` | As above, and the comment rides on the `reviewed` event (a comment on an already-reviewed item is a `commented` event) |
| `review --synced-today [--comment TEXT]` | Every Review synced today (America/New_York) that is still unreviewed, in one transaction; prints the ids it marked (issue #1782) |
| `flag ID "TEXT"` | As above; the note may follow the id (the form the desk writes) or come with `--note`, once |
| `list --kind reviews --unreviewed [--json]` | The Reviews still `open` (a flagged one was read), then `N unreviewed · ~M lines at level 2` (20 lines an item); `--json` prints `{count, level2_lines, today, items}`, the items without `summary_l2` (read a cached summary with `summary get`) and with `synced_on` (issue #1782). `--kind` also takes `decisions` and `reviews` |

### Sync

- **The window.** `--since` takes a date (00:00 UTC) or an ISO 8601 time with
  a zone. Without it the window starts one hour before the stored watermark,
  which covers GitHub's search-index lag. The first sync has no watermark and
  exits 4 asking for `--since`: where Reviews begin is the operator's call,
  never a silent backfill. The watermark is the reserved state key
  `reviews_watermark` (readable with `state get`, refused by `state set`); it
  moves to the sync's start time only after every row is written, and never
  backwards.
- **Once each.** A Review is keyed on its repository (case-insensitive) plus
  `pr-N` or `issue-N`. A PR or issue that already has a Review, in any status,
  is never added again, so overlapping windows, repeated syncs, and two syncs
  at once are safe (an advisory lock serializes them). Rows are written 50 to
  a transaction; a failure leaves earlier batches written, and re-running is
  safe.
- **Bounded.** Each search asks for at most 1000 results (GitHub's cap,
  `HUMAN_QUEUE_SYNC_LIMIT` lowers it); a search that returns its limit may
  have been cut short, so the sync stops, writes nothing, and keeps the
  watermark. Each GitHub call has a deadline (`HUMAN_QUEUE_GH_TIMEOUT`,
  default 60 s). The database is checked first, so exit 7 still comes within
  two seconds and before any GitHub call. GitHub failures exit 1.
- **What is stored.** The title as the question (control characters replaced,
  at most 500 characters; a credential-shaped title becomes `PR #N (title
  withheld: it looks like a credential)`), the link and the merge or filing
  time as the two context lines, and one `asked` event noted `synced from
  GitHub`. Never a body, a diff, or a transcript: an issue's body is read only
  to find the footer. A row GitHub returns malformed is skipped and counted.

### Summary levels

| Level | A PR | An issue | Stored |
|-------|------|----------|--------|
| 1, one line | title, labels, the closing issue's title | title, labels, a body excerpt | once, as `summary_l1` (007, #1782) |
| 2, about twenty lines | level 1 plus size, body, commit subjects, files with line counts, tests touched, links | title, labels, body, link | once, as `summary_l2` |
| 3, on demand | the diff, or one file's section with `--path`, capped by lines and bytes | the full body | never |

The desk's loop for level 2: `summary get R-n`; when it exits 4 (none
cached), run `pr-summary-material.sh OWNER/REPO pr-N --level 2`, write the
summary in the operator's shape, and `summary set R-n` it. The shape is
checked: line 1 one bold statement (`**...**`), then numbered points for what
changed functionally, the judgment calls, what was deferred, the tests, and the
links (indented continuation lines and blank lines allowed), at most 40 lines
and 4000 characters, secret-checked. A different second summary is refused, so
a cached summary is never regenerated; the same text again is a no-op.
Migration `004_reviews_summary.sql` keeps `tick` from reporting an item whose
only change is its cached summary (an annotation the desk writes itself, like
`comment`); before 004 is applied the item is reported once more, nothing
else differs. After a `flag`, the desk offers to open a follow-up issue seeded
with the item's title, link, and the flag's note (the Reviews view, #1758).

`pr-summary-material.sh` exits 0 ok, 1 when GitHub fails (including a diff
GitHub will not render), 3 when the number, the `pr-`/`issue-` kind, or the
`--path` file does not exist, and 4 on usage. Its caps are
`HQ_MATERIAL_EXCERPT_CHARS` (600), `HQ_MATERIAL_BODY_CHARS` (6000),
`HQ_MATERIAL_DIFF_LINES` (2000), and `HQ_MATERIAL_DIFF_BYTES` (200000); a
section a cap cuts ends with a `[truncated: ...]` line, and a list GitHub
returned only in part (labels, closing issues, commits, files) says how many
it left out. GitHub's text is untrusted, so a CRLF prints as LF and every
other control character but tab and newline prints as `?`.

### GitHub access and tests

Every GitHub read goes through `gh`, found by `bin/lib/github.sh`:
`HUMAN_QUEUE_GH` when set, else `/opt/homebrew/bin/gh`, else `gh` on `PATH`.
`jq` is required. The tests point `HUMAN_QUEUE_GH` at `tests/lib/gh-stub.sh`,
which serves `tests/fixtures/github/` (and the search results a suite writes),
so they run offline.

- `reviews-cli.test.sh` is offline: every new validation exits 4 or 5 without
  connecting, and `pr-summary-material.sh` prints the expected sections at
  each level from the fixtures (`--path` narrowing, caps, issues, not found,
  GitHub failures, the deadline). Both shells.
- `reviews.test.sh` is live (throwaway schemas, like the suites above): three
  merged PRs and two captured issues make five Reviews and a second sync none;
  the watermark, the limit and failure paths, 120 rows across batches, two
  concurrent syncs, `flag`, `review --comment`, `summary`, `list
  --unreviewed`, and `tick` with 004. It ends with a smoke run of
  `sync-reviews` and `pr-summary-material.sh` against the real GitHub API
  (skipped when `gh` is not authenticated).

The first live `sync-reviews` against the queue's own schema, and `migrate`
for 004, are run once by hand after this merges.
