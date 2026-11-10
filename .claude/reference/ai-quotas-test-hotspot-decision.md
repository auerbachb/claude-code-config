# Quota fixture dispatcher hotspot decision

Issue #1902. The untruncated default-branch detector after PR #2073 counted nine changes to `.claude/scripts/tests/ai-quotas.test.sh`, with score 9 and no recorded conflict re-resolutions. All three changes from the original report (#1865, #1890 and #1891) are in the count.

KEEP one test dispatcher and the existing 30 fixture groups. The dispatcher owns group selection, fake-provider preflight, and the whole-suite deadline. Each group owns its scenario assertions. That keeps shared isolation enforceable while allowing provider-specific coverage to change independently.

| Counted PRs | Why the tests changed |
|---|---|
| #1865, #1986 | Codex reset credits and HTTP response windows. |
| #1890, #1896 | Per-read outcomes and ordered provider fallback. |
| #1891, #1964 | Cross-wired profile handling and relogin notifications. |
| #1994, #2002, #2007 | Browser diagnostics, completed native reads, and Cursor token-store diagnosis. |

PR #2055 separately replaced the large suite with the current dispatcher and grouped fixtures. Its 35 changed paths exceed the detector's 20-path sweep threshold; it explains the current layout without adding to the counted baseline. Issue #1697, the local hang report, is closed.

Another split would move the dispatcher protocol to a shared helper. Revisit that if a second suite needs the same preflight and deadline contract, or if measured conflicts recur in the dispatcher itself. For now, retain one entry point and the existing module boundaries.
