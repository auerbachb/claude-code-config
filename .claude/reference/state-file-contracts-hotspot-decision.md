# State-File-Contracts Hotspot Decision

Reference for Issue #1012 (`.claude/reference/state-file-contracts.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the companion mechanism doc; **targeted dedup toward script headers**

Keep `.claude/reference/state-file-contracts.md` as the single expanded rationale doc for the
session-state and handoff state-file contracts. Do not split it by concern. The six reported touches
are not independent evolutionary paths: they record initial file creation, two new-mechanism
additions, two scope-resolution propagations into the repo-scoping section, and one previously
applied field-type dedup (PR #989). No merge conflicts were reported.

The doc already declares at its opening that the canonical contracts are the script headers
themselves, and that headers win on disagreement. Targeted dedup removes the "why" narrative that
duplicates those headers and replaces it with pointers, following the precedent set by the
field-type section in PR #989.

Raw touch count alone did not drive this decision. A split would break the file's role as the
single canonical mechanism companion for `session-state.sh`, `handoff-state.sh`, and
`state-lock.sh`, requiring callers to discover multiple per-concern docs.

## 1. Trigger and measured evidence

Issue #1012 recorded six merged PRs touching `state-file-contracts.md` since 2026-07-22.

| PR | Commit | Churn class | Section(s) affected |
|----|--------|-------------|---------------------|
| #742 | `c6189f9` | Doc creation (corpus compression, #740) | All (file created) |
| #763 | `27895b7` | New mechanism (#757) | Diff-survival snapshot |
| #820 | `15684f8` | New mechanism (#794) | Backoff schema fields |
| #970 | `b33f92b` | Scope resolution propagation (#967) | Repo scoping → polling-gate protection |
| #989 | `3422676` | Field-type dedup (#964) | Field-type contract (already applied) |
| #999 | `e58642f` | Scope resolution propagation (#971) | Repo scoping → polling-gate resolver |

**Conflict-round evidence:** none. The signal is edit frequency only. The file grew by six
distinct contributions (one creation, two new mechanism sections, two propagations into the
scoping section, and one targeted dedup); each contribution was to a different section or
subsection and did not revisit previously landed content.

## 2. Duplication evidence

Three sections carry "why" narrative that their owning script headers also state:

| Section | Duplicated in | Unique-to-doc content |
|---------|---------------|-----------------------|
| Repo scoping (#638) | `session-state.sh` REPO SCOPING header | `_unknown` fallback note, account-level fields |
| Write locks (#639, #682) | `state-lock.sh` header (WHY mkdir) | exit-6 contract, self-heal, inline-jq ban |
| Invoking-repo scope (#687) | `session-state.sh` --session-view section | authorship-guard analogy; left as-is |
| Scope-key normalization (#704) | `repo-normalizer.sh` CONTRACT section | three-code-path list; left as-is (per plan) |

The field-type contract (#625) was already deduped toward `session-state-schema.json` in PR #989
(the direct precedent for this remediation). No further change is needed there.

The invoking-repo scope (#687) section is brief (three short paragraphs), mostly doc-unique (the
authorship-guard analogy is not in any script header), and unchanged since file creation. No
trimming applied.

## 3. Decision: keep as companion doc

**SPLIT rejected.** The sections share a common theme: they explain the design of a single
coordinated mechanism — the repo-scoped, locked, migrated state file pair. Splitting by concern
(scope / lock / migration / schema) would give each concern a separate file without reducing
any of the six churn classes. The two new-mechanism sections (#757, #794) are independent
appendages, not independent runtime owners. The two scope-resolution subsections (#967, #971)
are sub-sections of the repo-scoping concern, not separate lifecycle stages.

**Pure KEEP (no change) rejected.** Genuine duplication exists between the Repo scoping and
Write locks sections and their owning script headers. The field-type precedent (PR #989) already
established that pointing to the header is the correct remedy when the script header is
authoritative and the doc restates it.

**KEEP + targeted dedup chosen.** Remove the opening "because" clause from the Repo scoping
section (duplicated from `session-state.sh`'s REPO SCOPING narrative) and replace the opening
sentence of the Write locks section with a pointer to the `state-lock.sh` header. Keep the
resolution priority list, `_unknown` note, exit-6 contract, self-heal note, and inline-jq ban —
all of which are quick-reference actionable content that callers need.

## 4. Canonical ownership

| Content | Canonical owner | Doc role |
|---------|-----------------|----------|
| Scope-key priority resolution order | `session-state.sh --help` | Quick-reference summary + pointer |
| Lock mechanism and staleness policy | `state-lock.sh` header | Pointer + actionable contracts (exit 6, inline-jq) |
| Handoff repo-scoped path contract | `handoff-state.sh --help` | Migration algorithm and path resolver snippet |
| Scope-key normalization | `lib/repo-normalizer.sh` CONTRACT | Cross-path story (three consumers) kept in doc |
| PR scope resolver boundary | `lib/pr-scope-resolver.sh` CONTRACT | Subsection kept; contracts unique to both |
| Field-type maps | `session-state-schema.json` `_field_types` | Already deduped (PR #989) |
| Backoff schema fields | `state-file-contracts.md` | Table owned here; no script header equivalent |
| Diff-survival scope | `diff-survival-guard.md` | Boundary explanation kept; pointers to full rationale |
| Scoping not retroactive, audit repair | `state-file-contracts.md` | Migration algorithm unique to doc |

## 5. Preserved invariants

- `state-file-contracts.md` remains the single expanded rationale companion for the state-file
  mechanism pair.
- The opening hierarchy statement is preserved verbatim: "Canonical contracts are the script
  headers themselves — `session-state.sh --help`, `handoff-state.sh --help`, `state-lock.sh`
  header. When this file and a script header disagree, the header wins."
- Every issue-number reference (#625, #638, #639, #651, #655, #682, #687, #704, #757, #794,
  #967, #971) and the section structure are preserved.
- The resolution priority list, `_unknown` fallback note, and account-level fields note remain
  in the Repo scoping section as quick-reference content.
- Exit-code 6 contract, self-heal behavior, and the inline-jq ban remain in the Write locks
  section — these are actionable and not restated in the script headers.
- The backoff schema field table, diff-survival scope explanation, and handoff migration algorithm
  remain unchanged — they are doc-unique content with no header equivalent.
- No runtime code, state migration, script, skill, CI file, or rule is changed.
- `reference-catalog-lint.sh` passes: one entry per file, no phantoms, no duplicates.

## 6. Targeted remediation

Changes applied in PR #1012:

1. **`state-file-contracts.md` § Repo scoping**: Removed the "because two repos routinely have
   PRs at the same number and a flat map silently merged them" clause; replaced with a pointer to
   `session-state.sh --help` (REPO SCOPING section) for the full resolution-priority narrative.
   Kept the priority list (quick-reference), `_unknown` note, and account-level fields note.

2. **`state-file-contracts.md` § Write locks**: Replaced the opening sentence
   "macOS ships no `flock(1)`, so `state-lock.sh` implements mutual exclusion with an atomic
   `mkdir` lockdir." with a pointer to the `state-lock.sh` header (WHY mkdir AND NOT flock(1)
   section). The rest of the section (exit 6, self-heal, inline-jq ban) is unchanged.

3. **`.claude/reference/README.md`**: Added one bullet for this decision record under the
   "Audits and research (point-in-time)" section. Refreshed the `state-file-contracts.md` catalog
   bullet: added missing tags (#757, #794, #967, #971); retained #655 (still referenced in two
   doc sections: the handoff-migration section and the polling-gate protection subsection).

## 7. Reconsideration

Reconsider splitting if:
- Two or more sections begin changing on independent cadences without referencing each other;
- A new caller needs only one section and cannot source a single reference; or
- Measured merge-conflict evidence appears (rounds-per-PR, not just touch count).

Reconsider further dedup if script headers for `handoff-state.sh`, `pr-scope-resolver.sh`, or
`repo-normalizer.sh` accumulate rationale that the current doc sections restate verbatim.

Raw touch count alone is never a reason to split a companion rationale doc.

## Related precedent

- `.claude/reference/session-state-schema-hotspot-decision.md` (#964) — direct precedent:
  KEEP + targeted dedup when the file is a canonical mechanism owner; field-type dedup applied
  to this exact file in PR #989.
- `.claude/reference/scheduling-reliability-hotspot-decision.md` (#959) — KEEP + targeted dedup
  when churn tracks coordinated contract delivery across several subsystems.
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational; edit frequency alone
  does not justify structural change.
