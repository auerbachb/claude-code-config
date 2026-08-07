#!/usr/bin/env bash
# Word-budget ratchet lint for the CLAUDE.md rule corpus.
#
# Companion to rule-lint.sh (mirrors chip-model-guard-lint.sh conventions).
# Validates:
#   - Total auto-loaded word count (CLAUDE.md + all rule files) stays within
#     the warning soft limit, committed ratchet cap, and hard limit.
#
# Run from repo root. Output uses GitHub Actions annotations (::error::,
# ::warning::). Exits 1 on any error condition; exit 2 on bad args.
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

SOFT_LIMIT=12000
HARD_LIMIT=13000
RATCHET_FLOOR=8500
RATCHET_HEADROOM=750

CLAUDE_MD="CLAUDE.md"
RULES_DIR=".claude/rules"
BUDGET_CAP_FILE="${RULES_DIR}/.budget-soft-cap"

errors=0
update_cap=0
allow_raise=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/rule-lint-ratchet.sh [--update-cap [--allow-raise]]

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

if (( allow_raise && ! update_cap )); then
  echo "::error::--allow-raise requires --update-cap"
  usage >&2
  exit 2
fi

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
    echo "::error file=${BUDGET_CAP_FILE}::Budget soft cap file is missing" >&2
    return 1
  fi
  if ! cap=$(python3 - "$BUDGET_CAP_FILE" <<'PY'
import re
import sys

data = open(sys.argv[1], "rb").read()
if not re.fullmatch(rb"[0-9]+(\r?\n)?", data):
    sys.exit(1)
sys.stdout.write(str(int(data.strip().decode("ascii"))))
PY
  ); then
    echo "::error file=${BUDGET_CAP_FILE}::Budget soft cap must contain a single integer, with at most a trailing newline"
    return 1
  fi
  printf '%s\n' "$cap"
}

# --- Word count budget and ratchet ---------------------------------------
rule_files=()
while IFS= read -r -d '' f; do
  rule_files+=("$f")
done < <(find "$RULES_DIR" -type f -name '*.md' -print0 | LC_ALL=C sort -z)
if (( ${#rule_files[@]} == 0 )); then
  echo "::warning::No rule files found in ${RULES_DIR}/"
  total=$(wc -w < "$CLAUDE_MD" | tr -d ' ')
else
  total=$(cat "$CLAUDE_MD" "${rule_files[@]}" | wc -w | tr -d ' ')
fi
echo "Total auto-loaded word count: ${total} (soft=${SOFT_LIMIT}, hard=${HARD_LIMIT})"

if (( update_cap )); then
  # One-way ratchet: the cap may only decrease or hold; it never auto-raises.
  # Formula is still max(count + RATCHET_HEADROOM, RATCHET_FLOOR) — unchanged.
  formula_cap=$(( total + RATCHET_HEADROOM ))
  if (( formula_cap < RATCHET_FLOOR )); then
    formula_cap=$RATCHET_FLOOR
  fi

  # Read the current cap for the ratchet comparison.  A separate RC variable is
  # required because set -e aborts the script when a command-substitution exits
  # non-zero, even when the failure is expected (bootstrap / invalid file case).
  prev_cap_rc=0
  prev_cap="$(python3 - "$BUDGET_CAP_FILE" <<'PY'
import re, sys
try:
    data = open(sys.argv[1], "rb").read()
    if not re.fullmatch(rb"[0-9]+(\r?\n)?", data):
        sys.exit(1)
    sys.stdout.write(str(int(data.strip().decode("ascii"))))
except Exception:
    sys.exit(1)
PY
  )" || prev_cap_rc=$?

  if (( prev_cap_rc != 0 )); then
    # Bootstrap: no valid prior cap to clamp toward; write the raw formula result.
    echo "Budget soft cap: no valid prior value — bootstrapping to formula result (${formula_cap})"
    updated_cap=$formula_cap
  elif (( allow_raise )); then
    # Explicit escape hatch: allow the cap to increase.
    updated_cap=$formula_cap
    delta=$(( formula_cap - prev_cap ))
    echo "Budget soft cap: ${prev_cap} → ${formula_cap} (+${delta}) [--allow-raise]"
  elif (( formula_cap < prev_cap )); then
    # Corpus shrank enough that the formula dips below the current cap: tighten.
    updated_cap=$formula_cap
    delta=$(( prev_cap - formula_cap ))
    echo "Budget soft cap: ${prev_cap} → ${formula_cap} (-${delta}) [lowered]"
  elif (( formula_cap == prev_cap )); then
    # Formula matches the current cap exactly: no change needed.
    updated_cap=$prev_cap
    echo "Budget soft cap: ${prev_cap} unchanged (formula matches cap)"
  else
    # Formula would raise the cap; ratchet holds.
    updated_cap=$prev_cap
    echo "Budget soft cap: ${prev_cap} unchanged (formula ${formula_cap} would raise — use --allow-raise to override)"
  fi

  tmp_cap=$(mktemp "${BUDGET_CAP_FILE}.tmp.XXXXXX")
  printf '%s' "$updated_cap" > "$tmp_cap"
  mv "$tmp_cap" "$BUDGET_CAP_FILE"
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

if (( total > 10#$budget_cap )); then
  echo "::error file=${BUDGET_CAP_FILE}::Auto-loaded word count ${total} exceeds ratchet cap ${budget_cap}. See .claude/reference/budget-cap-raise-decision.md to raise the cap."
  errors=$((errors + 1))
fi

if (( errors > 0 )); then
  echo "rule-lint-ratchet: ${errors} error(s) found"
  exit 1
fi

echo "rule-lint-ratchet: OK (total=${total}, cap=${budget_cap})"
