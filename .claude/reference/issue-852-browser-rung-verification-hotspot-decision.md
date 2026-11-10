<!-- churn-hotspot: .claude/reference/issue-852-browser-rung-verification.md -->
# Hotspot Decision — issue-852-browser-rung-verification.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-12
**Issue:** #1184
**Reporter:** `/wrap` post-merge churn report (PR #1183)

## Churn summary

`churn-hotspots.sh` flagged `.claude/reference/issue-852-browser-rung-verification.md`
as touched by 3 distinct merged PRs since 2026-07-30: PRs #1120, #1167, #1180.

| PR | Commit | Churn class | What changed |
|----|--------|-------------|--------------|
| PR #1120 | `ffc9121` | File creation — first verification pass | Created the file: live subagent runs + static check for the 5 Issue #864 AC items reachable that session. 5/7 items PASS; item 2b deferred (live login stalled across session boundary), item 5b FAIL (account-settings change went through without a live per-instance chat confirmation). Catalog entry added to `README.md`. |
| PR #1167 | `2368c4c` | Completion — second verification pass | Closed the 2 open items: item 1 re-run against `pm-worker` (the agent type the AC names, now that custom `subagent_type` values spawn; first pass used a proxy), item 2b closed (Console usage + rate-limit figures read post-login), item 5b resolved via rule-verification plus a clean negative observation (positive path explicitly stated as unobserved). Also fixed stale `allowed-tools:` → `tools:` key name in the reproduce command and in 3 sibling files. |
| PR #1180 | `9bb39aa` | Lint compliance — single comment marker | Added `<!-- deprecated-key-ok: allowed-tools -->` to one fenced code block. The new `deprecated-frontmatter-key-lint.sh` (introduced in the same PR) flags agent-scoped prose mentions of the deprecated `allowed-tools:` key; the opt-out marker suppresses the lint for this intentional historical record of the rename. No content change. |

## Diagnosis

The churn is a 3-stage natural lifecycle with no merge conflicts across any of the 3 PRs.

**Stage 1 — creation (PR #1120).** The file was purpose-built to record the live verification
of Issue #864's acceptance criteria. The PR body and follow-up notes explicitly deferred two
items: item 2b because the live-login check stalled when the subagent session ended before the
user could complete sign-in, and item 5b because the first-pass subagent violated the rule
(pre-authorized a category rather than confirming a specific instance). Both deferrals were
tracked as follow-ups in the document itself.

**Stage 2 — planned completion (PR #1167).** PR #1167 closed Issue #864 and completed the
two open items from the first pass. Each open item's method and result was re-documented with
the 2026-08-12 date, and the summary evidence table updated to reflect the full PASS state.
The same PR also fixed a stale key reference in the reproduce command (the `^allowed-tools:`
grep printed the wrong result for every agent, including restricted ones) — a correctness fix
rather than content evolution. All existing content was preserved unchanged.

**Stage 3 — lint compliance (PR #1180).** PR #1180 introduced `deprecated-frontmatter-key-lint.sh`,
which flags agent-scoped prose mentions of `allowed-tools:`. The verification doc's fenced
reproduce command mentioned the deprecated key in a deliberate historical context (recording
that the key was stale and had been fixed). Adding the inline opt-out marker was the correct
response — identical to the handling in the closest sibling
(`issue-1121-subagent-registration-verification.md`, also touched in PR #1180 for the same
reason). The change is a single HTML comment with no content effect.

**No split is warranted.** The file has one clear responsibility: record what was verified for
Issue #864 (browser capability rung AC), how it was verified, and what the results were. All
3 PRs contribute to that single narrative. There are no independently evolving sections, no
content duplicated against a sibling file, and no concern that belongs in a separate artifact.
The verify doc is 2,911 words, above the 2,000-word per-file warning — but that ceiling applies
to loaded rule corpus files, not to verification logs in `.claude/reference/`. The file is at
natural completion state: Issue #864 is closed, all 7 checks are resolved, and the only plausible
future additions are discovered regressions (which would open a new issue).

## Decision

**KEEP** `.claude/reference/issue-852-browser-rung-verification.md` as the single canonical
record of the Issue #864 browser-rung acceptance-criteria verification.

Make no operative change to any file. The 3 PRs represent a create–complete–maintain lifecycle,
not accumulation of independent concerns.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0` — rising PR count alone on a reference doc at the end of its lifecycle
is not a re-filing trigger.

## Expected impact

None. No rule corpus files, skills, or agent definitions were changed. The corpus word count
remains unchanged at the pre-adjudication baseline.

## Related

- Issue #852 / PR #858 — browser capability rung initial implementation (`browser-capability-rung.md`)
- Issue #864 / PR #1120 — first verification pass (file creation)
- Issue #864 / PR #1167 — second verification pass (completion; Issue #864 closure)
- Issue #1170 / PR #1180 — `deprecated-frontmatter-key-lint.sh`: introduced the lint that required the opt-out marker in this file
- Issue #1182 — closest sibling: `issue-1121-subagent-registration-verification-hotspot-decision.md` (same 3-PR create–complete–maintain pattern; also touched by PR #1180 for the same lint marker reason)
- `.claude/reference/browser-capability-rung.md` — the mechanism doc whose AC this file verifies
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
