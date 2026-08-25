#!/usr/bin/env bash
# estimate-resolve.sh — Resolve an issue number to its estimate string.
#
# PURPOSE
#   Used by dispatch/makespan helpers so /pm, /subagent, and /wave all show
#   the same per-issue estimate without duplicating resolution logic.
#
# USAGE
#   estimate-resolve.sh <issue_number> [--repo owner/repo]
#
# STDOUT (one line)
#   "Est: 45–90 min · plan on 90"   — from ## Estimate section (exit 0)
#   "Est: 15–30 min · plan on 30"   — tier-table fallback: Light (exit 1)
#   "Est: 45–90 min · plan on 90"   — tier-table fallback: Standard (exit 1)
#   "Est: 90–180 min · plan on 180" — tier-table fallback: Heavy (exit 1)
#   "unestimated"                    — no section and no tier label (exit 2)
#
# EXIT CODES
#   0  resolved from ## Estimate section in issue body
#   1  tier-table fallback (label-derived tier)
#   2  unestimated
#   3  usage error
#   4  gh / jq error
#
# PARSE PATTERN (from time-estimates.md)
#   ^Est:\s+(\d+)–(\d+)\s+min\s+·\s+plan\s+on\s+(\d+)$
#   The separator is an en-dash (U+2013), not a hyphen.
#
# TIER TABLE (from time-estimates.md)
#   Light    → Est: 15–30 min · plan on 30
#   Standard → Est: 45–90 min · plan on 90
#   Heavy    → Est: 90–180 min · plan on 180
#
# DEPENDENCIES
#   - gh (authenticated)
#   - jq >= 1.5

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
ISSUE_NUMBER=""
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -lt 2 ]] && { printf 'Usage: %s <issue_number> [--repo owner/repo]\n' "$(basename "$0")" >&2; exit 3; }
      REPO="$2"; shift 2 ;;
    --repo=*)
      REPO="${1#--repo=}"; shift ;;
    --help|-h)
      sed -n '2,/^set -/{ /^#/{ s/^# \?//; p }; /^set -/q }' "$0"
      exit 0 ;;
    -*)
      printf 'Usage: %s <issue_number> [--repo owner/repo]\n' "$(basename "$0")" >&2
      exit 3 ;;
    *)
      if [[ -z "$ISSUE_NUMBER" ]]; then
        ISSUE_NUMBER="$1"
      else
        printf 'Usage: %s <issue_number> [--repo owner/repo]\n' "$(basename "$0")" >&2
        exit 3
      fi
      shift ;;
  esac
done

if [[ -z "$ISSUE_NUMBER" ]]; then
  printf 'Usage: %s <issue_number> [--repo owner/repo]\n' "$(basename "$0")" >&2
  exit 3
fi

if ! [[ "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  printf 'estimate-resolve.sh: issue number must be a positive integer, got: %s\n' "$ISSUE_NUMBER" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Dependencies check
# ---------------------------------------------------------------------------
for cmd in gh jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'estimate-resolve.sh: missing dependency: %s\n' "$cmd" >&2
    exit 4
  fi
done

# ---------------------------------------------------------------------------
# Tier lookup table
# ---------------------------------------------------------------------------
tier_to_estimate() {
  local tier="$1"
  case "$(printf '%s' "$tier" | tr '[:upper:]' '[:lower:]')" in
    light|quick)
      printf 'Est: 15\xe2\x80\x9330 min \xc2\xb7 plan on 30' ;;
    standard|medium)
      printf 'Est: 45\xe2\x80\x9390 min \xc2\xb7 plan on 90' ;;
    heavy)
      printf 'Est: 90\xe2\x80\x93180 min \xc2\xb7 plan on 180' ;;
    *)
      return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Fetch issue body and labels
# ---------------------------------------------------------------------------
GH_ARGS=()
[[ -n "$REPO" ]] && GH_ARGS+=(--repo "$REPO")

ISSUE_JSON=""
if ! ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" "${GH_ARGS[@]}" \
    --json body,labels 2>&1); then
  printf 'estimate-resolve.sh: gh error fetching issue #%s: %s\n' \
    "$ISSUE_NUMBER" "$ISSUE_JSON" >&2
  exit 4
fi

BODY=$(printf '%s' "$ISSUE_JSON" | jq -r '.body // ""')

# ---------------------------------------------------------------------------
# Strategy 1: Parse ## Estimate section from issue body
# ---------------------------------------------------------------------------
# Find the ## Estimate heading and extract the Est: line that follows it.
# The en-dash is U+2013 (UTF-8: \xe2\x80\x93).
IN_ESTIMATE_SECTION=false
EST_LINE=""
while IFS= read -r line; do
  if [[ "$line" =~ ^##[[:space:]]+Estimate([[:space:]]|$) ]]; then
    IN_ESTIMATE_SECTION=true
    continue
  fi
  # Stop at the next heading
  if $IN_ESTIMATE_SECTION && [[ "$line" =~ ^## ]]; then
    break
  fi
  if $IN_ESTIMATE_SECTION && [[ "$line" =~ ^Est:[[:space:]] ]]; then
    EST_LINE="$line"
    break
  fi
done <<< "$BODY"

if [[ -n "$EST_LINE" ]]; then
  # Structural check first: the line must look like "Est: {N}...{N} min...plan on {N}".
  # This guards against accepting any line with 3 numbers that happen to satisfy the
  # numeric constraints — only lines with the canonical skeleton are parsed.
  # (The en-dash is non-digit; grep -qE treats it as separator bytes, which is fine.)
  if printf '%s' "$EST_LINE" | \
       grep -qE '^Est:[[:space:]]+[0-9]+[^0-9]+[0-9]+[[:space:]]+min[[:space:]].*plan[[:space:]]+on[[:space:]]+[0-9]+'; then
    # Extract all digit runs positionally to avoid UTF-8 en-dash byte fragility.
    # Canonical format: "Est: {lo}–{hi} min · plan on {bound}"
    # The en-dash (U+2013, UTF-8: \xe2\x80\x93) is non-digit so yields three numbers.
    # Use "|| true" so grep's exit 1 (no digit runs) does not abort under set -e.
    _NUMS=$(printf '%s' "$EST_LINE" | grep -oE '[0-9]+' || true)
    LO=$(printf '%s' "$_NUMS" | sed -n '1p')
    HI=$(printf '%s' "$_NUMS" | sed -n '2p')
    BOUND=$(printf '%s' "$_NUMS" | sed -n '3p')

    if [[ -n "$LO" && -n "$HI" && -n "$BOUND" && \
          "$LO" -lt "$HI" && "$BOUND" -eq "$HI" ]]; then
      printf '%s\n' "$EST_LINE"
      exit 0
    fi
  fi
  # Malformed or structurally invalid Est: line — fall through to tier fallback
fi

# ---------------------------------------------------------------------------
# Strategy 2: Tier-table fallback from labels
# ---------------------------------------------------------------------------
LABELS=$(printf '%s' "$ISSUE_JSON" | jq -r '[.labels[].name] | join(",")' | tr '[:upper:]' '[:lower:]')

TIER_ESTIMATE=""
# Check complexity labels in priority order (heavy wins over standard wins over light)
if printf '%s' "$LABELS" | grep -q 'complexity:heavy\|tier:heavy'; then
  TIER_ESTIMATE=$(tier_to_estimate heavy)
elif printf '%s' "$LABELS" | grep -q 'complexity:medium\|complexity:standard\|tier:standard\|tier:medium'; then
  TIER_ESTIMATE=$(tier_to_estimate standard)
elif printf '%s' "$LABELS" | grep -q 'complexity:light\|complexity:quick\|tier:light\|tier:quick'; then
  TIER_ESTIMATE=$(tier_to_estimate light)
fi

if [[ -n "$TIER_ESTIMATE" ]]; then
  printf '%s\n' "$TIER_ESTIMATE"
  exit 1
fi

# ---------------------------------------------------------------------------
# Strategy 3: Unestimated
# ---------------------------------------------------------------------------
printf 'unestimated\n'
exit 2
