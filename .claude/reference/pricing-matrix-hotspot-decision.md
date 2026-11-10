# Review-stack pricing matrix hotspot decision

Issue #1277. **Keep the matrix and its published rates block together.**
The audit finds the pricing file at its existing paths. The block gives
each rate or cap its source, unit and retrieval date, beside the context
that explains the public and account-specific figures.

The original scan counted #1208 (creation), #1217, #1218, and #1230, with
zero recorded conflicts. The current window since October 26, 2026,
has one raw touch, the 82-file Graphite retirement #1951. The detector
excludes that sweep, leaving zero counted touches.

Keep the file, section anchors, and machine-readable block unchanged.
Revisit if an independently maintained rates source becomes necessary or
a recorded conflict shows a maintenance cost. The baseline uses the
schema floor of 2; the measured count is zero and score 4 triggers
another look.
