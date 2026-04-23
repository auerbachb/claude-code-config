#!/usr/bin/env bash
# pr-issue-ref.sh — Extract the linked issue number from a PR body.
#
# Scans the PR body for `Closes #N` / `Fixes #N` / `Resolves #N`
# (case-insensitive, optional whitespace between keyword and `#`) and prints
# the first matching issue number on stdout. Prints nothing when no match
# is found.
#
# USAGE:
#   pr-issue-ref.sh <pr_number>
#   pr-issue-ref.sh --help | -h
#
# OUTPUT:
#   Issue number on stdout when found. Empty stdout when no match.
#
# EXIT CODES:
#   0    issue reference found (number on stdout)
#   1    no issue reference found (stdout empty)
#   2    usage error (missing/invalid args, unknown flag)
#   3    PR not found
#   4    gh / GitHub API error
#
# DEPENDENCIES:
#   - gh (authenticated)
#
# EXAMPLES:
#   pr-issue-ref.sh 290         # → "271" (or empty if no link)
#   ISSUE=$(pr-issue-ref.sh "$PR" || true)

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: pr-issue-ref.sh <pr_number>
       pr-issue-ref.sh --help | -h

Extract the first linked issue number from a PR body. Matches
`Closes #N`, `Fixes #N`, `Resolves #N` (case-insensitive, optional
whitespace between keyword and `#`).

Exit codes:
  0  issue reference found (number on stdout)
  1  no issue reference found (stdout empty)
  2  usage error
  3  PR not found
  4  gh / GitHub API error
EOF
}

# --- arg parsing ---
PR_NUM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown flag: $1" >&2
      print_usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUM" ]]; then
        echo "Error: unexpected positional argument: $1" >&2
        print_usage >&2
        exit 2
      fi
      PR_NUM="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUM" ]]; then
  echo "Error: <pr_number> is required" >&2
  print_usage >&2
  exit 2
fi

if ! [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: <pr_number> must be a positive integer, got: $PR_NUM" >&2
  exit 2
fi

# --- dependency check ---
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: 'gh' CLI not found on PATH" >&2
  exit 4
fi

# --- fetch PR body ---
# Distinguish "PR not found" (exit 3) from generic gh errors (exit 4) by
# inspecting stderr, matching the convention in cycle-count.sh and friends.
GH_STDERR="$(mktemp)"
trap 'rm -f "$GH_STDERR"' EXIT

if ! BODY="$(gh pr view "$PR_NUM" --json body --jq '.body // ""' 2>"$GH_STDERR")"; then
  if grep -qiE 'not.?found|could not resolve|no pull requests? found' "$GH_STDERR"; then
    echo "Error: PR #$PR_NUM not found" >&2
    exit 3
  fi
  sed 's/^/gh: /' "$GH_STDERR" >&2
  echo "Error: gh pr view failed for PR #$PR_NUM" >&2
  exit 4
fi

# --- extract issue number ---
# Match `(closes|fixes|resolves)[whitespace]*#<digits>` case-insensitively.
# `head -1` keeps the first hit; the second grep strips back to just the digits.
MATCH="$(printf '%s\n' "$BODY" | grep -oiE '(closes|fixes|resolves)[[:space:]]*#[0-9]+' | head -1 || true)"
if [[ -z "$MATCH" ]]; then
  exit 1
fi

NUM="$(printf '%s' "$MATCH" | grep -oE '[0-9]+' | head -1)"
if [[ -z "$NUM" ]]; then
  # Defensive: should not happen given the matched pattern includes digits.
  exit 1
fi

printf '%s\n' "$NUM"
