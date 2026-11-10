# Subagent usage-limit park reference hotspot decision

Issue #1693. **Keep [the park reference](subagent-thread-limit-park.md) together.** The reactive and pre-emptive paths use one park record. They share the claim, pipeline records, wake identity and resume route, so changes to ownership can affect several sections of the same procedure.

The original window counted #1628 (pre-emptive parking), #1653 (watch-only readers) and #1656 (claim-token checks). It excluded the document's creation in #1621. The recent untruncated scan on main at `8bcf2c95`, since October 26, 2026, counted two PRs with zero recorded conflict rounds. A reporting threshold of 2 makes the two changes visible below the usual score threshold of 3.

| Recent PR | Why it touched the reference |
| --- | --- |
| #2031 | Recovery reads the existing claim and wake from one immutable state snapshot. |
| #2050 | The original park identity survives claim, wake publication and recovery, which must agree about the owner. |

The watch-only posture in §8.1 is a possible extraction because its callers never claim a park. It still uses §7.1's horizon gate and §8's launch-ownership decision. Moving §8.1 now would add another reference for those callers to resolve without separating the two recent changes. Keep the existing caller paths and nine executable anchors intact.

Reconsider when watch-only changes recur independently, or when a recovery change can be isolated from claim and wake ownership. The baseline score is 2, so score 4 resurfaces the file for another decision. Qualifying recorded conflict cost bypasses the growth threshold.
