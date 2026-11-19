# repo-bootstrap.sh — File-Set Mechanism

> **Scope:** provisioned-file design only. Branch-protection mechanism: `repo-bootstrap-protection.md`.

## The one-list guarantee

`BOOTSTRAP_FILES` in `.claude/scripts/repo-bootstrap.sh` is the single source of truth for what the script provisions. Every code path — check, apply, and report — iterates that one array. There is no second enumeration anywhere. To add a file to the set, add one entry to `BOOTSTRAP_FILES` and one heredoc arm to `get_file_content()`.

## Format

Each entry in `BOOTSTRAP_FILES` is `"relative-path|file-mode"` (e.g. `".claude/scripts/pr-issue-ref.sh|755"`). The mode is applied by `chmod` before the file is published, so the canonical mode is preserved even though `mktemp` creates files at mode 600.

## Current file set

| Path | Mode | Purpose |
|------|------|---------|
| `.github/workflows/cr-plan-on-issue.yml` | 644 | Posts `@coderabbitai plan` when an issue is opened |
| `.github/workflows/ac-gate.yml` | 644 | CI gate that rejects PRs with unchecked AC boxes |
| `.claude/scripts/ac-gate.sh` | 644 | Logic for the AC gate (called by the workflow) |
| `.claude/scripts/pr-issue-ref.sh` | 755 | Extracts linked issue numbers from PR bodies; must be executable because callers test `[[ -x ]]` |
| `.github/workflows/pr-claim-check.yml` | 644 | Non-required PR claim check (issue #2288); passes with a notice only while the checker or `issue-claim.sh` is not yet on the base branch — including the PR that installs them, because the workflow checks out the base SHA |
| `.claude/scripts/pr-claim-check.sh` | 644 | Compares a PR's `claim-holder` line with each linked issue's winning claim (called by the workflow with `--report`; reads claims with `issue-claim.sh --check --no-viewer`) |
| `.claude/scripts/issue-claim.sh` | 755 | The claim helper the checker reads (issue #2412); without it the check never compares ownership. Executable because the `AGENTS.md` claim block calls it directly |
| `.claude/scripts/pr-claim-line.sh` | 755 | Prints the PR body's `claim-holder` line, as the `AGENTS.md` claim block documents (issue #2412). Optional `session-state.sh` absent → it falls through to the given holder |

Not provisioned: `session-state.sh` and `issue-claim-batch.sh`. Both are optional — `pr-claim-line.sh` works without session state, and the claim block falls back to one-issue claims when the batch helper is absent.

### Upgrading a repo that already has the claim check

`--apply` is add-only, so a repo bootstrapped before issue #2412 gets the two new helpers but keeps its older `pr-claim-check.sh` and workflow. That older checker does not pass `--no-viewer`, so under the Actions token its helper call still fails the viewer lookup and CI keeps reporting `unverifiable` (a warning, exit 0). Replace both template files by hand with the current ones to fix it — and `issue-claim.sh` too if the repo already had one older than `--no-viewer`, since `--apply` keeps it and the new checker's flag would be rejected (still `unverifiable`). The PR carrying those replacements still runs the old base-SHA checker, so merge it first, then confirm on a later PR — one whose base holds the updated files — that links an issue with a known live claim. A green run alone is not evidence that ownership was compared: inspect the verdict in the run log for `match` or `foreign`.

## Per-file add-only guarantee

`--apply` installs each missing file with an atomic `mkdir -p` → `mktemp` write → `ln` publish sequence. `ln` fails if the destination already exists, so a concurrent writer races harmlessly: the script treats a lost race as "already present" rather than overwriting. Each file's `[INSTALLED]` state is set only after its `ln` succeeds.

## Exit-code behavior across the set

A write failure on any file (failed `mkdir -p`, `mktemp`, content write, or `ln`) exits `5` immediately, before the report is printed. This ensures a mid-set failure cannot make any other file or the overall run appear clean.

The aggregate exit follows the documented contract: `0` (all clean), `1` (gaps remaining — either a missing file in `--check`, or branch protection in both modes), `5` (write failure in `--apply`).

## AGENTS.md claim block (issue #2285)

Not in `BOOTSTRAP_FILES` (that list is whole-file, add-only). `AGENTS.md` is usually a file the repo already owns, so the script manages only a marked block in it: `<!-- BEGIN agent-issue-claims ... -->` to `<!-- END agent-issue-claims -->`. The single source of the text is `.claude/reference/agent-issue-claims-block.md`, found next to the script, else under `~/.claude`.

- Absent file: `--apply` creates it with the block. Existing file without the block: the block is appended; every existing byte stays the file's prefix. Drifted block: only the lines between the markers are rewritten. Identical block: no write.
- Unbalanced markers or a symlinked `AGENTS.md`: reported, never edited (a gap, exit 1).
- `--check` reports `[MISSING]` when the block is absent or differs from the source.

Which file each tool reads (checked 2026-11, vendor documentation): Codex reads `AGENTS.md` from the repo root down to the working directory (<https://learn.chatgpt.com/docs/agent-configuration/agents-md>, formerly developers.openai.com/codex/guides/agents-md); Cursor reads `AGENTS.md` in the project root and subdirectories (<https://cursor.com/docs/context/rules>); Antigravity reads `AGENTS.md` or `GEMINI.md` in the workspace folder and parents up to the repo root (<https://antigravity.google/docs/rules>). All three read `AGENTS.md`, so no per-tool pointer file is installed. Claude Code reads `CLAUDE.md`, which this repo already carries.
