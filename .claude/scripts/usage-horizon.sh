#!/usr/bin/env bash
# usage-horizon.sh — Compatibility shim: the in-thread context figure is not a launch input (issue #2416).
# catalog: token-measurement — Always answers clear; the in-thread tokens-left figure no longer gates launches or parks a board
#
# PURPOSE
#   This script used to turn the harness-printed `<total_tokens>N tokens left`
#   figure into a `clear` / `approaching` / `critical` / `unknown` verdict that
#   held launches and parked boards ahead of time (#1427, #1619, #1428). The
#   figure is not the account's usage: it counts down a per-message budget or
#   the conversation's own context window (#2376, #2390). The owner does not
#   manage a thread's context window and the app compacts conversations by
#   itself, so no launch or park decision reads the figure any more (#2416).
#   Evidence: `.claude/reference/usage-horizon-desktop-investigation-2026-11.md`.
#
#   The script remains only so callers that still invoke it keep working. It
#   reads nothing, records nothing, estimates nothing, and answers `clear`.
#
#   What still gates autonomous work, untouched by this change:
#     - the weekly reserve         quota-reserve.sh   (provider-reported %)
#     - the daily budget           credit-budget.sh
#     - the REACTIVE usage-limit park, fired when the provider returns a limit
#   Safety rule: `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority".
#
# USAGE
#   usage-horizon.sh --observe <remaining> [--limit <total>] [--session <id>]
#   usage-horizon.sh --check [--session <id>] [--counter-never-seen]
#   usage-horizon.sh --help | -h
#
# MODES
#   --observe <remaining>   Accepted and ignored: nothing is recorded.
#   --check                 Answers clear.
#   The flags --limit, --session and --counter-never-seen are accepted for
#   compatibility and have no effect.
#
# OUTPUT
#   stdout: exactly two lines —
#             STATUS=clear
#             REASON=not-a-launch-input
#
# EXIT STATUS
#   0  clear (always, for a well-formed invocation)
#   4  Usage error (missing/invalid mode, unknown flag, malformed argument)
#   70 --help header extraction produced no output (internal defect).
set -uo pipefail

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "usage-horizon.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 4
}

MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --observe)
      [[ -n "$MODE" ]] && die_usage "only one of --observe, --check may be given"
      [[ $# -lt 2 ]] && die_usage "--observe requires a remaining-token value"
      MODE=observe; shift 2 ;;
    --check)
      [[ -n "$MODE" ]] && die_usage "only one of --observe, --check may be given"
      MODE=check; shift ;;
    --counter-never-seen) shift ;;
    --limit|--session)
      [[ $# -lt 2 ]] && die_usage "$1 requires a value"
      shift 2 ;;
    --) shift; break ;;
    -*) die_usage "unknown flag: $1" ;;
    *) die_usage "unexpected positional argument: $1" ;;
  esac
done
[[ -z "$MODE" ]] && die_usage "one of --observe, --check is required"
[[ $# -gt 0 ]] && die_usage "unexpected argument after --: $1"

printf 'STATUS=clear\nREASON=not-a-launch-input\n'
