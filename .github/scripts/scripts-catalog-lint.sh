#!/usr/bin/env bash
# Lint the .claude/scripts/ catalog against the directory contents (issues #898, #1578).
#
# The catalog is a thin index (.claude/scripts/README.md) plus one doc per
# category under .claude/scripts/docs/. Splitting it that way (issue #898) is
# what stops concurrent PRs from colliding in one shared file; this lint is
# what stops the split index from drifting out of sync with the scripts it
# describes.
#
# WHAT CHANGED IN #1578
#
# This lint used to validate HAND-WRITTEN rows: coverage, uniqueness, link
# integrity, index purity, per-doc row ordering. Every one of those checks
# demanded a human edit to a shared markdown file each time a script was added
# or renamed — churn no refactor could retire (issue #1571) and a recurring
# merge-conflict surface (PR #1543). The rows are now GENERATED from each
# file's own `# catalog: <category-id> — <description>` header line by
# .github/scripts/scripts-catalog-gen.sh, so those five properties hold by
# construction rather than by validation, and this lint no longer re-checks
# them. Decision record: .claude/reference/scripts-catalog-generation-decision.md.
#
# Validates:
#   1. Every category doc carries the back-link to the index, outside any
#      fenced code block — a link shown as an example is not navigation.
#   2. No catalog table row sits OUTSIDE a generated region. Generation only
#      rewrites what lies between the markers, so a hand-written row added
#      below one would otherwise survive every regeneration: it would never
#      appear in the generated block, never be checked for coverage, and
#      never be noticed. This is the one row-shaped property generation does
#      not make structural, which is exactly why it is checked here.
#   3. Everything else — that every in-scope file declares a description and a
#      resolvable category id, that every doc declares its own category, that
#      the generated rows, the index Categories table, and the catalog entries
#      in .claude/reference/churn-hotspot-exemptions.json match the directory
#      contents — is delegated to `scripts-catalog-gen.sh --check`. Delegating
#      rather than reimplementing is deliberate: a second spelling of "in
#      scope" or of "the row format" here is how a generator and its drift
#      check start disagreeing (shared helpers live in lib/lint-common.sh).
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

errors=0

# Sourced after errors=0, per lint-common.sh's caller contract, and before
# DOCS_DIR is set: the docs directory is taken from the shared constant rather
# than respelled here, so this lint and the generator cannot end up checking
# two different directories.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lint-common.sh
source "$SCRIPT_DIR/lib/lint-common.sh"

DOCS_DIR="$CATALOG_DOCS_DIR"

GEN="$SCRIPT_DIR/scripts-catalog-gen.sh"

usage() {
  cat <<'EOF'
Usage: .github/scripts/scripts-catalog-lint.sh

  Verifies .claude/scripts/README.md and .claude/scripts/docs/ stay in sync
  with the scripts and tests on disk. Row content is generated, so this checks
  the two properties generation cannot make structural — the per-doc back-link
  and the absence of hand-written rows outside a generated region — and
  delegates the rest to scripts-catalog-gen.sh --check.
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

if [[ ! -f "$GEN" ]]; then
  echo "::error::${GEN} not found — the catalog generator is what this lint checks against"
  exit 1
fi

# Shared awk prelude for reading a catalog document. Provides trim() and drops
# every line inside a fenced code block: a table row or a back-link shown inside
# a fence documents the format, so neither may count as catalog content.
#
# Every variable the prelude sets is named fence_* on purpose. The prelude runs
# in the same awk namespace as the program appended to it and as any -v the
# caller passes, so a plainly-named scratch variable here silently overwrites
# the caller's. That is not hypothetical: `fence_tok` was once `marker`, which
# clobbered a caller's -v marker on the first fence line and made the detector
# wrong in both directions. Keep new scratch names prefixed.
AWK_DOC_PRELUDE='
  function trim(s) {
    gsub(/^[[:space:]]+/, "", s)
    gsub(/[[:space:]]+$/, "", s)
    return s
  }
  /^[[:space:]]*(```|~~~)/ {
    fence_tok = ($0 ~ /^[[:space:]]*```/) ? "```" : "~~~"
    if (!in_fence) { in_fence = 1; fence = fence_tok }
    else if (fence_tok == fence) { in_fence = 0; fence = "" }
    next
  }
  in_fence { next }
'

# True when the doc carries a real back-link — one outside any code fence.
has_backlink() {
  awk "$AWK_DOC_PRELUDE"'
    index($0, "](../README.md)") > 0 { found = 1 }
    END { if (found) exit 0; exit 1 }
  ' "$1"
}

# Print the line number and text of every catalog table row that lies outside a
# generated region. Region state is tracked here rather than in the generator so
# the diagnostic can name the line; both begin-marker spellings are matched
# (rows and categories), because the index carries the categories region and the
# category docs carry the rows regions.
#
# The awk deliberately does not exit early. Under `set -o pipefail` an early
# exit closes the pipe and a clean read of a doc reports as a failed pipeline.
rows_outside_region() {
  awk "$AWK_DOC_PRELUDE"'
    /<!--[[:space:]]*catalog:(rows|categories):begin/ { inside = 1; next }
    /<!--[[:space:]]*catalog:(rows|categories):end/   { inside = 0; next }
    inside { next }
    /^[[:space:]]*\|[[:space:]]*\[[^]]+\]\([^)]+\)[[:space:]]*\|/ {
      s = index($0, "[") + 1
      e = index($0, "]")
      name = trim(substr($0, s, e - s))
      # Only a row whose link TEXT is a bare script or test filename is a
      # catalog row. That is exactly the shape the generator emits, and
      # narrowing to it keeps a category doc free to carry an ordinary link
      # table — a "Mechanism: [foo.md](../../reference/foo.md)" row is
      # documentation, not a smuggled catalog entry, and must not be reported.
      if (name !~ /^[^\/[:space:]]+\.(sh|py)$/) next
      printf "%d\037%s\n", NR, trim($0)
    }
  ' "$1"
}

doc_files=("$DOCS_DIR"/*.md)
if (( ${#doc_files[@]} == 0 )); then
  echo "::error::${DOCS_DIR}/ contains no category docs — the catalog is empty"
  exit 1
fi

# --- 1. Every category doc links back to the index ------------------------
for doc in "${doc_files[@]}"; do
  if ! has_backlink "$doc"; then
    echo "::error file=${doc}::missing the back-link to the index (expected a link to ../README.md)"
    errors=$((errors + 1))
  fi
done

# --- 2. No hand-written row outside a generated region --------------------
# Fail closed: an awk that errors out prints nothing, and `|| true` would turn
# that into "no stray rows found" — a guard that passes by not running.
for doc in "${doc_files[@]}" "$INDEX"; do
  if ! stray=$(rows_outside_region "$doc"); then
    echo "::error file=${doc}::could not scan for stray catalog rows — the scanner failed on this file"
    errors=$((errors + 1))
    continue
  fi
  [[ -z "$stray" ]] && continue
  while IFS=$'\037' read -r lineno text; do
    [[ -z "${lineno:-}" ]] && continue
    echo "::error file=${doc},line=${lineno}::hand-written catalog row outside a generated region: ${text} — rows are generated from each file's '# catalog:' header by .github/scripts/scripts-catalog-gen.sh; a row here is never regenerated and never checked"
    errors=$((errors + 1))
  done <<< "$stray"
done

# --- 3. Delegate coverage, rows, index, and exemptions to the generator ----
# Its ::error:: annotations are the diagnostics for this section; adding a
# summary line of our own on top of them would only bury them.
if ! bash "$GEN" --check; then
  errors=$((errors + 1))
fi

if (( errors > 0 )); then
  echo "scripts-catalog-lint: ${errors} error(s) found"
  exit 1
fi

doc_count=${#doc_files[@]}
echo "scripts-catalog-lint: OK (${doc_count} category docs, rows generated and in sync)"
