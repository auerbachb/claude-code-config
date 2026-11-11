## The Reviews view (issue #1782)

The first of `/desk`'s attention increments (`skill/reviews.md`, migration
`007_reviews_summary_l1.sql`). Interrupts, policy, and feedback tags are the
second (issue #1783, "Interrupts, policy, and feedback tags" below), the day
plan and end-of-day sweep the third (issue #1784, "Day plan and end-of-day
sweep" below), and the numbered PR
outline is issue #1768.

| The operator types | The desk runs |
|--------------------|---------------|
| `reviews` | `sync-reviews`; `pr-summary-material.sh --level 1` and `summary set --level 1` for each unreviewed item with no line yet; `list --kind reviews --unreviewed --json` through `desk.jq`'s `reviews_view` |
| `open R-<n>` | `get --json`: the cached `summary_l2` when there is one (no GitHub call), else `--level 2` material, then `summary set` |
| `diff R-<n> [path]` | `pr-summary-material.sh --level 3 [--path FILE]`; nothing is stored |
| `reviewed R-<n>` / `reviewed all today` | `review R-<n>` / `review --synced-today` |
| `flag R-<n> "…"` | `flag R-<n> --note …`, the note through a quoted here-document |
| `follow up R-<n>` (`… again` after an interrupted filing) | `comment R-<n> "follow-up: filing"`, then `gh issue create --repo <the item's repo>` (seven sections, the capture footer), then `comment R-<n> "follow-up: <url>"`; a `filing` mark with no URL after it stops the next `follow up` until `again` |

- **Level 1 is cached.** One line, at most 200 characters, written by the
  desk the first time the item is listed and stored with `summary set ID
  --level 1`; write-once like level 2. Migration 007 adds the column and
  extends 004's rule, so caching either summary is not a change `tick`
  reports. Before 007, level-1 calls exit 1 naming `migrate` and the view
  prints titles.
- **The view.** One line per unreviewed item, `R-12 · PR #1787 · <line>`,
  grouped `Today · <repo> (n)`, `Yesterday · …`, or `Mon Oct 5 · …`: the day
  the item was synced (its `created_at`, America/New_York), newest first,
  then repositories by name (the owner shown only when two share a name),
  oldest item first. An item still without its line shows its title, marked
  `(title; not summarized yet)`.
- **`reviewed all today`** marks only Reviews synced today that are still
  `open`: a flagged one keeps its flag (its follow-up is open), and
  reviewing an item twice records nothing.
- **Tests.** `tests/reviews-view-offline.test.sh` checks the new validation
  (exit 4 or 5 before connecting), `reviews_view` and `review_header` on
  `tests/fixtures/reviews/unreviewed.json`, and the skill's anchors.
  `tests/reviews-view.test.sh` (live, throwaway schema, the `gh` stub)
  runs the skill's own blocks: test 5.1 (the first `open R-2` calls GitHub,
  the cache block stores level 2, a second `open` makes no GitHub call), test
  5.2 (`reviewed all today` marks R-1 and R-2 only), the grouped view, a
  `diff` that stores nothing, a flag note full of shell metacharacters stored
  byte for byte, the follow-up issue, and a store without 007.

`migrate` for 007 runs at the next `/desk` start (its step 3), or by hand.
