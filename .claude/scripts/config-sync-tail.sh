#!/usr/bin/env bash
# catalog: trust-worktree-repo — Runs link verification or resolves and executes hook/trust setup inside the caller's bounded child
# No lock or deadline is acquired here: both belong to the calling sync process.
set -uo pipefail
mode="${1:-}"; [[ $# -eq 0 ]] || shift
skills=""; root_hint=""; hooks_script=""; state_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skills-worktree|--root-repo-hint|--hooks-script|--state-file)
      [[ $# -ge 2 ]] || exit 2
      case "$1" in
        --state-file) state_file="$2" ;;
        --skills-worktree) skills="$2" ;; --root-repo-hint) root_hint="$2" ;; --hooks-script) hooks_script="$2" ;;
      esac
      shift 2 ;;
    *) exit 2 ;;
  esac
done
[[ -n "${HOME:-}" ]] || { echo 'config-sync-tail: HOME unavailable' >&2; exit 4; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 4
resolve_tail_helper() {
  local name="$1" subdir="$2" candidate
  for candidate in "$skills/.claude/$subdir/$name" "$HOME/.claude/$subdir/$name" \
      "$script_dir/../$subdir/$name" "$script_dir/$name"; do
    if [[ -f "$candidate" && -r "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}
check_parent_lock() {
  local owner_token
  [[ "$state_file" == /* && "${CLAUDE_STATE_LOCK_HELD:-}" == "$state_file.lock" \
     && -n "${CLAUDE_STATE_LOCK_TOKEN:-}" ]] || return 6
  owner_token=$(awk '/^token=/{sub(/^token=/, ""); print; exit}' "$CLAUDE_STATE_LOCK_HELD/owner" 2>/dev/null) || return 6
  [[ "$owner_token" == "$CLAUDE_STATE_LOCK_TOKEN" ]]
}
case "$mode" in
  verify)
    verify_link() {
      local link="$1"
      [[ -L "$link" ]] || return 0
      [[ -e "$link" ]] && return 0
      printf 'dangling symlink: %s -> %s\n' "$link" "$(readlink "$link" 2>/dev/null)"
    }
    verify_link "$HOME/.claude/CLAUDE.md"
    verify_link "$HOME/.claude/rules"
    for directory in "$HOME/.claude/skills" "$HOME/.claude/agents"; do
      [[ -d "$directory" ]] || continue
      for link in "$directory"/*; do verify_link "$link"; done
    done
    exit 0 ;;
  hooks)
    [[ "$skills" == /* ]] || { echo 'config-sync-tail: worktree path unavailable' >&2; exit 4; }
    if [[ -z "$hooks_script" ]]; then hooks_script=$(resolve_tail_helper register-hooks.py hooks) || hooks_script=""; fi
    [[ -n "$hooks_script" && -f "$hooks_script" && -r "$hooks_script" ]] \
      || { echo 'config-sync-tail: register-hooks.py unavailable' >&2; exit 4; }
    command -v python3 >/dev/null 2>&1 || { echo 'config-sync-tail: python3 unavailable' >&2; exit 4; }
    if [[ -n "$root_hint" ]]; then
      export MANAGED_LEGACY_HOOKS_DIR="$root_hint/.claude/hooks"
    fi
    check_parent_lock || { echo 'config-sync-tail: parent lock ownership unavailable — setup declined' >&2; exit 6; }
    exec python3 "$hooks_script" "$skills" ;;
  trust)
    [[ "$skills" == /* ]] || { echo 'config-sync-tail: worktree path unavailable' >&2; exit 4; }
    helper=$(resolve_tail_helper repair-trust-all.sh scripts) || helper=""
    [[ -n "$helper" ]] || { echo 'config-sync-tail: repair-trust-all.sh unavailable' >&2; exit 4; }
    check_parent_lock || { echo 'config-sync-tail: parent lock ownership unavailable — setup declined' >&2; exit 6; }
    exec bash "$helper" ;;
  *) echo 'Usage: config-sync-tail.sh verify|hooks|trust [--skills-worktree PATH] [--root-repo-hint PATH] [--hooks-script PATH] --state-file PATH' >&2; exit 2 ;;
esac
