<!-- churn-hotspot: .claude/skills/open-code-review/SKILL.md -->
# Hotspot Decision — open-code-review/SKILL.md

**Verdict:** N/A — file does not exist (invalid hotspot; detector gap fixed in Issue #1118)
**Decided:** 2026-08-08
**Issue:** #1118
**Reporter:** `/wrap` post-merge churn report (PR #1117)

Reference for Issue #1118 (`.claude/skills/open-code-review/SKILL.md` churn hotspot false positive). Not auto-loaded — the rule corpus carries none of this.

## Evidence

### Path existence

The path `.claude/skills/open-code-review/SKILL.md` does not exist in the current tree:

```
git ls-files --error-unmatch .claude/skills/open-code-review/SKILL.md  # exits 1
ls .claude/skills/open-code-review/  # Directory does not exist on disk
```

The path does appear in git history (4 commits total). PR #822 deleted the file as part of cutting the `/open-code-review` skill (`feat(#793): cut /open-code-review — zero usage, ocr skips .md, native /code-review covers the role`).

### What PRs #750, #799, #822 actually touched

| PR | Title | Action on path |
|----|-------|----------------|
| PR #750 | `fix(#749): update model fleet to Opus 5 across agent + suggestion surfaces` | Propagated model-fleet update into `open-code-review/SKILL.md` |
| PR #799 | `feat(#791): versionless model names + effort recommendations on every surface` | Propagated versionless model name update into `open-code-review/SKILL.md` |
| PR #822 | `feat(#793): cut /open-code-review — zero usage, ocr skips .md, native /code-review covers the role` | **Deleted the file** (skill cut as zero-usage) |

PRs #750 and #799 were coordinated propagation PRs updating model-naming conventions across every skill surface simultaneously — none of them represented independent iterative churn on the open-code-review skill itself. PR #822 was the deletion commit.

No such skill exists in the README skill catalog. The `/code-review` skill (`pr-review-help`) covers the role that `/open-code-review` originally held.

## Diagnosis

### The detector gap

`churn-hotspots.sh` builds its touch-TSV from `git log --name-only`. The `git log` command includes file paths from deletion commits — a commit that deletes a file still "touches" that path in the log output. The detector never checked whether a path from history still exists in the working tree or at the scanned ref.

Because PR #822 deleted the file in a squash commit that carried a trailing `(#822)` PR marker, the detector counted it as a third PR touch. The file's three-PR history from window start 2026-07-28 crossed the default threshold of 3, and `/wrap` filed Issue #1118.

This is a detector false positive: a deleted file is not a refactor candidate regardless of how many PRs touched it before deletion.

### The fix (Issue #1118, PR #1141)

`churn-hotspots.sh` now calls `file_present` before writing any row to the touch TSV:
- **git path** (when `SCAN_REF` is non-empty): `git cat-file -e "$SCAN_REF:$file"` — checks the blob exists at the scanned ref
- **gh path** (when `SCAN_REF` is empty): `[ -e "$file" ]` — working-tree check (reliable since the script runs from inside a checkout)

Dropped paths increment `missing_count`, emitted as a top-level JSON field alongside `excluded_count`. The `/wrap` branching logic is unchanged — the fix is detection-layer only, per Design Choice 1 in the CR plan.

A regression test (Scenario 19 in `churn-hotspots.test.sh`) verifies the behavior: create a file, touch it across 3 PR commits, delete it, assert it is absent from `.hotspots` and `missing_count > 0`. Revert-verified: the assertions fail against the unfixed script and pass after the fix.

## Related

- `.claude/reference/churn-hotspots.md` — canonical narrative reference for `churn-hotspots.sh`; updated with the existence filter paragraph and `missing_count` field documentation
- `.claude/scripts/churn-hotspots.sh` — the fixed script; `file_present` helper added alongside `is_excluded`
- `.claude/scripts/tests/churn-hotspots.test.sh` — regression test added as Scenario 19
- PR #1117 — reporting merge that triggered this hotspot
- PR #822 — the PR that deleted `.claude/skills/open-code-review/SKILL.md`
- Issue #1118 — this hotspot
