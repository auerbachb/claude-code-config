#!/usr/bin/env bash
# pr-snapshot.sh — one short-lived, fail-closed per-PR snapshot of the GitHub
# reads that merge-gate.sh, pr-state.sh (and so escalate-review.sh),
# check-runs-snapshot.sh (and so ci-status.sh) and reviewer-of.sh each used to
# repeat inside one poll cycle: the reviews, the inline comments, the
# conversation comments, the commit statuses, the HEAD commit, and the enriched
# check-run list (issue #2444, slice 4 of #2421).
#
# It is built on lib/slow-read-cache.sh (same store, same envelope, same
# viewer/host helpers, atomic mode-600 writes under ~/.claude/slow-read-cache/,
# an older read never replaces a newer entry). These reads feed the merge gate,
# which decides whether unreviewed code merges, so every doubt is a live read:
#   - a missing, expired, wrong-host/repo/PR/viewer, wrong-HEAD, unreadable,
#     corrupt, partial or odd-shaped entry is a live read;
#   - a failed, rate-limited, partially decoded or truncated read is never
#     stored; a list is stored only from a complete successful read (exit 0, at
#     least one page, every page an array, every item an object with its id);
#   - an empty list of check-runs is never stored (a commit whose checks have not
#     started reads empty for a moment); the other lists may be empty;
#   - a failed write changes neither output nor exit code.
#
# Key: host (GH_HOST, github.com when unset), repo (lowercased), PR number, HEAD
# SHA, signed-in login. The caller passes the HEAD SHA it just read live; a live
# fetch is stored only when HEAD, read again after the fetch finished, is still
# that SHA (one GraphQL call, metered apart from the REST allowance). A hit is
# therefore never used across a HEAD change.
#
# Lifetime: PR_SNAPSHOT_TTL seconds, clamped in code to at most 60 (non-numeric
# -> 60, 0 -> sharing off and not one extra call). SLOW_READ_CACHE_TTL=0 turns it
# off too, so every path that already forces live reads with that switch
# (admin-merge.sh, clean-behind-check.sh) gets live snapshot reads as well. Age is
# counted from when the live read STARTED.
#
# New data: a review, comment, status or check-run that appears after a read
# started is seen by the first live read after that entry expires: at most 60s
# later. The unresolved-thread list, mergeStateStatus, mergeable, reviewDecision
# and HEAD itself are read live every run and are not part of the snapshot, so a
# new bot finding (an inline thread) or a new human CHANGES_REQUESTED on the
# required-review rule shows up in what the gate reads live at once.
#
# A hit is returned as ONE JSON array; a live read is returned exactly as gh
# printed it (a stream of pages). Every consumer folds both with `jq -s 'add'`
# (or a keyed variant of it), which gives the same array.
#
# No token or credential is read, passed, keyed on or stored here; the login
# comes from lib/gh-viewer.sh, exactly as in slow-read-cache.sh.
#
# If-None-Match is NOT used: a 304 needs the stored ETag and the full body kept
# beside it, plus a per-page story for paginated lists (an ETag covers one page),
# and the gain over sharing inside the cycle is small.

_PS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slow-read-cache.sh
. "$_PS_LIB_DIR/slow-read-cache.sh" || return 1

_PS_ON=0
_PS_REPO=""
_PS_PR=""
_PS_HEAD=""
_PS_VIEWER=""

# pr_snap_init <owner/repo> <pr> <head-sha>
# Call from the MAIN shell, not inside $( ): the login lookup exports its result.
# Leaves sharing off, and makes no call, when disabled or on any doubt.
pr_snap_init() {
  _PS_ON=0 _PS_REPO="" _PS_PR="" _PS_HEAD="" _PS_VIEWER=""
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "${2:-}" =~ ^[0-9]+$ && "${3:-}" =~ ^[0-9a-f]{40}$ ]] || return 0
  slow_cache_enabled pr-reviews || return 0
  slow_cache_viewer || return 0
  _PS_REPO="$1" _PS_PR="$2" _PS_HEAD="$3" _PS_VIEWER="$SLOW_CACHE_VIEWER" _PS_ON=1
  return 0
}

# _ps_valid <kind> <json> -> 0 when the payload has the shape the live read gives.
_ps_valid() {
  local kind="$1" json="$2"
  case "$kind" in
    pr-reviews | pr-comments | pr-issue-comments)
      printf '%s' "$json" | jq -e 'type == "array" and all(.[]; type == "object" and (.id | type) == "number")' >/dev/null 2>&1 ;;
    pr-statuses)
      printf '%s' "$json" | jq -e 'type == "array" and all(.[]; type == "object" and (.id | type) == "number" and (.context | type) == "string")' >/dev/null 2>&1 ;;
    pr-check-runs)
      # check_run_workflows.py also emits id-less entries it builds itself (a
      # queued workflow with no check yet, a pending replacement): those carry
      # id null AND one of its two markers; anything else without a numeric id is odd.
      printf '%s' "$json" | jq -e 'type == "array" and length > 0 and all(.[]; type == "object" and (.name | type) == "string"
        and ((.id | type) == "number" or (.id == null and (._workflow_inventory == true or ._superseded_check_pending == true))))' >/dev/null 2>&1 ;;
    pr-head-commit)
      printf '%s' "$json" | jq -e --arg h "$_PS_HEAD" 'type == "object" and .sha == $h' >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# _ps_head_now -> prints the PR's current HEAD SHA (one GraphQL call).
_ps_head_now() {
  local oid
  oid="$(gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){headRefOid}}}' \
    -f o="${_PS_REPO%%/*}" -f r="${_PS_REPO#*/}" -F n="$_PS_PR" \
    --jq '.data.repository.pullRequest.headRefOid' 2>/dev/null)" || return 1
  [[ "$oid" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$oid"
}

# pr_snap_get <kind> -> prints the stored payload; 0 hit, 1 miss.
pr_snap_get() {
  local kind="$1" val
  (( _PS_ON == 1 )) || return 1
  val="$(slow_cache_get "$kind" "$_PS_REPO" "pr$_PS_PR" "$_PS_HEAD" "$_PS_VIEWER")" || return 1
  [[ -n "$val" ]] && _ps_valid "$kind" "$val" || return 1
  printf '%s' "$val"
}

# pr_snap_put <kind> <json> <read_started_epoch> -> 0 stored. Never prints.
pr_snap_put() {
  local kind="$1" json="$2" started="$3" now_head dir
  (( _PS_ON == 1 )) || return 1
  _ps_valid "$kind" "$json" || return 1
  now_head="$(_ps_head_now)" || return 1
  [[ "$now_head" == "$_PS_HEAD" ]] || return 1
  slow_cache_put "$kind" "$_PS_REPO" "pr$_PS_PR" "$_PS_HEAD" "$_PS_VIEWER" "$json" "$started" || return 1
  # Keep the store small: drop snapshot files nobody has written for ten minutes.
  dir="$(slow_cache_dir)"
  find "$dir" -maxdepth 1 -type f -name '*__pr-*.json' -mmin +10 -exec rm -f {} + 2>/dev/null
  return 0
}

# pr_snap_list <reviews|comments|issue-comments|statuses> <endpoint>
# Paginated list read: the stdout, stderr and exit code of `gh api --paginate`.
pr_snap_list() {
  local kind="pr-$1" endpoint="$2" out rc=0 started norm
  if (( _PS_ON == 1 )) && out="$(pr_snap_get "$kind")"; then
    printf '%s\n' "$out"
    return 0
  fi
  started="$(date +%s)"
  out="$(gh api --paginate "$endpoint")" || rc=$?
  if (( rc == 0 && _PS_ON == 1 )); then
    norm="$(printf '%s' "$out" | jq -sc 'if length > 0 and all(.[]; type == "array") then add else error("bad pages") end' 2>/dev/null)" \
      && pr_snap_put "$kind" "$norm" "$started" || true
  fi
  [[ -z "$out" ]] || printf '%s\n' "$out"
  return "$rc"
}

# pr_snap_object head-commit <endpoint>
# Single-object read: the stdout, stderr and exit code of `gh api`.
pr_snap_object() {
  local kind="pr-$1" endpoint="$2" out rc=0 started norm
  if (( _PS_ON == 1 )) && out="$(pr_snap_get "$kind")"; then
    printf '%s\n' "$out"
    return 0
  fi
  started="$(date +%s)"
  out="$(gh api "$endpoint")" || rc=$?
  if (( rc == 0 && _PS_ON == 1 )); then
    norm="$(printf '%s' "$out" | jq -c . 2>/dev/null)" && pr_snap_put "$kind" "$norm" "$started" || true
  fi
  [[ -z "$out" ]] || printf '%s\n' "$out"
  return "$rc"
}
