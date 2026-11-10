# Candidate ownership script hotspot decision

Issue #1647. **Keep the read-only ownership sweep together.** The same candidate record collects the claim verdict, pause and handoff evidence, session liveness, and degraded reads. The final decision uses those fields together to dispatch an unowned candidate, surface a live or uncertain owner, or tell the caller how to resume dead work. The caller owns the adoption write.

The original window counted four changes after the script's creation in #1451:

| PR | Why it touched the script |
| --- | --- |
| #1607 | Read pause records and resume receipts by session. |
| #1623 | Guard a pipeline under `pipefail`. |
| #1627 | Record degradation for each pause source independently. |
| #1644 | Distinguish a literal string `"null"` from an absent slot. |

The current window since October 26, 2026, has zero touches on main at `e61985b1`. The detector did not report it, and the direct midnight history check confirms there is no activity below the reporting floor.

A reader or liveness classifier could be separated if several callers need it on its own. Today the readers supply one candidate's evidence and error details, and the fixture checks that those reach the same verdict without an ownership write. There is no recent churn to justify passing that state through a new helper. The script, its callers and the fixture remain unchanged.

Reconsider if a reader starts changing independently or the script records recurring conflicts. The baseline uses the schema minimum of 2 and records the measured count of zero separately. Score 4 brings the decision back for review, and a qualifying recorded conflict bypasses the growth threshold.
