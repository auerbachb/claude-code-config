<!-- churn-hotspot: .claude/reference/issue-1121-subagent-registration-verification.md -->
# Hotspot Decision — issue-1121-subagent-registration-verification.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-12
**Issue:** #1182
**Reporter:** `/wrap` post-merge churn report (PR #1180)

## Churn summary

`churn-hotspots.sh` flagged `.claude/reference/issue-1121-subagent-registration-verification.md`
as touched by 3 distinct merged PRs since 2026-07-29: PRs #1131, #1148, #1180.

| PR | Commit | Churn class | What changed |
|----|--------|-------------|--------------|
| PR #1131 | `9a4ab06` | File creation — diagnosis and fix | Created the file (68 lines): root cause of "Agent type not found", fix applied (`name:` frontmatter + `allowed-tools:` → `tools:` rename), restart precondition, fallback path, doc-drift resolved, evidence section. Live verification explicitly deferred to Issue #1130 in the PR body. |
| PR #1148 | `c65c403` | Completion — deferred verification | Added the "Live Verification — Issue #1130" section (~22 lines): all-five-types spawn table, method-and-limit note, cross-reference to Issue #1130 closure. No change to any prior section. |
| PR #1180 | `9bb39aa` | Lint compliance — single comment marker | Added `<!-- deprecated-key-ok: allowed-tools -->` to the end of one sentence (line 42). The new `deprecated-frontmatter-key-lint.sh` (introduced in the same PR) flags agent-scoped prose mentions of `allowed-tools:`; the marker suppresses the lint for this legitimate historical record of the rename. No content change. |

## Diagnosis

The churn is a 3-stage natural lifecycle with no merge conflicts across any of the 3 PRs.

**Stage 1 — creation (PR #1131).** The file was purpose-built to record the diagnosis and fix for
Issue #1121. The PR body explicitly stated "Live spawn verification is deferred — registration
requires a session restart after the files exist. Tracked in Issue #1130." This makes the follow-on
PR a planned continuation, not independent churn.

**Stage 2 — planned completion (PR #1148).** PR #1148 closed Issue #1130 and appended the
deferred verification evidence. It added exactly one new section to the bottom of the file and left
all existing content unchanged. This is the canonical "create then verify" two-PR pattern for
reference docs that require a session restart to confirm.

**Stage 3 — lint compliance (PR #1180).** PR #1180 introduced `deprecated-frontmatter-key-lint.sh`,
which flags agent-scoped mentions of `allowed-tools:`. The verification doc contained one such
mention in item 3 of the "Fix Applied" section — describing what was changed in
`.claude/agents/README.md`. Adding the inline opt-out marker on that line was the correct response:
the mention is a historical record of the rename, not erroneous usage. The change is a single
appended HTML comment with no content effect.

**No split is warranted.** The file has one clear responsibility: record what broke (Issue #1121),
why it broke, how it was fixed, and that the fix was verified live (Issue #1130). All 3 PRs
contributed to that single narrative. There are no independently evolving sections, no
duplicated content against a sibling file, and no concern that belongs in a separate artifact.

The file is 87 lines and 814 words — well below the 2,000-word per-file warning — and is at or
near its natural completion state. The only future additions would be follow-on verification
rounds (which would require a new issue) or a discovered regression (which would be tracked
separately). Neither scenario justifies a structural change now.

## Decision

**KEEP** `.claude/reference/issue-1121-subagent-registration-verification.md` as the single
canonical record of the Issue #1121 diagnosis, fix, and live verification.

Make no operative change to any file. The 3 PRs represent a create–complete–maintain lifecycle,
not accumulation of independent concerns.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0` — rising PR count alone on a reference doc at the end of its lifecycle
is not a re-filing trigger.

## Expected impact

None. No rule corpus files, skills, or agent definitions were changed. The corpus word count
remains unchanged at the pre-adjudication baseline.

## Related

- Issue #1121 / PR #1131 — "Agent type not found" fix: `name:` frontmatter + `tools:` rename
- Issue #1130 / PR #1148 — live verification of the fix after session restart
- Issue #1170 / PR #1180 — `deprecated-frontmatter-key-lint.sh`: introduced the lint that required the opt-out marker in this file
- `.claude/reference/researcher-hotspot-decision.md` — closest sibling (Issue #1172); `researcher.md` was also touched by PR #1131 (agent registration fix); same coordinated-fix verdict
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
