#!/bin/bash
# Shared metadata-only account attribution. Bash 3.2; no credential reads.
ledger_profile() {
  LEDGER_PROFILE="$(cd -P "$2" 2>/dev/null && pwd -P)" || LEDGER_PROFILE="$2"
  LEDGER_LABEL=unknown
  local rows path label physical matches=0
  if [ "$#" -ge 3 ]; then rows="$3"; else
  rows=$(jq -r --arg p "$1" '.accounts[] | select(.provider==$p) | select((.profile_dir|type)=="string" and (.label|type)=="string") | [.profile_dir,.label] | @tsv' "${AI_QUOTAS_CONFIG:-$HOME/.claude/ai-quotas.json}" 2>/dev/null) || return 0
  fi
  while IFS=$'\t' read -r path label; do
    [ -n "$path" ] || continue
    physical=$(cd -P "$path" 2>/dev/null && pwd -P) || continue
    if [ "$physical" = "$LEDGER_PROFILE" ]; then
      matches=$((matches+1)); LEDGER_LABEL="$label"
    fi
  done <<< "$rows"
  [ "$matches" = 1 ] || LEDGER_LABEL=unknown
}
ledger_issue() {
  LEDGER_ISSUE=""
  if [[ "$1" =~ (^|[/_-])issue-([0-9]+)($|[/_-]) ]]; then LEDGER_ISSUE="${BASH_REMATCH[2]}"; fi
}
ledger_repo_url() {
  local slug=""
  case "$1" in
    git@github.com:*) slug="${1#git@github.com:}" ;;
    https://github.com/*|http://github.com/*|ssh://git@github.com/*|git://github.com/*) slug="${1#*github.com/}" ;;
  esac
  slug="${slug%.git}"
  if [[ "$slug" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
    LEDGER_REPO=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
  else LEDGER_REPO=""; fi
}
ledger_repo() {
  LEDGER_REPO=""; LEDGER_BRANCH=""
  local fields root gitdir head="" origin
  fields=$(git -C "$1" rev-parse --show-toplevel --absolute-git-dir 2>/dev/null) || return 0
  root="${fields%%$'\n'*}"; gitdir="${fields#*$'\n'}"
  if [ "${2:-}" = basename ]; then LEDGER_REPO="${root##*/}"; return 0; fi
  # HEAD supplies the current symbolic branch even before the first commit.
  if [ -f "$gitdir/HEAD" ]; then IFS= read -r head < "$gitdir/HEAD" || true; fi
  case "$head" in 'ref: refs/heads/'*) LEDGER_BRANCH="${head#ref: refs/heads/}" ;; esac
  origin=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || origin=""
  ledger_repo_url "$origin"
  [ -n "$LEDGER_REPO" ] || LEDGER_REPO="${root##*/}"
}
ledger_append() {
  local file="${AI_ACCOUNT_LEDGER:-$HOME/.claude/ai-account-ledger.jsonl}" parent
  parent="${file%/*}"; [ "$parent" != "$file" ] || parent=.
  umask 077
  [ -d "$parent" ] || mkdir -p "$parent" || return 1
  # Reject configured symlinks/special files in this owner-controlled directory.
  [ ! -L "$file" ] || return 1
  [ ! -e "$file" ] || [ -f "$file" ] || return 1
  if [ -e "$file" ]; then chmod 600 "$file" || return 1; fi
  printf '%s\n' "$1" >> "$file"
}
ledger_row() {
  jq -cn --arg ts "$1" --arg provider "$2" --arg label "$LEDGER_LABEL" \
    --arg repo "$LEDGER_REPO" --arg branch "$LEDGER_BRANCH" --arg issue "$LEDGER_ISSUE" \
    --arg session_id "$3" --arg source "$4" --arg capture "$5" --arg profile_dir "$LEDGER_PROFILE" \
    '{ts:$ts,provider:$provider,label:$label,repo:(($repo|select(length>0)) // null),branch:(($branch|select(length>0)) // null),issue:(($issue|select(length>0)) // null),session_id:$session_id,source:$source,capture:$capture,profile_dir:$profile_dir,account_email:null}'
}
