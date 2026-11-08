#!/usr/bin/env bash
# catalog: trust-worktree-repo — *(library — source, do not execute)* Lock-verified pending hook/trust setup state shared by scheduled and SessionStart sync

# The caller already holds the canonical config-sync state lock. A pending flag
# is committed BEFORE a mutator starts and cleared only after confirmed success.
# Unknown fields survive; malformed state and unverifiable ownership decline.
config_sync_pending_set() { # state-file hooks|trust true|false
  local file="$1" operation="$2" pending="$3" input tmp rc=0
  CONFIG_SYNC_PENDING_ERROR=""
  export CONFIG_SYNC_PENDING_ERROR
  case "$operation:$pending" in hooks:true|hooks:false|trust:true|trust:false) ;; *) return 2 ;; esac
  if [[ -z "${STATE_LOCK_TOKEN:-}" || "${STATE_LOCK_HELD_DIR:-}" != "$file.lock" ]] \
      || ! state_lock_assert_held; then
    CONFIG_SYNC_PENDING_ERROR=lock_unverifiable
    return 6
  fi
  if [[ -L "$file" || ( -e "$file" && ! -f "$file" ) ]]; then
    CONFIG_SYNC_PENDING_ERROR=state_not_regular
    return 4
  fi
  input='{}'
  if [[ -f "$file" ]]; then
    input=$(cat "$file" 2>/dev/null) || { CONFIG_SYNC_PENDING_ERROR=state_unreadable; return 4; }
  fi
  if ! printf '%s' "$input" | jq -e -s '
    length == 1 and (.[0] | type == "object" and
      (.pending_setup == null or (.pending_setup | type == "object" and
        ([.hooks,.trust] | all(. == null or type == "boolean")))))
  ' >/dev/null 2>&1; then
    CONFIG_SYNC_PENDING_ERROR=state_invalid
    return 4
  fi
  tmp=$(mktemp "${file}.pending.XXXXXX" 2>/dev/null) || { CONFIG_SYNC_PENDING_ERROR=temp_unavailable; return 5; }
  if ! printf '%s' "$input" | jq --arg operation "$operation" --argjson pending "$pending" '
    .pending_setup = (.pending_setup // {}) | .pending_setup[$operation] = $pending
  ' > "$tmp" 2>/dev/null || ! chmod 600 "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    CONFIG_SYNC_PENDING_ERROR=prepare_failed
    return 5
  fi
  state_lock_commit "$tmp" "$file" 2>/dev/null || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp" 2>/dev/null || true
    CONFIG_SYNC_PENDING_ERROR="commit_failed:$rc"
    return "$rc"
  fi
  # In particular, reject mv's directory-destination shape as a false commit.
  if [[ -L "$file" || ! -f "$file" ]] || ! jq -e --arg operation "$operation" --argjson pending "$pending" \
      '.pending_setup[$operation] == $pending' "$file" >/dev/null 2>&1; then
    CONFIG_SYNC_PENDING_ERROR=commit_unverified
    return 5
  fi
  if ! state_lock_assert_held; then
    CONFIG_SYNC_PENDING_ERROR=lock_lost_after_commit
    return 6
  fi
  return 0
}

config_sync_pending_view() { # Only known flags are safe to expose in summaries.
  local file="$1"
  if [[ -f "$file" && ! -L "$file" ]] && jq -c -e -s '
    select(length == 1) | .[0] | select(type == "object") |
    .pending_setup | if . == null then {hooks:null,trust:null}
    else select(type == "object") | {hooks,trust} |
      select([.[]] | all(. == null or type == "boolean")) end
  ' "$file" 2>/dev/null; then return 0; fi
  printf '%s\n' '{"hooks":null,"trust":null}'
  return 1
}
