#!/usr/bin/env bash
# Lint the .claude/scripts/ catalog against the directory contents (issue #898).
#
# The catalog is a thin index (.claude/scripts/README.md) plus one doc per
# category under .claude/scripts/docs/. Splitting it that way is what stops
# concurrent PRs from colliding in one shared file; this lint is what stops the
# split index from drifting out of sync with the scripts it describes.
#
# Validates:
#   1. Every script, Python helper, and test in scope has exactly one row
#      across the category docs — no missing rows, no duplicates, no rows
#      naming a file that is not in scope.
#   2. Every table row is a relative link that resolves to an existing file,
#      the link text names the same file the link points at, and the target is
#      that file at its in-scope location — not a same-named file elsewhere.
#   3. The index links every doc in docs/ exactly once, and every doc it links
#      exists.
#   4. Every category doc carries the back-link to the index, outside any
#      fenced code block — a link shown as an example is not navigation.
#   5. The index itself holds no per-script rows — its table links only into
#      docs/, so per-script rows have exactly one home.
#
# In scope: .claude/scripts/*.sh, .claude/scripts/*.py (top level only) and
# .claude/scripts/tests/*.test.sh. Deliberately OUT of scope: lib/ (sourced
# helper libraries and jq programs, not invocable scripts), tests/lib/,
# tests/fixtures/, and non-script files such as the launchd .plist.
#
# Companion to skill-catalog-lint.sh and reference-catalog-lint.sh, which
# enforce the same index-alignment invariant for .claude/skills/ and
# .claude/reference/. Paths are repo-root-relative, so run it from the repo
# root. Picked up automatically by run-doc-lints.sh's *-lint.sh glob.
#
# Output uses GitHub Actions annotations (::error::) so issues surface
# directly on PR checks. Exits 1 on any error condition.

set -euo pipefail
shopt -s nullglob

INDEX=".claude/scripts/README.md"
SCRIPTS_DIR=".claude/scripts"
TESTS_DIR=".claude/scripts/tests"
DOCS_DIR=".claude/scripts/docs"

errors=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/scripts-catalog-lint.sh

  Verifies .claude/scripts/README.md and .claude/scripts/docs/ stay in sync
  with the scripts and tests on disk.
  No options. Run from the repo root. Exits 1 on any error.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "::error::Unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ ! -f "$INDEX" ]]; then
  echo "::error file=${INDEX}::index not found"
  exit 1
fi

if [[ ! -d "$DOCS_DIR" ]]; then
  echo "::error::${DOCS_DIR} directory not found"
  exit 1
fi

# Shared awk prelude for reading a catalog document. Provides trim() and drops
# every line inside a fenced code block: a table row or a back-link shown inside
# a fence documents the format, so neither may count as catalog content.
AWK_DOC_PRELUDE='
  function trim(s) {
    gsub(/^[[:space:]]+/, "", s)
    gsub(/[[:space:]]+$/, "", s)
    return s
  }
  /^[[:space:]]*(```|~~~)/ {
    marker = ($0 ~ /^[[:space:]]*```/) ? "```" : "~~~"
    if (!in_fence) { in_fence = 1; fence = marker }
    else if (marker == fence) { in_fence = 0; fence = "" }
    next
  }
  in_fence { next }
'

# Emit "name<US>target" for every catalog table row in the given file.
# A catalog row looks like:  | [pr-state.sh](../pr-state.sh) | Purpose |
# The unit separator keeps the two fields apart without colliding with the
# markdown pipe that delimits the table itself.
#
# Cell padding is matched as any run of spaces or tabs, not a single literal
# space. Markdown treats the two the same, so a table realigned by a formatter
# (or by hand) still parses; requiring exact spacing would drop every reflowed
# row out of the inventory and report each one as missing.
entry_rows() {
  awk "$AWK_DOC_PRELUDE"'
    /^[[:space:]]*\|[[:space:]]*\[[^]]+\]\([^)]+\)[[:space:]]*\|/ {
      s = index($0, "[") + 1
      e = index($0, "]")
      name = trim(substr($0, s, e - s))
      rest = substr($0, e + 1)
      s2 = index(rest, "(") + 1
      e2 = index(rest, ")")
      target = trim(substr(rest, s2, e2 - s2))
      printf "%s\037%s\n", name, target
    }
  ' "$1"
}

# True when the doc carries a real back-link — one outside any code fence.
has_backlink() {
  awk "$AWK_DOC_PRELUDE"'
    index($0, "](../README.md)") > 0 { found = 1 }
    END { if (found) exit 0; exit 1 }
  ' "$1"
}

# --- inventory ------------------------------------------------------------
# -maxdepth 1 on two named directories: bounded, and it never walks the rest
# of .claude/ (where untracked paths can stall a recursive find).
inscope=$(find "$SCRIPTS_DIR" -maxdepth 1 -type f \
            \( -name '*.sh' -o -name '*.py' \) -exec basename {} \; \
          | LC_ALL=C sort)

if [[ -d "$TESTS_DIR" ]]; then
  test_files=$(find "$TESTS_DIR" -maxdepth 1 -type f -name '*.test.sh' \
                 -exec basename {} \; | LC_ALL=C sort)
  inscope=$(printf '%s\n%s\n' "$inscope" "$test_files" | grep . | LC_ALL=C sort)
fi

inscope_count=$(printf '%s\n' "$inscope" | grep -c . || true)
if (( inscope_count == 0 )); then
  echo "::error::No scripts found under ${SCRIPTS_DIR}/ — the inventory glob is broken"
  exit 1
fi

# --- collect every catalog row across the category docs -------------------
doc_files=("$DOCS_DIR"/*.md)
if (( ${#doc_files[@]} == 0 )); then
  echo "::error::${DOCS_DIR}/ contains no category docs — the catalog is empty"
  exit 1
fi

all_rows=""
for doc in "${doc_files[@]}"; do
  rows=$(entry_rows "$doc" || true)
  [[ -z "$rows" ]] && continue
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    all_rows="${all_rows}${doc}"$'\037'"${row}"$'\n'
  done <<< "$rows"
done

documented_all=$(printf '%s' "$all_rows" | awk -F'\037' 'NF { print $2 }' | LC_ALL=C sort)
documented=$(printf '%s\n' "$documented_all" | grep . | LC_ALL=C sort -u || true)

if [[ -z "$documented" ]]; then
  echo "::error::No catalog rows found in ${DOCS_DIR}/ — the row pattern is broken"
  exit 1
fi

# --- 1. Coverage: exactly one row per in-scope file -----------------------
undocumented=$(comm -23 <(printf '%s\n' "$inscope") <(printf '%s\n' "$documented") || true)
phantom=$(comm -13 <(printf '%s\n' "$inscope") <(printf '%s\n' "$documented") || true)

if [[ -n "$undocumented" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "::error file=${INDEX}::'${f}' exists in ${SCRIPTS_DIR}/ but has no row in any ${DOCS_DIR}/ category doc"
    errors=$((errors + 1))
  done <<< "$undocumented"
fi

if [[ -n "$phantom" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "::error::${DOCS_DIR}/ documents '${f}' but no such script or test is in scope under ${SCRIPTS_DIR}/"
    errors=$((errors + 1))
  done <<< "$phantom"
fi

row_count=$(printf '%s\n' "$documented_all" | grep -c . || true)
unique_count=$(printf '%s\n' "$documented" | grep -c . || true)
if (( row_count != unique_count )); then
  printf '%s\n' "$documented_all" | uniq -d | while IFS= read -r dupe; do
    [[ -z "$dupe" ]] && continue
    echo "::error::'${dupe}' has more than one row across ${DOCS_DIR}/ — each script belongs to exactly one category"
  done
  errors=$((errors + row_count - unique_count))
fi

# --- 2. Every row is a link that resolves, to the file it names -----------
while IFS=$'\037' read -r doc name target; do
  [[ -z "${doc:-}" ]] && continue
  if [[ ! -f "${DOCS_DIR}/${target}" ]]; then
    echo "::error file=${doc}::link target '${target}' for '${name}' does not resolve to a file"
    errors=$((errors + 1))
    continue
  fi
  if [[ "$(basename "$target")" != "$name" ]]; then
    echo "::error file=${doc}::row '${name}' links to '${target}' — the link text and the link target name different files"
    errors=$((errors + 1))
    continue
  fi
  # Naming an in-scope file is not enough: the link has to point at that file
  # where the inventory found it. Otherwise a row reading
  # [foo.sh](../lib/foo.sh) passes on the strength of a top-level foo.sh while
  # sending the reader to an out-of-scope helper.
  if [[ "$target" != "../${name}" && "$target" != "../tests/${name}" ]]; then
    echo "::error file=${doc}::row '${name}' links to '${target}' — an in-scope entry must link to ../${name} or ../tests/${name}"
    errors=$((errors + 1))
  fi
done <<< "$all_rows"

# --- 3. Index <-> docs bijection ------------------------------------------
index_rows=$(entry_rows "$INDEX" || true)
docs_linked_all=$(printf '%s\n' "$index_rows" \
  | awk -F'\037' 'NF > 1 && $2 ~ /^docs\// { sub(/^docs\//, "", $2); print $2 }' \
  | LC_ALL=C sort)
docs_linked=$(printf '%s\n' "$docs_linked_all" | grep . | LC_ALL=C sort -u || true)

docs_present=$(printf '%s\n' "${doc_files[@]}" | xargs -n1 basename | LC_ALL=C sort -u)

# A doc linked twice survives the sort -u below, so the set comparison alone
# would call a duplicated category row a bijection. Count before dedup.
linked_count=$(printf '%s\n' "$docs_linked_all" | grep -c . || true)
linked_unique=$(printf '%s\n' "$docs_linked" | grep -c . || true)
if (( linked_count != linked_unique )); then
  printf '%s\n' "$docs_linked_all" | uniq -d | while IFS= read -r dupe; do
    [[ -z "$dupe" ]] && continue
    echo "::error file=${INDEX}::the index links docs/${dupe} more than once — each category doc gets exactly one index row"
  done
  errors=$((errors + linked_count - linked_unique))
fi

if [[ -z "$docs_linked" ]]; then
  echo "::error file=${INDEX}::the index links no category docs — the categories table is missing or malformed"
  errors=$((errors + 1))
else
  unlisted=$(comm -23 <(printf '%s\n' "$docs_present") <(printf '%s\n' "$docs_linked") || true)
  dangling=$(comm -13 <(printf '%s\n' "$docs_present") <(printf '%s\n' "$docs_linked") || true)

  if [[ -n "$unlisted" ]]; then
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      echo "::error file=${INDEX}::${DOCS_DIR}/${d} exists but the index does not link it"
      errors=$((errors + 1))
    done <<< "$unlisted"
  fi

  if [[ -n "$dangling" ]]; then
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      echo "::error file=${INDEX}::the index links docs/${d} but no such file exists"
      errors=$((errors + 1))
    done <<< "$dangling"
  fi
fi

# --- 4. Every category doc links back to the index ------------------------
for doc in "${doc_files[@]}"; do
  if ! has_backlink "$doc"; then
    echo "::error file=${doc}::missing the back-link to the index (expected a link to ../README.md)"
    errors=$((errors + 1))
  fi
done

# --- 5. The index holds no per-script rows --------------------------------
# Every row in the index must link into docs/. A row pointing at ../foo.sh (or
# anywhere else) means a per-script entry crept back into the shared file,
# which is exactly the collision this split removed.
while IFS=$'\037' read -r name target; do
  [[ -z "${name:-}" ]] && continue
  case "$target" in
    docs/*) ;;
    *)
      echo "::error file=${INDEX}::row '${name}' links to '${target}' — the index table may only link into ${DOCS_DIR}/; per-script rows belong in a category doc"
      errors=$((errors + 1))
      ;;
  esac
done <<< "$index_rows"

if (( errors > 0 )); then
  echo "scripts-catalog-lint: ${errors} error(s) found"
  exit 1
fi

doc_count=${#doc_files[@]}
echo "scripts-catalog-lint: OK (${unique_count} entries across ${doc_count} category docs)"
