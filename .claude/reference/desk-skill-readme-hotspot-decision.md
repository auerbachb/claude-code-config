# Desk skill README hotspot decision

Issue #1841. **Keep the README and give the component list one home.** The
README explains how the skill is installed and how to run it from a branch.
The router already names the files it loads, so the README links to that
table.

The original detector counted #1797, #1802, and #1825, with zero recorded
conflicts. Those changes maintained the second component list. The copies
have since diverged: the router includes the priority, day-plan and sweep
files, and the README did not. The current window since October 26, 2026,
has zero touches; the cleanup addresses the drift visible today.

The router, commands, and fixtures are unchanged. Record the baseline at the
schema floor of 2 and keep the measured zero separate. Revisit if the
remaining installation or branch-testing instructions start changing
independently, if the churn score grows to 4, or if recorded conflicts show
a maintenance cost.
