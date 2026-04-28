#!/usr/bin/env bash
# Lint the CLAUDE.md rule index and .claude/rules/ word-count budget.
#
# Validates:
#   1. The rule index table in CLAUDE.md matches the actual set of
#      .claude/rules/*.md files (no drift in either direction).
#   2. Total auto-loaded word count (CLAUDE.md + all rule files) stays
#      within the warning soft limit, committed ratchet cap, and hard limit.
#   3. Per-file size: any rule file > 2000 words emits a warning.
#
# Output uses GitHub Actions annotations (::error::, ::warning::) so
# issues surface directly on PR checks. Exits 1 on any error condition.

set -euo pipefail
shopt -s nullglob

SOFT_LIMIT=10000
HARD_LIMIT=11000
PER_FILE_WARN=2000
RATCHET_FLOOR=8500
RATCHET_HEADROOM=250

CLAUDE_MD="CLAUDE.md"
RULES_DIR=".claude/rules"
BUDGET_CAP_FILE="${RULES_DIR}/.budget-soft-cap"

errors=0
update_cap=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/rule-lint.sh [--update-cap]

  --update-cap  Rewrite .claude/rules/.budget-soft-cap to max(current_count + 250, 8500),
                then continue linting against the updated cap.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --update-cap)
      update_cap=1
      ;;
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

if [[ ! -f "$CLAUDE_MD" ]]; then
  echo "::error file=${CLAUDE_MD}::CLAUDE.md not found at repo root"
  exit 1
fi

if [[ ! -d "$RULES_DIR" ]]; then
  echo "::error::${RULES_DIR} directory not found"
  exit 1
fi

read_budget_cap() {
  local cap
  if [[ ! -f "$BUDGET_CAP_FILE" ]]; then
    echo "::error file=${BUDGET_CAP_FILE}::Budget soft cap file is missing"
    return 1
  fi
  if ! cap=$(python3 - "$BUDGET_CAP_FILE" <<'PY'
import re
import sys

data = open(sys.argv[1], "rb").read()
if not re.fullmatch(rb"[0-9]+", data):
    sys.exit(1)
sys.stdout.write(data.decode("ascii"))
PY
  ); then
    echo "::error file=${BUDGET_CAP_FILE}::Budget soft cap must contain a single integer with no whitespace"
    return 1
  fi
  printf '%s\n' "$cap"
}

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

if (( update_cap )); then
  updated_cap=$(( total + RATCHET_HEADROOM ))
  if (( updated_cap < RATCHET_FLOOR )); then
    updated_cap=$RATCHET_FLOOR
  fi
  printf '%s' "$updated_cap" > "$BUDGET_CAP_FILE"
  echo "Updated budget soft cap: ${updated_cap}"
fi

if ! budget_cap=$(read_budget_cap); then
  errors=$((errors + 1))
  budget_cap=$HARD_LIMIT
fi
echo "Ratchet budget cap: ${budget_cap} (formula=max(current_count + ${RATCHET_HEADROOM}, ${RATCHET_FLOOR}))"

if (( total > HARD_LIMIT )); then
  echo "::error file=${CLAUDE_MD}::Auto-loaded word count ${total} exceeds HARD limit ${HARD_LIMIT}. Rules must be condensed before merge."
  errors=$((errors + 1))
elif (( total > SOFT_LIMIT )); then
  echo "::warning file=${CLAUDE_MD}::Auto-loaded word count ${total} exceeds soft budget ${SOFT_LIMIT} (hard=${HARD_LIMIT}). Consider condensing rules."
fi

if (( total > budget_cap )); then
  echo "::error file=${BUDGET_CAP_FILE}::Auto-loaded word count ${total} exceeds ratchet cap ${budget_cap}. Run rule-lint.sh --update-cap only after intentional corpus reduction."
  errors=$((errors + 1))
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
