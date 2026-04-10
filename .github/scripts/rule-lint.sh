#!/usr/bin/env bash
# Lint the CLAUDE.md rule index and .claude/rules/ word-count budget.
#
# Validates:
#   1. The rule index table in CLAUDE.md matches the actual set of
#      .claude/rules/*.md files (no drift in either direction).
#   2. Total auto-loaded word count (CLAUDE.md + all rule files) is
#      within budget: soft 10000 (warn), hard 14000 (fail).
#      Note: hard cap is 14000 as a transition setting while rules are
#      condensed back toward the 10000 soft cap.
#      TODO(#203): revert HARD_LIMIT to 12000 (or lower) once total
#      word count drops back under the 10000 soft budget.
#   3. Per-file size: any rule file > 2000 words emits a warning.
#
# Output uses GitHub Actions annotations (::error::, ::warning::) so
# issues surface directly on PR checks. Exits 1 on any error condition.

set -euo pipefail
shopt -s nullglob

SOFT_LIMIT=10000
HARD_LIMIT=14000
PER_FILE_WARN=2000

CLAUDE_MD="CLAUDE.md"
RULES_DIR=".claude/rules"

errors=0

if [[ ! -f "$CLAUDE_MD" ]]; then
  echo "::error file=${CLAUDE_MD}::CLAUDE.md not found at repo root"
  exit 1
fi

if [[ ! -d "$RULES_DIR" ]]; then
  echo "::error::${RULES_DIR} directory not found"
  exit 1
fi

# --- 1. Rule index alignment check ---------------------------------------
# Extract basenames from the CLAUDE.md rule index table. Table rows look
# like:
#   | `issue-planning.md` | ... |
# Scope the grep to pipe-delimited table rows so prose references to
# other *.md files elsewhere in CLAUDE.md (e.g. README.md) aren't
# misread as rule-file entries.
# Allow empty results without aborting under `set -euo pipefail`: if either
# grep matches nothing it exits 1, which would kill the script. The `|| true`
# guard lets downstream comm/diagnostic logic handle the empty case.
indexed_files=$(grep -E '^\|' "$CLAUDE_MD" \
  | grep -oE '`[a-zA-Z0-9_-]+\.md`' \
  | tr -d '`' \
  | sort -u || true)

actual_files=$(find "$RULES_DIR" -maxdepth 1 -type f -name '*.md' -exec basename {} \; \
  | sort -u)

missing_from_index=$(comm -23 <(printf '%s\n' "$actual_files") <(printf '%s\n' "$indexed_files") || true)
missing_from_disk=$(comm -13 <(printf '%s\n' "$actual_files") <(printf '%s\n' "$indexed_files") || true)

if [[ -n "$missing_from_index" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "::error file=${CLAUDE_MD}::Rule file '${f}' exists in ${RULES_DIR}/ but is missing from the CLAUDE.md rule index table"
    errors=$((errors + 1))
  done <<< "$missing_from_index"
fi

if [[ -n "$missing_from_disk" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "::error file=${CLAUDE_MD}::Rule index lists '${f}' but no such file exists in ${RULES_DIR}/"
    errors=$((errors + 1))
  done <<< "$missing_from_disk"
fi

if [[ -z "$missing_from_index" && -z "$missing_from_disk" ]]; then
  file_count=$(printf '%s\n' "$actual_files" | grep -c . || true)
  echo "Rule index alignment: OK (${file_count} files)"
fi

# --- 2. Total word count budget ------------------------------------------
rule_files=("$RULES_DIR"/*.md)
if (( ${#rule_files[@]} == 0 )); then
  echo "::warning::No rule files found in ${RULES_DIR}/"
  total=$(wc -w < "$CLAUDE_MD" | tr -d ' ')
else
  total=$(cat "$CLAUDE_MD" "${rule_files[@]}" | wc -w | tr -d ' ')
fi
echo "Total auto-loaded word count: ${total} (soft=${SOFT_LIMIT}, hard=${HARD_LIMIT})"

if (( total > HARD_LIMIT )); then
  echo "::error file=${CLAUDE_MD}::Auto-loaded word count ${total} exceeds HARD limit ${HARD_LIMIT}. Rules must be condensed before merge."
  errors=$((errors + 1))
elif (( total > SOFT_LIMIT )); then
  echo "::warning file=${CLAUDE_MD}::Auto-loaded word count ${total} exceeds soft budget ${SOFT_LIMIT} (hard=${HARD_LIMIT}). Consider condensing rules."
fi

# --- 3. Per-file size check ----------------------------------------------
for f in "${rule_files[@]}"; do
  wc_words=$(wc -w < "$f" | tr -d ' ')
  if (( wc_words > PER_FILE_WARN )); then
    echo "::warning file=${f}::Rule file ${f} is ${wc_words} words (>${PER_FILE_WARN}). Consider splitting into a sub-topic."
  fi
done

if (( errors > 0 )); then
  echo "rule-lint: ${errors} error(s) found"
  exit 1
fi

echo "rule-lint: OK"
