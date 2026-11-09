# Issue claim script hotspot decision

Issue #2072. The untruncated default-branch detector after PR #2071 counted four changes to `.claude/scripts/issue-claim.sh`, with score 4 and no recorded conflict re-resolutions.

KEEP discovery, renewal and guarded release in one script. The same marker and winner rules determine which claim is current and whether the caller can write. Keeping the read, verification and write paths together makes it easier to check that renewal preserves the original claim time, release verifies the exact holder, and an unreadable newer claim cannot authorize either operation. The advisory label does not establish ownership.

| Counted PR | Ownership change |
|---|---|
| #1928 | Renewed a claim only for the same holder. |
| #1954 | Guarded renewal and release against a claim changing between reads. |
| #2035 | Recorded pickup time before claim cleanup removed that evidence. |
| #2064 | Refused a write when the newest claim could not be read reliably. |

The strongest extraction candidate is pure marker decoding: it can map a comment to typed claim data without making an ownership decision. Extract it if a second production caller needs the same decoder or if recurring conflicts show that parsing changes repeatedly collide with ownership changes. The detector recorded no conflicts, and the existing consumers call the script's command interface. Keep the winner check and write guards in the script even if the decoder moves later.
