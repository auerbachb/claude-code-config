# Active-work cap reference hotspot decision

Issue #1270. **Keep the reference together.** It explains how the
review-throughput evidence produced the shared default and why this
repo made its own override. The count contract and failure behavior
explain how those settings take effect.

The original report counted #1224 (creation), #1252, #1265, and #1267.
The current window since October 26, 2026, counts #1924 and #1937, with
zero recorded conflicts. Both current touches are steps in the same
owner decision: widen the resolver range and set this repo's cap, then
raise that cap after #1899 landed. The per-thread ceiling stays 6.

Keep the source file, settings, and anchors unchanged. Its sections
already separate the default rationale, owner override, and mechanics.
Reconsider if an independent section starts changing on its own,
the score grows to 4, or a recorded conflict shows a cost.
