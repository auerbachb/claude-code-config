#!/usr/bin/env bash
# state-lock-sweep.sh — inventory or remove leftover state-lock aside directories.
# catalog: session-state-locking — Inventory (default) or remove leftover `<state>.lock.rel.*` / `.lock.stale.*` lock-aside directories (issue #2402)
#
# PURPOSE
#   Releasing or breaking a state lock renames it aside and then deletes it.
#   A process killed between those two steps leaves the aside directory
#   behind forever (issue #2402 found 25 next to session-state.json). An aside
#   is no longer a lock — nothing reads it — so this removes the provably
#   safe ones. Selection and safety rules: state_lock_sweep_asides in
#   state-lock.sh, and .claude/reference/state-file-contracts.md §Lock asides.
#
# USAGE
#   state-lock-sweep.sh [--apply] [--state-file PATH]... [--grace-seconds N]
#                       [--max N] [--quiet]
#
#   (default)          Inventory only: lists each candidate as removable or
#                      retained (with the reason). Deletes nothing.
#   --apply            Remove the removable candidates.
#   --state-file PATH  A lock scope to sweep; repeatable (for example a
#                      handoff file). Default ~/.claude/session-state.json.
#   --grace-seconds N  Minimum aside age before removal (default 3600).
#   --max N            Candidates examined per scope (default 500); the rest
#                      are counted unexamined (one summary line), never zero.
#   --quiet            Print nothing when a scope has no candidates.
#   --help | -h
#
# OUTPUT
#   One `<outcome>\t<reason>\t<path>` line per examined candidate, one
#   `unexamined` summary line when --max was hit, then one
#   `totals\tremoved=N removable=N retained=N failed=N unexamined=N\t<state-file>`
#   line per scope.
#
# EXIT
#   0  done (retained candidates are not an error)
#   1  at least one removal failed
#   2  usage error, or state-lock.sh unavailable

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "state-lock-sweep.sh: $1" >&2; exit 2; }

MODE=inventory; GRACE=3600; MAX=500; QUIET=0
FILES=()
while (( $# > 0 )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --apply) MODE=apply ;;
    --quiet) QUIET=1 ;;
    --state-file|--grace-seconds|--max)
      (( $# >= 2 )) || die "$1 requires a value"
      case "$1" in
        --state-file) [[ -n "$2" ]] || die "empty --state-file"; FILES+=("$2") ;;
        --grace-seconds) [[ "$2" =~ ^[0-9]{1,9}$ ]] || die "--grace-seconds must be an integer 0-999999999"; GRACE="$2" ;;
        --max) [[ "$2" =~ ^[0-9]{1,9}$ ]] || die "--max must be an integer 0-999999999"; MAX="$2" ;;
      esac
      shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if (( ${#FILES[@]} == 0 )); then
  [[ -n "${HOME:-}" ]] || die "HOME is unset and no --state-file was given"
  FILES=("$HOME/.claude/session-state.json")
fi

[[ -f "$SCRIPT_DIR/state-lock.sh" ]] || die "state-lock.sh unavailable"
# shellcheck source=state-lock.sh
source "$SCRIPT_DIR/state-lock.sh"

RC=0
for f in "${FILES[@]}"; do
  rc=0
  out="$(state_lock_sweep_asides "$f" "$MODE" "$GRACE" "$MAX")" || rc=$?
  (( rc == 2 )) && exit 2
  (( rc == 0 )) || RC=1
  if (( QUIET )) && [[ "$(printf '%s\n' "$out" | grep -vc '^totals')" == 0 ]]; then
    continue
  fi
  printf '%s\n' "$out"
done
exit "$RC"
