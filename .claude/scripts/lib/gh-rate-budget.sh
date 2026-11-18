#!/usr/bin/env bash
# lib/gh-rate-budget.sh — pollers back off by themselves when the GitHub REST
# allowance runs low (issue #2445, slice 5 of 5 of #2421).
#
# Source it (preferred) or run it:
#   gh-rate-budget.sh status              print "remaining=N limit=L reset=E"; exit 1 when unreadable
#   gh-rate-budget.sh interval <secs>     print the interval to use now (== <secs> when nothing is wrong)
#
# From a script:  . lib/gh-rate-budget.sh;  gh_rate_sleep 60
#
# The figure comes only from GitHub: `gh api rate_limit`, which GitHub does not
# charge. Nothing is estimated or counted locally. No token or credential is
# read or handled; the helper only runs `gh`.
#
# Behaviour of gh_rate_interval <base>:
#   remaining >= threshold   -> <base>, silent
#   0 < remaining < threshold -> min(2 x base, cap), one notice per reset window
#   remaining == 0           -> wait until the reset GitHub reported (+2s, capped at
#                               an hour), never less than <base>; one notice
#   unreadable figure        -> <base>, silent (fail open on the figure)
# A rate-limited or failed GitHub response elsewhere is "no data"; this helper
# never turns it into a verdict. Merge paths (merge-gate.sh, /wrap, /merge,
# admin-merge.sh, clean-behind-check.sh) do not use it.
#
# The notice marker and the one-read-per-cycle cache live under
# ~/.claude/gh-rate-budget/ (mode 600, written atomically). Both are safe to lose:
# a lost marker repeats one notice, a lost cache costs one free rate_limit read.
#
# Environment:
#   GH_RATE_LOW_AT=N       threshold (default 300; non-numeric falls back to it)
#   GH_RATE_MAX_INTERVAL=S widening cap in seconds (default 1800)
#   GH_RATE_CACHE_SECS=S   reuse one read for S seconds (default 30; 0 = always read)
#   GH_RATE_SLEEP_CMD=cmd  sleep command for gh_rate_sleep (default sleep; tests inject)
#   GH_RATE_NOW=epoch      test hook: the current time
#   GH_RATE_QUIET=1        suppress the notice (the interval is unchanged)
#   GH_RATE_RESOURCE=r     which allowance to read: core (REST, default) or graphql —
#                          a poller whose calls are GraphQL (gh issue view, gh pr view)
#                          sets graphql; anything else falls back to core

_GH_RATE_DEFAULT_LOW=300
_GH_RATE_DEFAULT_CAP=1800
_GH_RATE_DEFAULT_CACHE=30
_GH_RATE_MAX_WAIT=3600

_gh_rate_resource() {
  case "${GH_RATE_RESOURCE:-core}" in graphql) printf graphql ;; *) printf core ;; esac
}

_gh_rate_label() { if [ "$(_gh_rate_resource)" = graphql ]; then printf GraphQL; else printf REST; fi; }

_gh_rate_is_uint() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

_gh_rate_now() {
  if _gh_rate_is_uint "${GH_RATE_NOW:-}"; then printf '%s' "$GH_RATE_NOW"; else date +%s; fi
}

_gh_rate_dir() {
  [ -n "${HOME:-}" ] || return 1
  printf '%s' "$HOME/.claude/gh-rate-budget"
}

# Atomically write one line to <dir>/<name>, mode 600. Returns non-zero on any failure.
_gh_rate_write() {
  local name="$1" line="$2" dir tmp
  dir=$(_gh_rate_dir) || return 1
  (umask 077 && mkdir -p "$dir") 2>/dev/null || return 1
  tmp=$(umask 077 && mktemp "$dir/.${name}.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$line" >"$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$name" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# gh_rate_read — set GH_RATE_REMAINING / GH_RATE_LIMIT / GH_RATE_RESET from GitHub.
# Returns 1 (and sets nothing) when the figure is unreadable.
gh_rate_read() {
  GH_RATE_REMAINING="" GH_RATE_LIMIT="" GH_RATE_RESET=""
  local now ttl dir fetched rem lim rst line res
  res=$(_gh_rate_resource)
  now=$(_gh_rate_now)
  ttl="${GH_RATE_CACHE_SECS:-$_GH_RATE_DEFAULT_CACHE}"
  _gh_rate_is_uint "$ttl" || ttl=$_GH_RATE_DEFAULT_CACHE
  if [ "$ttl" -gt 0 ] && dir=$(_gh_rate_dir) && [ -r "$dir/cache-$res" ]; then
    read -r fetched rem lim rst <"$dir/cache-$res" 2>/dev/null || true
    if _gh_rate_is_uint "$fetched" && _gh_rate_is_uint "$rem" && _gh_rate_is_uint "$lim" && _gh_rate_is_uint "$rst" \
      && [ "$fetched" -le "$now" ] && [ $((now - fetched)) -lt "$ttl" ]; then
      GH_RATE_REMAINING=$rem GH_RATE_LIMIT=$lim GH_RATE_RESET=$rst
      return 0
    fi
  fi
  command -v gh >/dev/null 2>&1 || return 1
  line=$(gh api rate_limit --jq ".resources.$res | [.remaining, .limit, .reset] | @tsv" 2>/dev/null) || return 1
  read -r rem lim rst <<EOF
$line
EOF
  _gh_rate_is_uint "$rem" && _gh_rate_is_uint "$lim" && _gh_rate_is_uint "$rst" || return 1
  GH_RATE_REMAINING=$rem GH_RATE_LIMIT=$lim GH_RATE_RESET=$rst
  _gh_rate_write "cache-$res" "$now $rem $lim $rst" || true
  return 0
}

# Print the notice once per (reset window, level). Silent when the marker cannot be written.
_gh_rate_announce() {
  local level="$1" text="$2" key dir seen
  [ "${GH_RATE_QUIET:-}" = "1" ] && return 0
  key="$(_gh_rate_resource) $GH_RATE_RESET $level"
  if dir=$(_gh_rate_dir) && [ -r "$dir/announced" ]; then
    seen=$(cat "$dir/announced" 2>/dev/null) || seen=""
    [ "$seen" = "$key" ] && return 0
  fi
  _gh_rate_write announced "$key" || return 0
  printf 'gh-rate-budget: %s\n' "$text" >&2
}

# gh_rate_interval <base-secs> — print the interval to use now.
gh_rate_interval() {
  local base="${1:-}" low cap now wait wide mins
  _gh_rate_is_uint "$base" && [ "$base" -gt 0 ] || return 2
  if ! gh_rate_read; then printf '%s\n' "$base"; return 0; fi
  low="${GH_RATE_LOW_AT:-$_GH_RATE_DEFAULT_LOW}"
  _gh_rate_is_uint "$low" || low=$_GH_RATE_DEFAULT_LOW
  cap="${GH_RATE_MAX_INTERVAL:-$_GH_RATE_DEFAULT_CAP}"
  _gh_rate_is_uint "$cap" || cap=$_GH_RATE_DEFAULT_CAP
  now=$(_gh_rate_now)
  if [ "$GH_RATE_REMAINING" -ge "$low" ]; then
    printf '%s\n' "$base"
    return 0
  fi
  if [ "$GH_RATE_REMAINING" -eq 0 ]; then
    wait=$((GH_RATE_RESET - now + 2))
    [ "$wait" -le "$_GH_RATE_MAX_WAIT" ] || wait=$_GH_RATE_MAX_WAIT
    if [ "$wait" -le "$base" ]; then printf '%s\n' "$base"; return 0; fi
    mins=$(((wait + 59) / 60))
    _gh_rate_announce zero "GitHub $(_gh_rate_label) allowance is used up ($GH_RATE_LIMIT per hour); waiting about $mins min for the reset instead of failing every call."
    printf '%s\n' "$wait"
    return 0
  fi
  wide=$((base * 2))
  [ "$wide" -le "$cap" ] || wide=$cap
  [ "$wide" -ge "$base" ] || wide=$base
  mins=$(((GH_RATE_RESET - now + 59) / 60))
  [ "$mins" -ge 0 ] || mins=0
  _gh_rate_announce low "GitHub $(_gh_rate_label) allowance is low ($GH_RATE_REMAINING of $GH_RATE_LIMIT left, resets in about $mins min); polling every $wide s instead of $base s until then."
  printf '%s\n' "$wide"
}

# gh_rate_sleep <base-secs> [max-secs] — sleep for gh_rate_interval (normal interval if
# it fails), never longer than max-secs when given (a caller with a deadline).
gh_rate_sleep() {
  local secs
  secs=$(gh_rate_interval "$1") || secs="$1"
  if _gh_rate_is_uint "${2:-}" && [ "$secs" -gt "$2" ]; then secs=$2; fi
  ${GH_RATE_SLEEP_CMD:-sleep} "$secs"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    status)
      if gh_rate_read; then
        printf 'remaining=%s limit=%s reset=%s\n' "$GH_RATE_REMAINING" "$GH_RATE_LIMIT" "$GH_RATE_RESET"
      else
        exit 1
      fi
      ;;
    interval) gh_rate_interval "${2:-}" ;;
    *) echo "usage: gh-rate-budget.sh status | interval <secs>" >&2; exit 2 ;;
  esac
fi
