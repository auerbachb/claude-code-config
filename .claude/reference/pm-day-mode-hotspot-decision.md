# PM day-mode reference hotspot decision

Issue #1314. Move the captured-wake procedure into its own reference and keep the day-mode rationale and park lifecycle together. The original report counted #1245, #1293 and #1313. It included the document's creation (#1245) and a 39-file terminology rename (#1313), both excluded by the current detector's default rules. The historical count is not the current baseline.

The current untruncated scan on main at `8bcf2c95` counted four changes and no recorded conflict re-resolutions.

| Counted PR | Why the reference changed |
|---|---|
| #1988 | Added finished-worktree sweep cadence to the day tick. |
| #2041 | Prevented retired parks from receiving wake identities. |
| #2050 | Kept durable identity through a usage-limit park. |
| #2077 | Bound captured-wake recovery to the confirmed owner and added the shared executable procedure. |

The last change added a 185-line procedure that the arm and tick recovery paths invoke only after selecting an active park. It can be read and maintained separately from the day-mode rationale. [PM day wake recovery](pm-day-wake-recovery.md) now owns those steps. The old heading remains a pointer, and the /pm link and three executable fixture anchors point to the new reference. Preparation, authorization and the surrounding park-retirement contract are unchanged. The publisher saves new Monitor IDs as strings so a later recovery can match the exact ID in the owning session's registry. Legacy numeric IDs still cannot authorize a stop.

The general reference went from 396 to 215 lines and from 7,675 to 6,423 words. These are source measurements; no token or runtime savings were measured. The measured pre-extraction baseline is score and count 4. A qualifying zero-conflict score of 8 surfaces the day-mode reference again; a qualifying hotspot with recorded conflict cost bypasses the baseline.
