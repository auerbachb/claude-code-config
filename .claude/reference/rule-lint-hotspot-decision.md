# `.github/scripts/rule-lint.sh` hotspot — ratchet delegation convergence decision

Reference for Issue #1151. Not auto-loaded.

<!-- churn-hotspot: .github/scripts/rule-lint.sh -->

## Churn diagnosis

`.github/scripts/rule-lint.sh` was touched by 3 distinct merged PRs between
2026-07-30 and 2026-08-10: #841, #974, #1149.

Per-PR attribution with evidence (real diffs traced via `git show <sha> -- .github/scripts/rule-lint.sh`):

| PR | Commit | Title | What changed in the script | Driver |
|----|--------|-------|---------------------------|--------|
| #841 | b3efd6b | fix(#832): one-way ratchet for rule-lint.sh --update-cap | Added one-way ratchet mechanism and `--allow-raise` escape hatch (~60 lines): `allow_raise` flag, updated usage text, explicit equal/lower/bootstrap branches | Independent feature iteration (ratchet logic addition) |
| #974 | a3ae873 | fix: make rule-corpus linting recursive and correct cap guidance | Made corpus linting recursive (removed `-maxdepth 1` from `find`), added duplicate-basename detection and error annotation, updated ratchet-cap guidance message | Independent feature iteration (corpus correctness fix) |
| #1149 | 8ab4742 | refactor(#1087): delegate rule-lint budget/ratchet to rule-lint-ratchet.sh | Replaced ~93 lines of inline budget/ratchet logic with a fail-closed call to `rule-lint-ratchet.sh`; moved `rule_files` loop to section 3; removed duplicate `SCRIPT_DIR` from section 4 | Extraction/cleanup (completing the PR #1086 subsystem extraction) |

**All three PRs trace to distinct, legitimate drivers.** PR #841 added the ratchet feature (Issue #832). PR #974 fixed corpus-linting correctness (Issue #939/938). PR #1149 completed the ratchet extraction started in PR #1086 (Issue #1087). No PR is an uncoordinated incidental touch.

## Decision: KEEP

**Verdict: KEEP** — no operative change.

### Rationale

**The churn is now structurally resolved.** PR #1149 completed the extraction of the budget/ratchet subsystem into `rule-lint-ratchet.sh` (the extraction begun in PR #1086). The inline ratchet logic that drove PR #841's addition and PR #974's corpus-measurement update is now fully delegated. Future ratchet changes will touch `rule-lint-ratchet.sh`, not this file.

**The remaining inline logic is one cohesive linting concern.** After delegation, `rule-lint.sh` (186 lines) owns four responsibilities:

- Section 1 (lines 86–138): Rule index alignment — recursive `find`, indexed-vs-actual set diff, duplicate-basename detection, GitHub Actions error annotations
- Section 2 (lines 140–159): Budget/ratchet delegation — fail-closed shim to `rule-lint-ratchet.sh`; forwards `--update-cap`/`--allow-raise`
- Section 3 (lines 161–171): Per-file size warnings — emits `::warning::` for any rule file exceeding 2000 words
- Section 4 (lines 173–179): Chip model-guard conformance — delegates to `chip-model-guard-lint.sh` and its test suite

These four sections are the natural top-level concerns of a single entry-point lint script. Sections 2 and 4 are already delegated to specialist scripts; sections 1 and 3 are the script's own logic. No section independently evolves fast enough to justify extraction: section 1 and section 3 have not churned in isolation, and section 4 already delegates. A SPLIT would add files without reducing coupling.

**A KEEP + extract option was evaluated and declined.** The chip-model-guard delegation block (section 4, 6 lines) was considered for extraction as a standalone "call two scripts, propagate error" block. Rejected: the block has no independent state, no independent CLI flags, and no churn history separate from `rule-lint.sh` itself. The extraction would mirror the ratchet delegation shape but without the ratchet's justification (independently-churning subsystem with its own state and `--update-cap` semantic).

**The config-protection constraint raises the bar for any future operative change.** `rule-lint.sh` is listed in `PROTECTED_RELATIVE_SUFFIXES` in `.claude/hooks/config-protection.py` (line 78), which blocks Write/Edit tool calls and Bash redirects to the file from agents. Any SPLIT or EXTRACT verdict would require an owner edit via the staged-cp workflow documented in Issue #1087 (the same cost incurred to land PR #1149's delegation). This constraint is not a reason to prefer KEEP in a clear SPLIT case, but it is a tiebreaker when the factoring argument is marginal.

### Convergence note

The filing PR (#1149) is itself the resolution to the churn driver. The detector fires on the PR that completes an extraction, recording it alongside the two PRs that introduced the logic being extracted. This is expected behavior: the churn count peaks at the moment the concern is resolved, then drops. The decision record closes the loop.

## Preserved invariants

- **Section 1 (rule index alignment):** The recursive `find`, duplicate-basename detection, indexed-vs-actual set logic, and `::error::` annotations remain unchanged. The `actual_files`/`indexed_files`/`missing_from_index`/`missing_from_disk` variable names are stable.
- **Section 2 (delegation shim):** `rule-lint-ratchet.sh` is the canonical home for budget/ratchet logic. The fail-closed contract (missing or failing ratchet script increments `errors`) is unchanged. `--update-cap` and `--allow-raise` are forwarded unchanged.
- **Section 3 (per-file size):** The `PER_FILE_WARN=2000` threshold and `::warning::` annotation are unchanged.
- **Section 4 (chip-model-guard):** The delegation to `chip-model-guard-lint.sh` and `tests/chip-model-guard-lint.test.sh` is unchanged.
- **Exit code contract:** `exit 1` on any `errors > 0`; `exit 0` with `rule-lint: OK` on a clean pass.

## Future ownership

New rule-index alignment logic (new corpus structures, new glob patterns, new error categories) belongs in `rule-lint.sh` sections 1 or 3 directly — these are the script's own concerns.

New budget/ratchet logic (new thresholds, new ratchet semantics, new CLI flags) belongs in `rule-lint-ratchet.sh`.

New chip-model-guard logic belongs in `chip-model-guard-lint.sh`.

**Reopening the KEEP verdict** is warranted if section 1 (index alignment) and section 3 (per-file-size) independently accumulate 3+ PRs on different release tracks — indicating they have diverged into separable concerns. The convergence note above predicts this will not occur: both sections have been stable since PR #974.

## Related

- `rule-lint-test-hotspot-decision.md` — SPLIT decision for `rule-lint.test.sh` (Issue #1059); extracted `rule-lint-ratchet.test.sh` + `tests/lib/rule-lint-sandbox.sh`
- `rule-lint-yml-hotspot-decision.md` — EXTRACT decision for `.github/workflows/rule-lint.yml` (Issue #1138); replaced per-step list with auto-discovery runner
- Issue #1087 — tracked the production-side delegation of the ratchet shim; the staged-cp workflow it required is the cost precedent for any future agent-unwritable file change
- Issue #1086 / PR #1086 — extracted `rule-lint-ratchet.sh` (the production ratchet script)
- PR #1149 — landed the delegation shim in `rule-lint.sh`, completing Issue #1087
