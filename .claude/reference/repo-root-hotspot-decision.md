<!-- churn-hotspot: .claude/scripts/repo-root.sh -->
# Hotspot Decision — .claude/scripts/repo-root.sh

**Verdict:** KEEP — no split, no further extraction
**Decided:** 2026-09-01
**Issue:** #1475
**Reporter:** `/wrap` churn sweep after PR #1472, re-evidenced after PR #1481
**Detector snapshot:** `score 5`, `pr_count 5`, `pr_numbers [1386, 1422, 1458, 1467, 1481]`, `conflict_rounds: 0`, `conflict_prs []`

Reference for Issue #1475. Not auto-loaded — the rule corpus carries none of this.

## Churn decomposition

| PR | Issue | Diffstat here | Class |
|----|-------|---------------|-------|
| #1386 | #1363 | +277 / −15 | **Incident response** — the 20-minute silent stall: bound every git call, drop the worktree enumeration |
| #1422 | #1403 | +176 / −10 | **Same incident, round 2** — split exit 4 ("git could not run") out of exit 1, so callers stop treating an indeterminate answer as determinate |
| #1467 | #1435 | +9 / −2 | **Same incident, round 3** — silence the `ps`/`tr` `command not found` narration that broke the one-line stderr contract round 1 introduced |
| #1458 | #1406 | +1 / −1 | **Mechanical sweep** — repo-wide `script-usage.log` stderr-guard ordering, one identical line across 72 files |
| #1481 | #1404 | +35 / **−132** | **Extraction already performed** — the bound machinery moved to `lib/bounded-run.sh`; this file got 97 lines smaller |

Five PRs, **one driving event**. #1386 → #1422 → #1467 is a single convergent
hardening chain descending from the 2026-08-27 hang (#1363), each round narrowing
the contract rather than re-contesting it, and each pinned by tests that name
themselves in the header (T6b/T6c, T16g/T16h, T16k, T16m). #1458 is a passenger
in a repo-wide sweep. #1481 is the structural remedy a SPLIT verdict would have
prescribed — already applied.

`conflict_rounds: 0`: no two threads ever contended for the same hunk.

## Why KEEP

445 lines, one job — resolve the main-worktree root — and one exit-code contract
(0/1/2/3/4) that safety-critical callers branch on: `admin-merge.sh`, `/wrap`,
`/merge`, Phase C, and the `CLAUDE.md` worktree sequence. Splitting it would
multiply the surfaces that must agree on that contract while removing nothing:
the one orthogonal, independently-evolving seam that existed — the wall-clock
bound — was extracted to `lib/bounded-run.sh` in PR #1481 and is now shared with
`admin-merge.sh`, `dirty-main-guard.sh` and `stale-cleanup.sh`.

CodeRabbit's plan for #1475 reached the same verdict independently, and added the
constraint adopted here: preserve the exact exit-code and stderr contract, because
the black-box suite and several callers encode it.

## What the audit did find: `--help` was truncated

`print_help()` extracted the header with

```bash
sed -n '/^# PURPOSE$/,/^# EXAMPLES$/p' "$0" | sed 's/^# \{0,1\}//'
```

A `sed` range stops **at** its terminator, so the range emitted the `EXAMPLES`
heading and excluded every example under it. `repo-root.sh --help` ended on a
bare, contentless `EXAMPLES` — and the three canonical invocation forms never
reached the operator. That matters here more than anywhere else: `safety.md`'s
MINDSET block and the `CLAUDE.md` worktree sequence both tell readers to copy
`ROOT_REPO=$(.claude/scripts/repo-root.sh)`, which is exactly the first suppressed
example line.

Nothing pinned it — `repo-root.test.sh` T8d–T8i2 assert `--help` exit 0 and
specific exit-code sentences, but no assertion covered the EXAMPLES section, which
is why three PRs walked past it.

Triage of Issue #1513 showed the same defect class in 11 more scripts, in two
families. Both were fixed together in one PR: all 12 now use the portable
`awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"` form, which
terminates on the first **blank** line — no named terminator to truncate on, and
no sed dialect to diverge on. The stale "between BEGIN/END markers" comment above
`print_help()` (there were never such markers) was corrected in the same change.

Coverage is now `.claude/scripts/tests/help-output.test.sh`, which asserts the
`EXAMPLES` body — `ROOT_REPO=$(.claude/scripts/repo-root.sh)` — is present, and
sweeps every `--help` in the repo for the same defect class on both CI platforms.

## Baseline

`.claude/reference/churn-hotspot-baselines.json` records
`score_at_decision: 5`, `pr_count_at_decision: 5`, `issue: 1475`, matching the
detector snapshot above. The 2× material-growth gate therefore re-surfaces this
path only at score 10.

The baseline's `issue` key must stay **1475**: `baseline_for()` in
`churn-hotspot-wrap-plan.sh` joins on `existing_hotspot_issue`, which the detector
resolves from the `Refactor hotspot: <path>` title or the
`<!-- churn-hotspot: <path> -->` marker — both of which point at #1475.

CodeRabbit's plan for #1475 proposed skipping the baseline entry, on the reading
that the map held only docs and `SKILL.md` files. That is out of date: it already
carries `chip-offer-registry.sh` (#1464), `handoff-state.sh` (#1461) and
`stale-cleanup.sh` (#1479). Script entries are the established practice, and
without one this path returns as `no_matching_baseline` on the next sweep with the
verdict already settled.
