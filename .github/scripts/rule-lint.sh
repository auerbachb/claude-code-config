#!/usr/bin/env bash
# Lint the CLAUDE.md rule index and .claude/rules/ word-count budget.
#
# Validates:
#   1. The rule index table in CLAUDE.md matches the actual set of
#      .claude/rules/**/*.md files (no drift in either direction).
#   2. Total auto-loaded word count budget + one-way ratchet cap — delegated
#      to rule-lint-ratchet.sh (same directory). --update-cap/--allow-raise
#      are forwarded; a missing or failing ratchet script fails the lint.
#   3. Per-file size: any rule file > 2000 words emits a warning.
#
# Output uses GitHub Actions annotations (::error::, ::warning::) so
# issues surface directly on PR checks. Exits 1 on any error condition.
#
# --update-cap (one-way ratchet):
#   Writes min(current_cap, max(count + 750, 8500)) to .budget-soft-cap.
#   The cap can only decrease or hold — it never auto-raises.  This prevents
#   a small intentional cut from silently widening the budget.
#
#   Bootstrap (missing / invalid cap file): the raw formula result is written
#   because there is no prior value to clamp toward.
#
# --allow-raise (escape hatch, must be used with --update-cap):
#   Overrides the ratchet and writes the raw formula result even if it
#   exceeds the current cap.  Prints old value, new value, and the delta so
#   the raise is visible in CI output and review history.

set -euo pipefail
shopt -s nullglob

PER_FILE_WARN=2000

CLAUDE_MD="CLAUDE.md"
RULES_DIR=".claude/rules"

errors=0
update_cap=0
allow_raise=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/rule-lint.sh [--update-cap [--allow-raise]]

  --update-cap   Rewrite .claude/rules/.budget-soft-cap to
                 min(current_cap, max(current_count + 750, 8500)).
                 The cap can only decrease or hold (one-way ratchet).
                 Then continue linting against the updated cap.

  --allow-raise  Override the ratchet: allow the cap to increase.
                 Only takes effect when combined with --update-cap.
                 Prints old value, new value, and the delta.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --update-cap)
      update_cap=1
      ;;
    --allow-raise)
      allow_raise=1
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

actual_files=$(find "$RULES_DIR" -type f -name '*.md' -exec basename {} \; \
  | sort -u)
duplicate_basenames=$(find "$RULES_DIR" -type f -name '*.md' -exec basename {} \; \
  | sort \
  | uniq -d)

missing_from_index=$(comm -23 <(printf '%s\n' "$actual_files") <(printf '%s\n' "$indexed_files") || true)
missing_from_disk=$(comm -13 <(printf '%s\n' "$actual_files") <(printf '%s\n' "$indexed_files") || true)

if [[ -n "$duplicate_basenames" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    duplicate_paths=$(find "$RULES_DIR" -type f -name "$f" | LC_ALL=C sort | paste -sd ',' -)
    echo "::error file=${CLAUDE_MD}::Rule basename '${f}' is ambiguous across the recursive corpus (${duplicate_paths}). The CLAUDE.md rule index is basename-only; rename these files to unique basenames."
    errors=$((errors + 1))
  done <<< "$duplicate_basenames"
fi

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

if [[ -z "$missing_from_index" && -z "$missing_from_disk" && -z "$duplicate_basenames" ]]; then
  file_count=$(printf '%s\n' "$actual_files" | grep -c . || true)
  echo "Rule index alignment: OK (${file_count} files)"
fi

# --- 2. Word-count budget + ratchet (delegated — issue #1087) -------------
# The budget/ratchet subsystem lives in rule-lint-ratchet.sh (extracted in
# PR #1086); this call completes the delegation. Fail closed: a missing or
# failing ratchet script is an error, never a silent skip. --allow-raise is
# forwarded only alongside --update-cap, preserving this script's documented
# "only takes effect when combined" semantics.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ratchet_args=()
if (( update_cap )); then
  ratchet_args+=(--update-cap)
  if (( allow_raise )); then
    ratchet_args+=(--allow-raise)
  fi
fi
if [[ ! -f "${SCRIPT_DIR}/rule-lint-ratchet.sh" ]]; then
  echo "::error::rule-lint-ratchet.sh not found next to rule-lint.sh — budget/ratchet checks did not run"
  errors=$((errors + 1))
elif ! bash "${SCRIPT_DIR}/rule-lint-ratchet.sh" ${ratchet_args[@]+"${ratchet_args[@]}"}; then
  errors=$((errors + 1))
fi

# --- 3. Per-file size check ----------------------------------------------
rule_files=()
while IFS= read -r -d '' f; do
  rule_files+=("$f")
done < <(find "$RULES_DIR" -type f -name '*.md' -print0 | LC_ALL=C sort -z)
for f in ${rule_files[@]+"${rule_files[@]}"}; do
  wc_words=$(wc -w < "$f" | tr -d ' ')
  if (( wc_words > PER_FILE_WARN )); then
    echo "::warning file=${f}::Rule file ${f} is ${wc_words} words (>${PER_FILE_WARN}). Consider splitting into a sub-topic."
  fi
done

# --- 4. Chip model-guard conformance (issue #731) -------------------------
if ! bash "${SCRIPT_DIR}/chip-model-guard-lint.sh"; then
  errors=$((errors + 1))
fi
if ! bash "${SCRIPT_DIR}/tests/chip-model-guard-lint.test.sh"; then
  errors=$((errors + 1))
fi

if (( errors > 0 )); then
  echo "rule-lint: ${errors} error(s) found"
  exit 1
fi

echo "rule-lint: OK"
