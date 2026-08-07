# chip-model-guard-lint.sh hotspot — diagnosis and extract-not-split decision

Reference for Issue #1042 (`.github/scripts/chip-model-guard-lint.sh` churn hotspot). Not auto-loaded.

## The problem being addressed

`.github/scripts/chip-model-guard-lint.sh` was touched by 5 distinct merged PRs since 2026-07-23:
PR #736, PR #775, PR #799, PR #812, PR #842.

The file is a 258-line static conformance checker that enforces the chip MODEL GUARD contract
across four contract documents and six skill files. It runs indirectly through `rule-lint.sh`
(Step 4) and through the `run-hook-tests.sh` auto-discovery glob.

## Churn diagnosis

Each PR added a new contract requirement plus paired semantic-inversion tests, not a structural defect:

| PR | Issue | Section touched | What changed |
|----|-------|-----------------|--------------|
| PR #736 | #731 | Initial creation | Created the lint script: §1–§4 contract checks, 5 canonical emitters, `require_file`, `require_pattern` |
| PR #775 | #770 | §2 resolver-emitter split | Added 6th emitter (harness-audit), split LITERAL vs RESOLVER classes, added `MODEL_LITERAL_RE`, `MODEL_ALIAS_RE`, `is_resolver_emitter()` |
| PR #799 | #791 | §1 Effort checks + §5 versioned-name scan | Added `**Effort:**` checks, `Ultra code` guidance, `Fable parent` check; added §5 versioned model name corpus scan across operative corpus |
| PR #812 | #802 | §2 placement regex | Strengthened first-line `**Model:**` placement to bilateral co-occurrence regex — prevents acceptance of placement phrases not bound to `**Model:**` |
| PR #842 | #837 | §1 family-comparison assertions | Added `Compare families only —`, `old-style version qualifier: ignore it on either side`, `Match (same family): state "Running on {FAMILY}"` checks with semantic-inversion-hardened anchors |

Issues #770, #791, #802, and #837 each added a new requirement that demanded a corresponding
semantic-inversion test in `.github/scripts/tests/chip-model-guard-lint.test.sh`. The churn is
legitimate contract growth that tracks the guard's expanding semantic coverage — not a structural
defect.

## Decision: extract, not split

**Splitting `chip-model-guard-lint.sh` is rejected.**

The script's class-based branching (LITERAL emitters name the model directly; RESOLVER emitters
look it up via `model-fleet.sh` and must contain no model literal), the positive and negative
assertions, and the paired inversion tests form one cohesive semantic contract. A physical split
by numbered section (§1 chip-launching, §2 emitter skills, §3 decision record, §4 global rule,
§5 corpus scan) would:

- Require the `is_resolver_emitter()` dispatch to be duplicated or extracted into a stub sourced
  by both a §1 and a §2 script, fragmenting the class definition from its consumers.
- Force `rule-lint.sh` (Step 4 subprocess invocation) and `run-hook-tests.sh` (auto-discovery
  glob) to discover and orchestrate multiple scripts where they now call one.
- Split the positive emitter checks (§2) from the resolver-emitter forbid checks (same §2 block),
  which require the class split to be understood together to reason about their coverage.

**Rejected: plain documented no-op** — The `require_file`/`require_pattern` boilerplate is
genuinely duplicated byte-for-byte across four lint siblings (`chip-model-guard-lint.sh`,
`merge-authority-lint.sh`, `verbatim-block-lint.sh`, `env-template-allowlist-lint.sh`),
making an extraction to `.github/scripts/lib/lint-common.sh` a clear improvement over a no-op.

This follows the same extract-not-split verdict as:
- `fixpr/SKILL.md` hotspot (#788) — `fixpr-hotspot-decision.md`
- `merge-gate.sh` hotspot (#936) — `merge-gate-hotspot-decision.md`

## Concrete remedy

Extraction of shared boilerplate into `.github/scripts/lib/lint-common.sh`, sourced from all
four lint scripts. Zero behavior change.

**What was extracted:**

- `require_file()` — checks for a required file and records an error; standardized to return `0`
  explicitly on the success path (two of the four scripts previously omitted this; bash's `if`
  command returns `0` when its condition is false and no `else` branch runs, so the function
  already behaved correctly without it — the explicit `return 0` is retained as a clear success
  contract, not because it changes behavior).
- `require_pattern()` — checks a required pattern in a file and records an error.

**What was NOT extracted:**

- Per-script `usage()` help text and argument-parsing loop — each script's help text is unique
  and documents that script's specific purpose.
- The `errors`-counter finalize block — each script emits a unique summary line naming itself;
  sharing this would require parameterization that adds more complexity than the duplication costs.
- `require_literal()` in `merge-authority-lint.sh` — unique to that script; not shared.
- `require_token()`, `forbid_token()` in `env-template-allowlist-lint.sh` — unique to that script.
- `extract_block()` in `verbatim-block-lint.sh` — unique to that script.

**Call-site audit:** All four scripts' `require_file` call patterns are compatible with the
standardized `return 0`:

- `chip-model-guard-lint.sh`: uses `|| true` exclusively — `return 0` is a no-op for these callers.
- `merge-authority-lint.sh`: uses `|| true` exclusively — same.
- `verbatim-block-lint.sh`: uses `|| true` (pre-flight) and `|| continue` (main loop) — the
  `|| continue` callers already required `return 0`; verbatim-block-lint.sh already had it.
- `env-template-allowlist-lint.sh`: uses `|| continue` (prompt surfaces) and `|| true`
  (safety.md) — same; env-template-allowlist-lint.sh already had `return 0`.

## What was explicitly preserved

- All regex checks: `require_pattern` arguments unchanged across all four scripts.
- Exit codes: 0 (clean), 1 (errors found), 2 (unknown argument) — unchanged in all four scripts.
- The `::error file=…::` GitHub Actions annotation format: unchanged.
- The indirect invocation through `rule-lint.sh` (Step 4 subprocess) and the
  `run-hook-tests.sh` auto-discovery glob: both continue to work without modification.
- The `is_resolver_emitter()` function, `MODEL_LITERAL_RE`, `MODEL_ALIAS_RE`, and
  the paired inversion tests in `chip-model-guard-lint.test.sh`: all unchanged.

## Related

- Issue #731 — initial lint script creation (PR #736)
- Issue #770 — resolver emitter class (PR #775)
- Issue #791 — versionless model names + Effort checks (PR #799)
- Issue #802 — placement co-occurrence regex (PR #812)
- Issue #837 — family-comparison assertions (PR #842)
- `.github/scripts/lib/lint-common.sh` — new shared helper library
- `fixpr-hotspot-decision.md` — structural precedent for extract-not-split
- `merge-gate-hotspot-decision.md` — structural precedent for extract-not-split
