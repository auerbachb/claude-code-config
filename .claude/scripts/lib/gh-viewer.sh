#!/usr/bin/env bash
# gh-viewer.sh — look up the authenticated GitHub login with `gh api user` once
# per script chain instead of once per script (issue #2442, slice of #2421).
#
# Nothing is written to disk and no credential is read or handled here: the
# lookup is the same `gh api user --jq .login` call the scripts made before, with
# whatever credentials gh picks by itself. The only sharing is in-memory, from a
# script to the scripts it runs (polling-state-gate.sh -> merge-gate.sh ->
# pr-authorship.sh), through two exported variables:
#   GH_VIEWER_LOGIN_CACHED   the login
#   GH_VIEWER_LOGIN_OWNER    PID of the script that did the live lookup
# The login feeds the authorship check, so an inherited value is trusted only
# when the owner PID names a LIVE ANCESTOR of this process whose command line is
# one of the gate scripts (below). A value exported by hand, or left in an
# interactive shell, names no such ancestor and is ignored: a live lookup runs.
# The check cannot stop someone who deliberately runs inside a gate-script
# process, who could equally swap the credentials gh uses. A failed or odd
# lookup is never exported or reused, and a stale inherited pair is dropped.
#
# Use gh_viewer_resolve, never $(...): a command substitution would lose the
# export. It sets GH_VIEWER_LOGIN (this shell only) and returns 1 on failure.

_GH_VIEWER_RE='^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$'
_GH_VIEWER_SCRIPTS_RE='(polling-state-gate|merge-gate|pr-authorship|escalate-review)\.sh'

# _gh_viewer_owner_valid <pid>: pid is this shell or a live ancestor running a gate script.
_gh_viewer_owner_valid() {
  local want="$1" p="$$" i=0 cmd
  [[ "$want" =~ ^[0-9]+$ && "$want" -gt 1 ]] || return 1
  while [[ "$p" =~ ^[0-9]+$ && "$p" -gt 1 && "$i" -lt 64 ]]; do
    if [[ "$p" == "$want" ]]; then
      cmd="$(ps -o command= -p "$p" 2>/dev/null)" || return 1
      [[ "$cmd" =~ $_GH_VIEWER_SCRIPTS_RE ]]
      return
    fi
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]')"
    i=$((i + 1))
  done
  return 1
}

gh_viewer_resolve() {
  local login="${GH_VIEWER_LOGIN_CACHED:-}"
  GH_VIEWER_LOGIN=""
  if [[ -n "$login" && "$login" =~ $_GH_VIEWER_RE ]] && _gh_viewer_owner_valid "${GH_VIEWER_LOGIN_OWNER:-}"; then
    GH_VIEWER_LOGIN="$login"
    return 0
  fi
  unset GH_VIEWER_LOGIN_CACHED GH_VIEWER_LOGIN_OWNER
  login="$(gh api user --jq '.login' 2>/dev/null || true)"
  [[ -n "$login" && "$login" =~ $_GH_VIEWER_RE ]] || return 1
  GH_VIEWER_LOGIN="$login"
  export GH_VIEWER_LOGIN_CACHED="$login" GH_VIEWER_LOGIN_OWNER="$$"
  return 0
}
