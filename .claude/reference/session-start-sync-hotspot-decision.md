# SessionStart sync hotspot decision

Issue #1821. The untruncated default-branch detector after PR #2066 counted three changes to `session-start-sync.sh`, with score 3 and no recorded conflict rounds.

KEEP the hook as the coordinator. Its lock acquisition, deadline and decision about whether to publish depend on the same sync result. Installing the cleanup trap before acquiring the shared lock lets the lock release run on exit. The registered deadline covers lock wait and the bounded sync and publish calls, so moving only one of these steps to a separately deployed helper would make it harder to preserve the deadline and recovery rules.

| Counted PR | Hook change |
|---|---|
| #1988 | Registered the current repo for workspace sweeps without running a sweep in the hook. |
| #2006 | Updated a fixture reference after splitting the tests; the hook change was a comment. |
| #2053 | Bounded first setup and retained pending recovery when sync could not complete. |

The original report counted #1709 for the guarded test deadline, #1752 for the actual lock-wait signal, and #1817 for audit repo registration. All are merged history outside this snapshot's count.

The lock-held region protects sync and publication. The root checkout's fast-forward and repo registration have separate boundaries. Only an actual uncontended startup can clear its matching restart marker; resume, clear and compact leave live scheduling state alone. The existing [skill sync reference](skill-sync-hooks.md) remains the operational contract.

The strongest extraction candidates are notice formatting and repo registration. Neither needs to own the lock, deadline or marker state. Reconsider if changes to those parts start causing conflicts or a separately deployed caller needs them. The five test suites are already separated by concern and run on both Bash versions; this decision leaves their behavior and the hook unchanged.
