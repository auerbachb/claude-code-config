## Priorities: the operator's backlog order for `/pm` (issue #1767)

The desk's Priorities surface (`skill/priorities.md`; DESIGN 2.1). The
operator types `top: #a #b`, `bump #N`, `park #N until <date>`, `drop #N`, or
`priorities`, each optionally ending `in <repo>`, and `/pm` honors the order
at its next ranking or refill: ordered issues first, parked issues skipped
until their date, everything else in its own OKR-aware ranking.

- **Not in the store.** The order is a file in the target repo,
  `.claude/pm-priority.json` at its main checkout, next to `pm-config.md`
  (DESIGN 7.6: per repo). Both its writer and its reader are
  `.claude/scripts/pm-priority.sh`, which `/pm` already resolves with its other
  helpers, so `/pm` honors the file even where no desk runs. Nothing here
  touches the database.
- **Overlay, not a re-score.** `/pm` scores and excludes as it always did,
  then pipes the eligible list through `pm-priority.sh apply`. Dropping an
  issue therefore restores its ranked place, and an absent file changes
  nothing. An unreadable file stops `/pm`'s autonomous launches until it reads
  again, because it may be hiding a park.
- **Tests.** `.claude/scripts/tests/pm-priority.test.sh` covers the helper
  (tests 5.1 and 5.2, AC 4.3, a corrupt file, worktrees, concurrent writers,
  `--repo`) and `/pm`'s own blocks. `tests/priorities-offline.test.sh` covers
  this skill: the routing lines and the anchored block run against the real
  helper.
