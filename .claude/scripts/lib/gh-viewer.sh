#!/usr/bin/env bash
# gh-viewer.sh — fetch the authenticated GitHub login once per token instead of
# once per script (issue #2442, slice of #2421).
#
# The cache holds ONLY the login. Its filename is a hash of the local gh token
# (read locally, no REST call), so `gh auth switch` or a new token yields a
# different file and never serves the old user. No token, hash failure, an odd
# value or a lookup failure means no cache: a live `gh api user` runs, and a
# failed one is never stored. Lifetime is VIEWER_CACHE_TTL seconds (default 3600).

_GH_VIEWER_RE='^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$'

gh_viewer_login() {
  local dir="${VIEWER_CACHE_DIR:-$HOME/.claude/viewer-cache}" tok key f="" login="" now mt tmp=""
  tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [[ -n "$tok" ]] || tok="$(gh auth token 2>/dev/null || true)"
  if [[ -n "$tok" ]]; then
    key="$(printf '%s' "$tok" | shasum -a 256 2>/dev/null | cut -c1-24 || true)"
    if [[ "$key" =~ ^[0-9a-f]{24}$ ]]; then
      f="$dir/$key"
      if [[ -f "$f" ]]; then
        now="$(date +%s)"
        mt="$(stat -f %m "$f" 2>/dev/null)" || mt=""
        [[ "$mt" =~ ^[0-9]+$ ]] || mt="$(stat -c %Y "$f" 2>/dev/null)" || mt=0
        if [[ "$mt" =~ ^[0-9]+$ ]] && (( now - mt >= 0 && now - mt < ${VIEWER_CACHE_TTL:-3600} )); then
          login="$(head -n1 "$f" 2>/dev/null || true)"
          if [[ "$login" =~ $_GH_VIEWER_RE ]]; then printf '%s' "$login"; return 0; fi
        fi
      fi
    fi
  fi
  login="$(gh api user --jq '.login' 2>/dev/null || true)"
  [[ -n "$login" && "$login" != "null" ]] || return 1
  if [[ -n "$f" && "$login" =~ $_GH_VIEWER_RE ]]; then
    if mkdir -p "$dir" 2>/dev/null && tmp="$(mktemp "$dir/.v.XXXXXX" 2>/dev/null)"; then
      { printf '%s\n' "$login" > "$tmp" && mv -f "$tmp" "$f"; } 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
  fi
  printf '%s' "$login"
}
