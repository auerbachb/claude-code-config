#!/usr/bin/env bash
# Lint the .claude/reference/ catalog against the directory contents.
# catalog: utilities — Lint the `.claude/reference/` catalog against the directory contents (index/disk parity, no phantoms, no duplicates)
#
# The catalog is a thin hub (.claude/reference/README.md) plus one page per
# category under .claude/reference/catalog/ (Issue #2188). Register new
# entries in the matching catalog page, not the hub.
#
# Validates:
#   1. Every *.md and *.json file under .claude/reference/ (excluding README.md
#      itself and the diagrams/ and catalog/ subdirectories) has exactly one
#      bullet in the ## Contents section of one catalog page.
#   2. Every bullet's filename token exists on disk (no phantom entries).
#   3. No duplicate filename entries, within one page or across pages.
#   4. Every catalog/*.md page on disk is linked exactly once from the hub
#      ## Contents section, and every linked page exists.
#   5. The hub ## Contents section holds no registration bullets (index purity).
#   6. Each hub link sits under the ### heading whose text equals the linked
#      page's H1, so swapped links cannot point readers at the wrong category.
#
# Scope note: diagrams/ rows (path-qualified, `diagrams/x.md`) are deliberately
# NOT checked for parity — the lint covers root-level files only.
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
CATALOG_DIR="${REFERENCE_DIR}/catalog"

errors=0

usage() {
  cat <<'EOF'
Usage: .claude/scripts/reference-catalog-lint.sh [--help]

  Verifies the catalog pages under .claude/reference/catalog/ stay in sync
  with the files in .claude/reference/ (root level only; diagrams/ and
  catalog/ excluded), and that .claude/reference/README.md links each page
  exactly once. Register new entries in the matching catalog page.
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

# Scope extraction to a file's ## Contents section only (stops at the next
# ## header) so incidental filename mentions elsewhere don't pollute the set.
contents_of() {
  awk '
    /^## Contents/ { in_section=1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$1"
}

# Registration rows: the leading backtick-quoted token of each bullet,
#   - `filename.md` — description …
# Only basenames (no path separator) ending in .md or .json count, so
# cross-references like `.claude/rules/foo.md` and diagrams/ rows are not
# mistaken for registrations.
rows_of() {
  { grep -oE '^- `[^`/]+\.(md|json)`' || true; } | sed "s/^- \`//; s/\`\$//"
}

# --- 1. Build actual set ---------------------------------------------------
# Root-level *.md and *.json regular files only; exclude README.md itself and
# subdirectories (catalog/ pages are not references). -type f prevents
# directories or symlinks named *.md from being counted. find errors
# propagate as non-zero exit so the script fails closed.
actual=$(find "$REFERENCE_DIR" -maxdepth 1 -type f \
  \( -name '*.md' -o -name '*.json' \) \
  ! -name 'README.md' \
  -exec basename {} \; \
  | sort -u)

# --- 2. Hub: page links and purity -----------------------------------------
hub_contents=$(contents_of "$README")

# Hub bullets that look like registrations belong on a catalog page.
hub_rows=$(printf '%s\n' "$hub_contents" | rows_of)
if [[ -n "$hub_rows" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "::error file=${README}::Hub index holds an entry row for '${f}' — register it in the matching ${CATALOG_DIR}/ page"
    errors=$((errors + 1))
  done <<< "$hub_rows"
fi

# Link targets of the form (catalog/<page>.md) inside the hub ## Contents.
linked_all=$(printf '%s\n' "$hub_contents" \
  | { grep -oE '\]\(catalog/[^/)#]+\.md\)' || true; } \
  | sed 's/^\](catalog\///; s/)$//' \
  | sort)
linked=$(printf '%s\n' "$linked_all" | sort -u)

pages_on_disk=""
if [[ -d "$CATALOG_DIR" ]]; then
  pages_on_disk=$(find "$CATALOG_DIR" -maxdepth 1 -type f -name '*.md' \
    -exec basename {} \; | sort -u)
fi

missing_pages=$(comm -23 <(printf '%s\n' "$linked") <(printf '%s\n' "$pages_on_disk"))
unlinked_pages=$(comm -13 <(printf '%s\n' "$linked") <(printf '%s\n' "$pages_on_disk"))
repeat_links=$(printf '%s\n' "$linked_all" | uniq -d)

while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  echo "::error file=${README}::Hub links '${CATALOG_DIR}/${p}' but no such page exists"
  errors=$((errors + 1))
done <<< "$missing_pages"

while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  echo "::error file=${README}::Page '${CATALOG_DIR}/${p}' exists but the hub ## Contents section does not link it"
  errors=$((errors + 1))
done <<< "$unlinked_pages"

while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  echo "::error file=${README}::Hub links '${CATALOG_DIR}/${p}' more than once"
  errors=$((errors + 1))
done <<< "$repeat_links"

# Each link must sit under the ### heading matching the page's H1.
current_heading=""
while IFS= read -r line; do
  if [[ "$line" =~ ^###[[:space:]]+(.*)$ ]]; then
    current_heading="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ \]\(catalog/([^/\)#]+\.md)\) ]]; then
    page="${BASH_REMATCH[1]}"
    [[ -f "${CATALOG_DIR}/${page}" ]] || continue
    page_title=$(sed -n '1s/^# *//p' "${CATALOG_DIR}/${page}")
    if [[ "$current_heading" != "$page_title" ]]; then
      echo "::error file=${README}::Hub link to '${CATALOG_DIR}/${page}' sits under heading '${current_heading}' but the page is titled '${page_title}'"
      errors=$((errors + 1))
    fi
  fi
done <<< "$hub_contents"

# --- 3. Rows from every page -----------------------------------------------
# Tab-separated "name<TAB>page" so a diagnostic can name the page that holds
# the row. Pages are read in sorted order for stable output.
page_count=0
rows_tagged=""
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  page_count=$((page_count + 1))
  page_rows=$(contents_of "${CATALOG_DIR}/${p}" | rows_of)
  [[ -z "$page_rows" ]] && continue
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    rows_tagged+="${name}"$'\t'"${CATALOG_DIR}/${p}"$'\n'
  done <<< "$page_rows"
done <<< "$pages_on_disk"

documented_all=$(printf '%s' "$rows_tagged" | cut -f1 | sort)
documented=$(printf '%s\n' "$documented_all" | sort -u)

# --- 4. Diff both directions -----------------------------------------------
undocumented=$(comm -23 \
  <(printf '%s\n' "$actual") \
  <(printf '%s\n' "$documented") || true)

phantom=$(comm -13 \
  <(printf '%s\n' "$actual") \
  <(printf '%s\n' "$documented") || true)

if [[ -n "$undocumented" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "::error file=${README}::File '${f}' exists in ${REFERENCE_DIR}/ but has no entry in any catalog page ## Contents index"
    errors=$((errors + 1))
  done <<< "$undocumented"
fi

if [[ -n "$phantom" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    holder=$(printf '%s' "$rows_tagged" | awk -F'\t' -v n="$f" '$1 == n { print $2; exit }')
    echo "::error file=${holder}::Catalog indexes '${f}' but no such file exists in ${REFERENCE_DIR}/"
    errors=$((errors + 1))
  done <<< "$phantom"
fi

# --- 5. Duplicate-entry check (within and across pages) ---------------------
row_count=$(printf '%s\n' "$documented_all" | grep -c . || true)
unique_count=$(printf '%s\n' "$documented" | grep -c . || true)

if (( row_count != unique_count )); then
  while IFS= read -r dupe; do
    [[ -z "$dupe" ]] && continue
    holders=$(printf '%s' "$rows_tagged" | awk -F'\t' -v n="$dupe" '$1 == n { print $2 }' | paste -sd, -)
    holder=${holders%%,*}
    echo "::error file=${holder}::'${dupe}' appears more than once in the catalog ## Contents indexes (${holders})"
  done < <(printf '%s\n' "$documented_all" | uniq -d)
  errors=$((errors + row_count - unique_count))
fi

# --- 6. Result -------------------------------------------------------------
if (( errors > 0 )); then
  echo "reference-catalog-lint: ${errors} error(s) — ${unique_count} of $( \
    printf '%s\n' "$actual" | grep -c . || true) files indexed"
  exit 1
fi

echo "reference-catalog-lint: OK (${unique_count} files indexed across ${page_count} pages)"
