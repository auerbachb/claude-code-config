#!/usr/bin/env bash
# ccusage-baseline.sh — Read-only per-repo/per-session spend and usage baseline (issue #781).
#
# PURPOSE:
#   Provides a reproducible, read-only way to capture per-session token spend
#   and 5-hour billing-block usage for the token-measurement baseline tracker
#   (`token-measurement-baseline-2026-08.md`). Shells out to `ccusage` and
#   normalises its output into a compact summary on stdout.
#
#   SCOPE: covers `ccusage blocks` (billing blocks) and `ccusage session` data
#   only. `/context` is interactive-only and is NOT captured here — see the
#   MANUAL CAPTURE section in the living-tracker doc for the `/context`
#   procedure.
#
#   READ-ONLY: this script never writes files, creates issues, posts comments,
#   or mutates any state. It is safe to run anywhere, including inside /wrap.
#
# USAGE:
#   ccusage-baseline.sh [--json] [--recent] [--since YYYYMMDD] [--help]
#
#   --json         Emit a single compact JSON object on stdout (default: human-
#                  readable text summary).
#   --recent       Show only the last 3 days of billing blocks (default: all).
#   --since <date> Filter blocks from date (YYYYMMDD). Mutually exclusive with
#                  --recent.
#   --help | -h    Print this help and exit 0.
#
# OUTPUT (human-readable default):
#   A short text summary with the active block's spend / token counts and a
#   recent-block rolling total. Safe to read in a terminal.
#
# OUTPUT (--json):
#   A single JSON object:
#   {
#     "ccusage_version": "<string>",
#     "generated_at": "<ISO-8601>",
#     "active_block": { <block object from ccusage> | null },
#     "recent_blocks": [ <block objects> ],
#     "recent_total_cost_usd": <number>,
#     "recent_total_tokens": <number>
#   }
#
# EXIT CODES:
#   0  Success — data captured and emitted
#   1  Clean run with no billing-block data (ccusage returned empty blocks)
#   2  Usage error (unknown flag or conflicting options)
#   3  ccusage not found or environment error (PATH or npx unavailable)
#   4  ccusage invocation failed (network, auth, or parse error)
#
# CCUSAGE DETECTION (in order):
#   1. ccusage binary on PATH
#   2. /opt/homebrew/bin/ccusage
#   3. /opt/homebrew/bin/npx ccusage@latest  (installs on first run via npx cache)
#   Graceful degradation: if none resolves, exits 3 with a clear error + doc note.
#
# EXAMPLES:
#   .claude/scripts/ccusage-baseline.sh
#   .claude/scripts/ccusage-baseline.sh --json
#   .claude/scripts/ccusage-baseline.sh --recent --json
#   .claude/scripts/ccusage-baseline.sh --since 20260801 --json \
#     | jq '.recent_total_cost_usd'
#
# DEPENDENCIES:
#   ccusage (via PATH, Homebrew, or npx); jq; bash 3.2+.

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

err() {
  printf 'ccusage-baseline.sh: %s\n' "$1" >&2
}

# ---- defaults ----------------------------------------------------------------
AS_JSON=0
RECENT=0
SINCE=""

# ---- flag parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --json)         AS_JSON=1 ;;
    --recent)       RECENT=1 ;;
    --since=*)      SINCE="${1#*=}" ;;
    --since)        shift; [ $# -gt 0 ] || { err "--since requires a value"; exit 2; }; SINCE="$1" ;;
    --help|-h)      print_help; exit 0 ;;
    *)              err "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

if [ "$RECENT" -eq 1 ] && [ -n "$SINCE" ]; then
  err "--recent and --since are mutually exclusive"
  exit 2
fi

# ---- locate ccusage ----------------------------------------------------------
# CCUSAGE_BIN env var: if explicitly set (even to ""), overrides detection.
# Set to "" in tests to simulate ccusage-absent environments.
CCUSAGE_CMD=""
if [ "${CCUSAGE_BIN+set}" = "set" ]; then
  # Caller explicitly set it; may be empty string (= not found)
  CCUSAGE_CMD="${CCUSAGE_BIN}"
elif command -v ccusage >/dev/null 2>&1; then
  CCUSAGE_CMD="ccusage"
elif [ -x "/opt/homebrew/bin/ccusage" ]; then
  CCUSAGE_CMD="/opt/homebrew/bin/ccusage"
elif [ -x "/opt/homebrew/bin/npx" ]; then
  CCUSAGE_CMD="/opt/homebrew/bin/npx ccusage@latest"
elif command -v npx >/dev/null 2>&1; then
  CCUSAGE_CMD="npx ccusage@latest"
fi

if [ -z "$CCUSAGE_CMD" ]; then
  err "ccusage is not installed and npx is not available."
  err "Install ccusage: npm install -g ccusage  OR  brew install ccusage"
  err "Alternatively, run the manual /context capture procedure documented in"
  err ".claude/reference/token-measurement-baseline-2026-08.md"
  exit 3
fi

command -v jq >/dev/null 2>&1 || { err "jq is required but not installed"; exit 3; }

# ---- capture ccusage version -------------------------------------------------
CCUSAGE_VERSION=""
RC=0
CCUSAGE_VERSION=$(eval "$CCUSAGE_CMD" --version 2>/dev/null) || RC=$?
case "$RC" in
  0)
    # Strip leading "ccusage " prefix if present ("ccusage 20.0.19" → "20.0.19")
    CCUSAGE_VERSION=$(printf '%s' "$CCUSAGE_VERSION" | head -1 | tr -d '[:space:]')
    CCUSAGE_VERSION="${CCUSAGE_VERSION#ccusage}"
    # Strip any remaining leading whitespace or separator
    CCUSAGE_VERSION="${CCUSAGE_VERSION# }"
    ;;
  *) CCUSAGE_VERSION="unknown" ;;
esac

# ---- build ccusage invocation ------------------------------------------------
BLOCKS_ARGS="blocks --json --no-color"
if [ "$RECENT" -eq 1 ]; then
  BLOCKS_ARGS="$BLOCKS_ARGS --recent"
elif [ -n "$SINCE" ]; then
  # Normalise YYYY-MM-DD to YYYYMMDD (ccusage blocks uses YYYYMMDD format)
  SINCE_NORM="${SINCE//-/}"
  BLOCKS_ARGS="$BLOCKS_ARGS --since $SINCE_NORM"
fi

# ---- invoke ccusage ----------------------------------------------------------
BLOCKS_RAW=""
RC=0
BLOCKS_RAW=$(eval "$CCUSAGE_CMD" $BLOCKS_ARGS 2>&1) || RC=$?

if [ "$RC" -ne 0 ]; then
  err "ccusage invocation failed (exit $RC): $BLOCKS_RAW"
  if [ "$AS_JSON" -eq 1 ]; then
    printf '{"error":"ccusage invocation failed","exit_code":%d}\n' "$RC"
  fi
  exit 4
fi

# Validate JSON
if ! printf '%s' "$BLOCKS_RAW" | jq -e . >/dev/null 2>&1; then
  err "ccusage returned non-JSON output: $(printf '%s' "$BLOCKS_RAW" | head -3)"
  if [ "$AS_JSON" -eq 1 ]; then
    printf '{"error":"ccusage non-JSON output"}\n'
  fi
  exit 4
fi

# ---- extract summary fields --------------------------------------------------
BLOCKS_JSON=$(printf '%s' "$BLOCKS_RAW" | jq -c '.blocks // []' 2>/dev/null) || BLOCKS_JSON='[]'
BLOCK_COUNT=$(printf '%s' "$BLOCKS_JSON" | jq 'length' 2>/dev/null) || BLOCK_COUNT=0

if [ "$BLOCK_COUNT" -eq 0 ]; then
  if [ "$AS_JSON" -eq 1 ]; then
    jq -cn \
      --arg ver "$CCUSAGE_VERSION" \
      --arg ts "$(date -u +%FT%TZ)" \
      '{ccusage_version:$ver,generated_at:$ts,active_block:null,recent_blocks:[],recent_total_cost_usd:0,recent_total_tokens:0}'
  else
    printf 'ccusage-baseline: no billing blocks found in the requested window.\n'
    printf 'Run: %s blocks --help  for filtering options.\n' "$CCUSAGE_CMD"
  fi
  exit 1
fi

ACTIVE_BLOCK=$(printf '%s' "$BLOCKS_JSON" | jq -c '[.[] | select(.isActive == true)] | first // null' 2>/dev/null) || ACTIVE_BLOCK='null'
RECENT_BLOCKS=$(printf '%s' "$BLOCKS_JSON" | jq -c '[.[] | select(.isActive != true)]' 2>/dev/null) || RECENT_BLOCKS='[]'

TOTAL_COST=$(printf '%s' "$BLOCKS_JSON" | \
  jq '[.[] | .costUSD // 0] | add // 0' 2>/dev/null) || TOTAL_COST=0
TOTAL_TOKENS=$(printf '%s' "$BLOCKS_JSON" | \
  jq '[.[] | .totalTokens // 0] | add // 0' 2>/dev/null) || TOTAL_TOKENS=0

# ---- emit output -------------------------------------------------------------
GENERATED_AT=$(date -u +%FT%TZ)

if [ "$AS_JSON" -eq 1 ]; then
  jq -cn \
    --arg ver "$CCUSAGE_VERSION" \
    --arg ts "$GENERATED_AT" \
    --argjson active "$ACTIVE_BLOCK" \
    --argjson recent "$RECENT_BLOCKS" \
    --argjson total_cost "$TOTAL_COST" \
    --argjson total_tokens "$TOTAL_TOKENS" \
    '{
      ccusage_version: $ver,
      generated_at: $ts,
      active_block: $active,
      recent_blocks: $recent,
      recent_total_cost_usd: $total_cost,
      recent_total_tokens: $total_tokens
    }'
else
  # Human-readable summary
  printf '=== ccusage baseline (%s) ===\n' "$GENERATED_AT"
  printf 'ccusage version: %s\n' "$CCUSAGE_VERSION"
  printf 'Billing blocks found: %d\n' "$BLOCK_COUNT"
  printf '\n'

  if [ "$ACTIVE_BLOCK" != 'null' ] && [ -n "$ACTIVE_BLOCK" ]; then
    ACTIVE_COST=$(printf '%s' "$ACTIVE_BLOCK" | jq -r '.costUSD // 0' 2>/dev/null) || ACTIVE_COST=0
    ACTIVE_TOKENS=$(printf '%s' "$ACTIVE_BLOCK" | jq -r '.totalTokens // 0' 2>/dev/null) || ACTIVE_TOKENS=0
    ACTIVE_START=$(printf '%s' "$ACTIVE_BLOCK" | jq -r '.startTime // "unknown"' 2>/dev/null) || ACTIVE_START="unknown"
    printf 'Active block (started %s):\n' "$ACTIVE_START"
    printf '  Cost:    $%.4f USD\n' "$ACTIVE_COST"
    printf '  Tokens:  %s\n' "$ACTIVE_TOKENS"
    printf '\n'
  fi

  printf 'Window total:\n'
  printf '  Cost:    $%.4f USD\n' "$TOTAL_COST"
  printf '  Tokens:  %s\n' "$TOTAL_TOKENS"
  printf '\n'
  printf 'For detailed breakdown: %s blocks --breakdown\n' "$CCUSAGE_CMD"
  printf 'For JSON output:        .claude/scripts/ccusage-baseline.sh --json\n'
  printf '\nNote: /context floor (system prompt + rules + MCP schemas) requires\n'
  printf 'manual capture — see .claude/reference/token-measurement-baseline-2026-08.md\n'
fi

exit 0
