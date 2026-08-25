#!/usr/bin/env bash
# .github/scripts/lib/lint-common.sh — Shared helpers for .github/scripts lint tools.
#
# Source this file (do NOT execute it directly) from the sibling lint scripts.
#
# CONTRACT
#   Provides the shared error primitives used by sibling lint scripts, plus the
#   data-returning published_skills helper used by portability enforcement:
#
#   require_file FILE
#     Emits a GitHub Actions ::error:: annotation and increments $errors if FILE
#     does not exist. Returns 1 on failure, 0 on success.
#     Callers use either `|| true` (ignore return value) or `|| continue` (skip
#     the rest of the loop body when the file is missing). The explicit `return 0`
#     makes the success contract clear; bash's `if` command returns 0 when its
#     condition is false and no `else` branch runs, so the function already
#     returned 0 on the success path without it — `return 0` is retained for
#     explicitness, not because it changes behavior.
#
#   require_pattern FILE PATTERN LABEL
#     Emits a GitHub Actions ::error:: annotation and increments $errors if
#     PATTERN (extended regex) is not found in FILE.
#
#   published_skills [REPO_ROOT]
#     Prints the sorted names of every immediate directory under
#     REPO_ROOT/.claude/skills/. This mirrors setup-skills-worktree.sh, whose
#     directory glob is the authoritative publication source. Returns 1 when
#     the skills directory is absent or contains no skill directories.
#
# CALLER RESPONSIBILITY
#   Each sourcing script must declare `errors=0` before sourcing this file so
#   that require_file and require_pattern can increment it.
#
# EXCLUDED (per-script only — not shared)
#   usage() help text, argument-parsing loops, errors-counter finalize blocks,
#   and any helper unique to one script (require_literal, require_token,
#   forbid_token, extract_block, etc.).
#
# Introduced by Issue #1042 (chip-model-guard-lint.sh churn hotspot).

# require_file FILE
# Returns 0 if FILE exists, 1 if it does not (after recording an error).
require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "::error file=${f}::Required file not found"
    errors=$((errors + 1))
    return 1
  fi
  return 0
}

# require_pattern FILE PATTERN LABEL
# Records an error and increments $errors if PATTERN (ERE) is not found in FILE.
require_pattern() {
  local file="$1" pattern="$2" label="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo "::error file=${file}::Missing required ${label} (expected /${pattern}/)"
    errors=$((errors + 1))
  fi
}

# published_skills [REPO_ROOT]
# Returns data on stdout rather than recording lint errors; callers decide
# whether an empty publication set is a missing-surface error or fixture setup
# failure. REPO_ROOT defaults to the current directory.
published_skills() {
  local repo_root="${1:-.}" skills_dir dir
  local -a names=()
  skills_dir="${repo_root%/}/.claude/skills"

  [[ -d "$skills_dir" ]] || return 1
  for dir in "$skills_dir"/*/; do
    [[ -d "$dir" ]] || continue
    names+=("$(basename "${dir%/}")")
  done
  (( ${#names[@]} > 0 )) || return 1
  printf '%s\n' "${names[@]}" | LC_ALL=C sort
}
