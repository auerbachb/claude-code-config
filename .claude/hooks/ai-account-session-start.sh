#!/bin/bash
# Metadata-only SessionStart recorder. Always fail open.
provider=claude
profile=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) [ "$#" -ge 2 ] || break; provider="$2"; shift 2 ;;
    --codex-home) [ "$#" -ge 2 ] || break; profile="$2"; shift 2 ;;
    *) shift ;;
  esac
done
trap 'if [ "$provider" != codex ]; then printf "{}\n"; fi; exit 0' EXIT
exec 2>/dev/null
command -v jq >/dev/null && command -v git >/dev/null || exit 0
lib="$(cd "${BASH_SOURCE[0]%/*}" && pwd)/lib/ai-account-ledger.sh"
[ -r "$lib" ] || exit 0
# shellcheck source=lib/ai-account-ledger.sh
source "$lib" || exit 0
registry="${AI_QUOTAS_CONFIG:-$HOME/.claude/ai-quotas.json}"
[ -f "$registry" ] && [ -r "$registry" ] || registry=/dev/null
parsed=$(jq -er --rawfile registry "$registry" --arg provider "$provider" '
  def clean: if type=="string" then gsub("[\u001f\t\r\n]";"") else "" end;
  ([.session_id // "",.cwd // "",.source // "startup",.transcript_path // ""] | map(clean) | join("\u001f")),
  ((try ($registry|fromjson|.accounts[]) catch empty) | select(.provider==$provider) |
    select((.profile_dir|type)=="string" and (.label|type)=="string") | [.profile_dir,.label] | @tsv)
') || exit 0
fields="${parsed%%$'\n'*}"
rows=""
case "$parsed" in *$'\n'*) rows="${parsed#*$'\n'}" ;; esac
IFS=$'\x1f' read -r session cwd source transcript <<< "$fields"
case "$source" in clear|compact) exit 0 ;; startup|resume|fork) ;; *) exit 0 ;; esac
case "$provider" in
  claude) profile="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
  codex)
    profile="${profile:-${CODEX_HOME:-}}"
    if [ -z "$profile" ]; then
      case "$transcript" in */sessions/*) profile="${transcript%%/sessions/*}" ;; */archived_sessions/*) profile="${transcript%%/archived_sessions/*}" ;; esac
    fi
    profile="${profile:-$HOME/.codex}" ;;
  *) exit 0 ;;
esac
ledger_profile "$provider" "$profile" "$rows"
ledger_repo "${cwd:-$PWD}"
ledger_issue "$LEDGER_BRANCH"
row=$(ledger_row "$(date -u +%FT%TZ)" "$provider" "$session" "$source" hook) || exit 0
ledger_append "$row" || true
