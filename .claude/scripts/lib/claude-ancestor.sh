#!/usr/bin/env bash
# claude-ancestor.sh — sourced library, never executed directly.
#
# claude_ancestor_identity: print `claude=<pid>|start=<lstart>` for the nearest
# ancestor process whose command basename is `claude`, walking up from this
# process's parent. Prints nothing when no such ancestor exists (never a guess).
#
# The start time is part of the identity, so a reused pid cannot match an
# identity recorded for an earlier claude process. Same derivation as
# usage-horizon.sh's claude_ancestor_identity (issue #2300 shares it for the
# session breadcrumb; usage-horizon keeps its own copy until a follow-up).

claude_ancestor_identity() {
  local pid line ppid comm base start depth
  pid="${PPID:-0}"
  depth=0
  while [[ "$depth" -lt 24 ]]; do
    case "$pid" in ''|0|1) return 0 ;; esac
    line="$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)" || line=""
    [[ -n "$line" ]] || return 0
    ppid="$(printf '%s' "$line" | awk '{print $1}')"
    comm="$(printf '%s' "$line" | awk '{$1=""; sub(/^[ \t]+/, ""); print}')"
    base="${comm##*/}"
    if [[ "$base" == "claude" ]]; then
      start="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' || true)"
      printf 'claude=%s|start=%s' "$pid" "$start"
      return 0
    fi
    pid="$ppid"
    depth=$((depth + 1))
  done
  return 0
}
