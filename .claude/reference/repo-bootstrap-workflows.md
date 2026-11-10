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

## Per-file add-only guarantee

`--apply` installs each missing file with an atomic `mkdir -p` → `mktemp` write → `ln` publish sequence. `ln` fails if the destination already exists, so a concurrent writer races harmlessly: the script treats a lost race as "already present" rather than overwriting. Each file's `[INSTALLED]` state is set only after its `ln` succeeds.

## Exit-code behavior across the set

A write failure on any file (failed `mkdir -p`, `mktemp`, content write, or `ln`) exits `5` immediately, before the report is printed. This ensures a mid-set failure cannot make any other file or the overall run appear clean.

The aggregate exit follows the documented contract: `0` (all clean), `1` (gaps remaining — either a missing file in `--check`, or branch protection in both modes), `5` (write failure in `--apply`).
