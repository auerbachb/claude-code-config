# Contributing to claude-code-config

This repo is the single source of truth for Claude Code skills, rules, hooks, and `CLAUDE.md`. Any change here affects every session that uses this config, so every change must go through the standard issue → PR → review → squash-merge flow.

For deep-dive architecture (symlink topology, hook lifecycle, multi-agent orchestration, review loop internals), see [ARCHITECTURE.md](ARCHITECTURE.md).

## PR Workflow (general)

- **Every PR links to a GitHub issue.** Create one first via `gh issue create` if none exists. Reference it with `Closes #N` in the PR body.
- **Branch naming:** `issue-N-short-description`. Never work on `main`.
- **Always use a worktree** for isolated work — see the "Always use a worktree" section of [CLAUDE.md](CLAUDE.md).
- **Local review before push:** run `coderabbit review --agent` until one clean pass, then commit and push. See [`.claude/rules/cr-local-review.md`](.claude/rules/cr-local-review.md).
- **Merge gate:** 1 explicit CodeRabbit APPROVED on current HEAD (plus CodeAnt clean signal when CodeAnt has run on that SHA), or 1 clean BugBot pass, or a clean Greptile severity gate. See [`.claude/rules/cr-merge-gate.md`](.claude/rules/cr-merge-gate.md).
- **CI must pass before merge** (including the `rule-lint` check that verifies rule-file sizes and index alignment).
- **Squash merge only:** `gh pr merge --squash --delete-branch`.
- **Test plan required:** every PR body must include a `## Test plan` section with a checkbox for each acceptance criterion.

## Adding a New Skill

Skills live in `.claude/skills/<name>/SKILL.md`.

1. **Create `SKILL.md`** with YAML frontmatter:
   - `name` (required)
   - `description` (required — used by the model for discovery; be specific about when to trigger)
   - `model` (optional: `sonnet` or `opus` override)
   - `triggers` (optional: natural-language invocation phrases)
   - `allowed-tools` (optional: restrict the skill to specific tools — **correct for skills only**; agent definitions under `.claude/agents/` use `tools:` instead)
   - `disable-model-invocation` (optional: prevents auto-trigger AND hides from slash-command autocomplete — avoid unless you really mean both)
2. **Skill body:** step-by-step instructions, exact bash commands with absolute paths, and clear exit criteria. Subagents skip prose rules — prefer numbered checklists with explicit STOP conditions.

> **Authoring judgment (not just mechanics):** for *how* to write a discoverable description and a discipline rule that holds under pressure — description-as-trigger, matching guidance form to failure type, and bulletproofing — see [`.claude/reference/skill-authoring-patterns.md`](.claude/reference/skill-authoring-patterns.md). It also applies to rules below.

After adding or revising a skill, run `bash .claude/scripts/skill-conventions-audit.sh` to check frontmatter and description conventions.
3. **Symlink checklist after merge** (via the skills worktree — never symlink directly to the root repo):

   ```bash
   # Update the skills worktree to pick up the new skill
   git -C ~/.claude/skills-worktree fetch origin main --quiet
   git -C ~/.claude/skills-worktree reset --hard origin/main --quiet

   # Create/update the global symlink (idempotent)
   ln -sfn ~/.claude/skills-worktree/.claude/skills/<name> ~/.claude/skills/<name>
   ```

See [`.claude/rules/skill-symlinks.md`](.claude/rules/skill-symlinks.md) for the full symlink rules and verification commands.

## Adding a New Rule

Rules live in `.claude/rules/<name>.md` and auto-load in every parent-agent session.

1. **Create the file** at `.claude/rules/<name>.md`.
2. **File size limits** (see CLAUDE.md "Rule File Size Guidelines"):
   - **Soft cap:** ~150 lines / ~1,500 words per file — consider splitting if exceeded.
   - **Hard cap:** 200 lines / 2,000 words per file — must split.
3. **Total budget — the gate:** CLAUDE.md + all rule files ≤ **12,000 words** soft warning / **13,000** hard fail (matches `.coderabbit.yaml` and `rule-lint.sh`). These two numbers are absolute: nothing waives them.
4. **Ratchet cap — visibility, not the gate:** `.claude/rules/.budget-soft-cap` holds `max(count + 750, 8500)` and `rule-lint.sh` fails when the corpus exceeds it. Its job is to make every increment show up as a deliberate line in a diff, not to freeze the corpus. Two ways to stay green:
   - **Pay for the addition with cuts** so the total stays under the committed cap — always available, and the right default when the growth is restatement you can compress away.
   - **Raise the cap**, which is legitimate *when accompanied by a PR-body line naming what was added and why it belongs in the auto-loaded corpus rather than in `.claude/reference/`*. Raise it with `bash .github/scripts/rule-lint.sh --update-cap --allow-raise` (writes `count + 750` and prints old → new → delta); a raise to a specific number is an owner edit, because `config-protection.py` blocks agent writes to the cap file. `--update-cap` alone only lowers or holds.

   Full policy and rationale: [`.claude/reference/budget-cap-raise-decision.md`](.claude/reference/budget-cap-raise-decision.md) (Issue #879).
5. **Verification command:**

   ```bash
   { cat CLAUDE.md; find .claude/rules -name '*.md' -exec cat {} +; } | wc -w
   ```

   Run this on any PR that touches CLAUDE.md or `.claude/rules/`. Compare it against both the committed cap (`cat .claude/rules/.budget-soft-cap`) and the 12,000/13,000 limits before merging. CI lints the merge ref, so leave a margin of ~30 words rather than landing on the number exactly.
6. **Update the CLAUDE.md rule index table** with a new row for the file (file name + one-line contents summary).
7. **CI will verify** index alignment, the ratchet cap, and the word-count budget via the `rule-lint` check. A ratchet-cap breach fails the check — that is by design, and the fix is a cut or a justified raise, never a suppression.

## Adding a New Hook

Hooks live in `.claude/hooks/` and run automatically during Claude Code sessions.

1. **Create the script** at `.claude/hooks/<name>.sh` (bash) or `.claude/hooks/<name>.py` (Python). Make it executable: `chmod +x .claude/hooks/<name>.sh` (or `.py`).
2. **Implement the JSON contract** for the event type (`PreToolUse`, `PostToolUse`, `Stop`, etc.) — see existing hooks in `.claude/hooks/` for reference patterns.
3. **Register the hook** in `global-settings.json` under `hooks.{event}` using the `/path/to/claude-code-config` placeholder path.
4. **Auto-registration** handles the rest: the `session-start-sync.sh` hook resolves placeholders to the skills-worktree hooks directory and adds the entry to each user's `~/.claude/settings.json` on the next session start. Existing entries (including user-customized timeouts) are preserved.
5. **Test locally** by running the script directly with a sample JSON payload on stdin before pushing.

See [ARCHITECTURE.md](ARCHITECTURE.md) "Hook Lifecycle" and "Hook Auto-Registration" for details on event types and the registration flow.

## Adding a Test

Tests are **auto-discovered** by the [`hook-scripts.yml`](.github/workflows/hook-scripts.yml) CI workflow — you do **not** edit the workflow to register one (issue #681, which retired the hand-maintained per-test step list that made that file a merge-conflict hotspot).

- **Bash tests** — drop a `<name>.test.sh` into `.claude/scripts/tests/`, `.claude/hooks/tests/`, or `.github/scripts/tests/`. They are discovered and run by [`.github/scripts/run-hook-tests.sh`](.github/scripts/run-hook-tests.sh).
- **Python tests** — drop a `test_*.py` unittest module into `tests/`. It runs under **both** the default-Python job and the pinned-3.9 job, so keep it **Python 3.9-compatible** (e.g. `from __future__ import annotations` before any PEP 604 `X | Y` annotation; no `match`/`case`).

**Discovery contract** (a test must satisfy these to be picked up correctly): exit `0` on pass / non-zero on fail; be invoked via `bash` (the executable bit is **not** required — some suites are intentionally non-exec); and require **no** positional arguments.

**Shared test helpers** live in `.claude/scripts/tests/lib/` — outside the flat `*.test.sh` glob, so they are never run as suites. Notably [`lib/skill-bash.sh`](.claude/scripts/tests/lib/skill-bash.sh) extracts a fenced `bash` block out of a `SKILL.md` by an `<!-- test-anchor: <name> -->` comment, so a test can exercise the **real** skill-embedded bash instead of a copy that drifts (issue #888). Use it to bring any other skill block under regression coverage; `pmm-wake-step-4a.test.sh` is the worked example.

Run the whole suite locally from the repo root before pushing:

```bash
bash .github/scripts/run-hook-tests.sh        # all bash suites
bash .github/scripts/run-python-tests.sh      # all Python suites
```

**Runtime budget — one suite is slow on purpose (issue #1505).** Suites are otherwise
quick, but [`checkpoint-handoff.test.sh`](.claude/scripts/tests/checkpoint-handoff.test.sh)
builds a throwaway git repository per case: ~71s idle, ~156s with four copies running
concurrently, ~202s under concurrent subagents — and it climbs from there. It announces
this on its first line of output, because silence from it is fixture construction, not a
hang.

Neither the runner nor CI bounds any suite today. **If you add a bound — in a runner, a CI
job, or an ad-hoc invocation — keep it ≥420s for that suite.** A tighter bound does not
detect a hang, it manufactures one: a ~240s alarm on a loaded machine is what produced a
phantom hang report that parked real, already-correct work. The floor is enforced by
[`checkpoint-handoff-slow-bound.test.sh`](.claude/scripts/tests/checkpoint-handoff-slow-bound.test.sh).

**Compact mode (`--json`)** — both runners also emit the one-line result contract from
[`compact-result-contract.md`](.claude/reference/compact-result-contract.md) instead of every
suite's raw output, which is what CI uses and what an agent should read:

```bash
bash .github/scripts/run-hook-tests.sh --json
# {"ok":true,"failed_tests":[],"relevant_error":null,"log_path":"/tmp/run-hook-tests-...log","total":94,"failed":0}
```

A green run drops from thousands of lines to one; the full capture is always at `log_path`, and
**failing** suites still print in full (on stderr) in both modes. In CI both runners go through
[`summarize-test-run.sh`](.github/scripts/summarize-test-run.sh), which mirrors the contract into
the job's step summary and raises an `::error::` annotation on a red run.

## Adding a Script or Test to the `.claude/scripts/` Catalog

The catalog — [`.claude/scripts/README.md`](.claude/scripts/README.md) plus one doc per category under `.claude/scripts/docs/` — is **generated**, not hand-authored (issue #1578).

**To add a script or a test suite:** put one line in the new file's own header block and regenerate.

```bash
# in the new file, inside the leading comment block:
# catalog: <category-id> — <one-line description>

bash .github/scripts/scripts-catalog-gen.sh --write
```

`<category-id>` is the filename stem of the owning doc under `.claude/scripts/docs/` (`tests`, `utilities`, `release-cadence`, …). That is the whole change — you never edit a shared doc, which is what removed both the structural churn (issue #1571) and the recurring merge conflicts in `docs/tests.md` (PR #1543). A region two branches both regenerated is resolved by re-running the generator, not by reading a diff.

**To add a category:** add `docs/<id>.md` carrying an H1, `<!-- catalog:category id=<id> order=<N> -->`, `<!-- catalog:covers <one-line index summary> -->`, a `<!-- catalog:rows:begin -->` / `<!-- catalog:rows:end -->` pair (plus a second pair marked `<!-- catalog:rows:begin kind=py -->` if the category will hold Python helpers — a `.py` file whose doc has no `kind=py` region is reported as unplaced, never silently dropped), and the `[← back to the index](../README.md)` back-link — then regenerate. Adding a category is adding a file; there is no shared registry to edit. Regeneration also rewrites this doc's entry in `.claude/reference/churn-hotspot-exemptions.json` (a generated region is lint-enforced churn, so it is exempt from hotspot scoring by construction) — commit that file alongside the new category doc.

`.github/scripts/scripts-catalog-lint.sh` (auto-discovered, see below) fails CI when a file has no declaration, when a declaration names a category with no doc, when a committed region has drifted, or when a hand-written row appears outside a generated region. Rationale and the rejected alternatives: [`scripts-catalog-generation-decision.md`](.claude/reference/scripts-catalog-generation-decision.md).

## Adding a Doc Lint

Doc lints are **auto-discovered** by the [`rule-lint.yml`](.github/workflows/rule-lint.yml) CI workflow — you do **not** edit the workflow to register one (issue #1138, which retired the per-lint step list that made that file a merge-conflict hotspot; same pattern as issue #681 for tests).

**To add a standalone doc lint:**

1. Drop a `<name>-lint.sh` file into `.github/scripts/`. Name it to describe what it checks — `agents-frontmatter-lint.sh`, `skill-catalog-lint.sh`, etc.
2. It is **automatically** discovered and run by [`.github/scripts/run-doc-lints.sh`](.github/scripts/run-doc-lints.sh) next time the `rule-lint` CI job runs. No workflow edit needed.
3. Add a `<name>-lint.test.sh` in `.github/scripts/tests/` — the test suite is auto-discovered by `hook-scripts.yml` (see "Adding a Test" above). The test should cover both a clean pass and a representative failure.

**Discovery contract** (a lint must satisfy these): exit `0` on pass / non-zero on fail; be invoked via `bash` with no positional arguments; emit `::error::` GitHub Actions annotations on failures.

**Excluded from auto-discovery** (lints that have their own CI path):

| Script | Why excluded |
|---|---|
| `chip-model-guard-lint.sh` | Already invoked inside `rule-lint.sh` section 4; running it standalone would double-enforce the check. |
| `env-template-allowlist-lint.sh` | CI wiring is via `hook-scripts.yml` test auto-discovery — its test suite runs the lint. |
| `merge-authority-lint.sh` | Same — CI wiring via `hook-scripts.yml` tests. |

If your new lint should follow one of these patterns instead (e.g. it is best exercised from a test suite rather than as a direct CI step), add it to the exclusion list in `run-doc-lints.sh` `EXCLUDED_BASENAMES` with a comment naming the alternative CI path.

**Exception — `.claude/scripts/`:** `reference-catalog-lint.sh` lives in `.claude/scripts/` by history. It is included via an explicit extra path in the runner, not the glob. New lints should go in `.github/scripts/` unless there is a strong reason to place them elsewhere.

Run the full doc-lint suite locally:

```bash
bash .github/scripts/run-doc-lints.sh        # all doc lints (human mode)
bash .github/scripts/run-doc-lints.sh --json # compact contract
# Example (total reflects the current discovered lint set — grows as lints are added):
# {"ok":true,"failed_tests":[],"relevant_error":null,"log_path":"…","total":5,"failed":0}
```

## Git Pre-commit Hook (Worktree Enforcement)

`setup.sh` installs `.claude/git-hooks/pre-commit` into the shared git hooks directory on first run (and reuses it on later runs when unchanged). When this hook is installed and not bypassed, it rejects commits made on `main` in the root checkout, enforcing the "never work on main" rule at the git level for any committer — human, Claude, Cursor, Codex, or a random terminal session.

- **Blocks:** `git commit` while on `main` in the root checkout.
- **Allows:** any other branch, detached HEAD, and commits on `main` inside a worktree (rare but not this hook's concern).
- **Bypass:** `git commit --no-verify` still works for genuine emergencies — left functional on purpose.
- **User customization:** if `.git/hooks/pre-commit` already exists with different content, `setup.sh` warns and leaves your hook in place.

## Modifying CLAUDE.md

- CLAUDE.md is the **executive summary** — high-level non-negotiables and pointers to rule files. Target: **≤ 1,300 words** (relaxed from 1,000 after #443; keep it lean — detail belongs in rule files).
- **Detailed protocols, step-by-step procedures, and edge cases belong in `.claude/rules/*.md`**, not in CLAUDE.md.
- **Do not duplicate** content between CLAUDE.md and rule files. When the same topic appears in both, CLAUDE.md should link to the rule file as the authoritative source.
- Any change that touches CLAUDE.md must re-run the word-count verification command above.

## Deep-Dive Reference

For symlink topology, the skills worktree rationale, hook lifecycle, session lifecycle, multi-agent orchestration, the review loop fallback chain, and key design decisions, see [ARCHITECTURE.md](ARCHITECTURE.md).
