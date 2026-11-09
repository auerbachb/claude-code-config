# Session scheduling reconciliation hotspot decision

Issue #1297. **Keep the session-start reconciliation script together.** It checks the session and its recorded scheduling state before deciding which stale entries can be retired and which scheduled prompts should be surfaced. The command's argument handling and its liveness checks serve the same startup boundary.

The original report counted #1186, #1206, and #1243: the TestFlight cadence, the review-stack audit nudge, and support for the equals form of command options. The current window since October 26, 2026, contains zero changes to the script. The detector reported none, and a direct midnight history check agrees.

A separate audit reader could help if it gained independent callers or changed on a different cadence. Today its result is part of the same session-start report, and moving it would add a new caller boundary without evidence of recurring churn. Keep the script and the isolated scheduling fixture unchanged.

Reconsider if recurring audit changes become independent of session reconciliation, or if a recorded conflict shows a maintenance cost. The baseline uses the schema minimum of 2 with the measured zero stated separately. Score 4 resurfaces the decision, and qualifying conflict cost bypasses that threshold.
