#!/usr/bin/env bash
# gh-viewer.sh — fetch the authenticated GitHub login once per credential instead
# of once per script (issue #2442, slice of #2421).
#
# The login decides authorship (whose PR is "mine"), so every doubt is a live
# lookup with nothing cached. The cache holds ONLY the login. Its filename is a
# hash of the effective GitHub host AND the credential gh would use for that host
# (read locally, no REST call), so `gh auth switch`, a new token, GH_HOST or an
# enterprise token yields a different file and never serves another identity. The
# live lookup is bound to that same captured credential and host, so an account
# switch between the read and the request cannot store one login under another
# credential's hash. No host/credential, hash failure, an odd value or a failed
# lookup means no cache: a live `gh api user` runs, and a failed one is never
# stored. Lifetime is VIEWER_CACHE_TTL seconds (default 3600).

_GH_VIEWER_RE='^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$'

gh_viewer_login() {
  local dir="${VIEWER_CACHE_DIR:-$HOME/.claude/viewer-cache}" host tok="" key f="" login="" now mt tmp=""
  local -a bound=()
  host="${GH_HOST:-github.com}"
  if [[ "$host" == "github.com" ]]; then
    tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    [[ -n "$tok" ]] || tok="$(gh auth token --hostname "$host" 2>/dev/null || true)"
    [[ -n "$tok" ]] && bound=(env "GH_TOKEN=$tok")
  else
    tok="${GH_ENTERPRISE_TOKEN:-${GITHUB_ENTERPRISE_TOKEN:-}}"
    [[ -n "$tok" ]] || tok="$(gh auth token --hostname "$host" 2>/dev/null || true)"
    [[ -n "$tok" ]] && bound=(env "GH_ENTERPRISE_TOKEN=$tok" "GH_HOST=$host")
  fi
  if [[ -n "$tok" && ${#bound[@]} -gt 0 ]]; then
    key="$(printf '%s\n%s' "$host" "$tok" | shasum -a 256 2>/dev/null | cut -c1-24 || true)"
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
  if [[ ${#bound[@]} -gt 0 ]]; then
    login="$("${bound[@]}" gh api user --jq '.login' 2>/dev/null || true)"
  else
    login="$(gh api user --jq '.login' 2>/dev/null || true)"
  fi
  [[ -n "$login" && "$login" != "null" ]] || return 1
  if [[ -n "$f" && ${#bound[@]} -gt 0 && "$login" =~ $_GH_VIEWER_RE ]]; then
    if mkdir -p "$dir" 2>/dev/null && tmp="$(mktemp "$dir/.v.XXXXXX" 2>/dev/null)"; then
      { printf '%s\n' "$login" > "$tmp" && mv -f "$tmp" "$f"; } 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
  fi
  printf '%s' "$login"
}
