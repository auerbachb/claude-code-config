<!-- churn-hotspot: .claude/scripts/tests/churn-hotspots.test.sh -->
# Hotspot Decision — churn-hotspots.test.sh

**Verdict:** KEEP (no structural change)
**Decided:** 2026-08-07
**Issue:** #1100
**Reporter:** `/wrap` post-merge churn report (PR #1099)

Reference for Issue #1100 (`.claude/scripts/tests/churn-hotspots.test.sh` churn hotspot). Not auto-loaded — the rule corpus carries none of this.

**Disambiguate from sibling records:** `.claude/reference/churn-hotspots-script-hotspot-decision.md` (Issue #1095) adjudicates the *script* `.claude/scripts/churn-hotspots.sh`. `.claude/reference/churn-hotspots-hotspot-decision.md` (Issue #1081) adjudicates the reference *doc* `.claude/reference/churn-hotspots.md`. All three records share the same three reporting PRs (#766, #882, #925), because each PR that changed the script's behavior also changed the test suite and the reference doc. The three records describe entirely different concerns — executable implementation, regression tests, and narrative rationale.

## Churn summary

`churn-hotspots.sh` flagged `.claude/scripts/tests/churn-hotspots.test.sh` as touched by 3 distinct merged PRs since 2026-07-24: PRs #766, #882, and #925.

| PR | Title | Merge date | Driver |
|----|-------|-----------|--------|
| PR #766 | feat(#755): detect multi-PR file churn and auto-file refactor-candidate issues | 2026-07-28 | Initial creation (entire test file) |
| PR #882 | fix(#861): scope churn scan to the default branch, not the invoking HEAD | 2026-08-01 | Bug fix — ref scoping; test scenarios 14–18 added |
| PR #925 | fix(#915): surface closed hotspot issues so /wrap stops re-filing them | 2026-08-01 | Bug fix — closed-match lookup; stub and scenarios 7/8/9 extended |

## Per-section churn attribution (evidence)

Sections organized by the `# Scenario N` block boundaries plus the shared infrastructure preamble.

| Section | PR #766 | PR #882 | PR #925 | Count |
|---------|---------|---------|---------|-------|
| Shared infrastructure (counters, helpers, gh stub, fixture helpers) | ✓ | ✓ | ✓ | 3 |
| Scenario 1 — 3-PR hotspot | ✓ | — | — | 1 |
| Scenario 2 — below threshold | ✓ | — | — | 1 |
| Scenario 3 — issue-ref vs PR-ref in subject | ✓ | ✓ (label fix) | — | 2 |
| Scenario 4 — conflict round weighting | ✓ | — | — | 1 |
| Scenario 5 — MIN_PRS floor | ✓ | — | — | 1 |
| Scenario 6 — fresh clone / no session state | ✓ | — | — | 1 |
| Scenarios 7/8/9 — existing hotspot issue lookup | ✓ | — | ✓ | 2 |
| Scenario 10 — default exclusions | ✓ | — | — | 1 |
| Scenario 11 — gh enumeration path | ✓ | — | — | 1 |
| Scenario 12 — --top truncation | ✓ | — | — | 1 |
| Scenario 13 — argument handling | ✓ | — | — | 1 |
| Scenarios 14–18 — ref scoping | — | ✓ | — | 1 |

### PR #766 — Test suite creation (Issue #755)

PR #766 introduced `churn-hotspots.sh` as a new script and authored the test suite in the same PR. The file did not exist before PR #766. It was created as 403 lines with 62 assertions.

**Shared infrastructure established by PR #766:**

- Global `PASS`/`FAIL` counters with `pass()`/`fail()` reporters and `check_eq()`/`check_jq()` assertion helpers
- `gh` stub at `$TMP/bin/gh`: routes `repo view`, `issue list`, `pr list`, and `/files` REST path fragments to pre-seeded fixture files; unhandled invocations exit 1 loudly; token-matched on a single stable token per case (never on `--json` field order, which changes as callers add fields)
- `new_repo()` helper: initializes a temp git repo with a fixed committer identity
- `commit_touch()` helper: commits one or more files with a controlled author/committer date and subject
- `run_in()` helper: `cd`s into a repo, runs the script with given args, captures `OUT` and `RC`
- Single `$TMP` sandbox shared across all scenarios; `cleanup()` trap removes it on exit

**Scenarios 1–13 established by PR #766:**

- Scenario 1: three distinct PRs on one file, TSV and JSON output, merge-window bounds
- Scenario 2: below-threshold file produces no hotspot
- Scenario 3: subject carrying both an issue ref and a PR marker — only the trailing marker counts
- Scenario 4: conflict rounds carry documented weight in the score formula
- Scenario 5: MIN_PRS floor — conflict rounds alone never make a hotspot
- Scenario 6: fresh clone / no session-state history (`conflict_rounds` defaults to 0)
- Scenarios 7/8/9: existing hotspot issue lookup — no match (null), title match, body-marker match, near-miss titles rejected, capped lookup treated as failed
- Scenario 10: default exclusions (`package-lock.json`, `yarn.lock`, etc.)
- Scenario 11: gh enumeration path — `pr list` + `/files` REST endpoint; `--source gh`, `--source auto`, field-order independence
- Scenario 12: `--top` truncation preserves the full total count
- Scenario 13: usage and argument handling — `--since` date, `--threshold`, `--ref/SHA` for `--since`, unresolvable `--since` exits 3

Conflict rounds: 0.

### PR #882 — Ref-scoping test expansion (Issue #861)

PR #882 fixed the bug where `git log` ran against the invoking worktree's `HEAD` rather than the default branch. From a feature-branch worktree, `HEAD` was wrong in both directions: it missed squash commits merged to main since the branch forked, and it included unsquashed local commits with only leading `type(#N):` issue references that were incorrectly parsed as PR numbers. Measured impact on two live worktrees: one invented a phantom PR inflating 13 files by one PR each and manufacturing 2 hotspots outright; the other missed 7 merged PRs and 5 hotspots.

The test file grew from 403 → 598 lines, 62 → 94 assertions.

**Shared infrastructure changes by PR #882:**

- Added `new_repo_on()` helper: wraps `new_repo()` but sets the branch name explicitly via `git symbolic-ref HEAD`, bypassing the host ambient `init.defaultBranch`. Needed because fixtures must exercise a known branch name rather than whatever the runner defaults to.
- Added `add_origin()` helper: creates a bare git remote, points the bare repo's HEAD at the published branch (not the runner default), pushes, fetches, and sets `refs/remotes/origin/HEAD`. Without the explicit HEAD pointer, a `git clone` of the bare repo checks out a branch that does not exist, causing subsequent pushes in scenario 15 to fail.

**Scenario 3 label fix by PR #882:**

One assertion label was updated: "the LAST (#N) marker is taken as the PR number" → "the TRAILING (#N) marker is taken as the PR number". This was not a behavior change — the assertion itself was unchanged. It reflects the doc clarification that the marker is trailing (appended by GitHub on squash-merge) rather than merely the last one in arbitrary subject text.

**Scenarios 14–18 added by PR #882:**

- Scenario 14: scan is scoped to the default branch (not the invoking worktree's `HEAD`); a feature branch is checked out during the run; leading `docs(#838)` issue references on the branch do not inflate any PR count; detached HEAD resolves the same ref
- Scenario 15: `origin/HEAD` wins over a local branch that has drifted; unpushed local commits not counted; `--fetch` picks up a PR merged since the last fetch; explicit `--ref origin/main --fetch` order of operations verified
- Scenario 16: a default branch not named `main` (here: `trunk`); a stray local `main` does not outrank the remote's real default branch
- Scenario 17: `--ref` overrides resolution and is reported as `scan_ref_source: "explicit"`; unresolvable `--ref` exits 3; `--ref` on the gh path is a usage error (exit 2)
- Scenario 18: HEAD fallback when nothing resolves; leading-only `(#N)` markers produce no PR attribution; `auto` falls through to the gh path when no trailing marker survives; explicit `--ref` refuses the gh fallback rather than scanning repo-wide (exit 3); `--source git` still scans the pinned ref as-is

Conflict rounds: 0.

### PR #925 — Closed-match test extension (Issue #915)

PR #925 fixed the bug where `churn-hotspots.sh` used `--state open` for the hotspot issue lookup, making already-reviewed-and-closed hotspot issues invisible. `/wrap` read `existing_hotspot_issue: null`, treated the path as never-ticketed, and re-filed it on every subsequent wrap.

The test file grew from 598 → 694 lines, 94 → ~106 assertions.

**Shared infrastructure changes by PR #925:**

The `gh` stub's `issue list` handler was rewritten from a single `cat "$TMP/issue_list.json"` to a three-way `--state`-filtering case:

```
*"--state open"*)   jq ... '[.[] | select(state != "CLOSED")]' ...
*"--state closed"*) jq ... '[.[] | select(state == "CLOSED")]' ...
*)                  cat "$TMP/issue_list.json"  # --state all
```

This is load-bearing: a state-agnostic stub would let the closed-match tests pass even when the script uses `--state open`. The bug being guarded is a server-side state filter; the stub must faithfully replicate the server's behavior so that the test fails when the script uses the wrong `--state` value.

A comment header was added to the stub explaining this decision:

> "A fixture row with no 'state' field stands in for an open issue. The type guard keeps a deliberately malformed fixture (non-string state) from aborting the stub itself rather than the code under test."

**Scenarios 7/8/9 changes by PR #925:**

A comment header was added above the block explaining why state filtering matters and how the closed-match fixtures are shaped.

Existing fixture rows were updated to include `"state":"OPEN"` (scenarios 7, 8a, 8b/old, 9). The behavior of existing passing assertions was unchanged — the state-aware stub's `--state all` path still returns these rows; only an `--state open` call differs on closed rows.

New assertions added:

| Case | What it covers |
|------|---------------|
| 7c | `existing_hotspot_issue_state` field always emitted; `null` when no match |
| 8b | An open match reports `state: "open"` |
| 8c | Body-marker match also sets state (combined assertion with 8b's shape) |
| 8d | A closed match is reported (non-null `existing_hotspot_issue`) rather than dropped |
| 8e | A closed match reports `state: "closed"` |
| 8f | TSV format suffixes a closed match with `(closed)` |
| 8g | Open match wins over a closed match for the same path (open listed second) |
| 8h | Open match wins over a closed match regardless of search order (open listed first) |
| 8i | An unrecognized state (`"ARCHIVED"`) reports `state: "unknown"`, not null |
| 8j | TSV suffixes an unknown-state match with `(unknown)` |
| 8k | A non-string state (`404`) degrades that one row without emptying the hotspot report |
| 9a | Near-miss title check now mixes open and closed fixtures to verify both are rejected |

Conflict rounds: 0.

## Diagnosis

### The three PRs form a "create then harden twice" lifecycle

The three-PR hotspot score is the sum of:

1. **PR #766** — foundational burst construction. The test suite did not exist before this PR. Every scenario, every helper, every fixture stub was created in one commit as the companion test suite for the new `churn-hotspots.sh` script.
2. **PR #882** — a single-concern bug fix (HEAD scoping) that expanded the test suite with scenarios 14–18 and two new fixture helpers. PR #882 did not touch scenarios 1–13, did not change the gh stub routing, and did not touch the existing-issue lookup coverage.
3. **PR #925** — a single-concern bug fix (closed-match lookup) that extended the gh stub and scenarios 7/8/9. PR #925 did not touch the ref-scoping scenarios 14–18 and did not touch the fixture helpers added by PR #882.

The only section touched by all three PRs is the shared infrastructure block, and even there the contributions are purely additive:
- PR #766 created the base helpers and stub
- PR #882 added `new_repo_on()` and `add_origin()` — two new helpers not present in PR #766
- PR #925 rewrote the `issue list` branch of the existing gh stub — touching what PR #766 created without conflicting with PR #882's additions

No section was independently contested by two different PRs. No merge conflicts were recorded across any of the three PRs.

### The shared fixture layer is load-bearing across all 18 scenarios

Every scenario uses `commit_touch()`, `run_in()`, and at least one fixture helper (`new_repo()`, `new_repo_on()`, or the cloned-remote setup). The global `PASS`/`FAIL` counters aggregate across all 18 scenarios. The single `$TMP` sandbox holds the `gh` stub, the fixture files (`issue_list.json`, `repo_view.txt`), and the temporary git repos for every scenario. A split into per-concern files would require either:

1. Re-creating the entire infrastructure in each sibling (multiplying per-change edit sites: a future script change would require updating N fixtures in N files), or
2. Extracting the infrastructure into `tests/lib/churn-hotspots-fixtures.sh` and sourcing it from N siblings (adding a source dependency to every file and complicating the `bash <script>` invocation that CI uses)

Neither option buys a correctness or maintainability benefit that the current structure lacks.

### No extractable duplication within the file

The five helper functions (`pass`, `fail`, `check_eq`, `check_jq`, and the `run_in` wrapper) are not duplicated in any companion file. No `tests/lib/` subdirectory exists for the scripts/ test suite. The `check_eq`/`check_jq` pattern appears in other test files, but those are independent files for different scripts; they are not copies of each other, and there is no shared companion for `churn-hotspots.test.sh` specifically.

### No coverage gap to close

All 18 scenarios have direct test assertions tied to their driving script feature or bug fix. The file passes 104+ assertions on current HEAD. Every PR that extended the script's behavior also extended the test suite in the same PR — there are no shipped-and-untested changes.

### Comparison with relevant KEEP precedents

**`merge-gate-review-substance-test-hotspot-decision.md` (Issue #1014):** The closest structural analogue — a single self-contained test suite that accumulates cases for external contract evolution with no companion file and no internal duplication. This file follows the same pattern: each PR that changes the script's behavior adds a new scenario block without restructuring what the previous PR wrote.

**`polling-backoff-warn-test-hotspot-decision.md` (Issue #1069):** Another "create then harden twice" pattern, 3 PRs, each tracking a change in the scheduling substrate used by the hook under test. Same KEEP reasoning: external-contract-driven churn, not instability or scatter.

**`polling-state-gate-test-hotspot-decision.md` (Issue #1003):** The extraction precedent — two companion files with their own diverged copies of `mk_repo`, `write_handoff`, and `write_polling_gh_stub`. That file has no companion. There is no cross-file duplication to extract.

## Decision

**KEEP** `.claude/scripts/tests/churn-hotspots.test.sh` with no structural change.

The churn is "create then harden twice": PR #766 created the script and its test suite together; PR #882 fixed one bug and added 5 test scenarios; PR #925 fixed another bug and extended one existing scenario group. Each PR added orthogonal coverage for a different behavioral contract.

The shared fixture layer (`TMP`, `PASS`/`FAIL`, `pass`/`fail`, `check_eq`/`check_jq`, `gh` stub, `new_repo`/`new_repo_on`/`add_origin`/`commit_touch`/`run_in`) is the load-bearing mechanism that makes all 18 scenarios hermetic and fast without network access. Splitting this suite would require re-creating or sourcing that layer across sibling files — more edit sites, no correctness gain.

## Why not split / Why not extract

**Why not split into per-concern files (one per PR's scenarios):**
The three PR groups share the entire fixture infrastructure. Scenario 14 (`new_repo_on`) and scenario 7/8/9 (gh stub state filtering) would each need the same `new_repo()`, `commit_touch()`, `run_in()`, and `$TMP` setup. The only clean split boundary would be "ref scoping" (14–18) vs "everything else", but even that is not clean — scenarios 1 and 3 already exercise the `--since`/`--ref` date argument, and scenarios 7/8/9 use `$R1` from scenario 1. The coupling is real, not incidental.

**Why not extract helpers into `tests/lib/`:**
No companion file exists for `churn-hotspots.test.sh`. The helpers are used by exactly one file. Extraction adds a `source` dependency, complicates the `bash .claude/scripts/tests/churn-hotspots.test.sh` invocation that CI expects, and saves zero lines of shared content (there is only one user). The `merge-gate-review-substance-test-hotspot-decision.md` record (Issue #1014, "declined extraction" finding) documents the same reasoning.

## Future-edits guardrail

When `churn-hotspots.sh` is updated to emit new fields, change state semantics, or add new enumeration behavior, update the corresponding scenario(s) in this test file in the same PR. Do not split the file or move helpers to `tests/lib/` — the adjudication above explains why both are the wrong direction.

Re-file this hotspot only when `conflict_rounds > 0`. A rising PR count on a living test suite that tracks external contract evolution is not a re-filing trigger.

## Cross-reference with sibling decision records

### Issue #1095 — churn-hotspots.sh (the script)

`churn-hotspots-script-hotspot-decision.md` (Issue #1095) adjudicates the script `.claude/scripts/churn-hotspots.sh`. Attribution in both records is consistent: the same PR that changes the script's behavior also changes the test suite, because the two are maintained together. See the disambiguation note at the top of this record.

### Issue #1081 — churn-hotspots.md (the doc)

`churn-hotspots-hotspot-decision.md` (Issue #1081) adjudicates the reference doc `.claude/reference/churn-hotspots.md`. Same three PRs. Consistent per-PR attribution across all three records:

| PR | This record (test suite) | Issue #1095 record (script) | Issue #1081 record (doc) |
|----|-------------------------|----------------------------|--------------------------|
| PR #766 | Created test file (403 lines, 62 assertions, scenarios 1–13) | Created `churn-hotspots.sh` entirely | Created `churn-hotspots.md` entirely |
| PR #882 | Added `new_repo_on`/`add_origin` helpers + scenarios 14–18 | Fixed `resolve_scan_ref` + ref-scoping plumbing | Extended "Enumeration" section with `--ref`/HEAD-scoping narrative |
| PR #925 | Rewrote gh stub `issue list` handler + extended scenarios 7/8/9 | Extended existing-issue lookup jq with `norm_state` and state-aware matching | Updated "Why `/wrap` files at most one per run" + "The dedup key" sections |

### Issue #1076 — autofile-dedup.md

`autofile-dedup-hotspot-decision.md` (Issue #1076) flagged PRs #766 and #925 for `autofile-dedup.md`. Attribution in that record is consistent with the PR #766 (initial hotspot infrastructure) and PR #925 (closed-match eligibility) roles documented here.

## Related

- `.claude/scripts/tests/churn-hotspots.test.sh` — the adjudicated test suite
- `.claude/scripts/churn-hotspots.sh` — the script under test
- `.claude/reference/churn-hotspots.md` — canonical narrative reference doc for the script
- `.claude/reference/churn-hotspots-script-hotspot-decision.md` — sibling decision (Issue #1095); adjudicates the *script*, not the test suite; same three PRs; KEEP verdict for same reasons
- `.claude/reference/churn-hotspots-hotspot-decision.md` — sibling decision (Issue #1081); adjudicates the *doc*, not the test suite; same three PRs; KEEP verdict
- `.claude/reference/autofile-dedup-hotspot-decision.md` — sibling decision (Issue #1076); confirms PRs #766 and #925 attribution is consistent across all records
- `.claude/reference/merge-gate-review-substance-test-hotspot-decision.md` — structural KEEP precedent (Issue #1014): single self-contained test suite tracking external contract evolution, no companion, no internal duplication
- `.claude/reference/polling-backoff-warn-test-hotspot-decision.md` — "create then harden twice" KEEP precedent (Issue #1069): same 3-PR pattern, each PR tracking a scheduling-substrate change
- Issue #1100 — this hotspot (test suite)
- Issue #755 — churn-hotspot detector creation (PR #766)
- Issue #861 — `--ref`/HEAD scoping bug (PR #882)
- Issue #915 — closed-hotspot re-filing bug (PR #925)
- PR #1099 — reporting merge that triggered this hotspot
