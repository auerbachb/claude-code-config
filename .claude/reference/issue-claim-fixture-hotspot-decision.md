# Issue claim fixture hotspot decision

Issue #2074. Keep `.claude/scripts/tests/issue-claim.test.sh` as one offline suite. The original report counted four merges. The untruncated 2026-10-26 to 2026-11-09 scan on main at `8ac2031e` counted six merges and no recorded conflict re-resolutions.

| Counted PR | Why the fixture changed |
|---|---|
| #1928 | Covered renewal with the same holder, retaining the original pickup time. |
| #1954 | Covered races in renewal, guarded cleanup and release. |
| #2035 | Covered logging the original pickup before releasing the claim. |
| #2064 | Verified an unreadable winning marker fails closed. |
| #2083 | Distinguished actual claim records from quoted examples. |
| #2093 | Exercised the direct chip claim across checkout creation, recovery, and a later takeover. |

PR #2079 touched 62 paths and is excluded by the 20-path sweep cutoff. The four original fixture changes accompanied the production claim script, which has a separate KEEP decision in [Issue #2072's record](issue-claim-script-hotspot-decision.md). The two newer fixture changes exercise the same ownership boundary.

The suite is 1,466 lines and groups scenarios by operation. Acquisition, renewal, release, and parsing all use the same fake GitHub state and marker history. The new Form A receipt scenarios could move to a separate suite, but their recovery case must still acquire and renew with the real claim helper and the same fixture. The history shows one new receipt change and no conflict rework, so the benefit of another harness is unproven. Both Bash versions passed all 428 assertions. Revisit a receipt-only split if those cases start changing independently, or separate another group if recorded conflicts identify a clear seam.

The baseline is score and count 6. A qualifying zero-conflict score of 12 surfaces the decision again; a qualifying hotspot with recorded conflict cost bypasses the baseline.
