# End-of-task reply

The canonical human output policy is `decision-only-output.md` (Issue #1873). This replaces the older fixed-slot recap and ceremony-only Eastern-time prefix.

At the terminal state of the user's requested work, give the minimal useful outcome, with a PR/artifact link when useful. Do not list phases, components, filenames, lessons, unchanged behavior, or decisions already recorded merely to fill a template. For example: “Merged [PR #123](https://github.com/owner/repo/pull/123); failure evidence remains available in CI.” If a clean `merged PR #N` line already communicates the complete outcome, do not duplicate it in another report unless the host requires a terminal reply.

When blocked, lead with the required action and practical options/consequence, then the evidence link. Preserve diagnosis, attempted recovery, AC verification, and resume state in existing artifacts. Never claim completion while work or required checks remain.

Explicit `/standup`, `/board`, summary and verbose requests retain their useful formats. Machine EXIT_REPORT/FIXPR footers and PM turnover/handoff artifacts keep their parser contracts; their existence never requires a duplicate human recap. A day-loop teardown's human-facing report follows this policy too; retain its full fixed-field data in resumable state/handoff.

Enforcement decision: `terminal-output-enforcement-decision.md` (Issue #1665) retains documentation-only human reply deduplication, with explicit limits and reconsideration triggers. Completion/closure checks and machine footers keep their existing contracts.
