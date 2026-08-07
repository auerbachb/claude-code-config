# `rule-lint.test.sh` hotspot — ratchet extraction decision

Reference for Issue #1059. Not auto-loaded.

<!-- churn-hotspot: .github/scripts/tests/rule-lint.test.sh -->

## Churn diagnosis

`.github/scripts/tests/rule-lint.test.sh` was touched by 4 distinct merged PRs
between 2026-07-24 and 2026-08-05: #841, #908, #932, #974. Per-PR attribution
with evidence:

| PR | Title | What changed in the test file | Ratchet subsystem? |
|----|-------|-------------------------------|-------------------|
| #841 | fix(#832): one-way ratchet for rule-lint.sh --update-cap | Created the file (197 lines) with cases a, b, c, d — ratchet correctness: holds, lowers, raises, bootstraps | Yes — ratchet only |
| #908 | fix(#906): make rule-lint ratchet fixtures hermetic | Added sandbox copy-of-working-tree, `real_cap_fingerprint`, `assert_real_cap_untouched`, hermeticity case (g), equal-case (f), `expect()` runner | Yes — ratchet hermeticity |
| #932 | docs(#879): ratchet cap is a visibility mechanism, not the gate | Added ratchet-breach hard-fail case (h) pinning the `::error` severity | Yes — ratchet severity decision |
| #974 | fix: make rule-corpus linting recursive and correct cap guidance | Added nested-rule case (i) and recursive corpus counting (not ratchet logic) | Partial — case (i) covers the index/size subsystem, but the recursive counting change also updated ratchet corpus measurement |

**Verdict on the "all 4 trace to the ratchet" claim:** Largely accurate with one
nuance. PR #974's case (i) is the index-alignment and per-file-size check, not
the ratchet — the ratchet-adjacent change in #974 was updating `CURRENT_COUNT`
to use recursive `find` so the test's corpus measurement matched the updated
production script. The ratchet subsystem was the primary source of churn; case
(i) is an independent concern that belongs in the index/size suite.

The test file bundles the stateful word-budget ratchet (cases a, b, c, d, f, g,
h) with the index-alignment and per-file-size check (case i) and the real-repo
conformance run (case e). These are separable concerns: future ratchet changes
should not require touching the index or size tests, and vice versa.

## Decision: SPLIT/EXTRACT — test split landed, production delegation deferred

**Verdict: SPLIT/EXTRACT** (partial — test split and standalone ratchet script
landed; production delegation to rule-lint.sh deferred by constraint below).

### What was done

- `.github/scripts/rule-lint-ratchet.sh` — standalone ratchet production script;
  companion to `rule-lint.sh` (mirroring `chip-model-guard-lint.sh`); contains
  the full word-budget ratchet logic extracted from `rule-lint.sh` check #2
- `.github/scripts/tests/lib/rule-lint-sandbox.sh` — shared sandbox construction,
  `real_cap_fingerprint`, `assert_real_cap_untouched`, `set_cap`, `read_cap`,
  `read_cap_value`, and `run_update_cap()`/`expect()` runner; deliberately does NOT
  end in `.test.sh` so `run-hook-tests.sh` does not execute it directly
- `.github/scripts/tests/rule-lint-ratchet.test.sh` — ratchet cases (a, b, c, d,
  f, g, h); sources `lib/rule-lint-sandbox.sh`; exercises ratchet behavior through
  `rule-lint.sh --update-cap` (the production CI path)
- `.github/scripts/tests/rule-lint.test.sh` (reduced) — index/size case (i) and
  real-repo conformance case (e); sources `lib/rule-lint-sandbox.sh`

### What is deferred

**`rule-lint.sh` delegation** — adding
`if ! bash "${SCRIPT_DIR}/rule-lint-ratchet.sh" "$@"; then errors=$((errors+1)); fi`
to replace the inline check #2 in `rule-lint.sh` — is blocked because
`.github/scripts/rule-lint.sh` is in `PROTECTED_RELATIVE_SUFFIXES` in
`.claude/hooks/config-protection.py`. The hook blocks Write/Edit tool calls and
Bash redirects to this file. The delegation must be applied as an owner edit or
via `--update-cap --allow-raise` invocation when rule-lint.sh is next modified
for another reason.

Until the delegation lands, `rule-lint.sh` retains the inline ratchet logic and
`rule-lint-ratchet.sh` is the canonical home for that logic going forward. The
ratchet test exercises `rule-lint.sh --update-cap` (the actual CI path), so CI
conformance is not degraded.

**Precedents:** This follows the `chip-model-guard-lint.sh` production-script
extraction pattern (PR #1072) and the `escalate-review-*.test.sh` concern-based
test split with a shared fixture lib (PR #969).

**A no-op KEEP was rejected:** the ratchet subsystem is a separable, high-churn
concern distinct from the index and size checks. Keeping them in one file means
every ratchet change risks touching index/size test setup and vice versa.

## Preserved invariants

- The index-alignment, per-file-size, and chip-model-guard checks keep their
  current behavior and exit codes in `rule-lint.sh`.
- The ratchet CLI flags `--update-cap` and `--allow-raise` keep their semantics;
  while delegation is deferred, `rule-lint.sh` retains its own inline handling of
  these flags. Delegation to `rule-lint-ratchet.sh` is tracked in Issue #1087.
- The `.claude/rules/.budget-soft-cap` ratchet formula (`max(count + 750, 8500)`)
  is unchanged.
- All case labels (a–i) remain represented across the two test files so issue and
  review history stays searchable.
- CI behavior is behavior-preserving: `rule-lint.sh` exit code and output strings
  are identical before and after the extraction.

## Future ownership

New ratchet coverage (new `--update-cap` scenarios, new bootstrap shapes, new
breach assertions) belongs in `rule-lint-ratchet.test.sh`.

New index-alignment or per-file-size coverage belongs in `rule-lint.test.sh`.

Reusable sandbox setup (new fixture helpers, new hermeticity probes) belongs only
in `tests/lib/rule-lint-sandbox.sh`; scenario logic must not migrate there merely
to reduce line counts.
