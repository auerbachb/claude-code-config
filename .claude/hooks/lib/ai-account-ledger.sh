#!/bin/bash
# Shared metadata-only account attribution. Bash 3.2; no credential reads.
# Resolve provider/profile to one exact declared registry match; set PROFILE and LABEL globals.
# Args: provider, directory, optional pre-parsed TSV rows. Missing/ambiguous means unknown.
ledger_profile() {
  LEDGER_PROFILE="$2"
  LEDGER_LABEL=unknown
  local rows path="" label="" matches=0
  if [ "$#" -ge 3 ]; then rows="$3"; else
  local registry="${AI_QUOTAS_CONFIG:-$HOME/.claude/ai-quotas.json}"
  [ -f "$registry" ] && [ -r "$registry" ] || return 0
  rows=$(jq -rs --arg p "$1" 'select(length==1) | .[0] | .accounts | arrays | .[] | objects | select(.provider==$p) | select((.profile_dir|type)=="string" and (.label|type)=="string") | select((.profile_dir|contains("\u0000")|not) and (.label|contains("\u0000")|not)) | [.profile_dir,.label] | @tsv' "$registry" 2>/dev/null) || return 0
  fi
  while IFS=$'\t' read -r path label; do
    # jq @tsv escapes backslashes/tabs/newlines; decode without command substitution
    # so trailing newlines remain part of the declared credential-realm spelling.
    printf -v path '%b' "${path:-}"
    printf -v label '%b' "${label:-}"
    [ -n "${path:-}" ] && [ -n "${label:-}" ] || continue
    # Credential realms can differ for symlink, dot-segment or trailing-slash spellings.
    # Exact matching is conservative even when a provider normalizes Unicode to NFC.
    if [ "$path" = "$LEDGER_PROFILE" ]; then
      matches=$((matches+1)); LEDGER_LABEL="$label"
    fi
  done <<< "$rows"
  [ "$matches" = 1 ] || LEDGER_LABEL=unknown
}
# Extract an issue-N branch token into LEDGER_ISSUE, or leave it empty.
ledger_issue() {
  LEDGER_ISSUE=""
  if [[ "$1" =~ (^|[/_-])issue-([0-9]+)($|[/_-]) ]]; then LEDGER_ISSUE="${BASH_REMATCH[2]}"; fi
}
# Set LEDGER_REPO from an allowlisted GitHub URL; reject userinfo/query/fragment forms.
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
# Resolve cwd metadata into REPO/BRANCH globals. Optional basename mode avoids live origin/HEAD.
ledger_repo() {
  LEDGER_REPO=""; LEDGER_BRANCH=""
  local fields root gitdir head="" origin
  # Preserve trailing newlines, then refuse Git's ambiguous multi-line path format.
  fields=$(git -C "$1" rev-parse --show-toplevel --absolute-git-dir 2>/dev/null && printf '\037') || return 0
  fields="${fields%$'\037'}"; fields="${fields%$'\n'}"
  case "${fields#*$'\n'}" in *$'\n'*) return 0 ;; esac
  root="${fields%%$'\n'*}"; gitdir="${fields#*$'\n'}"
  if [ "${2:-}" = basename ]; then LEDGER_REPO="${root##*/}"; return 0; fi
  # HEAD supplies the current symbolic branch even before the first commit.
  if [ -f "$gitdir/HEAD" ]; then IFS= read -r head < "$gitdir/HEAD" || true; fi
  case "$head" in 'ref: refs/heads/'*) LEDGER_BRANCH="${head#ref: refs/heads/}" ;; esac
  origin=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || origin=""
  ledger_repo_url "$origin"
  [ -n "$LEDGER_REPO" ] || LEDGER_REPO="${root##*/}"
}
# Append one compact JSON row to the owner-only regular ledger; return nonzero on failure.
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
# Serialize globals plus args: UTC timestamp, provider, session ID, source, capture mode.
# Never open account/auth stores; email evidence remains null during capture.
ledger_row() {
  jq -cn --arg ts "$1" --arg provider "$2" --arg label "$LEDGER_LABEL" \
    --arg repo "$LEDGER_REPO" --arg branch "$LEDGER_BRANCH" --arg issue "$LEDGER_ISSUE" \
    --arg session_id "$3" --arg source "$4" --arg capture "$5" --arg profile_dir "$LEDGER_PROFILE" \
    '{ts:$ts,provider:$provider,label:$label,repo:(($repo|select(length>0)) // null),branch:(($branch|select(length>0)) // null),issue:(($issue|select(length>0)) // null),session_id:$session_id,source:$source,capture:$capture,profile_dir:$profile_dir,account_email:null}'
}
