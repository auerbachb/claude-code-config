# Subagent park fixture hotspot decision

Issue #1682. The default-branch detector after PR #2089 counted three merges touching `.claude/scripts/tests/subagent-limit-park.test.sh` since October 26, 2026: #2031, #2050, and #2077. Its score is 3, with zero recorded conflict re-resolutions. The four older PRs from the original issue explain the fixture's layout; they are outside this baseline window.

**Decision: keep the fixture together.** The tests exercise one contract: a thread records a usage-limit park, recovers the correct generation and owner, and resumes only the work it owns. The fixture gives those cases one isolated home and uses the real session-state, park generation, wake publishing, and retirement helpers. The reactive and pre-emptive paths meet at ownership and wake publication, where the suite checks that one adopts or yields to the other.

| Changes | What they exercise |
| --- | --- |
| #1628, #1650 | Pre-emptive parking and the compare-and-set claim for reactive parking. |
| #1653, #1656 | The same usage-horizon checks in sibling readers and token checks when releasing an old park. |
| #2031 | Recovery from one state snapshot, including stale and competing claims. |
| #2050, #2077 | Carrying the original identity through the park and confirming the owner before waking PM. |

The wiring assertions and the state-transition fixtures are a possible seam, but the recent changes span both. Splitting now would duplicate the setup or move it to a new shared helper without removing a recurring conflict. Reconsider if those groups start changing independently, if the fixture records repeated conflicts, or if the measured score reaches 6. That threshold calls for another look, not an automatic split.
