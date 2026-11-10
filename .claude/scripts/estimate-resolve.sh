#!/usr/bin/env bash
# estimate-resolve.sh — Resolve an issue number to its estimate string.
# catalog: backlog-pm — Resolve an issue number to its estimate string so every dispatch helper reports the same figure
#
# PURPOSE
#   Used by dispatch/makespan helpers so /pm, /subagent, and /wave all show
#   the same per-issue estimate without duplicating resolution logic.
#
# USAGE
#   estimate-resolve.sh <issue_number> [--repo owner/repo]
#
# STDOUT (one line)
#   "Est: 120–180 min · plan on 180" — from ## Estimate section (exit 0)
#   "Est: 60–90 min · plan on 90"    — tier-table fallback: Light (exit 1)
#   "Est: 120–180 min · plan on 180" — tier-table fallback: Standard (exit 1)
#   "Est: 210–300 min · plan on 300" — tier-table fallback: Heavy (exit 1)
#   "Est: 180–360 min · plan on 360" — tier-table fallback: XL (exit 1)
#   "unestimated"                    — no section and no tier label (exit 2)
#
# EXIT CODES
#   0  resolved from ## Estimate section in issue body
#   1  tier-table fallback (label-derived tier)
#   2  unestimated
#   3  usage error
#   4  gh / jq error
#   70  --help header extraction produced no output (internal defect).
#
# PARSE PATTERN (from time-estimates.md)
#   ^Est:\s+(\d+)–(\d+)\s+min\s+·\s+plan\s+on\s+(\d+)$
#   The separator is an en-dash (U+2013), not a hyphen.
#
# TIER TABLE (from time-estimates.md — rounds-based: coding + rounds × 30)
#   Light    → Est: 60–90 min · plan on 90      (30 min coding + 1–2 rounds)
#   Standard → Est: 120–180 min · plan on 180   (30–60 min coding + 3–4 rounds)
#   Heavy    → Est: 210–300 min · plan on 300   (60–90 min coding + 5–7 rounds)
#   XL       → Est: 180–360 min · plan on 360   (a bound marker, NOT a rounds row:
#              it says only "over three hours". Set by an explicit upward
#              adjustment or a size:XL / size:XXL label, never inferred from a
#              description — time-estimates.md "The XL row".)
#
#   These are FIXED published rows and are deliberately NOT derived from
#   SPLIT_OVER_MIN (pm-config.md). That knob decides when the split trigger
#   fires; this table decides what an estimate line can say. Deriving the row
#   from the knob would re-tier every already-published estimate whenever a repo
#   retuned it, and estimate-log.sh classifies historical rows by exact
#   {lo}/{hi} pair — so the rollup would silently stop matching them.
#
# DEPENDENCIES
#   - gh (authenticated)
#   - jq >= 1.5

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  2>/dev/null >> "$HOME/.claude/script-usage.log" || true

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
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
        { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
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
      printf 'Est: 60\xe2\x80\x9390 min \xc2\xb7 plan on 90' ;;
    standard|medium)
      printf 'Est: 120\xe2\x80\x93180 min \xc2\xb7 plan on 180' ;;
    heavy)
      printf 'Est: 210\xe2\x80\x93300 min \xc2\xb7 plan on 300' ;;
    xl|xxl)
      printf 'Est: 180\xe2\x80\x93360 min \xc2\xb7 plan on 360' ;;
    *)
      return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Fetch issue body and labels
# ---------------------------------------------------------------------------
GH_ARGS=()
[[ -n "$REPO" ]] && GH_ARGS+=(--repo "$REPO")

# Expand with ${ARR[@]+"${ARR[@]}"}: under `set -u`, a bare "${GH_ARGS[@]}" on an
# EMPTY array aborts on macOS bash 3.2 (and bash 4.0-4.3), which is every
# no-flags invocation — the whole lookup died before reaching gh (issue #1371).
ISSUE_JSON=""
if ! ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" ${GH_ARGS[@]+"${GH_ARGS[@]}"} \
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
  # Structural check: the line must contain the key words in order.
  # An additional canonical-format gate below rejects lines that use non-canonical
  # separators (e.g. a plain hyphen instead of en-dash, or no middle dot).
  if grep -qE '^Est:[[:space:]]+[0-9]+[^0-9]+[0-9]+[[:space:]]+min[[:space:]].*plan[[:space:]]+on[[:space:]]+[0-9]+' \
       <<<"$EST_LINE"; then
    # Extract all digit runs positionally to avoid UTF-8 en-dash byte fragility.
    # Canonical format: "Est: {lo}–{hi} min · plan on {bound}"
    # The en-dash (U+2013, UTF-8: \xe2\x80\x93) is non-digit so yields three numbers.
    # Use "|| true" so grep's exit 1 (no digit runs) does not abort under set -e.
    _NUMS=$(printf '%s' "$EST_LINE" | grep -oE '[0-9]+' || true)
    LO=$(printf '%s' "$_NUMS" | sed -n '1p')
    HI=$(printf '%s' "$_NUMS" | sed -n '2p')
    BOUND=$(printf '%s' "$_NUMS" | sed -n '3p')

    # Canonical-format gate: require the documented separators.
    # EN_DASH (U+2013, UTF-8: \xe2\x80\x93) must appear between the two numbers.
    # MIDDLE_DOT (U+00B7, UTF-8: \xc2\xb7) must appear between "min" and "plan on".
    # This rejects lines using a plain hyphen, "to", comma, or any other separator.
    _EN_DASH=$(printf '\xe2\x80\x93')
    _MIDDLE_DOT=$(printf '\xc2\xb7')
    if [[ -n "$LO" && -n "$HI" && -n "$BOUND" && \
          "$LO" -lt "$HI" && "$BOUND" -eq "$HI" ]] && \
       grep -qF "$_EN_DASH" <<<"$EST_LINE" && \
       grep -qF "$_MIDDLE_DOT" <<<"$EST_LINE"; then
      printf '%s\n' "$EST_LINE"
      exit 0
    fi
    # Numbers valid but canonical separators missing — fall through to tier fallback
  fi
  # Malformed or structurally invalid Est: line — fall through to tier fallback
fi

# ---------------------------------------------------------------------------
# Strategy 2: Tier-table fallback from labels
# ---------------------------------------------------------------------------
# Newline-delimited, not comma-delimited: a GitHub label may contain a comma but
# never a newline, so this is the one separator that cannot appear inside a name.
LABELS=$(printf '%s' "$ISSUE_JSON" | jq -r '[.labels[].name] | join("\n")' | tr '[:upper:]' '[:lower:]')
LABELS_DELIM=$'\n'"$LABELS"$'\n'

# has_label <name>... — true when the issue carries any of these labels, matched
# WHOLE. A substring match is not good enough: `size:xl` is a substring of
# `size:xlarge`, `complexity:heavy` of `complexity:heavyweight`, and either would
# silently resolve a differently-named label to a tier its owner never chose.
# Pure bash `case`, deliberately not a pipe into grep: `grep -q` exits on its
# first match, and under `set -o pipefail` the SIGPIPE'd producer can fail a
# pipeline whose consumer succeeded.
has_label() {
  local candidate
  for candidate in "$@"; do
    case "$LABELS_DELIM" in
      *$'\n'"$candidate"$'\n'*) return 0 ;;
    esac
  done
  return 1
}

TIER_ESTIMATE=""
# Check complexity labels in priority order (XL wins over heavy wins over standard
# wins over light). XL is checked first deliberately: an issue carrying BOTH
# `size:XL` and `complexity:heavy` is one whose owner said "bigger than Heavy",
# and resolving it to Heavy's 300 would silently discard the larger claim.
if has_label complexity:xl tier:xl size:xl size:xxl; then
  TIER_ESTIMATE=$(tier_to_estimate xl)
elif has_label complexity:heavy tier:heavy; then
  TIER_ESTIMATE=$(tier_to_estimate heavy)
elif has_label complexity:medium complexity:standard tier:standard tier:medium; then
  TIER_ESTIMATE=$(tier_to_estimate standard)
elif has_label complexity:light complexity:quick tier:light tier:quick; then
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
