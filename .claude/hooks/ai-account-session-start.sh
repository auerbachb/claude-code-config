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
command -v jq >/dev/null || exit 0
lib="$(cd "${BASH_SOURCE[0]%/*}" && pwd)/lib/ai-account-ledger.sh"
[ -r "$lib" ] || exit 0
# shellcheck source=lib/ai-account-ledger.sh
source "$lib" || exit 0
registry="${AI_QUOTAS_CONFIG:-$HOME/.claude/ai-quotas.json}"
[ -f "$registry" ] && [ -r "$registry" ] || registry=/dev/null
parsed=$(jq -er --rawfile registry "$registry" --arg provider "$provider" '
  def clean: if type=="string" then gsub("[\u001f\t\r\n]";"") else "" end;
  def path_field: if type=="string" then [.] | @tsv | gsub("\u001f";"\\037") else "" end;
  select([.cwd,.transcript_path] | all(if type=="string" then (contains("\u0000")|not) else true end)) |
  (([((.session_id // "")|clean),(.cwd|path_field),((.source // "startup")|clean)] | join("\u001f")) +
    "\u001f" + (.transcript_path | path_field)),
  ((try ($registry|fromjson|.accounts[]) catch empty) | select(.provider==$provider) |
    select((.profile_dir|type)=="string" and (.label|type)=="string") | select((.profile_dir|contains("\u0000")|not) and (.label|contains("\u0000")|not)) | [.profile_dir,.label] | @tsv)
') || exit 0
fields="${parsed%%$'\n'*}"
rows=""
case "$parsed" in *$'\n'*) rows="${parsed#*$'\n'}" ;; esac
IFS=$'\x1f' read -r session cwd source transcript <<< "$fields"
# Decode the escaped path losslessly, retaining trailing newlines and literal backslashes.
printf -v transcript '%b' "$transcript"
printf -v cwd '%b' "$cwd"
case "$source" in clear|compact) exit 0 ;; startup|resume|fork) ;; *) exit 0 ;; esac
case "$provider" in
  claude) profile="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
  codex)
    profile="${profile:-${CODEX_HOME:-}}"
    if [ -z "$profile" ]; then
      # The nearest container wins; the home itself can contain either component.
      ancestor="${transcript%/*}"
      while [ -n "$ancestor" ]; do
        case "$ancestor" in
          */sessions|*/archived_sessions)
            profile="${ancestor%/*}"; [ -n "$profile" ] || profile=/; break ;;
        esac
        parent="${ancestor%/*}"
        [ "$parent" != "$ancestor" ] || break
        ancestor="$parent"
      done
    fi
    profile="${profile:-$HOME/.codex}" ;;
  *) exit 0 ;;
esac
ledger_profile "$provider" "$profile" "$rows"
ledger_repo "${cwd:-$PWD}"
ledger_issue "$LEDGER_BRANCH"
ts=$(date -u +%FT%TZ) || exit 0
row=$(ledger_row "$ts" "$provider" "$session" "$source" hook) || exit 0
ledger_append "$row" || true
