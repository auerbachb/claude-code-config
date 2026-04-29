#!/usr/bin/env bash
# hhg-state.sh — Extract a 2-letter USPS state code from HHG-formatted text.
#
# PURPOSE
#   Centralizes the state-code extraction contract used by `/wrap` Step 3.2
#   when splitting an HHG follow-up into the two-ticket scraping + ETL pair.
#   The input is the concatenation of the source PR title, linked-issue title,
#   and linked-issue body. The output is the single USPS code best describing
#   which state the HHG work targets, uppercased.
#
#   Extraction is two-pass to keep HHG-adjacent matches beating loose ones:
#     Pass 1 — a state code appearing immediately before or after the literal
#              token "HHG" (e.g. "TX HHG" or "HHG TX"). This wins over any
#              other state code mentioned elsewhere in the text.
#     Pass 2 — fallback. The first state code matched anywhere in the text,
#              only consulted when Pass 1 finds nothing.
#
#   The 50 USPS codes are the whitelist. Unrelated 2-letter tokens that look
#   state-shaped (e.g. "CI", "PR", "TODO" substrings) do not match because
#   they are not in the list. "OK" (Oklahoma) is in the list and will match —
#   that is intentional: this script only runs when the source text already
#   contains "HHG", where "OK" as "okay" is extraordinarily unlikely.
#
# USAGE
#   hhg-state.sh <text>
#   hhg-state.sh --help | -h
#
#   <text> may be a single quoted argument or multiple arguments that will be
#   space-joined. Either form works — callers like `/wrap` concatenate the PR
#   title, issue title, and issue body into a single string before invoking.
#
# OUTPUT
#   stdout: the matched 2-letter USPS state code, uppercased, followed by a
#           newline. Empty (no output) when no state code matches.
#
# EXIT STATUS
#   0  Match found (state code printed on stdout)
#   1  No match (nothing printed)
#   2  Usage error (missing argument, unknown flag)
#
# EXAMPLES
#   # HHG-adjacent match beats unrelated later state reference.
#   hhg-state.sh "TX HHG export carriers; also mentions CA office"
#   # -> TX
#
#   # Fallback: state not adjacent to HHG, picked up on pass 2.
#   hhg-state.sh "HHG follow-up for the Oregon office (OR) — scrape + ETL"
#   # -> OR
#
#   # No match — no USPS code in the text.
#   hhg-state.sh "HHG follow-up for scraper fix"
#   # (no stdout, exit 1)

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

print_help() {
  # Print the header comment block (from shebang's next line until the first
  # blank comment line that terminates it). Mirrors the pattern in
  # reply-thread.sh: skip line 1 (shebang), strip the leading "# " or "#",
  # and stop at the first blank line.
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

# Emit the "missing <text>" usage error and exit 2. Called both before the
# case arm (no args at all) and after it (the `--` end-of-options consumed
# the lone argument, leaving no text behind).
require_text() {
  echo "hhg-state.sh: <text> is required" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# --- arg parsing ---
if [[ $# -eq 0 ]]; then
  require_text
fi

case "$1" in
  -h|--help)
    print_help
    exit 0
    ;;
  --)
    shift
    ;;
  -*)
    echo "hhg-state.sh: unknown flag: $1" >&2
    echo "Run with --help for usage." >&2
    exit 2
    ;;
esac

# Re-check after possible `--` shift — `hhg-state.sh --` leaves no text behind.
if [[ $# -eq 0 ]]; then
  require_text
fi

# Join all positional arguments with spaces. Callers can pass either a single
# pre-concatenated string or multiple tokens — both produce the same input.
TEXT="$*"

# --- state whitelist ---
# 50 USPS state codes, pipe-separated for use inside a grep -E alternation.
# Kept as a single literal so it is trivially auditable against the canonical
# USPS list in the header comment. Omits DC and US territories by design —
# HHG tickets are state-scoped.
US_STATES='AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY'

# --- pass 1: HHG-adjacent ---
# Matches `<STATE> HHG` or `HHG <STATE>` with any horizontal whitespace
# between them. The outer grep captures the whole "<STATE> HHG" / "HHG
# <STATE>" substring; a second grep peels the state code out of that match.
# Case-insensitive on input; uppercased on output via tr.
#
# Word boundaries use POSIX `[[:<:]]` (start-of-word) and `[[:>:]]` (end-of-
# word) instead of `\b`. Both GNU grep and BSD grep (macOS default) support
# these; `\b` is GNU-specific and silently fails to match on strict BSD grep.
STATE=$(printf '%s\n' "$TEXT" \
  | grep -oiE "[[:<:]](${US_STATES})[[:>:]][[:space:]]+HHG|HHG[[:space:]]+[[:<:]](${US_STATES})[[:>:]]" \
  | grep -oiE "[[:<:]](${US_STATES})[[:>:]]" \
  | head -1 \
  | tr '[:lower:]' '[:upper:]' || true)

# --- pass 2: first state code anywhere (fallback) ---
if [[ -z "$STATE" ]]; then
  STATE=$(printf '%s\n' "$TEXT" \
    | grep -oiE "[[:<:]](${US_STATES})[[:>:]]" \
    | head -1 \
    | tr '[:lower:]' '[:upper:]' || true)
fi

if [[ -z "$STATE" ]]; then
  exit 1
fi

printf '%s\n' "$STATE"
exit 0
