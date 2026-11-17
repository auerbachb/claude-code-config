#!/usr/bin/env bash
# gh-viewer.sh — fetch the authenticated GitHub login once per credential instead
# of once per script (issue #2442, slice of #2421).
#
# The login decides authorship (whose PR is "mine"), so every doubt is a live
# lookup with nothing cached. The cache holds ONLY the login. Its filename is a
# SHA-256 of "<effective host>\n<credential>" truncated to 24 hex chars, so
# `gh auth switch`, a new token, GH_HOST or another credential yields a different
# file and never serves another identity. (The credential never appears in a file
# name, file body, argument vector, log line or error message; the hash is
# unsalted, but the file sits in the owner-only ~/.claude tree and reveals nothing
# beyond what a reader of the token already holds.) The live lookup is pinned to
# that same host and credential through scoped environment assignments only (never
# argv), so an account switch between the read and the request cannot store one
# login under another credential's hash.
#
# Effective host, as gh derives it: GH_HOST if set; otherwise github.com when
# the config lists no host or only github.com. Any other shape (several hosts,
# or one non-github.com host) has no host this helper can name with certainty, so
# nothing is cached and a plain live `gh api user` runs. Credential variable by
# host, as gh does: github.com, *.ghe.com and *.localhost use GH_TOKEN /
# GITHUB_TOKEN; every other host uses GH_ENTERPRISE_TOKEN /
# GITHUB_ENTERPRISE_TOKEN. No credential, hash failure, an odd value or a failed
# lookup means no cache; a failed lookup is never stored. Lifetime is
# VIEWER_CACHE_TTL seconds (default 3600).

_GH_VIEWER_RE='^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$'

# _gh_viewer_host -> effective host on stdout, or fail when undeterminable.
_gh_viewer_host() {
  local cfg hosts n
  if [[ -n "${GH_HOST:-}" ]]; then printf '%s' "$GH_HOST"; return 0; fi
  cfg="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/gh}}"
  [[ -n "$cfg" ]] || cfg="${HOME:+$HOME/.config/gh}"
  hosts=""
  if [[ -r "$cfg/hosts.yml" ]]; then
    hosts="$(grep -E '^[^[:space:]#][^:]*:' "$cfg/hosts.yml" 2>/dev/null | sed 's/:.*//' || true)"
  fi
  n="$(printf '%s' "$hosts" | grep -c . || true)"
  if [[ "$n" == 0 || ( "$n" == 1 && "$hosts" == "github.com" ) ]]; then printf 'github.com'; return 0; fi
  return 1
}

gh_viewer_login() {
  local dir="${VIEWER_CACHE_DIR:-$HOME/.claude/viewer-cache}" host="" tok="" key f="" login="" now mt tmp="" kind=""
  if host="$(_gh_viewer_host)" && [[ "$host" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
    case "$host" in
      github.com|*.ghe.com|*.localhost) kind=github ;;
      *) kind=enterprise ;;
    esac
    if [[ "$kind" == github ]]; then
      tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    else
      tok="${GH_ENTERPRISE_TOKEN:-${GITHUB_ENTERPRISE_TOKEN:-}}"
    fi
    [[ -n "$tok" ]] || tok="$(gh auth token --hostname "$host" 2>/dev/null || true)"
  fi
  if [[ -n "$tok" && -n "$kind" ]]; then
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
  # Scoped assignments put the credential in the child's environment only.
  if [[ -n "$tok" && "$kind" == github ]]; then
    login="$(GH_HOST="$host" GH_TOKEN="$tok" gh api user --jq '.login' 2>/dev/null || true)"
  elif [[ -n "$tok" && "$kind" == enterprise ]]; then
    login="$(GH_HOST="$host" GH_ENTERPRISE_TOKEN="$tok" gh api user --jq '.login' 2>/dev/null || true)"
  else
    f=""
    login="$(gh api user --jq '.login' 2>/dev/null || true)"
  fi
  [[ -n "$login" && "$login" != "null" ]] || return 1
  if [[ -n "$f" && "$login" =~ $_GH_VIEWER_RE ]]; then
    if mkdir -p "$dir" 2>/dev/null && tmp="$(mktemp "$dir/.v.XXXXXX" 2>/dev/null)"; then
      { printf '%s\n' "$login" > "$tmp" && mv -f "$tmp" "$f"; } 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
  fi
  printf '%s' "$login"
}
