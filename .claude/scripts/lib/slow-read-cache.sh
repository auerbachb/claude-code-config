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
# Environment: SLOW_READ_CACHE_TTL (seconds; clamped to the kind's maximum,
# non-numeric -> the maximum, 0 -> no caching), SLOW_READ_CACHE_DIR (tests).

SLOW_CACHE_MAX_SHA_KEYED=300
SLOW_CACHE_MAX_SETTING=120
_SLOW_CACHE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# slow_cache_ttl <kind> -> seconds (0 for an unknown kind: never cached)
slow_cache_ttl() {
  local max v
  case "$1" in
    codeowners | pm-config) max="$SLOW_CACHE_MAX_SHA_KEYED" ;;
    required-checks) max="$SLOW_CACHE_MAX_SETTING" ;;
    *) printf '0'; return 0 ;;
  esac
  v="${SLOW_READ_CACHE_TTL:-$max}"
  [[ "$v" =~ ^[0-9]{1,9}$ ]] || v="$max"
  v=$((10#$v))
  (( v > max )) && v="$max"
  printf '%s' "$v"
}

slow_cache_dir() { printf '%s' "${SLOW_READ_CACHE_DIR:-$HOME/.claude/slow-read-cache}"; }

# slow_cache_file <kind> <owner/repo> <ref> -> path (fails on unusable input)
slow_cache_file() {
  local kind="$1" or_lc ref="$3" sum
  or_lc="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  [[ "$kind" =~ ^[a-z-]+$ && "$or_lc" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ && -n "$ref" ]] || return 1
  # cksum only names the file; the ref itself is stored and compared on load.
  sum="$(printf '%s' "$ref" | cksum | tr -d ' \t')" || return 1
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
     --arg key "$key" --arg viewer "$viewer" --argjson now "$now" --argjson ttl "$ttl" '
    select(type == "object" and .schema == 1 and .kind == $kind and .owner_repo == $or and .ref == $ref
      and .key == $key and (.viewer | type) == "string" and .viewer == $viewer
      and (.saved_epoch | type) == "number" and ($now - .saved_epoch) >= 0 and ($now - .saved_epoch) < $ttl
      and (.value | type) == "string")
    | .value' "$f" 2>/dev/null
}

# slow_cache_put <kind> <owner/repo> <ref> <key> <viewer> <value> -> 0 saved, 1 not. Never prints.
slow_cache_put() {
  local kind="$1" or="$2" ref="$3" key="$4" viewer="${5:-}" value="$6" f dir tmp now
  [[ "$(slow_cache_ttl "$kind")" =~ ^[1-9][0-9]*$ && -n "$key" && -n "$viewer" ]] || return 1
  f="$(slow_cache_file "$kind" "$or" "$ref")" || return 1
  dir="$(dirname "$f")"
  (umask 077; mkdir -p "$dir") 2>/dev/null || return 1
  tmp="$(mktemp "$dir/.slow.XXXXXX" 2>/dev/null)" || return 1
  now="$(date +%s)"
  if jq -cn --arg kind "$kind" --arg or "$(printf '%s' "$or" | tr '[:upper:]' '[:lower:]')" --arg ref "$ref" \
       --arg key "$key" --arg viewer "$viewer" --argjson now "$now" --arg value "$value" \
       '{schema: 1, kind: $kind, owner_repo: $or, ref: $ref, key: $key, viewer: $viewer, saved_epoch: $now, value: $value}' \
       > "$tmp" 2>/dev/null \
     && [[ -s "$tmp" ]] && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}
