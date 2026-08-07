<!-- churn-hotspot: .claude/hooks/polling-backoff-warn.sh -->
# Hotspot Decision — polling-backoff-warn.sh

**Verdict:** KEEP + minimal header-pointer dedup (no runtime change)
**Decided:** 2026-08-07
**Issue:** #1065
**Reporter:** `/wrap` post-merge churn report (PR #1064)

## Churn summary

`churn-hotspots.sh` flagged `.claude/hooks/polling-backoff-warn.sh` as touched by 3
distinct merged PRs since 2026-07-30: PRs #820, #867, #982.

### Per-PR attribution (section-level, with evidence from `gh pr diff`)

| PR | Sections changed in hook | Churn driver |
|----|--------------------------|--------------|
| PR #820 | Added `cadence_base_minutes` read + `WIDE_MIN = max(15, 3×base)` calculation; removed the separate streak>=6 STOP tier; unified into streak>=3 widen with dynamic `${WIDE_MIN}m`; updated emit message to include the dynamic interval | Scheduling-substrate migration: implementing the stable-state backoff formula from `.claude/rules/scheduling-reliability.md` §Stable-State Backoff (issue #794) |
| PR #867 | Updated STOP emit message to reference `/loop` cancellation and conditional `ScheduleWakeup` teardown (vs prior `CronDelete` only); updated WIDEN emit to say "do NOT stop the poll" and include `/loop` re-arm language; updated test file comment from "CronDelete" to "stop the poll" | Scheduling-primitive migration: CronCreate/CronDelete → `/loop` mechanism (issue #827) |
| PR #982 | Updated STOP emit to reference `TaskStop`, `monitor_task_id`, `monitor_generation`, and atomic state clear; updated WIDEN emit with Monitor stop-then-replace flow (stop prior Monitor, fresh generation, arm replacement at `${WIDE_MIN}m`, atomically persist identity pair); minor header comment fix ("cron actions" → "poll-lifecycle writes") | Scheduling-primitive migration: dynamic `/loop` → persistent Monitor with TaskStop/monitor_generation teardown (issue #924) |

All three PRs trace to a single coordinated cause: the backoff hook tracks whatever
scheduling primitive the polling skills use. As the primitive migrated
(`CronCreate` → `/loop` → persistent `Monitor`), the hook's advisory text
updated in lock-step. This is policy-tracking churn, not instability.

## Diagnosis

### KEEP is correct

**File is small and single-purpose.** At diagnosis time, the hook is 117 lines with
one decision procedure: inspect polling-related Bash calls; compute `WIDE_MIN` from
session state; emit a WIDEN advisory for streaks 3–8 and a STOP advisory for
streak>=9 or `blocker_kind==user_input`. A split would add edit surface without
isolating an independently evolving concern.

**Churn is externally driven.** All three PRs modified the hook because the
upstream scheduling primitive changed. The hook's own structure was stable — no
merge conflicts were recorded across the three PRs. Future primitive changes will
require the same in-place update regardless of structural shape.

**No extractable duplication with companion files.** The companion test file
(`polling-backoff-warn.test.sh`) carries `write_state`, `run_hook`, and `context_of`
helpers, but these are test harness — not shared logic. The sibling decision record
(`polling-backoff-warn-test-hotspot-decision.md`, Issue #1069) confirms this: the
companion `babysit-tick-watchdog.test.sh` has diverged implementations incompatible
with extraction.

### Header-pointer gap: add a specific section pointer

The hook header currently reads:

> `# The scheduling rule owns the behavior; this hook is a non-blocking safety net`

This is correct in intent but incomplete: it does not name the specific file or
section. Per the canonical-ownership mandate in `scheduling-reliability-hotspot-decision.md`
§3 (Digest inputs, widening formula, and stop/resume thresholds row):

> "Incident docs preserve history and link to this section without copying values"
> Canonical owner: `.claude/rules/scheduling-reliability.md` `## Stable-State Backoff`
> Non-owner action: reference docs retain evidence without copying values

Enforcement points should point to the canonical section, not leave the pointer
implicit. A single comment line naming the file and section closes the gap without
changing any runtime logic or threshold values.

**Applied change:** one comment line added after the existing "The scheduling rule
owns the behavior" line:

```
# Backoff thresholds and formula: .claude/rules/scheduling-reliability.md §Stable-State Backoff
```

No other change to the hook.

## Comparison with the sibling test-file decision (Issue #1069)

`polling-backoff-warn-test-hotspot-decision.md` (Issue #1069, PR #1075) adjudicated
the companion test file `polling-backoff-warn.test.sh`. That decision reached the
same KEEP verdict for the same underlying reason: all three PRs (#820, #867, #982)
updated the test assertions to match the hook's updated emit messages, which
themselves tracked the scheduling-primitive migration. Both files churn together
because both track the same external contract.

Cross-reference: the test-file decision documents the 16 labeled test sections and
their boundary coverage in detail. This decision focuses on the hook's runtime
structure and the header-pointer remediation.

## Why not split / Why not no-change

**Why not split:**
The file is 117 lines with one decision tree. Splitting would produce a "detection"
fragment and an "emission" fragment that evolve together — the WIDE_MIN computation
directly feeds the emit messages. A split adds files without reducing edit surface.

**Why not pure KEEP (no-change):**
The header pointer gap is confirmed and the remediation is low-cost (one comment
line). The `scheduling-reliability-hotspot-decision.md` mandate explicitly names
this hook's concern area (backoff thresholds and formula) as requiring a canonical
pointer rather than a self-contained definition. Leaving the pointer vague
risks future editors restating values instead of citing the rule.

## Future-edits guardrail

When the scheduling substrate changes again (e.g., Monitor lifecycle fields are
renamed or a new stop primitive is introduced), update the STOP and WIDEN emit
messages in this hook to match, then update the assertions in
`polling-backoff-warn.test.sh` to pin the new contract. Do not split the hook or
extract the emit messages — the diagnosis above explains why both are the wrong
direction.

The backoff thresholds (streak boundaries, WIDE_MIN formula) are owned by
`.claude/rules/scheduling-reliability.md` §Stable-State Backoff. The hook reads
`babysit.cadence_base_minutes` dynamically from session state, but the streak
boundaries (≥3 widen, ≥9 stop), the multiplier (3×), and the floor (15m) are
hardcoded. If any of those values change in the canonical rule, update the rule
first and then edit the corresponding lines in this hook to match.
