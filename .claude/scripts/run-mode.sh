#!/usr/bin/env bash
# catalog: backlog-pm — Read or set the PM run mode (default|speed|cheap) stored at .repos["<key>"].run_mode
#
# Usage:
#   run-mode.sh [--repo KEY] [--state-helper PATH] get
#   run-mode.sh [--repo KEY] [--state-helper PATH] set <default|speed|cheap>
#   run-mode.sh names
#
# get          Always prints exactly one of: default, speed, cheap. Exit 0 (fail-open).
#              Missing helper, missing state, absent/invalid value, malformed state,
#              or an unresolved / _unknown repo all read as "default".
# set MODE     Exit 2 on an invalid MODE (valid names on stderr; no write).
#              Exit 5 on an unresolved or _unknown repo, or a failed write (no claim of durability).
#              Prints "unchanged <mode>" when the stored value already matches (no write),
#              or "changed <old> <new>" after one targeted session-state.sh --set.
# names        Prints the three valid names, one per line.
# Informational only: this helper never reads or affects pause, park, scope, capacity or deadline gates.
# Full contract: .claude/reference/run-modes.md
set -euo pipefail

MODES=(default speed cheap)

usage() {
  printf '%s\n' 'Usage: run-mode.sh [--repo KEY] [--state-helper PATH] get | set <default|speed|cheap> | names'
}

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="$scripts/session-state.sh"
repo_arg=""

# Parse options anywhere on the line; keep positional words in order.
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      repo_arg="$2"; shift 2 ;;
    --state-helper)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      state="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      positional+=("$1"); shift ;;
  esac
done

verb="${positional[0]:-}"
arg="${positional[1]:-}"
[[ ${#positional[@]} -le 2 ]] || { usage >&2; exit 2; }

is_mode() {
  local m
  for m in "${MODES[@]}"; do
    [[ "$1" == "$m" ]] && return 0
  done
  return 1
}

if [[ "$verb" == names ]]; then
  printf '%s\n' "${MODES[@]}"
  exit 0
fi

case "$verb" in
  get) ;;
  set)
    is_mode "$arg" || {
      printf 'run-mode: invalid mode %s; valid modes are default, speed, cheap\n' "'$arg'" >&2
      exit 2
    }
    ;;
  *) usage >&2; exit 2 ;;
esac

# Resolve the repo key once. Failure leaves key empty (treated as unresolved).
key=""
if [[ -x "$state" || -f "$state" ]]; then
  if [[ -n "$repo_arg" ]]; then
    key=$("$state" --repo "$repo_arg" --repo-key 2>/dev/null) || key=""
  else
    key=$("$state" --repo-key 2>/dev/null) || key=""
  fi
fi
if [[ ! "$key" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]]; then
  key=""
fi

# read_mode sets two globals (no subshell, so both survive):
#   STORED     the stored valid mode, or empty when absent.
#   CONFIRMED  1 when the stored value is known (absent or a valid mode), 0 when the
#              read failed or the value is not a valid mode (not confirmed).
STORED=""
CONFIRMED=0
read_mode() {
  local raw rc=0 mode=""
  STORED=""
  CONFIRMED=0
  if [[ -z "$key" || ! -f "$state" ]]; then
    CONFIRMED=1
    return 0
  fi
  raw=$("$state" --repo "$key" --get-json ".repos[\"$key\"].run_mode" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    3) CONFIRMED=1; return 0 ;;
    *) printf 'run-mode: state unreadable; reading default\n' >&2; return 0 ;;
  esac
  if [[ "$raw" == null ]]; then
    CONFIRMED=1
    return 0
  fi
  mode=$(jq -r 'if type == "string" then . else "" end' <<<"$raw" 2>/dev/null) || mode=""
  if [[ -n "$mode" ]] && is_mode "$mode"; then
    STORED="$mode"
    CONFIRMED=1
  fi
}

read_mode
if [[ "$verb" == get ]]; then
  printf '%s\n' "${STORED:-default}"
  exit 0
fi

# verb == set
if [[ -z "$key" || "$key" == _unknown* ]]; then
  printf 'run-mode: repo unresolved; mode not saved\n' >&2
  exit 5
fi

# Only a confirmed same value skips the write. An unreadable or non-enum stored value
# is not confirmed, so the write runs and the result reports the old value as unknown.
if [[ "$CONFIRMED" -eq 1 && "${STORED:-default}" == "$arg" ]]; then
  printf 'unchanged %s\n' "$arg"
  exit 0
fi
old="unknown"
[[ "$CONFIRMED" -eq 1 ]] && old="${STORED:-default}"

if ! "$state" --repo "$key" --set ".repos[\"$key\"].run_mode=$arg" >/dev/null 2>&1; then
  printf 'run-mode: write failed; mode not saved\n' >&2
  exit 5
fi
printf 'changed %s %s\n' "$old" "$arg"
