# Candidate ownership fixture hotspot decision

Issue #1659. Keep `.claude/scripts/tests/candidate-ownership.test.sh` as one offline suite. The issue originally reported three changes; the history since 2026-08-22 contains five counted merges and no recorded conflict re-resolutions. The latest change was PR #1706 on 2026-09-11.

| Counted PR | Why the suite changed |
|---|---|
| #1451 | Established the shared ownership sweep and its stateful fixtures. |
| #1607 | Covered keyed pause records and resume receipts. |
| #1644 | Distinguished a stored JSON string from an absent pause slot. |
| #1658 | Verified that the Wave skill uses the shared sweep rather than its own stale filter. |
| #1706 | Covered the PM session listing and adoption of an owner that is no longer live. |

The generated catalog sweep in PR #1645 touched 239 paths, above the detector's 20-path sweep threshold. Its catalog header is not evidence of fixture maintenance.

The assertions about PM and Wave wiring could move to a separate file. The behavior cases still share one fake issue, PR, session-state, and worktree setup; a split would either repeat that setup or add a second helper boundary. The consumer assertions are stable and the history shows expected contract coverage, not a recurring conflict or separate maintenance burden. Both local Bash versions passed all 212 assertions. Revisit if the wiring checks begin changing on their own or if conflicts make the shared suite costly.

The baseline is score and count 5. The current 2× threshold suppresses a closed issue below 10 and surfaces material growth at 10.
