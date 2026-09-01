<!-- churn-hotspot: .claude/scripts/chip-offer-registry.sh -->
# `chip-offer-registry.sh` hotspot — diagnosis and KEEP decision

Reference for Issue #1464 (`.claude/scripts/chip-offer-registry.sh` churn hotspot). Not auto-loaded.

| Field | Value |
|-------|-------|
| **Verdict** | KEEP — no extraction, no split; one documentation-drift fix applied |
| **Decided** | 2026-08-29 |
| **Issue** | #1464 |
| **Reporter** | `/wrap` churn detection after PR #1456 merged |
| **Detector snapshot** | `score 3`, `conflict_rounds 0`, `pr_count 3` (PRs #1250, #1267, #1458) |

## The problem being read

`.claude/scripts/chip-offer-registry.sh` was touched by 3 distinct merged PRs
since 2026-08-15: #1250, #1267, #1458. The file is a 605-line repo-scoped,
lifecycle-aware registry of chip offers. It is structurally central: every chip
emitter (`/pm`, `/prompt`, `/wave`, `/issue-maker`, `/start-issue`,
`/harness-audit`) must call `--reserve` before `spawn_task`, and
`active-work-cap.sh` reads it as a counting source so offered chips are visible
to the cap before a PR exists.

That centrality is what put it in the report. The change *history*, however,
does not describe a file under maintenance pressure.

## Churn attribution — per-PR evidence

All three PRs are verifiable in the current clone; `git log` and the detector
both resolve them. (The CodeRabbit plan for this issue asserted the clone was
shallow and that #1250/#1267/#1458 were unverifiable, and built its attribution
table on Issue lineage instead. That premise is incorrect and was not followed —
the PR numbers below come from `git show` on each commit.)

| PR | Commit | Δ in this file | Nature | Driver |
|----|--------|----------------|--------|--------|
| #1250 | `992e702` | +512 / −0 | **File creation** | Issue #1225 — repo-scoped registry with lifecycle states and atomic reservation lease |
| #1267 | `28180f3` | +116 / −23 | **One planned feature round** | Issue #1238 — the three deferrals recorded at creation time: dedup exclusion via `issues[]` (Deferral 1), immediate `--retract` (Deferral 2), caller-supplied stable `--task-id` (Deferral 3) |
| #1458 | `ada79b4` | **+1 / −1** | **Mechanical repo-wide sweep** | Issue #1406 — `script-usage.log` stderr-guard ordering, applied identically across **72 files** in one commit |

## Churn classification

**The effective churn is one substantive follow-up round after creation.**

- PR #1250 is the file coming into existence. A file cannot be a churn hotspot
  for having been created.
- PR #1267 landed the three deferrals that PR #1250 explicitly scheduled. This is
  a plan being completed on time, not rework.
- PR #1458 changed **one line** as part of a 72-file mechanical sweep. The file
  was a passenger. It carries no signal about this file's design.

**Zero bug-fix churn. Zero unplanned rework. Zero merge conflicts**
(`conflict_rounds == 0`). No PR in the window reacted to a defect in this file's
structure. This is the healthiest possible trajectory — create, complete the
scheduled deferrals, then be swept along with the rest of the repo — and it is
the same create–complete–maintain lifecycle already adjudicated KEEP in
`issue-1121-subagent-registration-verification-hotspot-decision.md` and
`issue-852-browser-rung-verification-hotspot-decision.md`.

## Decision: KEEP the single file

The 607-line file is ~125 header lines plus ~480 lines of code implementing five
modes (`--reserve`, `--transition`, `--retract`, `--count`, `--list`) over one
store. Every consumer calls one script and receives one result. The dual
`issue`/`issues[]` schema and the lifecycle counting rules are a single
responsibility — capacity admission — and must stay co-located with the lock they
are protected by. Splitting would multiply the files a single lifecycle change
touches, with no caller benefit.

### Why the proposed extraction is not warranted

The CodeRabbit plan proposed extracting the shared `--transition` / `--retract`
skeleton into an in-file `_transition_entry` helper.

The duplication is real but small — roughly 20 lines of lock-acquire → read →
`found` lookup → jq patch → write → release appear in both blocks. Against that:

1. **The blocks diverge in four ways**, not one: target state (validated
   `--state` vs literal `retracted`), unknown-id policy (**exit 2** vs
   **idempotent exit 0**), the error message, and the `VALID_STATES` validation
   that only `--transition` performs. A helper must take the unknown-id policy as
   a parameter, which re-introduces inside the helper the branch it claims to
   remove.
2. **This is the highest-risk code in the file.** The shared skeleton *is* the
   critical section that makes capacity reservation atomic, including the
   `state_lock_assert_held` re-check before `mv` and the `_retry_or_fail`
   re-exec path. It is pinned by concurrency tests (true-concurrent race, and
   the sequential double-reserve pair).
3. **Precedent is against it.** `escalate-review-hotspot-decision.md` declined an
   extraction on exactly this shape — small shared logic, divergent output
   contracts, reshaping code longer than the logic it saves. The counter-example
   it cites (`_fetch_bot_approvals`, Issue #936) collapsed **104** duplicated
   lines with identical semantics on both sides. Twenty lines with a divergent
   exit-code policy is not that case.

Rewriting the atomic critical section to save ~20 lines is a negative
risk/benefit trade on a file with no defect history.

### Why the proposed header trim is not warranted

The plan also proposed replacing the RESERVATION LEASE, ONE ENTRY PER CHIP,
RELEASE ON FAILURE, TASK-ID STABILITY, LIFECYCLE STATES, and COUNTING blocks with
one-line pointers to `chip-launching.md` and `active-work-cap.md`. This was
declined on three findings:

1. **The header *is* the `--help` output.** `usage()` is
   `sed -n '2,/^$/p' "$0"` — it prints header lines 2–123 verbatim (line 124 is
   the terminating blank). Trimming the header is an externally observable change
   to the CLI's help surface, not a comment cleanup.
2. **It would create a circular reference.** `chip-launching.md` §Offer Registry
   (line 250) already states: *"Full contract: `chip-offer-registry.sh --help`."*
   The reference doc deliberately defers **to** the header. Pointing the header
   back at the reference doc would leave both ends pointing at each other with the
   content deleted.
3. **It would delete the API's main footgun warning.** The RESERVATION LEASE
   block documents that `--cap-free` is an *absolute admission limit* and that
   callers must pass `registry_baseline + FREE`, never raw `FREE` — passing
   `FREE` directly causes false cap exhaustion whenever `active_count > 0`. That
   is the single most misuse-prone part of the interface and belongs where a
   caller reading `--help` will see it.

No test asserted on `--help` output before this issue, so this regression would
have passed CI silently — the reason it is recorded here rather than left implicit.

## Concrete remedy applied

One real defect surfaced during adjudication and was fixed:

- **Emitter allowlist drift.** The header `VALID EMITTERS` block listed five
  emitters (`pm, prompt, wave, issue-maker, start-issue`) while the `--emitter`
  `case` statement accepts six — `harness-audit` included. `chip-launching.md`
  confirms six canonical emitters. Because `usage()` prints the header verbatim,
  `--help` was under-reporting the accepted values. The header now lists all six,
  and the `PURPOSE` block — printed by the same `usage()` call — was
  de-duplicated to point at `VALID EMITTERS` rather than carry a second copy of
  the list that could drift independently. One enumeration, one source of truth.
- **Drift-guard regression test** (`chip-offer-registry.test.sh` test 36) parses
  the emitter list out of `--help` and out of the `case` allowlist and asserts
  they match, failing closed if either list cannot be extracted. Verified against
  a negative control: the guard **fails** on pre-fix `origin/main`
  (`help=[issue-maker pm prompt start-issue wave]` vs
  `case=[harness-audit issue-maker pm prompt start-issue wave]`) and passes after
  the fix.
- **Behavioral pin** (test 37) asserts `--emitter harness-audit` is accepted by
  `--reserve`.

Both additions are additive regression guards on contracts this record depends
on — the drift guard keeps `--help` honest about the accepted emitters, and the
behavioral pin keeps `harness-audit` accepted — and neither weakens or rewrites
an existing assertion.

## What was explicitly preserved

- [x] All five CLI modes: `--reserve`, `--transition`, `--retract`, `--count`, `--list`
- [x] Exit codes 0 / 2 / 4 / 5 / 6 / 7 and their meanings
- [x] The `--transition` (exit 2) vs `--retract` (idempotent exit 0) unknown-id divergence
- [x] The dual `issue` (scalar) / `issues[]` (array) entry schema
- [x] `--cap-free` admission-limit semantics and the RESERVATION LEASE prose
- [x] The atomic critical section, `state_lock_assert_held` re-check, and `_retry_or_fail`
- [x] TTL handling, including fail-closed treatment of a missing `offered_at`
- [x] `--help` output, apart from the two header edits that *are* the remedy:
      the corrected `VALID EMITTERS` list, and the `PURPOSE` block pointing at
      that list instead of re-enumerating it. `usage()` prints the whole header,
      so both are user-visible; nothing else in the output changed.

## What would change this verdict

A future round in which the `--transition` / `--retract` blocks diverge further
and a fix has to be applied twice — or in which lifecycle-state handling starts
accumulating independent concerns beyond capacity admission — would reopen the
extraction case. Ordinary growth should not: the KEEP is snapshotted in
`churn-hotspot-baselines.json`, so the file re-surfaces only on material (2x)
growth.

## Related

- `merge-gate-hotspot-decision.md` — KEEP + extract precedent (`_fetch_bot_approvals`, 104 duplicated lines)
- `escalate-review-hotspot-decision.md` — KEEP, extraction declined on divergent contracts; closest structural precedent
- `chip-launching-hotspot-decision.md` — sibling adjudication for the reference doc this script's `--help` is the contract for
- `.claude/reference/chip-launching.md` §Offer Registry — caller-side reservation protocol
- `.claude/reference/active-work-cap.md` — `registry_baseline` and the counting sources
- `.claude/reference/churn-hotspot-baselines.json` — KEEP snapshot feeding the re-surfacing gate
