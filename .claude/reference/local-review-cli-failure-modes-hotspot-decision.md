# Local Review CLI Failure Modes Hotspot Decision

Reference for Issue #1005 (`.claude/reference/local-review-cli-failure-modes.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single multi-incident reference file; make **no runtime change**

Keep `.claude/reference/local-review-cli-failure-modes.md` as the single diagnostic reference for
all observed local CLI failure signatures. Do not split it by CLI, extract sections into scripts,
or deduplicate against other files.

The six contributing PRs each added a distinct new incident section to a file whose explicit scope
is to collect every discovered failure mode. No single section was edited more than once; growth
is coordinated and additive, not colliding. This matches the `scheduling-failure-modes.md`
append-only-evidence-log precedent: the file exists precisely because failure modes accumulate
unpredictably, and centralising them in one place prevents agents from re-diagnosing the same
failure on a second encounter.

## 1. Trigger and current evidence

Issue #1005 was filed by `/wrap` churn detection after PR #1004 merged. The issue body records 6
distinct merged PRs since 2026-07-21: PRs #650, #666, #806, #821, #858, #946.

At diagnosis time the file is 227 lines and approximately 1,752 words — below the 2,000-word
per-file warning. The touches map to seven documented `##` sections, each keyed to a separate
discovered incident:

| Section (`##` heading) | Anchor incident | Contributing PR(s) |
|---|---|---|
| CodeAnt CLI not installed | Issue #819 (binary absent, `command not found` before any API call) | PR #821 |
| The false-clean | Issue #642 (stderr error, stdout `{"issues":[]}` clean lie) | PR #650 |
| Classifying a 403: the daily cap, not credentials | Issue #643 (undocumented daily agent-review quota) | PR #666 |
| The 15-file cap | 15-file `meta.capped` limit (no single issue anchor, companion to #642) | PR #650 |
| CodeRabbit: failure on stdout, exit 0 | stdout NDJSON `type:"error"` pattern | PR #806 |
| Coverage enum — mapping failure states | Coverage enum consolidation (#769) | PR #806, #858 |
| CodeAnt auth storage | `~/.codeant/config.json` shape and `logout` semantics | PR #946 |

**Churn class:** each PR added a distinct new incident section. No section shows repeated
colliding re-edits. Growth is coordinated and additive — consistent with an incident log whose
scope is "collect every new failure signature."

Today's session (PRs #1008–#1016) independently corroborates the file's documented failure modes:
the CodeRabbit CLI rate-limit and the CodeAnt 403 daily cap both fired, matching sections 5 and
3 respectively. The file's value as a pre-diagnosis lookup is confirmed.

## 2. Options considered

### Option 1: SPLIT into per-CLI or per-concern files

Create separate reference files for CodeAnt failure modes and CodeRabbit failure modes (or other
splits such as rate-limit vs. false-clean).

**Rejected.** `cr-local-review.md` points to this file as a single target for the full false-clean
check specification and 403 triage. A split would force the rule to choose which fragment to cite
or list multiple fragments — either outcome widens the pointer surface without reducing churn, because
each new incident would still need to land somewhere. Agents diagnosing an unknown failure mode
would need to decide which fragment to consult before the failure is classified, defeating the
purpose of the lookup.

### Option 2: KEEP + extract (pull deterministic logic into a script)

Extract the 403-triage discriminant commands or the false-clean test into a diagnostic script.

**Rejected.** The sections are incident prose, not reusable command forms. `local-review.sh`
already owns the deterministic wrapper (`local-review.sh --tool codeant|coderabbit`); the
reference docs explain *why* each failure mode looks the way it does and how to classify it.
Extracting narrative into a script does not remove churn; it splits authorship across two files
for each future incident.

### Option 3: KEEP + dedup (collapse a downstream restatement)

Identify a section that is restated in another file and collapse to a pointer.

**Rejected.** `cr-local-review.md` holds only a condensed enforcement blockquote, not a full
restatement of any section. `cr-rate-limits.md` covers a different subsystem (GitHub App rate
limits, not CLI tool failure modes). There is no confirmed downstream duplication to remove.

### Option 4: KEEP (no runtime change)

Record a "by design" KEEP decision and leave the file byte-for-byte unchanged.

**Chosen.** The file's scope is append-only incident collection. Each added section is a
non-repeating incident entry with no cross-section coordination dependency. This is the same
design as `.claude/reference/scheduling-failure-modes.md`, whose churn is also expected to grow
as new scheduler failure patterns are discovered. A structural intervention would not prevent the
next incident from being appended.

## 3. Canonical ownership boundaries

| Concern | Owner | Non-owner action |
|---|---|---|
| Enforced directive: dual-CLI review, false-clean check, 403 drop rule | `.claude/rules/cr-local-review.md` | Point to this reference file; do not restate mechanism |
| Failure-mode diagnosis prose and worked incident examples | `.claude/reference/local-review-cli-failure-modes.md` | Append new sections; leave rule file to policy |
| CLI wrapper contract, exit codes, log path, coverage enum enforcement | `.claude/scripts/local-review.sh` | Reference doc explains *why*; script enforces *how* |
| CodeAnt GitHub App merge-gate path (independent of CLI) | `.claude/reference/merge-gate-reviewer-paths.md` §CodeAnt | This file covers CLI surface only |
| GitHub App rate limits and CR cooldown guidance | `.claude/reference/cr-rate-limits.md` | Different subsystem; no overlap with CLI failure modes |

## 4. Preserved invariants

- `.claude/reference/local-review-cli-failure-modes.md` stays byte-for-byte unchanged.
- The three-way alignment (this doc → `local-review.sh` exit codes → `local-review.test.sh`
  failure fixtures) stays synchronized; new failure modes must update all three if they affect
  the `verified_run` classification.
- The condensed 403 blockquote in `cr-local-review.md` stays a minimal enforced directive. It
  must not grow toward re-explaining mechanism — full mechanism lives here.
- `cr-rate-limits.md` remains scoped to the GitHub App / CI surface and does not absorb CLI
  failure content.

## 5. Remediation and verification

The only changes in this PR are:
1. This decision record (`.claude/reference/local-review-cli-failure-modes-hotspot-decision.md`).
2. One catalog bullet in `.claude/reference/README.md`.

No rule, script, or agent file is modified. `reference-catalog-lint.sh` must pass with exactly
one registered bullet for the new decision doc and no phantom entries.

## 6. Future edits and reconsideration

A future PR that discovers a new CLI failure mode should append a new section to
`local-review-cli-failure-modes.md` (the expected pattern) — that is not a reason to reopen
this decision.

Reconsider if:
- A future PR re-edits an *existing* section (not appends a new one), indicating colliding
  independent ownership rather than coordinated growth.
- The file exceeds the 2,000-word per-file warning, at which point section-level extraction
  into per-CLI reference files should be reconsidered.
- A downstream file begins restating section content rather than pointing to it, creating
  confirmed synchronization burden.

## 7. Related precedent

- `.claude/reference/phase-a-fixer-hotspot-decision.md` — KEEP, no runtime change; same
  "required propagation" churn class where each touch added distinct new content.
- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup precedent; contrasting
  case where a confirmed downstream restatement existed to remove.
- `.claude/reference/escalate-review-test-hotspot-decision.md` — SPLIT verdict; contrasting
  case where sections had independent authors, no shared-mechanism dependency, and size exceeded
  file limits.
- `.claude/reference/fixpr-hotspot-decision.md` — KEEP + extract precedent; contrasting case
  where deterministic command forms (not incident prose) justified extraction.
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger
  logic.
