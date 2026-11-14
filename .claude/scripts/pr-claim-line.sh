#!/usr/bin/env bash
# pr-claim-line.sh — Print the hidden claim-holder line a PR body carries (issue #2288).
# catalog: pr-state-polling — Print the hidden `claim-holder` line that ties a PR body to the issue claim it was built under (pr-claim-check.sh compares it)
#
# PURPOSE
#   pr-claim-check.sh (the PR-side gate) compares the holder of each linked
#   issue's winning claim with the holder a PR body names. This script prints
#   that one line so every PR-creation path writes the same shape:
#
#       <!-- claim-holder: h-<12 lowercase hex> -->
#
#   The value is NOT the raw holder token. Older tokens embed a hostname and a
#   checkout path, and a PR body is public. The value is the first 12 hex
#   characters of the SHA-256 of the raw holder string, prefixed `h-`. A raw
#   holder already shaped `h-<12 hex>` (the issue #2284 default) passes through
#   unchanged, so both forms agree with issue-claim.sh.
#
# HOLDER SOURCE ORDER
#   --holder TOKEN  ->  $CLAUDE_CLAIM_HOLDER  ->  the session-state record
#   .repos["<repo key>"].pipelines["<ISSUE>"].claim_holder (null, empty or
#   "_unknown" means absent)  ->  the default holder issue-claim.sh computes
#   (h-<digest of hostname:git toplevel>, the same formula as issue-claim.sh's
#   resolve_holder).
#
# FAIL-CLOSED
#   No SHA-256 tool (shasum or sha256sum) -> exit 1 with a message. A weak hash
#   is never substituted: a collision would let one checkout read as another.
#
# USAGE
#   pr-claim-line.sh <ISSUE> [--holder TOKEN]
#   pr-claim-line.sh --help | -h
#
# EXIT STATUS
#   0  line printed          1  no SHA-256 tool / holder unresolvable
#   2  usage error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: pr-claim-line.sh <ISSUE> [--holder TOKEN]
       pr-claim-line.sh --help | -h

Prints one line for a PR body:
  <!-- claim-holder: h-<12 hex> -->

--holder TOKEN   Raw holder token to hash (overrides the environment and the
                 session-state record). Passed through unhashed only when it is
                 already shaped h-<12 lowercase hex>.
USAGE
}

usage_err() {
  echo "pr-claim-line.sh: $1" >&2
  usage >&2
  exit 2
}

ISSUE=""
HOLDER_ARG=""
HOLDER_GIVEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --holder)
      [[ $# -ge 2 ]] || usage_err "--holder needs a value"
      HOLDER_ARG="$2"; HOLDER_GIVEN=1; shift 2 ;;
    --holder=*) HOLDER_ARG="${1#--holder=}"; HOLDER_GIVEN=1; shift ;;
    -*) usage_err "unknown flag: $1" ;;
    *)
      [[ -z "$ISSUE" ]] || usage_err "unexpected extra argument: $1"
      ISSUE="$1"; shift ;;
  esac
done

[[ -n "$ISSUE" ]] || usage_err "missing issue number"
[[ "$ISSUE" =~ ^[1-9][0-9]*$ ]] || usage_err "issue number must be a positive integer"
if [[ "$HOLDER_GIVEN" -eq 1 && -z "$HOLDER_ARG" ]]; then
  usage_err "--holder must not be empty"
fi

# digest_hex <text> <n>: first n hex chars of a SHA-256. Fails closed (see header).
digest_hex() {
  local d=""
  if command -v shasum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-64)"
  elif command -v sha256sum >/dev/null 2>&1; then
    d="$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-64)"
  fi
  if [[ -z "$d" ]]; then
    echo "pr-claim-line.sh: no shasum or sha256sum found; cannot derive a claim-holder value (pass --holder with a value already shaped h-<12 hex>)" >&2
    return 1
  fi
  printf '%s' "${d:0:$2}"
}

# session_holder: the raw holder recorded for this issue by /subagent, or nothing.
session_holder() {
  local ss="$SCRIPT_DIR/session-state.sh" key v
  [[ -x "$ss" ]] || return 0
  key="$("$ss" --repo-key 2>/dev/null)" || return 0
  key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$key" ]] || return 0
  v="$("$ss" --get ".repos[\"$key\"].pipelines[\"$ISSUE\"].claim_holder" 2>/dev/null)" || return 0
  case "$v" in
    ""|null|_unknown) return 0 ;;
  esac
  printf '%s' "$v"
}

# default_raw_holder: the same default issue-claim.sh's resolve_holder computes.
default_raw_holder() {
  local host top
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host)"
  top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf '%s:%s' "$host" "$top"
}

RAW=""
if [[ "$HOLDER_GIVEN" -eq 1 ]]; then
  RAW="$HOLDER_ARG"
elif [[ -n "${CLAUDE_CLAIM_HOLDER:-}" ]]; then
  RAW="$CLAUDE_CLAIM_HOLDER"
else
  RAW="$(session_holder)"
fi

if [[ -n "$RAW" ]]; then
  if [[ "$RAW" =~ ^h-[0-9a-f]{12}$ ]]; then
    VALUE="$RAW"
  else
    d="$(digest_hex "$RAW" 12)" || exit 1
    VALUE="h-$d"
  fi
else
  # The default is a digest of the checkout's host and path (issue #2284). Its
  # result is already shaped h-<12 hex>, so it is never hashed a second time.
  d="$(digest_hex "$(default_raw_holder)" 12)" || exit 1
  VALUE="h-$d"
fi

printf '<!-- claim-holder: %s -->\n' "$VALUE"
