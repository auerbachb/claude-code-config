# Desk control skill hotspot decision

Issue #1804. **Keep [the desk control skill](../../desk/skill/SKILL.md) together.** Its startup steps share one captured interrupt default and one validated hold. Those values carry through the first tick, Monitor arming, registration, and recovery.

The original window counted #1797, #1801, and #1802; it excluded the skill's creation in #1792. The untruncated scan since October 26, 2026, at main `e61985b1` counted two changes with no recorded conflict rounds. A reporting threshold of 2 exposes them below the normal score threshold of 3. The broader #2079 portability change touched 62 files and is excluded by the detector's sweep rule.

| Recent PR | Why it touched the skill |
| --- | --- |
| #2024 | Kept interrupt queries and re-armed loops on the default captured at startup. |
| #2032 | Validated the initial hold before registration and carried it into the Monitor so the backlog refreshes when focus ends. |

The policy and release commands already live in [the interrupt reference](../../desk/skill/interrupts.md). Moving the remaining startup steps would separate instructions that must agree on the same hold, default, and session identity. Keep the six executable anchors and existing caller paths intact.

Reconsider if an independent part of the skill changes repeatedly or incurs recorded conflicts. The baseline score is 2, so score 4 brings it back for a decision. Qualifying recorded conflict cost bypasses the growth threshold.
