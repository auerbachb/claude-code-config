# Shared session-state collector hotspot decision

Issue #1329. **Keep [the shared collector](session-state-collector.md) together.** It is the common read procedure for /pm-handoff and /end. The callers render different handoffs, but both need the same repo-scoped PR state, exact background task identities, and distinction between an empty result and a failed read.

The original report counted #1309, #1313, #1315, and #1320. A direct Git history check from midnight Eastern includes all four. A later reproduction with a bare date missed #1309, which landed at 00:37 Eastern, because Git used the invocation's time of day. An earlier detector cutoff and the explicit midnight history both reproduced the four changes. That historical boundary is separate from the current count.

The current window since October 26, 2026, has zero changes to the collector. The detector reported none and the direct midnight history check agrees. The guide already puts its data sources under separate headings. Extraction would make the callers open more references without separating a current maintenance cost. Keep the section paths and executable examples unchanged.

Reconsider if different callers need independently changing collection logic or a recorded conflict establishes a cost. The baseline uses the schema minimum of 2 with the measured count of zero stated separately. Score 4 surfaces the decision again; qualifying recorded conflict cost bypasses the threshold.
