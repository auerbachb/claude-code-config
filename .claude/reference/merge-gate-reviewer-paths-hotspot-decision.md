# Merge Gate Reviewer Paths Hotspot Decision

Reference for Issue #1002 (`.claude/reference/merge-gate-reviewer-paths.md` churn hotspot). Not auto-loaded.

Third leg of the merge-gate seam, companion to `merge-gate-hotspot-decision.md` (Issue #936, PR #1010,
the script) and `cr-merge-gate-rule-hotspot-decision.md` (Issue #940, PR #1013, the rule). This file
covers the reference document that holds expanded per-path prose for both.

## Executive summary

### Verdict: **KEEP** the single reference file; **targeted pointer deduplication only**

Keep `.claude/reference/merge-gate-reviewer-paths.md` as the single detailed source for all
reviewer-path semantics. Do not split it into per-path reference files. The churn is coordinated
propagation of shared CR-path and dedup mechanisms, not independent per-path drift; the file is
explicitly designated by `cr-merge-gate-rule-hotspot-decision.md` §3.1 and §3.2 as the expansion
home for gate prose that the rule files shed for budget reasons. Splitting it would scatter the
prose that `cr-merge-gate.md`, `bugbot.md`, and `greptile.md` now depend on as a single pointer
target.

One targeted deduplication: each shared-mechanism section receives a brief canonical-source marker
pointing to the authoritative script, so future gate changes know where to land first and where to
reflect the update.

## 1. Trigger and measured evidence

Issue #1002 was filed by `/wrap` churn detection after PR #1001 merged. The issue body recorded
7 distinct merged PRs since 2026-07-21: PRs #686, #727, #840, #849, #907, #965, #1001. PR #1013
(merged the same hour as this adjudication) added one more: the evidence comment appended to the
issue records 8 PRs total: PRs #686, #727, #840, #849, #907, #965, #1001, #1013.

At diagnosis time the file is ~78 lines and ~900 words, well below the 2,000-word per-file warning.
The touches fall into four groups:

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| BugBot hardening | #849, #907, #965 | Silent-pass shapes (issue #844), publisher fail-closed (issue #962), timestamp/commit-id staleness guards |
| Greptile edge cases | #727, #1001 | Comment-based clean-pass detection (issue #723), zero-P0 round reuse with fix-only push provenance (issue #1000) |
| Shared-mechanism updates | #686, #840 | Check-run dedup (issue #675), stale-approval guard (issue #836) |
| Authority clarification | #1013 | Policy-vs-runtime split in the header; `merge-gate.sh` for runtime, `cr-merge-gate.md` for policy |

## 2. Options considered

### Option 1: Split the file per reviewer path

Create separate reference files for CR/CodeAnt, BugBot, Greptile, and shared mechanisms.

**Rejected.** The companion rule decision (PR #1013) explicitly named this file as "the single
detailed source for all reviewer-path semantics" and restructured `bugbot.md` §Merge Gate and
`cr-merge-gate.md` §Greptile path to point here rather than restate the content. Splitting now
would require updating those pointers and re-expanding prose in multiple files — reversing the
deduplication just completed. The churn classes (BugBot, Greptile, shared) reuse the same CR-path
and dedup mechanisms via cross-reference, not independent per-path state. Splitting would not
remove the coordination dependency.

### Option 2: KEEP with no content change

Record a "by design" decision and make no changes to the reference file.

**Rejected.** A targeted pointer deduplication is available: the shared-mechanism sections
(check-run dedup, stale-approval guard) name the authoritative scripts in prose but do not mark
them as canonical. Adding brief markers reduces drift risk for future gate changes without removing
any prose. This is the same targeted-pointer shape applied by the companion rule decision §3.3.

### Option 3: KEEP + targeted pointer deduplication (Chosen)

Retain the file's shape and per-path prose. Add canonical-source markers to the two shared-mechanism
sections so future gate changes land in the script first and propagate to this reference as a pointer.

**Chosen.** Matches the KEEP + dedup precedent in `monitor-mode-hotspot-decision.md` and
`cr-merge-gate-rule-hotspot-decision.md`. Preserves the designated expansion-home role while
reducing the drift surface for shared-mechanism sections.

## 3. Canonical ownership

| Concern | Authoritative script | Reference doc role |
|---------|---------------------|--------------------|
| Check-run dedup | `check-runs-dedup.sh` | Prose explaining the grouping algorithm, `filter=latest` limitation, ordering by `check_suite.id`, and polling consequences |
| Stale-approval guard | `merge-gate.sh` (`LAST_COMMIT_TS` comparison) | Prose explaining the force-push retargeting scenario, what it applies to, and the disable-on-empty fallback |
| CR/CodeAnt clean approval shapes | `merge-gate.sh` | Prose expanding `cr-merge-gate.md` Step 1 CR path (re-trigger policy, stale bot dismissal, not-approvals list) |
| Stale bot `CHANGES_REQUESTED` dismissal | `dismiss-stale-bot-changes.sh` | Prose explaining when to dismiss vs. when a human block holds |
| BugBot silent-pass shapes | `merge-gate.sh` | Prose expanding issue #844 shape details (two accepted shapes, fail-closed conditions) |
| BugBot publisher fail-closed | `merge-gate.sh` (contrast: `escalate-review.sh` opens; `merge-gate.sh` closes) | Prose explaining the asymmetric identity check and why the contrast is intentional |
| Greptile detection and zero-P0 reuse | `merge-gate.sh` | Prose expanding the severity-gated merge-ready conditions and fix-only-push provenance chain |

## 4. Remediation applied

- Added a brief "**Authoritative source:** `check-runs-dedup.sh`" marker to the check-run dedup
  section so future dedup changes know to land in the script first.
- Added a brief "**Authoritative source:** `merge-gate.sh`" marker to the stale-approval guard
  section, naming the `LAST_COMMIT_TS` comparison as the canonical implementation.
- No prose removed; no section headers changed; no issue-number citations altered; no behavioral
  semantics modified.
- Registered this decision in `.claude/reference/README.md`.

## 5. Preserved invariants

- The file remains the single detailed source for all reviewer-path semantics: CR/CodeAnt, BugBot,
  Greptile, and shared mechanisms.
- All issue-number citations (e.g., #675, #836, #844, #962, #1000) remain in their original positions.
- All section headers remain unchanged.
- The authority-clarity header added by PR #1013 (`merge-gate.sh` authoritative for runtime behavior,
  `cr-merge-gate.md` authoritative for policy) is preserved as the file's canonical framing.
- The "Stay on BugBot / stay on Greptile" behavioral directives are untouched.
- The file's role as the pointer target for `bugbot.md` §Merge Gate and `cr-merge-gate.md` §Greptile
  path (deduplication completed by PR #1013) is preserved.

## 6. Re-open trigger

Per `.claude/reference/churn-hotspots.md`, `/wrap` must re-file this hotspot only when
`conflict_rounds > 0`. Rising PR count from policy propagation (the inherent role of this
designated-expansion file) is not a re-filing trigger; the closed decision on record covers that
case explicitly.

## 7. Future edits

New merge-gate edits must land in the authoritative script first (`merge-gate.sh`,
`check-runs-dedup.sh`, `dismiss-stale-bot-changes.sh`, `escalate-review.sh`), then propagate to
this reference as a pointer or prose expansion. The rule file (`cr-merge-gate.md`) carries the
policy intent; this reference carries the expanded per-path semantics. This file should not be the
first place a gate change is recorded.

Reconsider the SPLIT verdict only if BugBot or Greptile sections start evolving independently of
the shared CR-path and check-run-dedup mechanisms — specifically, if a BugBot or Greptile gate
change arrives that has no shared-mechanism dependency and adds more than 200 words to its section.

## 8. Related

- Issue #936 / PR #1010 — `merge-gate.sh` hotspot, companion script decision (`merge-gate-hotspot-decision.md`)
- Issue #940 / PR #1013 — `cr-merge-gate.md` hotspot, companion rule decision (`cr-merge-gate-rule-hotspot-decision.md`)
- Issue #675 — check-run dedup (shared mechanism: `check-runs-dedup.sh`)
- Issue #836 — stale-approval guard (shared mechanism: `merge-gate.sh` `LAST_COMMIT_TS`)
- Issue #844 — BugBot silent-pass shapes (BugBot hardening)
- Issue #962 — BugBot publisher fail-closed (BugBot hardening)
- Issue #723 / Issue #1000 — Greptile comment-based clean pass, zero-P0 round reuse (Greptile edge cases)
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup precedent (rule hub file)
- `.claude/reference/fixpr-hotspot-decision.md` — KEEP + extract precedent (contrasting extraction case)
