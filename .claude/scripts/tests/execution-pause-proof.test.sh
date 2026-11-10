#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATE="$ROOT/.claude/scripts/execution-pause.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export CLAUDE_SESSION_STATE_FILE="$TMP/state.json"
export CLAUDE_EXECUTION_PAUSE_MARKER_DIR="$TMP/markers"
SID=11111111-1111-4111-8111-111111111111
SIBLING=22222222-2222-4222-8222-222222222222

gate() { "$GATE" --repo owner/repo --session "$SID" "$@"; }
must_hold() {
  local rc=0
  "$@" > "$TMP/refused.out" 2> "$TMP/refused.err" || rc=$?
  [[ "$rc" -eq 4 && ! -s "$TMP/refused.out" ]]
}

must_hold gate --end-proof
gate --activate --command end --window-minutes 5
proof="$(gate --end-proof)"
printf '%s\n' "$proof" | jq -e --arg sid "$SID" \
  '.command == "end" and .session_id == $sid and .window_minutes == 5 and (.at | type) == "string"' >/dev/null
[[ "$(gate --status)" == active ]]
must_hold "$GATE" --repo owner/other --session "$SID" --end-proof
must_hold "$GATE" --repo owner/repo --session "$SIBLING" --end-proof

shopt -s nullglob
markers=("$CLAUDE_EXECUTION_PAUSE_MARKER_DIR"/*)
[[ "${#markers[@]}" -eq 1 ]]
marker="${markers[0]}"
cp "$marker" "$TMP/saved-marker"
jq '.window_minutes += 1' "$marker" > "$TMP/changed-marker"
mv "$TMP/changed-marker" "$marker"
must_hold gate --end-proof
[[ "$(gate --status)" == active ]]
cp "$TMP/saved-marker" "$marker"
[[ "$(gate --end-proof)" == "$proof" ]]
mv "$marker" "$TMP/moved-marker"
ln -s "$TMP/moved-marker" "$marker"
must_hold gate --end-proof
mv -f "$TMP/moved-marker" "$marker"
[[ "$(gate --end-proof)" == "$proof" ]]

gate --activate --command pause --window-minutes 5
must_hold gate --end-proof
[[ "$(gate --status)" == active ]]
gate --clear
must_hold gate --end-proof
[[ "$(gate --status)" == inactive ]]
echo 'OK: scoped execution-pause proof requires matching active /end evidence'
