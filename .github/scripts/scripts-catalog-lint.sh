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
#   6. A category doc that opts in by carrying the marker
#      <!-- catalog-lint: ordered --> lists its rows in LC_ALL=C sort order.
#      Opt-in, not repo-wide: the other category docs group rows by workflow
#      role on purpose — pr-state-polling.md leads with pr-state.sh before its
#      helpers, utilities.md keeps the portable-handoff-* family together — so
#      a blanket ordering rule would be wrong against them, and a one-doc rule
#      hard-coded here would make a convention official for one doc of
#      thirteen. The marker lets a doc whose order is genuinely alphabetical
#      say so and have it enforced, and leaves every other doc untouched
#      (issue #1544).
#
# In scope: .claude/scripts/*.sh, .claude/scripts/*.py (top level only) and
# .claude/scripts/tests/*.test.sh. Deliberately OUT of scope: lib/ (sourced
# helper libraries and jq programs, not invocable scripts), tests/lib/,
# tests/fixtures/, and non-script files such as the launchd .plist.
#
# Entry identity is a normalized repo-root-relative path, never a basename
# (issue #1452). Both in-scope globs can produce the same basename — a
# top-level foo.test.sh and tests/foo.test.sh — and under basename keying that
# pair collapsed into one entry: a correctly documented pair was rejected as a
# duplicate *and* as missing, while a genuinely missing row named a bare
# filename that did not say which of the two files it meant. The coverage set
# is therefore built from each row's link target, resolved against docs/, and
# the index<->docs bijection is keyed the same way.
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

# Sourced after errors=0, per lint-common.sh's caller contract. Provides
# normalize_relpath, which is what lets every set below be keyed on a
# normalized repo-root-relative path instead of a bare filename (issue #1452).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lint-common.sh
source "$SCRIPT_DIR/lib/lint-common.sh"

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

# The row-ordering opt-in marker (check 6). Defined once and read by the
# detector, the error message, and the docs that carry it, so the string the
# lint looks for and the string it tells you to write cannot drift apart.
ORDER_MARKER='<!-- catalog-lint: ordered -->'

# True when the doc opts in to row ordering — marker present outside any code
# fence. Same fence skip as the back-link, for the same reason: a marker shown
# inside a fenced block documents the format, and must not quietly opt that doc
# in. Position is not constrained beyond that; a marker anywhere in the doc
# counts, so a marker written below the table opts the doc in rather than
# silently doing nothing.
has_order_marker() {
  awk -v marker="$ORDER_MARKER" "$AWK_DOC_PRELUDE"'
    index($0, marker) > 0 { found = 1 }
    END { if (found) exit 0; exit 1 }
  ' "$1"
}

# Emit "previous<US>offending" for every adjacent pair of rows that is out of
# LC_ALL=C order. A list is sorted exactly when no adjacent pair is inverted,
# so checking pairs is the same test as comparing the list against its sort —
# and it names the row that has to move instead of printing a diff.
#
# The key is the link *text*: the filename a reader scans down the table, so
# the lint enforces the order the eye checks. That is deliberately not the
# path key checks 1 and 3 use — two rows whose link text is identical (the
# top-level/tests/ namesake pair of issue #1452) compare equal here and may
# appear in either order, because nothing visible in the rendered doc tells a
# reader which is which.
#
# The awk deliberately does not exit early. Under `set -o pipefail` an early
# exit closes the pipe, entry_rows takes SIGPIPE, and a clean read of a doc
# reports as a failed pipeline.
row_order_violations() {
  entry_rows "$1" | LC_ALL=C awk -F$'\037' '
    $1 == "" { next }
    prev != "" && $1 < prev { printf "%s\037%s\n", prev, $1 }
    { prev = $1 }
  '
}

# --- inventory ------------------------------------------------------------
# -maxdepth 1 on two named directories: bounded, and it never walks the rest
# of .claude/ (where untracked paths can stall a recursive find).
#
# find prints "$SCRIPTS_DIR/name" verbatim, and both directory variables are
# already repo-root-relative and free of . and .. segments, so the paths are
# normalized as they stand. They still go through normalize_relpath so the
# inventory is keyed by the exact same function as the documented set — a
# second spelling of "normalized" here is how the two sides drift apart.
inscope=$(find "$SCRIPTS_DIR" -maxdepth 1 -type f \
            \( -name '*.sh' -o -name '*.py' \) \
          | while IFS= read -r f; do normalize_relpath "" "$f"; done \
          | LC_ALL=C sort)

if [[ -d "$TESTS_DIR" ]]; then
  test_files=$(find "$TESTS_DIR" -maxdepth 1 -type f -name '*.test.sh' \
               | while IFS= read -r f; do normalize_relpath "" "$f"; done \
               | LC_ALL=C sort)
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

# The coverage set is built from each row's link *target*, resolved against
# docs/, not from the link text. The text is a bare filename by contract, so it
# cannot distinguish a top-level foo.test.sh from tests/foo.test.sh; the target
# can, and check 2 below independently holds the target to ../<name> or
# ../tests/<name>. A row whose target is bogus therefore lands in this set as a
# path that does not exist, and is reported as a phantom entry as well as a
# broken link — two symptoms of the one defect, not a double count of it.
documented_all=$(printf '%s' "$all_rows" \
  | while IFS=$'\037' read -r doc name target; do
      if [[ -n "${target:-}" ]]; then
        normalize_relpath "$DOCS_DIR" "$target"
      fi
    done \
  | LC_ALL=C sort)
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
    echo "::error file=${INDEX}::'${f}' exists but has no row in any ${DOCS_DIR}/ category doc"
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
# Both sides of this bijection are repo-root-relative doc paths, the same form
# the coverage sets use. Membership is decided on the *normalized* target
# rather than a literal "docs/" prefix on the raw text: a row written
# docs/../foo.sh starts with the prefix but does not point into docs/, and
# under the textual test it entered this set as "../foo.sh" — a key matching
# nothing on either side.
index_rows=$(entry_rows "$INDEX" || true)
docs_linked_all=$(printf '%s\n' "$index_rows" \
  | while IFS=$'\037' read -r name target; do
      if [[ -n "${target:-}" ]]; then
        resolved=$(normalize_relpath "$SCRIPTS_DIR" "$target")
        case "$resolved" in
          "${DOCS_DIR}/"*) printf '%s\n' "$resolved" ;;
        esac
      fi
    done \
  | LC_ALL=C sort)
docs_linked=$(printf '%s\n' "$docs_linked_all" | grep . | LC_ALL=C sort -u || true)

docs_present=$(printf '%s\n' "${doc_files[@]}" \
  | while IFS= read -r d; do normalize_relpath "" "$d"; done \
  | LC_ALL=C sort -u)

# A doc linked twice survives the sort -u below, so the set comparison alone
# would call a duplicated category row a bijection. Count before dedup.
linked_count=$(printf '%s\n' "$docs_linked_all" | grep -c . || true)
linked_unique=$(printf '%s\n' "$docs_linked" | grep -c . || true)
if (( linked_count != linked_unique )); then
  printf '%s\n' "$docs_linked_all" | uniq -d | while IFS= read -r dupe; do
    [[ -z "$dupe" ]] && continue
    echo "::error file=${INDEX}::the index links ${dupe} more than once — each category doc gets exactly one index row"
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
      echo "::error file=${INDEX}::${d} exists but the index does not link it"
      errors=$((errors + 1))
    done <<< "$unlisted"
  fi

  if [[ -n "$dangling" ]]; then
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      echo "::error file=${INDEX}::the index links ${d} but no such file exists"
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
#
# Membership is tested on the normalized target, matching check 3. A literal
# "docs/" prefix on the raw text is not the same question: docs/../foo.sh
# carries the prefix while pointing outside docs/, and would satisfy a textual
# test while check 3 correctly declined to count it as a docs link — leaving
# the row unclaimed by either check.
while IFS=$'\037' read -r name target; do
  [[ -z "${name:-}" ]] && continue
  case "$(normalize_relpath "$SCRIPTS_DIR" "$target")" in
    "${DOCS_DIR}/"*) ;;
    *)
      echo "::error file=${INDEX}::row '${name}' links to '${target}' — the index table may only link into ${DOCS_DIR}/; per-script rows belong in a category doc"
      errors=$((errors + 1))
      ;;
  esac
done <<< "$index_rows"

# --- 6. Row ordering, per-doc opt-in (issue #1544) ------------------------
# Only docs carrying ORDER_MARKER are examined; every other doc passes this
# check without being read for order at all. That is the whole point of the
# marker — see the header block for why a repo-wide rule would be wrong here.
for doc in "${doc_files[@]}"; do
  has_order_marker "$doc" || continue
  violations=$(row_order_violations "$doc" || true)
  [[ -z "$violations" ]] && continue
  while IFS=$'\037' read -r previous offending; do
    [[ -z "${offending:-}" ]] && continue
    echo "::error file=${doc}::row '${offending}' is out of order — it follows '${previous}', and this doc carries ${ORDER_MARKER}, so its rows must be in LC_ALL=C sort order"
    errors=$((errors + 1))
  done <<< "$violations"
done

if (( errors > 0 )); then
  echo "scripts-catalog-lint: ${errors} error(s) found"
  exit 1
fi

doc_count=${#doc_files[@]}
echo "scripts-catalog-lint: OK (${unique_count} entries across ${doc_count} category docs)"
