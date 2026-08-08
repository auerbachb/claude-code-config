# `.github/workflows/rule-lint.yml` hotspot — auto-discovery extraction

Reference for Issue #1138. Not auto-loaded.

<!-- churn-hotspot: .github/workflows/rule-lint.yml -->

## Churn diagnosis

`.github/workflows/rule-lint.yml` was touched by 3 distinct merged PRs between
2026-07-30 and 2026-08-08: #801, #960, #1131.

Per-PR attribution with evidence:

| PR | Title | What changed in the workflow | Pattern |
|----|-------|------------------------------|---------|
| #801 | feat(#767): lint verbatim SAFETY/MINDSET/SKILLS blocks | Added `Run verbatim-block-lint` step | Append a step |
| #960 | fix(#950): give reference-catalog-lint a CI caller | Added `Run reference-catalog-lint` step | Append a step |
| #1131 | fix(#1121): add required name frontmatter so custom agents register | Added `Run agents-frontmatter-lint` step | Append a step |

All three PRs used the same mechanical pattern: append a new `- name:/run:` step
at the tail of the shared `rule-lint` job. Each addition was a direct consequence
of `# New doc lints belong here as steps` comment (issue #591 convention), which
directed every new lint author to modify this file.

This is structurally identical to the `hook-scripts.yml` hotspot fixed by
Issue #681 — a hand-maintained per-item step list that every new item collides on.

## Decision: EXTRACT (auto-discovery)

**Verdict: EXTRACT** — replace the per-lint step list with a single
auto-discovery runner step.

### What was done

- `.github/scripts/run-doc-lints.sh` — new discovery runner; globs
  `.github/scripts/*-lint.sh` (minus an exclusion list for scripts with their
  own CI path) and appends `.claude/scripts/reference-catalog-lint.sh`
  explicitly; mirrors the `run-hook-tests.sh` compact-result-contract (#782)
  and the `summarize-test-run.sh` wrapping pattern; supports `--json` for
  compact CI output; exits 3 on empty discovery (guards against silent green)
- `.github/scripts/tests/run-doc-lints.test.sh` — 36-case hermetic test suite:
  clean pass, failing lint, exclusion enforcement, `*-ratchet.sh` glob boundary,
  empty-discovery sentinel, default mode, argument handling, marker-less failure
- `.github/workflows/rule-lint.yml` — single `Run doc lints (auto-discovered)`
  step replaces 5 per-lint steps; job id `rule-lint` preserved; no trigger change
- `CONTRIBUTING.md` — new "Adding a Doc Lint" section documents the new
  convention; names the exclusion list and its rationale

### Why KEEP was rejected

The churn driver — "edit the workflow to register a lint" — is a structural
problem, not a content-accretion one. A KEEP decision doc would leave the
footgun in place; the next lint author would still append a step.

### Why SPLIT was not applicable

The workflow file has one job (`rule-lint`) and one concern (running all doc
lints under that required status check). There is no separable sub-concern to
split into a second file.

### Exclusion list design

Three scripts match the `*-lint.sh` glob but are NOT standalone doc-lint steps:

| Script | CI path | Why excluded from glob |
|---|---|---|
| `chip-model-guard-lint.sh` | Inside `rule-lint.sh` section 4 | Double-enforcement if also discovered standalone |
| `env-template-allowlist-lint.sh` | `hook-scripts.yml` test auto-discovery | Reached via its test suite; standalone step would double-run it |
| `merge-authority-lint.sh` | `hook-scripts.yml` test auto-discovery | Same |

`rule-lint-ratchet.sh` is a `*-ratchet.sh` script (not `*-lint.sh`) so the glob
never matches it; explicit exclusion is unnecessary.

## Preserved invariants

- **Job id `rule-lint`** — the required branch-protection status-check name on
  `main`; unchanged. The `name:` field was absent before and remains absent;
  adding it would silently drop the check from branch protection.
- **Trigger** — `on: pull_request` with no path filter; unchanged.
- **Effective lint set** — all 5 lints run before still run: `rule-lint.sh`,
  `skill-catalog-lint.sh`, `verbatim-block-lint.sh`,
  `reference-catalog-lint.sh`, `agents-frontmatter-lint.sh`. None added, none
  dropped.
- **Exit-code contract** — each lint is still invoked as `bash <script>` with no
  positional arguments; exit 0 = pass, non-zero = fail.
- **Annotations** — each lint's `::error::` annotations pass through to CI via
  the runner's stderr path (failing lints print in full on stderr; passing lints
  are silenced in `--json` mode).

## Criteria for reopening

Reopen the EXTRACT decision if any of the following arise:

- A new lint-specific CI requirement cannot be served by the auto-discovery
  runner (e.g. a lint needs a separate job, a different runner environment,
  or extra setup steps that cannot be encoded in the lint script itself).
- The runner contract changes in a breaking way (glob pattern, exclusion-list
  interface, exit-code semantics, or `--json` output shape) that would require
  per-lint workflow steps to diverge from the unified runner call.
- A security or reproducibility finding shows that glob-based auto-discovery
  introduces a risk that explicit step registration eliminates.

In all other cases — including adding, removing, or renaming lint scripts —
the current EXTRACT design handles the change with no workflow edit.

## Future ownership

New standalone doc lints: drop a `*-lint.sh` file into `.github/scripts/`. No
workflow edit needed.

Lints with test-based CI wiring (reached via `hook-scripts.yml`): add to the
`EXCLUDED_BASENAMES` array in `run-doc-lints.sh` with a comment naming the
alternative path.

Precedents: `hook-scripts.yml` auto-discovery (issue #681),
`run-hook-tests.sh` compact-result-contract (issue #782).
