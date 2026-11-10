<!-- churn-hotspot: .claude/scripts/tests/reply-thread.test.sh -->

# reply-thread.test.sh Hotspot Decision

Reference for Issue #1110 (`.claude/scripts/tests/reply-thread.test.sh` churn hotspot).
Not auto-loaded.

**Verdict:** KEEP — no split, no extraction
**Decided:** 2026-08-08
**Issue:** #1110
**Reporter:** /wrap post-merge churn report, PR #1109

## Executive summary

Keep `.claude/scripts/tests/reply-thread.test.sh` as the single regression suite for
`reply-thread.sh`. Do not split, extract, or modify the file.

All three PRs flagged by the detector are substantiated by the full repository history and
verified via `gh pr view --json files` plus `git log --follow` and `git show`. The filed
PR list (#798, #904, #1001) matches the verified attribution — no discrepancy. The verdict
is KEEP: PR #798 is the sole creation event (13 cases covering all four reviewer modes and
CodeAnt strip behavior), PR #904 extended the suite with 6 new fallback-path cases tracking
the exit-code correctness fix (Issue #884), and PR #1001 added 1 case for the provenance
marker feature (Issue #1000). No PR edited two independent internal concerns simultaneously
after creation.

The file is 342 lines / 20 test cases, single-purpose, and coupled to one script
(`reply-thread.sh`) via its `--reviewer` flag contract and exit-code table. There are no
independent evolving seams.

## 1. Trigger and measured evidence

The hotspot detector recorded 3 merged PRs touching
`.claude/scripts/tests/reply-thread.test.sh` since 2026-07-24: PRs #798, #904, #1001.

At adjudication, the file is **342 lines / 20 test cases**. No conflict rounds recorded.

### Per-PR diff analysis (all three PRs verified via `git log --follow` and `git show`)

| PR | Title | Touch class | Driver |
|----|-------|-------------|--------|
| #798 | fix(#772): add codeant reviewer mode to reply-thread.sh | File creation | Created 236-line suite with cases (1)–(13): all four `--reviewer` modes accepted/rejected, `@codeant-ai` strip rules (case-insensitive, word-boundary, multi-occurrence), body-empty-after-strip guard, and backward-compat smoke tests for cr/bugbot/greptile modes |
| #904 | fix(#884): reply-thread.sh fallback exits 0 on success | Fallback-contract extension | Extended `gh` stub with `pr comment` branch; added `run_split` helper; added cases (14)–(19): fallback success exits 0 (the exact Issue #884 regression), stderr note distinguishes fallback path, `&&`-chain behavior (the incident pattern), no-`--pr` guard (exit 3), both-404 (exit 3), fallback non-404 error (exit 4) |
| #1001 | fix(#1000): reuse zero-P0 Greptile review rounds | Provenance-marker extension | Updated `pr comment` stub to capture fallback body; added case (20): asserts that the fallback body contains `<!-- review-comment-id:1234567 -->` plus the original reply text |

**PR #798 — creation confirmed.** `git show 4e66f31 --stat` shows `new file mode`, `+236 lines`. All 13 initial cases exist from the creation commit.

**PR #904 — fallback-contract-only confirmed.** `git show 3eaf6e6 --` on this file shows stub extension, `run_split` helper addition, and 6 new test cases (14–19). Cases (1)–(13) are untouched.

**PR #1001 — provenance-marker-only confirmed.** `git show e7b4a67 --` on this file shows the `pr comment` stub capture update and one new test case (20). No other cases changed.

### The two internal sections

The test suite covers two sections, both present as stubs from creation (PR #798):

- **(a) Inline-reply path — cases (1)–(13):** All four reviewer modes accepted/rejected;
  `strip_standalone_token()` behavior for `@codeant-ai` at various boundary conditions;
  backward-compat coverage for cr/bugbot/greptile modes. Driven by Section C of
  `reply-thread.sh` (body transformation).
- **(b) Fallback path — cases (14)–(20):** Exit-code contract for the PR-level fallback
  (`gh pr comment`); stderr distinguishability; `&&`-chain safety; no-`--pr`/both-404/error
  paths; fallback body provenance marker. Driven by Sections A and F of `reply-thread.sh`
  (exit-code table, PR-comment fallback).

No PR after creation edited both sections simultaneously:
- PR #904 touched only section (b) — fallback path.
- PR #1001 touched only section (b) — fallback path (one new case).

## 2. Options considered

### Option 1: Keep the file; no content change (Chosen)

**Chosen.** Three PRs, one creation event, two orthogonal fallback-path extensions. The
creation event established both sections together as a coherent harness. Neither PR #904 nor
PR #1001 demonstrates that the two sections are independently evolving seams — both extensions
targeted section (b) only because `reply-thread.sh`'s fallback section received two sequential
contract additions (exit-code correctness then provenance marker). The inline-reply section
(a) has been stable since PR #798.

### Option 2: Split by inline vs. fallback concern (Rejected)

**Rejected.** The split precedent (`escalate-review-test-hotspot-decision.md`, Issue #966;
`usage-limit-record-test-hotspot-decision.md`, Issue #1071; `merge-gate-ci-dedup-test-hotspot-decision.md`,
Issue #1106) requires proof that a single PR touches one concern without touching the other
and that the concerns have distinct callers or independently evolving code paths. The evidence
does not meet this bar:

- PR #904 and PR #1001 both targeted section (b) because `reply-thread.sh`'s fallback
  section received sequential contract additions — that is coordinated evolution of one
  functional section, not two independent seams diverging.
- Sections (a) and (b) share the same `$TMP`/`$STUB_BIN`/`PASS`/`FAIL` harness, the same
  `gh` stub binary, and the same `run`/`run_and_capture`/`run_split` helpers. Splitting
  would require duplicating that infrastructure with no reduction in per-change edit sites
  (future `reply-thread.sh` contract changes would still touch section (b) only, in
  whichever file holds it).
- 20 cases / 342 lines is below the threshold where split overhead pays off.

### Option 3: Extract shared helpers into `tests/lib/` (Rejected)

**Rejected.** The extraction precedent (`polling-state-gate-test-hotspot-decision.md`,
Issue #1003) extracts shared test infrastructure only when 2 or more test suites consume it.
`reply-thread.test.sh` currently has exactly one file with no companion suite. Preemptive
extraction for a single caller creates indirection without value.

## 3. Structural protections that predict low future churn

- **Single script under test:** The suite is coupled to exactly one script (`reply-thread.sh`)
  with a stable public contract (`--reviewer`, `--body`, `--pr`, exit codes 0/2/3/4/5).
  New reviewer modes or exit-code changes flow through that contract; they do not bypass it.
- **Inline section stable since creation:** Cases (1)–(13) have not changed across two
  subsequent PRs. The strip rules and reviewer accept-list are stable; a fifth reviewer mode
  would be the only driver for a future inline-section edit.
- **Fallback section coverage:** Cases (14)–(20) cover the tested fallback exit outcomes
  (exit 0 on both paths, exit 3 on no-fallback-target or both-404, exit 4 on fallback error)
  and the two body-format invariants (stderr note, provenance marker). The documented exit-5
  path has no dedicated test case. Further extensions to the fallback section are unlikely
  without a new fallback output field.
- **Regression test pins the Issue #884 scenario exactly:** Case (14) is annotated with the
  original incident — inline 404, fallback posts OK, exit code must be 0. The comment
  traces the before-state (`exit 1 even though the reply posted`). This makes silent
  reintroduction structurally testable.

## 4. Remediation applied

None. `.claude/scripts/tests/reply-thread.test.sh` is unchanged.

## 5. Preserved invariants

- All four `--reviewer` values (`cr`, `bugbot`, `greptile`, `codeant`) must remain accepted
  by the script; the test suite asserts each one. An unknown reviewer still exits 2.
- The `strip_standalone_token()` word-boundary rule for `@codeant-ai` must remain
  case-insensitive (cases 3–4) and boundary-aware (case 13: `x@codeant-ai` not stripped).
- Exit-code contract: inline success → 0; body-empty-after-strip → 2. Cases (14)–(19) pin
  the fallback outcomes: success → 0, both endpoints 404 → 3, and fallback non-404 error
  → 4. Exit 5 gained its first dedicated case in Issue #1446 — case (23b), a non-404
  failure of the PR-number lookup.
  **Superseded in part by Issue #1446 (2026-08-28):** the "no `--pr` → 3" leg is gone —
  the inline route is PR-scoped, so the PR number is resolved from the comment before the
  inline attempt and a genuine inline 404 can still fall back. Exit 3 now covers
  "PR number unresolvable from the comment (and no `--pr`)" or "both endpoints 404";
  case (17) was reworked accordingly.
- Fallback body must contain `<!-- review-comment-id:$COMMENT_ID -->` when the inline path
  returns 404 (case 20, Issue #1000 provenance requirement).
- The inline reply must POST to the **PR-scoped** route
  `repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies` (case 21, Issue #1446). The
  PR-less form does not accept POST; pinning the endpoint shape is what makes a silent
  regression to it testable.
- Assertion count: 68 across 26 cases (measured on the Issue #1446 branch; 46 across 20
  cases on the preceding `main` — the "32" recorded here before 2026-08-28 was already
  stale when written). Any PR that removes or rewrites an assertion should justify the
  count change explicitly.

## 6. Future reconsideration

Reopen this decision only if:

- A companion test suite emerges that tests a script sharing `reply-thread.sh`'s harness
  infrastructure — this would satisfy the ≥2-consumer bar for extracting shared fixtures,
  matching the precedent in `polling-state-gate-test-hotspot-decision.md`.
- `conflict_rounds > 0` — two contributors editing the same test cases in the same window,
  causing merge conflicts (touch count alone is insufficient for a split verdict).
- A fifth reviewer mode is added, causing section (a) to grow independently of section (b)
  for the first time — that pattern change would move the file closer to the split bar.

## 7. Related

- Issue #884 — fallback exit-code fix (PR #904); the known bug where `reply-thread.sh`'s
  fallback posted successfully but exited 1, causing `&&`-chained callers (e.g., `/fixpr`)
  to treat a successful post as failure and post duplicate comments; fixed by changing
  `exit 1` → `exit 0` on the success path (see memory `feedback_reply_thread_fallback_exit.md`)
- Issue #1000 — Greptile zero-P0 round reuse; the `<!-- review-comment-id:$COMMENT_ID -->`
  provenance marker added to fallback body (PR #1001)
- Issue #772 — CodeAnt reviewer mode (PR #798, the file creation event)
- `.claude/reference/reply-thread-hotspot-decision.md` — companion KEEP decision for
  `reply-thread.sh` itself (Issue #1097); confirms same three PRs (#798, #904, #1001) as
  the churn contributors, with per-section attribution from the script side
- `.claude/scripts/reply-thread.sh` — the script under test; exit-code contract authoritative
  in `--help` output; C-09 in `script-extraction-audit.md`
- `.claude/reference/escalate-review-test-hotspot-decision.md` — SPLIT precedent for
  comparison (Issue #966): requires proven independent seams with single-PR isolated
  concern changes; 11 PRs; this file does not meet that bar
- `.claude/reference/polling-backoff-warn-test-hotspot-decision.md` — KEEP precedent for
  a test suite of similar size (3 merged PRs, 16 sections); external-contract-driven churn
  with no companion file and no internal duplication — analogous classification
