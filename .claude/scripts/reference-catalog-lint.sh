#!/usr/bin/env bash
# Lint the .claude/reference/ catalog against the directory contents.
#
# Validates:
#   1. Every *.md and *.json file under .claude/reference/ (excluding README.md
#      itself and the diagrams/ subdirectory) has exactly one bullet in the
#      ## Contents section of .claude/reference/README.md.
#   2. Every bullet's filename token exists on disk (no phantom entries).
#   3. No duplicate filename entries in the index.
#
# Companion to .github/scripts/skill-catalog-lint.sh, which enforces the same
# index-alignment invariant for .claude/skills/ against README.md.
# Paths are repo-root-relative; run from the repo root.
#
# Output uses GitHub Actions annotations (::error::) so issues surface
# directly on PR checks. Exits 1 on any error condition.
#
# Usage:
#   .claude/scripts/reference-catalog-lint.sh [--help]
#
# Agent usage: run before committing any change that adds, removes, or renames
# a file under .claude/reference/.

set -euo pipefail

REFERENCE_DIR=".claude/reference"
README="${REFERENCE_DIR}/README.md"

errors=0

usage() {
  cat <<'EOF'
Usage: .claude/scripts/reference-catalog-lint.sh [--help]

  Verifies .claude/reference/README.md ## Contents section stays in sync
  with the files in .claude/reference/ (root level only; diagrams/ excluded).
  Run from the repo root. Exits 1 on any error.

  Reported as GitHub Actions ::error:: annotations when running in CI.
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

if [[ ! -f "$README" ]]; then
  echo "::error file=${README}::${README} not found — run from the repo root"
  exit 1
fi

if [[ ! -d "$REFERENCE_DIR" ]]; then
  echo "::error::${REFERENCE_DIR} directory not found — run from the repo root"
  exit 1
fi

# --- 1. Build actual set ---------------------------------------------------
# Root-level *.md and *.json regular files only; exclude README.md itself and
# subdirectories. -type f prevents directories or symlinks named *.md from
# being counted. find errors (permission/I/O) propagate as non-zero exit so
# the script fails closed rather than silently under-reporting.
actual=$(find "$REFERENCE_DIR" -maxdepth 1 -type f \
  \( -name '*.md' -o -name '*.json' \) \
  ! -name 'README.md' \
  -exec basename {} \; \
  | sort -u)

# --- 2. Build documented set from ## Contents section ----------------------
# Scope extraction to ## Contents only (stops at the next ## header) so that
# incidental filename mentions elsewhere in the README don't pollute the set.
# Extract the leading backtick-quoted token from each bullet line:
#   - `filename.md` — description …
# Accepts only basenames (no path separator) that end in .md or .json, so
# cross-references like `.claude/rules/foo.md` or `~/.claude/session-state.json`
# are not mistaken for registrations.
contents_section=$(awk '
  /^## Contents/ { in_section=1; next }
  in_section && /^## / { exit }
  in_section { print }
' "$README")

documented_all=$(printf '%s\n' "$contents_section" \
  | grep -oE '^- `[^`/]+\.(md|json)`' \
  | sed "s/^- \`//; s/\`\$//" \
  | sort || true)
documented=$(printf '%s\n' "$documented_all" | sort -u)

# --- 3. Diff both directions -----------------------------------------------
undocumented=$(comm -23 \
  <(printf '%s\n' "$actual") \
  <(printf '%s\n' "$documented") || true)

phantom=$(comm -13 \
  <(printf '%s\n' "$actual") \
  <(printf '%s\n' "$documented") || true)

if [[ -n "$undocumented" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "::error file=${README}::File '${f}' exists in ${REFERENCE_DIR}/ but has no entry in the ## Contents index"
    errors=$((errors + 1))
  done <<< "$undocumented"
fi

if [[ -n "$phantom" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "::error file=${README}::README indexes '${f}' but no such file exists in ${REFERENCE_DIR}/"
    errors=$((errors + 1))
  done <<< "$phantom"
fi

# --- 4. Duplicate-entry check ----------------------------------------------
row_count=$(printf '%s\n' "$documented_all" | grep -c . || true)
unique_count=$(printf '%s\n' "$documented" | grep -c . || true)

if (( row_count != unique_count )); then
  printf '%s\n' "$documented_all" | sort | uniq -d | while IFS= read -r dupe; do
    [[ -z "$dupe" ]] && continue
    echo "::error file=${README}::'${dupe}' appears more than once in the ## Contents index"
  done
  errors=$((errors + row_count - unique_count))
fi

# --- 5. Result -------------------------------------------------------------
if (( errors > 0 )); then
  echo "reference-catalog-lint: ${errors} error(s) — ${unique_count} of $( \
    printf '%s\n' "$actual" | grep -c . || true) files indexed"
  exit 1
fi

echo "reference-catalog-lint: OK (${unique_count} files indexed)"
