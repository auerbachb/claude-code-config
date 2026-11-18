#!/usr/bin/env bash
# slow-read-cache.sh — short-lived, fail-closed reuse of the GitHub reads that
# rarely change: CODEOWNERS and pm-config.md at the base branch, and the base
# branch's required status checks (issue #2443, slice 3 of #2421).
#
# These feed the merge gate, which decides whether unreviewed code merges, so
# every doubt is a miss and a miss means a live read. A saved value is returned
# ONLY when ALL hold:
#   - the file parses and carries the full schema (schema 1, kind, repo, ref,
#     key, viewer, saved time, and a string value);
#   - kind, repo (lowercased), ref (the base branch name), key and the
#     authenticated viewer login all match what the caller has just read live;
#   - it is younger than the kind's lifetime and not from the future.
#
# Two kinds of staleness, two guards:
#   - File reads at the base branch (codeowners, pm-config): the key is the base
#     branch's tip commit SHA, read through GraphQL (which GitHub meters apart
#     from the 5,000-an-hour REST allowance) BEFORE the live read and AGAIN after
#     it. A value is stored only when both reads succeeded and agree; a hit needs
#     the key read now to equal the stored one. A push to the base changes the
#     key, so the value is never used across a base change. Lifetime: 300s max.
#   - Repository settings (required-checks): the same tip key guards against a base
#     push, but branch protection changes move no SHA, so the lifetime is the only
#     guard against that and is shorter: 120s hard maximum.
#     Only a positive answer (a non-empty required list read successfully) is ever
#     stored; "no protection", "no required checks" and every unreadable answer
#     are read live every time, so an old "no requirement" can never outlive a
#     change. A stale positive list can only make the gate stricter, or lag a
#     newly required check by under two minutes — GitHub itself still refuses the
#     merge for a required check that has not passed.
#
# A failed read is never stored (callers store only a definite answer: success,
# or an explicit HTTP 404 for a file). A failed write is ignored by the caller and
# changes no output or exit code. No token or credential is read, passed, keyed
# on or stored here; the viewer login comes from lib/gh-viewer.sh. Files live
# under ~/.claude/slow-read-cache/ (never in a worktree), are written atomically
# with mode 600 in a mode 700 directory.
#
# Age is counted from the moment the live read STARTED (the caller passes that
# time to slow_cache_put), never from the write, and a write never replaces an
# entry whose read started no earlier than its own: a slow or delayed run can
# therefore neither extend a value's life nor put an older read over a newer one.
#
# Host: the value of GH_HOST (github.com when unset) is part of the identity (stored and
# compared; it also names the file). Hosts chosen only through gh's own config are
# NOT distinguished: telling them apart would mean reading gh's config or
# credentials, which this library never does. The risk is a same-named repository
# on another host with the same base tip and the same login inside the lifetime.
#
# Environment: SLOW_READ_CACHE_TTL (seconds; clamped to the kind's maximum,
# non-numeric -> the maximum, 0 -> no caching; callers check slow_cache_enabled
# first, so with caching off not even the base-tip probe runs),
# SLOW_READ_CACHE_DIR (tests).

SLOW_CACHE_MAX_SHA_KEYED=300
SLOW_CACHE_MAX_SETTING=120
SLOW_CACHE_MAX_PR_SNAPSHOT=60
_SLOW_CACHE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# slow_cache_ttl <kind> -> seconds (0 for an unknown kind: never cached)
slow_cache_ttl() {
  local max v
  v="${SLOW_READ_CACHE_TTL:-}"
  case "$1" in
    codeowners | pm-config) max="$SLOW_CACHE_MAX_SHA_KEYED" ;;
    required-checks) max="$SLOW_CACHE_MAX_SETTING" ;;
    # Per-PR snapshot kinds (lib/pr-snapshot.sh, issue #2444): their own switch,
    # PR_SNAPSHOT_TTL, plus the shared "off" switch: SLOW_READ_CACHE_TTL=0 (which
    # admin-merge.sh and clean-behind-check.sh export) turns them off too.
    pr-reviews | pr-comments | pr-issue-comments | pr-statuses | pr-head-commit | pr-check-runs)
      max="$SLOW_CACHE_MAX_PR_SNAPSHOT"
      if [[ "$v" =~ ^0+$ ]]; then printf '0'; return 0; fi
      v="${PR_SNAPSHOT_TTL:-}" ;;
    *) printf '0'; return 0 ;;
  esac
  [[ -n "$v" ]] || v="$max"
  [[ "$v" =~ ^[0-9]{1,9}$ ]] || v="$max"
  v=$((10#$v))
  (( v > max )) && v="$max"
  printf '%s' "$v"
}

# slow_cache_enabled <kind> -> 0 when entries of this kind may be stored/served.
slow_cache_enabled() { [[ "$(slow_cache_ttl "$1")" =~ ^[1-9][0-9]*$ ]]; }

# slow_cache_host -> the lowercased GH_HOST, or "github.com" when it is unset or
# empty. Nothing else.
slow_cache_host() { printf '%s' "${GH_HOST:-github.com}" | tr '[:upper:]' '[:lower:]'; }

slow_cache_dir() { printf '%s' "${SLOW_READ_CACHE_DIR:-$HOME/.claude/slow-read-cache}"; }

# slow_cache_file <kind> <owner/repo> <ref> -> path (fails on unusable input)
slow_cache_file() {
  local kind="$1" or_lc ref="$3" sum
  or_lc="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  [[ "$kind" =~ ^[a-z-]+$ && "$or_lc" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ && -n "$ref" ]] || return 1
  # cksum only names the file; the ref itself is stored and compared on load.
  sum="$(printf '%s|%s' "$(slow_cache_host)" "$ref" | cksum | tr -d ' \t')" || return 1
  [[ "$sum" =~ ^[0-9]+$ ]] || return 1
  printf '%s/%s__%s.%s.json' "$(slow_cache_dir)" "${or_lc//\//__}" "$kind" "$sum"
}

# slow_cache_viewer -> sets SLOW_CACHE_VIEWER; fails (and sets it empty) when the
# login cannot be read, which means "do not use the cache".
slow_cache_viewer() {
  SLOW_CACHE_VIEWER=""
  [[ -r "$_SLOW_CACHE_LIB_DIR/gh-viewer.sh" ]] || return 1
  # shellcheck source=gh-viewer.sh
  . "$_SLOW_CACHE_LIB_DIR/gh-viewer.sh" 2>/dev/null || return 1
  gh_viewer_resolve || return 1
  SLOW_CACHE_VIEWER="$GH_VIEWER_LOGIN"
}

# slow_cache_base_tip <owner/repo> <branch> -> prints the branch's tip commit SHA.
# One GraphQL call (not REST). Fails on any error or an odd answer.
slow_cache_base_tip() {
  local or="$1" branch="$2" oid
  [[ "$or" == */* && -n "$branch" ]] || return 1
  oid="$(gh api graphql \
    -f query='query($o:String!,$r:String!,$b:String!){repository(owner:$o,name:$r){ref(qualifiedName:$b){target{oid}}}}' \
    -f o="${or%%/*}" -f r="${or#*/}" -f b="refs/heads/$branch" \
    --jq '.data.repository.ref.target.oid' 2>/dev/null)" || return 1
  [[ "$oid" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$oid"
}

# slow_cache_get <kind> <owner/repo> <ref> <key> <viewer> -> prints the stored
# value; 0 hit, 1 miss. A hit may be an empty string (a stored definite absence).
slow_cache_get() {
  local kind="$1" or="$2" ref="$3" key="$4" viewer="${5:-}" f ttl now
  ttl="$(slow_cache_ttl "$kind")"
  [[ "$ttl" =~ ^[0-9]+$ ]] && (( ttl > 0 )) || return 1
  f="$(slow_cache_file "$kind" "$or" "$ref")" || return 1
  # A file this process cannot overwrite is one it could not replace either.
  [[ -n "$key" && -n "$viewer" && -f "$f" && -r "$f" && -w "$f" ]] || return 1
  now="$(date +%s)"
  jq -je --arg kind "$kind" --arg or "$(printf '%s' "$or" | tr '[:upper:]' '[:lower:]')" --arg ref "$ref" \
     --arg host "$(slow_cache_host)" --arg key "$key" --arg viewer "$viewer" --argjson now "$now" --argjson ttl "$ttl" '
    select(type == "object" and .schema == 1 and .kind == $kind and .owner_repo == $or and .ref == $ref
      and .host == $host and .key == $key and (.viewer | type) == "string" and .viewer == $viewer
      and (.saved_epoch | type) == "number" and ($now - .saved_epoch) >= 0 and ($now - .saved_epoch) < $ttl
      and (.value | type) == "string")
    | .value' "$f" 2>/dev/null
}

# slow_cache_put <kind> <owner/repo> <ref> <key> <viewer> <value> [read_started_epoch]
# -> 0 saved or kept a newer entry, 1 not. Never prints. read_started_epoch is the
# time the live read began (default: now); it is the entry's age origin.
slow_cache_put() {
  local kind="$1" or="$2" ref="$3" key="$4" viewer="${5:-}" value="$6" started="${7:-}" f dir tmp now cur
  [[ "$(slow_cache_ttl "$kind")" =~ ^[1-9][0-9]*$ && -n "$key" && -n "$viewer" ]] || return 1
  f="$(slow_cache_file "$kind" "$or" "$ref")" || return 1
  dir="$(dirname "$f")"
  (umask 077; mkdir -p "$dir") 2>/dev/null || return 1
  tmp="$(mktemp "$dir/.slow.XXXXXX" 2>/dev/null)" || return 1
  now="$(date +%s)"
  [[ "$started" =~ ^[0-9]{1,12}$ ]] || started="$now"
  (( started > now )) && started="$now"
  # Never put an older read over a newer one: leave an entry whose read started at
  # or after ours alone (a narrow check-then-rename race remains, but every entry's
  # age is counted from its own read start, so none can outlive its lifetime).
  if [[ -f "$f" ]]; then
    cur="$(jq -r 'select(type == "object") | .saved_epoch | select(type == "number")' "$f" 2>/dev/null)" || cur=""
    if [[ "$cur" =~ ^[0-9]+$ ]] && (( cur >= started )); then rm -f "$tmp" 2>/dev/null; return 0; fi
  fi
  if jq -cn --arg kind "$kind" --arg or "$(printf '%s' "$or" | tr '[:upper:]' '[:lower:]')" --arg ref "$ref" \
       --arg host "$(slow_cache_host)" --arg key "$key" --arg viewer "$viewer" --argjson now "$started" --arg value "$value" \
       '{schema: 1, kind: $kind, owner_repo: $or, ref: $ref, host: $host, key: $key, viewer: $viewer, saved_epoch: $now, value: $value}' \
       > "$tmp" 2>/dev/null \
     && [[ -s "$tmp" ]] && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}
