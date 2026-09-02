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
#   normalize_relpath BASE TARGET
#     Joins BASE and TARGET and prints the result with '.' and '..' segments
#     collapsed, so two spellings of one location compare equal. Purely
#     LEXICAL: it never touches the filesystem, so it does not resolve
#     symlinks and does not care whether the path exists. Callers that need
#     existence must test it themselves.
#
#     TARGET wins when absolute; BASE is ignored for an empty or "." base.
#     A relative result keeps leading '..' segments that escape BASE
#     ('..' cannot be cancelled by a parent that is not in the string); an
#     absolute result drops them, matching '/..' == '/'. A path that collapses
#     to nothing prints '.'.
#
#     Deliberately not `realpath --relative-to`: that flag is GNU-only and the
#     macOS runners have no equivalent.
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

# normalize_relpath BASE TARGET
# Lexical only — see the CONTRACT header. Splits with parameter expansion
# rather than an unquoted IFS='/' expansion: the latter would glob a segment
# containing '*' against the cwd. The stack is indexed by an explicit counter
# because bash 3.2 (the macOS system bash) leaves a hole behind `unset arr[i]`,
# which would shift every later index.
normalize_relpath() {
  local base="${1-}" target="${2-}"
  local joined rest seg out=""
  local absolute=0 n=0 i
  local -a stack=()

  if [[ "$target" == /* ]]; then
    joined="$target"
  elif [[ -z "$base" || "$base" == "." ]]; then
    joined="$target"
  else
    joined="${base%/}/${target}"
  fi

  if [[ "$joined" == /* ]]; then
    absolute=1
  fi

  rest="$joined"
  while [[ -n "$rest" ]]; do
    seg="${rest%%/*}"
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
    case "$seg" in
      '' | '.')
        # An empty segment is a repeated or trailing slash, not a directory.
        ;;
      '..')
        if (( n > 0 )) && [[ "${stack[n-1]}" != ".." ]]; then
          n=$((n - 1))
        elif (( absolute )); then
          : # '/..' is '/' — a parent of the root does not exist.
        else
          stack[n]=".."
          n=$((n + 1))
        fi
        ;;
      *)
        stack[n]="$seg"
        n=$((n + 1))
        ;;
    esac
  done

  for (( i = 0; i < n; i++ )); do
    if [[ -z "$out" ]]; then
      out="${stack[i]}"
    else
      out="${out}/${stack[i]}"
    fi
  done

  if (( absolute )); then
    printf '%s\n' "/${out}"
  elif [[ -z "$out" ]]; then
    printf '%s\n' "."
  else
    printf '%s\n' "$out"
  fi
}
