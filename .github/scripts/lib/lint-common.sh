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
#   catalog_inscope_files [REPO_ROOT]
#     Prints the normalized repo-root-relative path of every file in the
#     .claude/scripts/ catalog's scope, LC_ALL=C sorted: top-level *.sh and
#     *.py plus tests/*.test.sh. Deliberately excludes lib/, tests/lib/,
#     tests/fixtures/ and non-script files. Returns 1 when the scope is empty
#     (a broken glob is never a silent pass). Shared so the catalog generator
#     and the catalog lint enumerate from one implementation (issue #1578).
#
#   catalog_meta FILE
#     Reads FILE's `# catalog: <id> — <description>` header line and prints
#     "<id><US><description>" (US = 0x1f). Returns 1 when the line is absent,
#     2 when it is present but malformed, and 3 when FILE could not be read at
#     all — three distinct answers, because folding an I/O error into either
#     of the other two reports a file that could not be examined as a file
#     that was examined and found wanting. Only the leading comment region is
#     read — everything from line 2 up to the first line that is neither
#     blank nor a `#` comment — so a `# catalog:` string in a script's body
#     or in a heredoc can never be mistaken for the declaration.
#
#     The separator is matched with sub(), not substr()/length(): an em dash
#     is three bytes in UTF-8 and one character, and awk implementations
#     disagree about which a byte-index sees. A regex is right in both.
#
#   catalog_row PATH DESCRIPTION
#     Prints one catalog table row — `| [name](target) | description |` —
#     for the in-scope file at repo-root-relative PATH. The target is
#     computed with normalize_relpath from .claude/scripts/docs/, so the row
#     a doc carries is the row this function spells. A '|' inside
#     DESCRIPTION is escaped, so a description can never split the table.
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

# --- .claude/scripts/ catalog helpers (issue #1578) -------------------------
# Shared by .github/scripts/scripts-catalog-gen.sh (which writes the catalog)
# and .github/scripts/scripts-catalog-lint.sh (which checks it). One
# implementation is the point: a second spelling of "in scope" or of "the row
# format" is exactly how a generator and its drift check start disagreeing.

CATALOG_SCRIPTS_DIR=".claude/scripts"
CATALOG_TESTS_DIR=".claude/scripts/tests"
CATALOG_DOCS_DIR=".claude/scripts/docs"

# catalog_inscope_files [REPO_ROOT]
# -maxdepth 1 on two named directories: bounded, and it never walks the rest of
# .claude/ (where untracked paths can stall a recursive find).
catalog_inscope_files() {
  local root="${1:-.}" found
  local scripts_dir tests_dir
  scripts_dir="${root%/}/$CATALOG_SCRIPTS_DIR"
  tests_dir="${root%/}/$CATALOG_TESTS_DIR"

  found=$(
    {
      if [[ -d "$scripts_dir" ]]; then
        find "$scripts_dir" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \)
      fi
      if [[ -d "$tests_dir" ]]; then
        find "$tests_dir" -maxdepth 1 -type f -name '*.test.sh'
      fi
    } | while IFS= read -r f; do
          # Re-key on the repo-root-relative path, never on what find printed:
          # REPO_ROOT may be absolute (a fixture tree), and every consumer
          # compares these against paths written in a doc.
          normalize_relpath "" "${f#"${root%/}/"}"
        done | LC_ALL=C sort
  )

  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

# catalog_meta FILE  ->  "<id><US><description>"
# 1 = no declaration, 2 = malformed declaration.
catalog_meta() {
  local file="$1" out rc
  [[ -r "$file" ]] || return 3
  out=$(awk '
    NR == 1 && /^#!/ { next }
    /^[[:space:]]*$/ { next }
    !/^[[:space:]]*#/ { exit }
    {
      line = $0
      if (!match(line, /^[[:space:]]*#[[:space:]]*catalog:[[:space:]]*/)) next
      line = substr(line, RSTART + RLENGTH)
      if (!match(line, /^[A-Za-z0-9][A-Za-z0-9_-]*/)) { print "MALFORMED"; exit }
      id = substr(line, RSTART, RLENGTH)
      rest = substr(line, RSTART + RLENGTH)
      # Accept an em dash or a plain hyphen as the separator; require one, so a
      # declaration that lost its description cannot read as a long id.
      if (sub(/^[[:space:]]*(—|-)[[:space:]]*/, "", rest) != 1) { print "MALFORMED"; exit }
      sub(/[[:space:]]+$/, "", rest)
      if (rest == "") { print "MALFORMED"; exit }
      printf "OK\037%s\037%s\n", id, rest
      exit
    }
  ' "$file")
  rc=$?
  (( rc == 0 )) || return 3
  case "$out" in
    OK*) printf '%s\n' "${out#OK$'\037'}" ;;
    MALFORMED) return 2 ;;
    *) return 1 ;;
  esac
}

# catalog_row PATH DESCRIPTION
catalog_row() {
  local path="$1" desc="$2" name target rel
  name="${path##*/}"
  rel="${path#"$CATALOG_SCRIPTS_DIR/"}"
  target=$(normalize_relpath ".." "$rel")
  # The link text is escaped for the same reason the description is: an
  # unescaped pipe splits the row, and the split regenerates identically.
  name="${name//|/\\|}"
  desc="${desc//|/\\|}"
  printf '| [%s](%s) | %s |\n' "$name" "$target" "$desc"
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
