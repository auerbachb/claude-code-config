#!/bin/bash
# catalog: token-measurement — Capture metadata-only AI account sessions, backfill Codex rollouts, install Codex hooks, and report projects by registered account.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$SELF_DIR/../hooks/lib/ai-account-ledger.sh"
[ -r "$lib" ] || lib="$HOME/.claude/hooks/lib/ai-account-ledger.sh"
[ -r "$lib" ] || { echo 'account ledger library unavailable' >&2; exit 5; }
# shellcheck source=../hooks/lib/ai-account-ledger.sh
source "$lib"
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 5; }
usage() { echo 'Usage: ai-account-ledger.sh report [--days N] [--provider claude|codex] [--json] | backfill-codex [--codex-home DIR] [--dry-run] | install-codex-hooks' >&2; exit 3; }
action="${1:-report}"; [ "$#" -eq 0 ] || shift
days=14; provider=""; json=0; home=""; dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --days) [ "$#" -ge 2 ] || usage; days="$2"; shift 2 ;;
    --provider) [ "$#" -ge 2 ] || usage; provider="$2"; shift 2 ;;
    --json) json=1; shift ;;
    --codex-home) [ "$#" -ge 2 ] || usage; home="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) usage ;;
  esac
done
[[ "$days" =~ ^[1-9][0-9]*$ ]] && [ "${#days}" -le 6 ] || usage
case "$provider" in ''|claude|codex) ;; *) usage ;; esac
registry="${AI_QUOTAS_CONFIG:-$HOME/.claude/ai-quotas.json}"
ledger="${AI_ACCOUNT_LEDGER:-$HOME/.claude/ai-account-ledger.jsonl}"
profiles() {
  if [ -n "$home" ]; then printf '%s\n' "$home"; return; fi
  { jq -r '.accounts[]? | select(.provider=="codex") | .profile_dir | select(type=="string")' "$registry" 2>/dev/null || true; printf '%s\n' "$HOME/.codex"; } | sort -u
}
case "$action" in
  backfill-codex)
    ids="$(jq -Rr 'fromjson? | select(type=="object") | select(.provider=="codex") | .session_id | select(type=="string" and length>0)' "$ledger" 2>/dev/null || true)"
    # Bash3.2 has no associative arrays: build one exact newline-delimited lookup.
    ids=$'\n'"$ids"$'\n'
    scanned=0; added=0; skipped=0; malformed=0
    while IFS= read -r dir; do
      [ -d "$dir" ] || continue
      ledger_profile codex "$dir"
      while IFS= read -r -d '' file; do
        scanned=$((scanned+1))
        # Read precisely the initial metadata record, never subsequent messages.
        first=""
        IFS= read -r first < "$file" 2>/dev/null || true
        fields=$(printf '%s\n' "$first" | jq -er 'select(.type=="session_meta") | .payload | select(type=="object") | [(.id // .session_id),.timestamp,(.cwd // ""),(.git.branch // ""),(.git.repository_url // "")] | select(.[0]|type=="string" and length>0) | select(.[1]|type=="string" and (sub("\\.[0-9]+Z$";"Z") | try (fromdateiso8601 != null) catch false)) | map(if type=="string" then gsub("[\u001f\r\n]";"") else "" end) | join("\u001f")' 2>/dev/null) || { malformed=$((malformed+1)); continue; }
        IFS=$'\x1f' read -r id ts cwd branch url <<< "$fields"
        # Quoting id keeps wildcard characters literal and avoids per-row processes.
        case "$ids" in *$'\n'"$id"$'\n'*) skipped=$((skipped+1)); continue ;; esac
        ledger_repo_url "$url"
        if [ -z "$url" ] && [ -n "$cwd" ]; then ledger_repo "$cwd" basename; fi
        # Historical metadata is authoritative; never use today's branch.
        LEDGER_BRANCH="$branch"; ledger_issue "$branch"
        row=$(ledger_row "$ts" codex "$id" backfill backfill) || { malformed=$((malformed+1)); continue; }
        if [ "$dry" = 1 ]; then :; else ledger_append "$row" || { echo 'could not append ledger' >&2; exit 5; }; fi
        ids="${ids}${id}"$'\n'; added=$((added+1))
      done < <(find "$dir/sessions" "$dir/archived_sessions" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)
    done < <(profiles)
    printf 'files scanned: %s; rows %s: %s; skipped: %s; malformed: %s\n' "$scanned" "$([ "$dry" = 1 ] && echo planned || echo added)" "$added" "$skipped" "$malformed" >&2
    ;;
  report)
    registry_json=$(jq -c 'select(.accounts|type=="array")' "$registry" 2>/dev/null) || registry_json='{"accounts":[]}'
    [ -n "$registry_json" ] || registry_json='{"accounts":[]}'
    input="$ledger"; [ -r "$input" ] || input=/dev/null
    result=$(jq -Rn --argjson days "$days" --arg provider "$provider" --argjson registry "$registry_json" '
      def has_id: .session_id | if type=="string" then length>0 else false end;
      def session_count: ([.[] | select(has_id) | .session_id] | unique | length) + ([.[] | select(has_id|not)] | length);
      def epoch: sub("\\.[0-9]+Z$";"Z") | try fromdateiso8601 catch null;
      now as $end | ($end - $days*86400) as $start |
      [inputs | fromjson? | select(type=="object") | select(.provider=="claude" or .provider=="codex") |
        select(.label|type=="string") | select(.ts|type=="string") |
        select(.repo == null or (.repo|type)=="string") |
        select((.ts|epoch) as $t | $t != null and $t >= $start and $t <= $end) |
        select($provider=="" or .provider==$provider)] as $rows |
      {window:{start:($start|todateiso8601),end:($end|todateiso8601),days:$days},
       accounts:($rows | group_by([.provider,.label]) | map(.[0] as $a |
         {provider:$a.provider,label:$a.label,nickname:([$registry.accounts[]? | select(.provider==$a.provider and .label==$a.label) | .nickname // empty][0] // null),
          projects:(group_by(.repo // "(no repo)") | map({repo:(.[0].repo // "(no repo)"),sessions:session_count,last_ts:(map(.ts)|max)}))})),
       unknown_sessions:([$rows[] | select(.label=="unknown")] | group_by([.provider,.repo]) | map(session_count) | add // 0),
       annotations:([$rows[] | select(.provider=="claude" and (.label|contains("@"))) |
          select(.account_email|type=="string" and length<=254 and test("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,63}\\z")) |
          select((.label|ascii_downcase)!=(.account_email|ascii_downcase)) |
          {provider,label,kind:"possible_mislabel",account_email}]|unique)}' < "$input") || exit 5
    if [ "$json" = 1 ]; then printf '%s\n' "$result"; else
      printf '%s\n' "$result" | jq -r '(.accounts[] | "\(.provider) \(.label)\(if .nickname then " (\(.nickname))" else "" end): " + ([.projects[] | "\(.repo) ×\(.sessions) (last \(.last_ts))"]|join(", "))), (.annotations[] | "WARNING possible mislabel: \(.provider) \(.label), account metadata \(.account_email)")'
    fi
    ;;
  install-codex-hooks)
    temp=""
    trap '[ -z "$temp" ] || [ ! -f "$temp" ] || unlink "$temp"' EXIT
    hook=""
    for candidate in "$HOME/.claude/skills-worktree/.claude/hooks/ai-account-session-start.sh" "$HOME/.claude/hooks/ai-account-session-start.sh" "$SELF_DIR/../hooks/ai-account-session-start.sh"; do
      if [ -x "$candidate" ]; then hook="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"; break; fi
    done
    [ -n "$hook" ] || { echo 'account SessionStart hook unavailable' >&2; exit 5; }
    while IFS= read -r dir; do
      [ -d "$dir" ] || continue
      target="$dir/hooks.json"
      [ ! -L "$target" ] || { echo "refusing symlink: $target" >&2; exit 5; }
      existing='{}'; if [ -e "$target" ]; then existing=$(cat "$target") || exit 5; fi
      printf -v command '%q --provider codex --codex-home %q' "$hook" "$dir"
      umask 077
      temp=$(mktemp "$dir/.ledger-hooks.XXXXXX") || exit 5
      # Reject unexpected shapes instead of replacing user-owned hooks.
      if ! printf '%s\n' "$existing" | jq -s --arg command "$command" '
        select(length==1) | .[0] | select(type=="object") | .hooks = (.hooks // {}) |
        select(.hooks|type=="object") | .hooks.SessionStart = (.hooks.SessionStart // []) |
        select(.hooks.SessionStart|type=="array") |
        def covers($source): any(.hooks.SessionStart[]; . as $group |
          any(.hooks[]?; .command==$command) and
          (if (.matcher // "")=="" or .matcher=="*" then true
           else try ($source|test($group.matcher)) catch false end));
        . as $config |
        (["startup","resume","fork"] | map(. as $source | select(($config|covers($source))|not))) as $missing |
        if ($missing|length)==0 then . else
          .hooks.SessionStart += [{matcher:($missing|join("|")),hooks:[{type:"command",command:$command,timeout:5}]}] end' > "$temp" || [ ! -s "$temp" ]; then
        echo "invalid hooks configuration: $target" >&2; exit 5
      fi
      mv "$temp" "$target" || exit 5
      temp=""
      printf 'Installed metadata hook: %s (Codex hook support is version-dependent; use backfill when unsupported)\n' "$dir"
    done < <(profiles)
    ;;
  *) usage ;;
esac
