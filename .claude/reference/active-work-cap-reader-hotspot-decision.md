# Active-work cap reader hotspot decision

Issue #1269. **Keep the entry point and read the legacy offer state
once.** The first pass used to calculate the live offer count while a
second pass looked up which issues to list. If an issue closed between
reads, one invocation could report a live offer without its issue.

Derive the count and issue numbers from the same filtered set. The
count still treats a multi-issue offer as one slot. Preserve repo
attribution, existing exclusions and read failures. Registry and
pipeline totals already derive their count and identities from one
read; their behavior stays the same.

The original report counted #1224 (creation), #1250, #1252, and #1265.
The current pre-change window since October 26, 2026, contains one
change, the #1924 cap-bound update, with no recorded conflicts. The
churn baseline uses the schema floor of 2, separate from the measured
one. Reconsider if another part begins changing independently or
conflict cost shows a maintenance problem.
