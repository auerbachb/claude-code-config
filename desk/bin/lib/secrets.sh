# shellcheck shell=bash
# desk/bin/lib/secrets.sh — refuses secret-shaped free text before it can reach
# the human-queue store (issue #1775). Sourced by the command files that accept
# free text, after lib/common.sh; never executed. Bash 3.2 compatible.
#
# hq_refuse_secret FIELD VALUE
#   Exits 5 (one stderr line naming FIELD and the kind of secret, never the
#   value) when VALUE looks like a credential; returns 0 otherwise.
#
# A heuristic, not a guarantee: it recognizes the common shapes below and will
# miss a bare password with no label. What it catches:
#   - private keys (-----BEGIN ... PRIVATE KEY)
#   - provider keys and tokens: AWS access key ids, Google API keys, Slack,
#     GitHub (ghp_/gho_/ghu_/ghs_/ghr_/github_pat_), Stripe, sk-... (OpenAI,
#     Anthropic), Neon passwords (npg_...)
#   - JSON Web Tokens and Authorization bearer values
#   - URLs carrying credentials (scheme://user:password@host)
#   - labeled values such as password=..., token: ..., api_key=..., when the
#     value is at least six characters and mixes letters and digits, so prose
#     like "password: required" or "token=$GITHUB_TOKEN" is not refused
#
# Matching is done in-process with [[ =~ ]] on purpose. A pipe into grep can
# turn a match into a miss under `set -o pipefail` (the writer takes SIGPIPE
# when grep exits early), and a here-string makes bash 3.2 write the value to a
# temp file. Neither may happen to text that might be a secret.

# hq__secret_class VALUE — sets HQ__SECRET_CLASS and returns 0 on a match;
# returns 1 otherwise. Provider-specific shapes come first so the message names
# the most specific kind.
HQ__SECRET_CLASS=""
hq__secret_class() {
  local v="$1" re rest val label_re nocase=0
  HQ__SECRET_CLASS=""

  re='-----BEGIN [A-Z0-9 ]*PRIVATE KEY'
  if [[ $v =~ $re ]]; then HQ__SECRET_CLASS="a private key"; return 0; fi
  re='(AKIA|ASIA)[A-Z0-9]{16}'
  if [[ $v =~ $re ]]; then HQ__SECRET_CLASS="an AWS access key"; return 0; fi
  re='AIza[0-9A-Za-z_-]{35}'
  if [[ $v =~ $re ]]; then HQ__SECRET_CLASS="a Google API key"; return 0; fi
  re='xox[abposr]-[0-9A-Za-z-]{10,}'
  if [[ $v =~ $re ]]; then HQ__SECRET_CLASS="a Slack token"; return 0; fi
  re='(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
  if [[ $v =~ $re ]]; then HQ__SECRET_CLASS="a GitHub token"; return 0; fi
  re='[rs]k_(live|test)_[A-Za-z0-9]{10,}'
  if [[ $v =~ $re ]]; then HQ__SECRET_CLASS="a Stripe key"; return 0; fi
  re='sk-[A-Za-z0-9_-]{20,}'
  if [[ $v =~ $re ]]; then HQ__SECRET_CLASS="an API key (sk-...)"; return 0; fi
  re='npg_[A-Za-z0-9]{10,}'
  if [[ $v =~ $re ]]; then HQ__SECRET_CLASS="a Neon password"; return 0; fi
  re='eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  if [[ $v =~ $re ]]; then HQ__SECRET_CLASS="a JSON Web Token"; return 0; fi

  # The rest are case-insensitive. nocasematch is restored before returning,
  # whatever the caller had.
  if shopt -q nocasematch; then nocase=1; fi
  shopt -s nocasematch

  re='bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}'
  if [[ $v =~ $re ]]; then HQ__SECRET_CLASS="a bearer token"; fi
  re='[a-z][a-z0-9+.-]*://[^/@[:space:]]+:[^/@[:space:]]+@'
  if [ -z "$HQ__SECRET_CLASS" ] && [[ $v =~ $re ]]; then
    HQ__SECRET_CLASS="a URL with credentials"
  fi

  # Labeled values: walk every label in the text, so a harmless first one
  # ("token: none") cannot hide a real one later in the same value.
  label_re="(password|passwd|pwd|secret|client[_-]?secret|api[_-]?key|access[_-]?key|access[_-]?token|auth[_-]?token|token|authorization)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?([^[:space:]\"']+)"
  rest="$v"
  while [ -z "$HQ__SECRET_CLASS" ] && [[ $rest =~ $label_re ]]; do
    val="${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    case "$val" in
      '$'*|'<'*|'{'*|'['*|'('*) continue ;;
    esac
    if [ "${#val}" -ge 6 ] && [[ $val == *[0-9]* ]] && [[ $val == *[A-Za-z]* ]]; then
      HQ__SECRET_CLASS="a labeled credential (password=, token:, api_key=, ...)"
    fi
  done

  if [ "$nocase" -eq 0 ]; then shopt -u nocasematch; fi
  [ -n "$HQ__SECRET_CLASS" ]
}

hq_refuse_secret() {
  if hq__secret_class "$2"; then
    hq_die_secret "secret refused: $1 looks like $HQ__SECRET_CLASS; nothing was stored (put secrets in .env, never in the queue)"
  fi
  return 0
}
