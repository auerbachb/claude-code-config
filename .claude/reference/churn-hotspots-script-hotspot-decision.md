<!-- churn-hotspot: .claude/scripts/churn-hotspots.sh -->
# Hotspot Decision — churn-hotspots.sh (script)

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-07
**Issue:** #1095
**Reporter:** `/wrap` post-merge churn report (PR #1094)

Reference for Issue #1095 (`.claude/scripts/churn-hotspots.sh` churn hotspot). Not auto-loaded — the rule corpus carries none of this.

**Disambiguate from sibling record:** `.claude/reference/churn-hotspots-hotspot-decision.md` (Issue #1081) adjudicates the reference *doc* `.claude/reference/churn-hotspots.md`. This record adjudicates the *script* `.claude/scripts/churn-hotspots.sh`. The two files share the same three reporting PRs (#766, #882, #925) but describe entirely different concerns — documentation vs. executable implementation. See the cross-reference section below.

## Churn summary

`churn-hotspots.sh` was flagged as touched by 3 distinct merged PRs since 2026-07-28: PRs #766, #882, and #925.

| PR | Title | Merge date | Driver |
|----|-------|-----------|--------|
| PR #766 | feat(#755): detect multi-PR file churn and auto-file refactor-candidate issues | 2026-07-28 | Initial creation (entire script) |
| PR #882 | fix(#861): scope churn scan to the default branch, not the invoking HEAD | 2026-08-01 | Bug fix — ref resolution |
| PR #925 | fix(#915): surface closed hotspot issues so /wrap stops re-filing them | 2026-08-02 | Bug fix — issue lookup |

## Per-section churn attribution (evidence)

Sections mapped to the `# ---- section ----` boundaries in the script:

| Section | PR #766 | PR #882 | PR #925 | Count |
|---------|---------|---------|---------|-------|
| Comment header / doc | ✓ | ✓ | ✓ | 3 |
| Flag parsing | ✓ | ✓ | — | 2 |
| print_help | ✓ | ✓ | — | 2 |
| emit helpers (emit_and_exit) | ✓ | ✓ | ✓ | 3 |
| repo resolution | ✓ | ✓ | — | 2 |
| resolve_scan_ref | — | ✓ | — | 1 |
| window resolution | ✓ | — | — | 1 |
| is_excluded | ✓ | — | — | 1 |
| enumerate_git / enumerate_gh | ✓ | ✓ | — | 2 |
| conflict-rounds lookup (CONFLICT_MAP) | ✓ | — | — | 1 |
| **Scoring aggregation jq** | ✓ | — | — | **1** |
| --top truncation | ✓ | — | — | 1 |
| **Existing-issue lookup jq** | ✓ | — | ✓ | **2** |

### PR #766 — Script creation (Issue #755)

PR #766 introduced the entire `churn-hotspots.sh` script as a new file. It created every section from scratch — flag parsing, ref resolution, window resolution, exclusion matching, both enumeration engines (git and gh), conflict-rounds lookup, the scoring aggregation jq, --top truncation, and the existing-issue lookup jq. This is authorship, not independent iteration on existing content. Conflict rounds: 0.

### PR #882 — Ref-resolution bug fix (Issue #861)

PR #882 fixed a bug where `git log` ran against the invoking worktree's `HEAD` rather than the default branch. From a feature-branch worktree, `HEAD` was wrong in both directions: it missed squash commits merged to main since the branch forked, and it included unsquashed local commits that would never exist on main.

Sections touched by PR #882:

- **Comment header / doc**: Added `--ref` and `--fetch` to the usage line; expanded the ENUMERATION section with the HEAD-scoping rationale and ref resolution order; updated the OUTPUT schema to include `scan_ref`/`scan_ref_source`; updated EXIT CODES to name unresolvable-ref as an error class.
- **Flag parsing**: Added `--ref=*`/`--ref` and `--fetch` branches to the `while` loop.
- **print_help**: Changed from a hardcoded `sed -n '2,118p'` line-range to a self-terminating `awk` pattern (so help auto-adjusts when the header grows).
- **emit helpers**: Added `SCAN_REF=""` and `SCAN_REF_SOURCE="n/a"` variables; added `--arg scan_ref`/`--arg scan_ref_source` to the `jq -cn` call in `emit_and_exit`; extended the JSON template to emit those two fields.
- **repo resolution**: Added a guard block rejecting `--ref` on the gh path (usage error) and warning about `--fetch` inertness on that path.
- **resolve_scan_ref** (new section): Added the entire `resolve_scan_ref()` function implementing the resolution order (`--ref` → `origin/HEAD` → `origin/main` → `origin/master` → `main` → `master` → `HEAD` fallback with a loud warning).
- **enumerate_git**: Updated to call `resolve_scan_ref` before the `git log` invocation and to pass `"$SCAN_REF"` as the ref argument.

Conflict rounds: 0.

### PR #925 — Closed-match issue lookup fix (Issue #915)

PR #925 fixed a bug where `churn-hotspots.sh` used `--state open` for the hotspot issue lookup, making already-reviewed-and-closed hotspot issues invisible to `/wrap`. `/wrap` read `existing_hotspot_issue: null`, treated the path as never-ticketed, and re-filed it on every subsequent wrap — indefinitely. The fix had already produced one confirmed duplicate (Issue #815 closed, Issue #881 open for the same file) before the pattern was noticed.

Sections touched by PR #925:

- **Comment header / doc**: Rewrote the EXISTING-ISSUE LOOKUP section to document `--state all` semantics, the closed-match reporting behavior, open-beats-closed preference, and the unchanged cap guard. Expanded the OUTPUT section's TSV description with `<number> (closed)` and `<number> (unknown)` suffix forms and the `existing_hotspot_issue_state` JSON field semantics.
- **emit helpers**: Extended the TSV formatter inside `emit_and_exit` to emit the `(closed)`/`(unknown)` suffix for non-open matches; the original single branch (`if .existing_hotspot_issue == null then "-" else tostring end`) was replaced with the three-branch form that reads `existing_hotspot_issue_state`.
- **Existing-issue lookup jq**: Changed `OPEN_ISSUES` to `CANDIDATE_ISSUES`; changed `--state open` to `--state all` and added `state` to the `--json` fields; rewrote the final `jq -c` merge block to add `def norm_state`, collect all matches, apply open-beats-closed preference via `([ $matches[] | select((.state | norm_state) == "open") ] | first) // ($matches | first)`, and set both `existing_hotspot_issue` and `existing_hotspot_issue_state` on each hotspot.

Conflict rounds: 0.

## Diagnosis

### The jq blocks were not the independently churning concern

The CR plan proposed extracting the two embedded jq programs into `lib/*.jq` files if the attribution showed they churned. The evidence is clear that they did not:

**Scoring aggregation jq** (the `HOTSPOTS=$(jq -Rs -c ...)` block, lines 664–690 in current HEAD): touched only by PR #766 (initial creation). Zero churn — the scoring formula, `min_prs` floor, conflict-weight arithmetic, and sort order have not been touched since the file was written.

**Existing-issue lookup jq** (the `HOTSPOTS=$(printf '%s' ... | jq -c ...)` block, lines 754–775): touched by PR #766 (created) and PR #925 (extended with `norm_state` and state-aware matching). Score = 2, below the hotspot threshold of 3. PR #925's change was additive: it added the state-aware preference logic that the `--state all` behavior required. The underlying structure (collect all matches, pick the best) was not contested by independent owners.

### The churn is burst construction + two orthogonal fixes

The three-PR hotspot score on this file is the sum of:
1. **PR #766** — foundational burst construction. The script did not exist before this PR. Every section was created in one commit.
2. **PR #882** — a single-concern bug fix touching `resolve_scan_ref` and the plumbing that connects it (flag parsing, emit helpers, enumerate_git wiring, repo resolution guard). PR #882 did not touch the scoring aggregation jq or the existing-issue lookup jq at all.
3. **PR #925** — a single-concern bug fix touching the existing-issue lookup and its TSV output format. PR #925 did not touch `resolve_scan_ref`, the scoring aggregation jq, or the enumeration engines.

The two sections with the highest per-section count (comment header and emit helpers, both at 3 PRs) are additive accumulation, not contested independent iteration:
- The **comment header** grew with each PR because each bug fix needed new CLI doc and output schema documentation for the features it added.
- The **emit helpers** accumulated output fields: PR #882 added `scan_ref`/`scan_ref_source`, PR #925 added the state-aware TSV formatter. No PR rewrote what another had written.

No merge conflicts were recorded across any of the 3 PRs.

## Decision: KEEP

**KEEP** `.claude/scripts/churn-hotspots.sh` with no operative change.

The CR plan (Option 3) proposed extracting the embedded jq programs into `lib/*.jq` files following the `pr-state.sh` precedent. That option was explicitly conditioned on attribution confirming the jq blocks churned. The attribution shows they did not:

- Scoring aggregation jq: 1 PR (initial build only)
- Existing-issue lookup jq: 2 PRs (initial build + one additive fix)

The CR plan's stated fallback applies: "If the recovered attribution shows the jq blocks did NOT churn, DOWNGRADE to KEEP-only and record that."

Extraction without a churn justification would impose `jq -f` invocation overhead and add an external lib file dependency — costs without the benefit of reducing per-PR edit surface on a section that has not in fact seen independent iteration. The script is a single flag-driven contract consumed by `/wrap` by exact CLI and output shape; that contract is not in tension with the file size.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when `conflict_rounds > 0` — a rising PR count on a living operational script is not a re-filing trigger.

## Cross-reference with sibling decision records

### Issue #1081 — churn-hotspots.md (the doc, not the script)

`churn-hotspots-hotspot-decision.md` (Issue #1081) adjudicates the reference doc `.claude/reference/churn-hotspots.md`, which was flagged with the same three PRs (#766, #882, #925). Attribution in both records is consistent: the same PR touches both the script and its reference doc because bug fixes to the script's behavior necessarily update the doc that narrates that behavior. The two records describe different things — executable implementation vs. narrative rationale.

### Issue #1076 — autofile-dedup.md

`autofile-dedup-hotspot-decision.md` (Issue #1076) flagged PRs #766 and #925 in its window. Attribution is consistent across all three records:

| PR | This record (script) | Issue #1081 record (doc) | Issue #1076 record (autofile-dedup.md) |
|----|---------------------|--------------------------|----------------------------------------|
| PR #766 | Created `churn-hotspots.sh` entirely | Created `churn-hotspots.md` entirely | Created "Exact-artifact dedup" section in `autofile-dedup.md` |
| PR #925 | Extended existing-issue lookup jq with state-aware matching | Updated eligibility + dedup-key sections in `churn-hotspots.md` | Added 2 clarifying bullet points to "Exact-artifact dedup" in `autofile-dedup.md` |

The same PR touching all three files is expected: a bug fix to the lookup behavior updates the script logic, its narrative reference doc, and the dedup contract that governs the lookup.

## What was explicitly preserved

- All sections enumerated in the per-section table above — no section was modified.
- The single flag-driven CLI contract (`--since`, `--threshold`, `--repo`, `--conflict-weight`, `--exclude`, `--no-default-excludes`, `--source`, `--ref`, `--fetch`, `--pr-cap`, `--top`, `--json`).
- The TSV and JSON output schemas (field names, types, exit codes).
- The `emit_and_exit` funnel — all exit paths route through it.
- The `/wrap` call site: `"$CHURN_SH" --json 2>/dev/null` continues to work identically.

## Expected impact

None. No files were modified. The corpus word count is unchanged (this record is not auto-loaded).

## Related

- `.claude/scripts/churn-hotspots.sh` — the adjudicated script; read-only churn detector for `/wrap` Step 3.10a
- `.claude/reference/churn-hotspots.md` — canonical narrative reference doc for the script
- `.claude/reference/churn-hotspots-hotspot-decision.md` — sibling decision (Issue #1081); adjudicates the *doc*, not the script; same three PRs; KEEP verdict for same reasons (burst construction + two orthogonal fixes to different sections)
- `.claude/reference/autofile-dedup-hotspot-decision.md` — sibling decision (Issue #1076); confirms PRs #766 and #925 attribution is consistent across all three records
- `.claude/reference/fixpr-hotspot-decision.md` — structural precedent for the extract-not-split direction (extraction removes per-PR edit surface; junction contracts stay intact); not applied here because the jq blocks did not independently churn
- Issue #1095 — this hotspot
- Issue #755 — churn-hotspot detector creation (PR #766)
- Issue #861 — `--ref`/HEAD scoping bug (PR #882)
- Issue #915 — closed-hotspot re-filing bug (PR #925)
- PR #1094 — reporting merge that triggered this hotspot
