# PM day horizon fixture hotspot decision

Issue #1678. Keep `.claude/scripts/tests/pm-day-horizon.test.sh` as one offline suite. The original untruncated scan from 2026-08-24 on main at `400a8305` counted five changes and no recorded conflict re-resolutions: atomic park writes (#1595), the horizon park (#1628), reactive park compare-and-set (#1650), the two other horizon readers (#1653), and protection from a stale release (#1656).

The untruncated 2026-10-26 to 2026-11-09 scan on main at `592d9e8b` counted three changes and no recorded conflicts.

| Counted PR | Why the fixture changed |
|---|---|
| #2041 | Prevented a retired park from receiving a wake identity. |
| #2050 | Kept the park's durable identity across usage limits. |
| #2077 | Bound captured wake recovery to the confirmed owner. |

The 1,493-line fixture executes the real fenced Bash from `/pm` and the shared wake recovery reference. Its cases reuse a stubbed usage horizon and real session state in an isolated temporary home. The horizon verdicts and wake recovery are distinguishable groups, but they protect the same park lifecycle and share the test harness. The recent changes all covered that lifecycle, with no observed conflict rework or independently recurring test edits. Both Bash versions passed all 301 assertions. Revisit if the wake recovery tests begin changing independently or recorded conflicts identify a group that can move without duplicating setup.

The baseline is score and count 3. A qualifying zero-conflict score of 6 surfaces the decision again; a qualifying hotspot with recorded conflict cost bypasses the baseline.
