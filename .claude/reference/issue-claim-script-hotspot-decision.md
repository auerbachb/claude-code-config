# Issue claim script hotspot decision

Issue #2072. The initial detector after PR #2071 counted four changes to `.claude/scripts/issue-claim.sh`. The fresh detector after PR #2083 counts five, with score 5 and no recorded conflict re-resolutions.

KEEP discovery, renewal and guarded release in one script. The same marker and winner rules determine which claim is current and whether the caller can write. Keeping the read, verification and write paths together makes it easier to check that renewal preserves the original claim time, release verifies the exact holder, and an unreadable newer claim cannot authorize either operation. The advisory label does not establish ownership.

| Counted PR | Ownership change |
|---|---|
| #1928 | Renewed a claim only for the same holder. |
| #1954 | Guarded renewal and release against a claim changing between reads. |
| #2035 | Recorded pickup time before claim cleanup removed that evidence. |
| #2064 | Refused a write when the newest claim could not be read reliably. |
| #2083 | Distinguished protocol records from quoted examples while retaining the malformed-winner guard. |

The estimate logger is a second reader of these comments. Its separate substring check picked a bot explanation instead of the authentic pickup timestamp in an offline replay of this issue. Issue #2087 tracks sharing record recognition with that reader. Keep that small protocol boundary separate from the ownership decision: the newest-marker check, renewal verification and release guards should stay together. No recorded conflicts justify splitting the ownership lifecycle.
