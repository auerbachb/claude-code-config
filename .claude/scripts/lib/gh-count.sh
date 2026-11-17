#!/usr/bin/env bash
# lib/gh-count.sh — per-run GitHub REST call count for the review-loop gate scripts (issue #2441).
#
# Sourced by merge-gate.sh, polling-state-gate.sh and escalate-review.sh. Off by
# default: unless GH_REST_COUNT=1 or GH_REST_WARN_AT is set, `gh_count_reexec`
# returns immediately and the caller runs exactly as before (byte-identical
# stdout, stderr and exit code).
#
# When on, the caller is re-run as a child with a counting `gh` shim first on
# PATH. Every script the child starts inherits the shim, so one tally covers the
# whole cycle (polling-state-gate.sh -> merge-gate.sh -> ci-status.sh, ...).
# The shim runs the real gh with GH_DEBUG=api, which makes gh log every HTTP
# request it actually sends — one per page of a --paginate call — together with
# GitHub's own X-RateLimit-Remaining response header. The shim strips that debug
# text from stderr (so scripts that read gh's stderr see what they always saw),
# records one line per request, and passes stdout and the exit code through.
#
# Output (stderr, after the child exits, never altering its exit code):
#   GH_REST_COUNT=1       one line: rest=N graphql=M and GitHub's remaining figures
#   rest > GH_REST_WARN_AT  one warning line (default threshold 60 when counting)
# Below the threshold with GH_REST_COUNT unset, nothing is printed.
# If counting cannot be set up or read, one "unavailable" line is printed and the
# script runs / exits exactly as it would without counting.
#
# REST vs GraphQL: gh api <path> and the REST calls behind `gh api --paginate`
# are REST. `gh pr view`, `gh repo view` and `gh api graphql` are GraphQL, which
# GitHub meters separately; they are tallied apart. /rate_limit is free and is
# not counted.
#
# Environment:
#   GH_REST_COUNT=1       print the count line
#   GH_REST_WARN_AT=N     warn when the REST count exceeds N (a whole number; also enables counting)
#   GH_REST_COUNT_ACTIVE  internal: set in the child so nested scripts add to
#                         the same tally instead of starting their own

_GH_COUNT_DEFAULT_WARN=60

_gh_count_unavailable() {
  printf '%s: GitHub REST call count unavailable (%s)\n' "$(basename "$1")" "$2" >&2
}

# gh_count_reexec <script-path> [args...] — run the script again under the shim
# and exit with its exit code; return (so the caller continues normally) when
# counting is off or cannot be set up.
gh_count_reexec() {
  local self="$1"
  shift
  [ -z "${GH_REST_COUNT_ACTIVE:-}" ] || return 0
  # On only for GH_REST_COUNT=1 or a numeric GH_REST_WARN_AT; GH_REST_COUNT=0 or junk stays off.
  case "${GH_REST_WARN_AT:-}" in '' | *[!0-9]*) _gh_warn_on=0 ;; *) _gh_warn_on=1 ;; esac
  [ "${GH_REST_COUNT:-}" = "1" ] || [ "$_gh_warn_on" = "1" ] || return 0

  local real_gh dir tally warn_at
  real_gh=$(command -v gh 2>/dev/null) || real_gh=""
  if [ -z "$real_gh" ] || [ ! -f "$self" ]; then
    _gh_count_unavailable "$self" "gh or the script path not found"
    return 0
  fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/gh-count.XXXXXX" 2>/dev/null) || dir=""
  if [ -z "$dir" ]; then
    _gh_count_unavailable "$self" "could not create a temp directory"
    return 0
  fi
  tally="$dir/tally"
  if ! : >"$tally" 2>/dev/null || ! _gh_count_write_shim "$dir/gh"; then
    _gh_count_unavailable "$self" "could not write the counting shim"
    rm -f "$dir/tally" "$dir/gh"
    rmdir "$dir" 2>/dev/null
    return 0
  fi

  local rc=0
  GH_REST_COUNT_ACTIVE=1 GH_REST_COUNT_FILE="$tally" GH_REST_COUNT_REAL_GH="$real_gh" \
    PATH="$dir:$PATH" "${BASH:-bash}" "$self" "$@" || rc=$?

  warn_at="${GH_REST_WARN_AT:-$_GH_COUNT_DEFAULT_WARN}"
  _gh_count_report "$self" "$tally" "$warn_at" || _gh_count_unavailable "$self" "tally unreadable"
  rm -f "$dir/tally" "$dir/gh"
  rmdir "$dir" 2>/dev/null
  exit "$rc"
}

# Write the counting gh shim. Kept as a heredoc so the shim is one self-contained file.
_gh_count_write_shim() {
  cat >"$1" <<'SHIM' || return 1
#!/usr/bin/env bash
# Counting gh shim (issue #2441) — see lib/gh-count.sh.
real="${GH_REST_COUNT_REAL_GH:-}"
tally="${GH_REST_COUNT_FILE:-}"
if [ -z "$real" ] || [ -z "$tally" ]; then
  echo "gh shim: counting environment missing" >&2
  exit 127
fi
errf=$(mktemp "${TMPDIR:-/tmp}/gh-count-err.XXXXXX" 2>/dev/null) || {
  # Cannot capture the request log: run gh untouched, but mark the tally incomplete.
  echo "unavailable" >>"$tally" 2>/dev/null
  exec "$real" "$@"
}
rc=0
GH_DEBUG=api "$real" "$@" 2>"$errf" || rc=$?
# gh's request log sits between "* Request at" and "* Request took". Drop it from
# stderr, keep everything else, and record one tally line per request.
awk -v tally="$tally" '
  /^\* Request at / { inreq = 1; url = ""; rem = ""; next }
  inreq && /^\* Request to / { url = $4; next }
  inreq && tolower($0) ~ /^< x-ratelimit-remaining:/ { rem = $3; sub(/\r$/, "", rem); next }
  inreq && /^\* Request took / { record(); inreq = 0; next }
  inreq { next }
  { print }
  function record(   kind) {
    if (url ~ /\/rate_limit$/) return
    kind = (url ~ /\/graphql$/) ? "graphql" : "rest"
    print kind, (rem == "" ? "-" : rem) >> tally
  }
  END { if (inreq) record() }
' "$errf" >&2 || echo "unavailable" >>"$tally" 2>/dev/null
rm -f "$errf"
exit "$rc"
SHIM
  chmod +x "$1"
}

_gh_count_report() {
  local self="$1" tally="$2" warn_at="$3" line rest graphql first last
  [ -r "$tally" ] || return 1
  # A call that could not be counted makes the figure a lower bound; say so, never print it as exact.
  if grep -q '^unavailable' "$tally"; then return 1; fi
  line=$(awk '
    $1 == "rest" { rest++; if ($2 != "-") { if (first == "") first = $2; last = $2 } }
    $1 == "graphql" { gql++ }
    END { printf "%d %d %s %s", rest, gql, (first == "" ? "-" : first), (last == "" ? "-" : last) }
  ' "$tally") || return 1
  set -- $line
  rest="$1" graphql="$2" first="$3" last="$4"
  case "$rest$graphql" in *[!0-9]*) return 1 ;; esac
  case "$warn_at" in '' | *[!0-9]*) warn_at=$_GH_COUNT_DEFAULT_WARN ;; esac
  if [ "${GH_REST_COUNT:-}" = "1" ]; then
    printf '%s: gh-count rest=%s graphql=%s (GitHub X-RateLimit-Remaining first=%s last=%s)\n' \
      "$(basename "$self")" "$rest" "$graphql" "$first" "$last" >&2
  fi
  if [ "$rest" -gt "$warn_at" ]; then
    printf '%s: WARNING this run made %s GitHub REST calls (threshold %s; the hourly allowance is 5000 and shared by every agent)\n' \
      "$(basename "$self")" "$rest" "$warn_at" >&2
  fi
  return 0
}
