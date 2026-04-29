#!/usr/bin/env bash
# Verify stdin contains a parseable EXIT_REPORT per
# .claude/reference/exit-report-format.md — header line plus KEY: value fields.
# Exit 0 = valid block with all required fields; 1 = missing/invalid.
set -euo pipefail

required=(
  PHASE_COMPLETE
  PR_NUMBER
  HEAD_SHA
  REVIEWER
  OUTCOME
  FILES_CHANGED
  NEXT_PHASE
  HANDOFF_FILE
)

content=$(cat || true)
if ! printf '%s\n' "$content" | grep -qx 'EXIT_REPORT'; then
  echo "verify-exit-report-block: missing EXIT_REPORT header line" >&2
  exit 1
fi

# Contiguous block: EXIT_REPORT then KEY: value (value may be empty; optional single space after colon)
mapfile -t lines < <(printf '%s\n' "$content" | awk '
  /^EXIT_REPORT$/ { inblk=1; next }
  inblk && /^[A-Z_]+:/ { print; next }
  inblk { exit }
')

declare -A seen=()
for line in "${lines[@]}"; do
  key=${line%%:*}
  [[ -n "$key" ]] || continue
  seen["$key"]=1
done

missing=()
for k in "${required[@]}"; do
  [[ -n "${seen[$k]-}" ]] || missing+=("$k")
done

if ((${#missing[@]})); then
  echo "verify-exit-report-block: missing required field(s): ${missing[*]}" >&2
  exit 1
fi

# Disallow tab-only or multiple spaces after colon (keep single space or none per templates)
while IFS= read -r line; do
  if [[ "$line" =~ ^[A-Z_]+:[[:space:]] ]]; then
    rest=${line#*:}
    if [[ "$rest" =~ ^[[:space:]]{2,} ]]; then
      echo "verify-exit-report-block: disallowed multiple spaces after colon: $line" >&2
      exit 1
    fi
    if [[ "$rest" =~ $'\t' ]]; then
      echo "verify-exit-report-block: tab in value start not allowed: $line" >&2
      exit 1
    fi
  fi
done < <(printf '%s\n' "${lines[@]}")

echo "OK: EXIT_REPORT block has all required fields ($(printf '%s ' "${required[@]}"))"
exit 0
