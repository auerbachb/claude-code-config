<!-- churn-hotspot: .claude/scripts/tests/lib/skill-bash.sh -->

# skill-bash.sh Test Library Hotspot Decision

Reference for Issue #1103 (`.claude/scripts/tests/lib/skill-bash.sh` churn hotspot).
Not auto-loaded.

**Verdict:** KEEP — no split, no extraction
**Decided:** 2026-08-07
**Issue:** #1103
**Reporter:** /wrap post-merge churn report, PR #1101

## Executive summary

Keep `.claude/scripts/tests/lib/skill-bash.sh` as the single test-utility library for
skill-embedded bash extraction. Do not split, extract, or modify the file.

All three PRs asserted by the detector are substantiated by the full repository history —
the CR implementation plan's hypothesis that PRs #929 and #1004 were detector artifacts
(shallow-clone / squash history collapse) is **refuted**. However, the verdict remains KEEP:
PR #921 is the sole creation event, and PRs #929 and #1004 are documentation-only corrections
to the library's own header comments. The behavioral contract has not changed since creation.

The file is 183 lines / 1,115 words, single-purpose, single-consumer, and convention-protected
from suite discovery. There is nothing to split.

## 1. Trigger and measured evidence

The hotspot detector recorded 3 merged PRs touching
`.claude/scripts/tests/lib/skill-bash.sh` since 2026-07-24: PRs #921, #929, #1004.

At adjudication, the file is **183 lines / 1,115 words** — well below the 2,000-word per-file
warning. No conflict rounds recorded.

### Per-PR diff analysis (all three PRs verified via `git log --follow` and `gh pr diff`)

| PR | Title | Touch class | Driver |
|----|-------|-------------|--------|
| #921 | test(#888): anchored skill-bash extractor + pmm-wake Step 4a regression suite | File creation | Created the 183-line library: `extract_skill_bash` function, anchored extraction contract, exit-code specification (7 codes), FAIL-LOUD / never-empty policy, sourcing guard, and full header doc |
| #929 | docs(#926): align skill-bash.sh anchoring-rule header with its actual blank-line tolerance | Doc/comment correction | Updated header to reflect multi-blank-line tolerance already implemented: "immediately before" → "above"; "A single blank line" → "Blank lines"; exit-status 5 description and error message updated to match; **zero behavior change** |
| #1004 | refactor: extract pr-state jq filters | Incidental doc update | Updated "sibling precedent" paragraph to reflect the `pr-state-classify.jq` extraction (sed-extract prose → canonical-file-invocation prose); **zero behavior change in `skill-bash.sh`** — the update is to a historical analogy in the header comment |

**PR #921 — creation attribution confirmed.** `gh pr diff 921` shows `new file mode 100644`; all
183 lines added in one commit. The file did not exist before this PR.

**PR #929 — documentation-only confirmed.** `gh pr diff 929` shows only header comment edits
and one updated error message string. No logic, no awk/sed extraction code, no exported function
signatures were modified.

**PR #1004 — incidental doc update confirmed.** `gh pr diff 1004` on this file shows 3 lines
changed in the `# WHY THIS EXISTS` paragraph. The function body is untouched. The primary work
of PR #1004 was extracting jq programs from `pr-state.sh`; the change here is a comment update
so the historical analogy in `skill-bash.sh`'s header remains accurate.

### Detector-artifact hypothesis refuted

The CR implementation plan (retrieved via `.claude/scripts/cr-plan.sh 1103`) proposed that
PRs #929 and #1004 "are not substantiated by repo evidence and appear to be a detector artifact
(shallow clone / squash history collapse)." This hypothesis was formed in CodeRabbit's shallow
sandbox clone where those commits were not visible.

Running `git log --follow --oneline -- .claude/scripts/tests/lib/skill-bash.sh` against the
full repository history returns:

```
835c60f refactor: extract pr-state jq filters (#1004)
e8da8d6 docs(#926): align skill-bash.sh anchoring-rule header with its actual blank-line tolerance (#929)
527c10d test(#888): anchored skill-bash extractor + pmm-wake Step 4a regression suite (#921)
```

All three commits are present. The detector is correct. The CR plan's hypothesis is incorrect
because it was based on a shallow clone — a known limitation when CR reviews repos with squash
history. This is the same class of false-positive documented in
`.claude/reference/contributing-md-hotspot-decision.md` §1, where CR's plan also flagged
unverified PRs that were real upon full-history inspection.

**Watch item (not a concrete bug):** The shallow-clone artifact hypothesis in the CR plan is not
evidence of a bug in `churn-hotspots.sh` — the detector uses the full local git history and
correctly identified all three PRs. No follow-up issue is warranted against the detector. The
CR plan's caution was appropriate given its limited visibility.

## 2. Options considered

### Option 1: Split the library into multiple files (Rejected)

**Rejected.** The file exports one function (`extract_skill_bash`). There is no independent
concern to separate. At 183 lines it is already small. The header doc is large relative to the
function body, but that is a deliberate design choice: a sourced library with a novel anchoring
convention requires extensive inline documentation for the next editor. Splitting the doc from
the code would produce two files neither of which is self-contained.

### Option 2: Extract `extract_skill_bash` into a wrapper or module (Rejected)

**Rejected.** There is one consumer (`pmm-wake-step-4a.test.sh`). No other test needs this
pattern yet. Preemptive extraction for a single caller creates indirection without value.

### Option 3: Keep the file; no content change (Chosen)

**Chosen.** Three PRs, one creation event, two documentation-only corrections. The file is
cohesive, sub-threshold in size, convention-protected, and has zero merge conflicts. A
record-only adjudication closes the observational ticket without touching the source file.

## 3. Structural protections that predict low future churn

- **Convention exclusion:** The file lives in `tests/lib/` and lacks a `.test.sh` suffix.
  The CI harness (`run-hook-tests.sh`) uses a `*.test.sh` glob on `tests/` — this file is
  never accidentally run as a suite.
- **Scenario-free convention:** The repo forbids scenario/assertion logic inside `tests/lib/`.
  The file only exports a utility function; test scenarios must live in `tests/*.test.sh`.
- **Single consumer:** Only `pmm-wake-step-4a.test.sh` sources this library. Changes to the
  function signature require changing exactly one call site.
- **Anchor stability:** The `<!-- test-anchor: … -->` pattern embedded in `SKILL.md` files
  this library supports is stable — the contract is designed around Markdown-mutable prose.

## 4. Remediation applied

None. `.claude/scripts/tests/lib/skill-bash.sh` is unchanged.

## 5. Preserved invariants

- The `extract_skill_bash` function signature (`<markdown-path> <anchor-name>`) must stay
  stable — changing it requires a coordinated edit to `pmm-wake-step-4a.test.sh`.
- Exit codes 0/2/3/4/5/6/7 must stay consistent with the header doc and the test suite's
  direct assertions on non-zero returns.
- The sourcing guard (non-zero exit when executed directly) must remain — the library is
  `source`d, never run.

## 6. Future reconsideration

Reopen this decision only if:

- `conflict_rounds > 0` — two contributors editing the same function in the same window,
  causing merge conflicts (touch count alone is insufficient; both #929 and #1004 are
  documentation-only).
- A second consumer emerges that sources this library and imposes different interface
  requirements, creating genuine independent concern.
- The file grows past 300 lines — current trajectory (3 PRs, 2 doc-only) does not suggest
  this is imminent.

## 7. Related

- `.claude/reference/pr-monitor-and-manage-wake-hotspot-decision.md` — companion decision for
  the skill that `skill-bash.sh` test-pins; PR #921 is a shared PR between both hotspots
- `.claude/reference/contributing-md-hotspot-decision.md` — KEEP + no-content-change;
  PR #921 also touched `CONTRIBUTING.md` (added shared test helper paragraph)
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational; adjudication
  decides whether a structural remedy exists
- `.claude/scripts/tests/lib/skill-bash.sh` — the adjudicated file
