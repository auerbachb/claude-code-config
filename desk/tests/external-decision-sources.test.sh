#!/usr/bin/env bash
# Exercise the native adapter payloads and a local import against a scratch
# schema. All accounts, worktrees and wake targets below are synthetic.
set -euo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
hq_t_require_db "external-decision-sources.test.sh"
HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

export HUMAN_QUEUE_SCHEMA="hq_test_$$_${RANDOM}_sources"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hq-source-test.XXXXXX")
cleanup() {
  hq_psql -At -c "DROP SCHEMA IF EXISTS $HUMAN_QUEUE_SCHEMA CASCADE;" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  hq__cleanup_tmp
}
trap cleanup EXIT
export HOME="$tmp/home" AI_QUOTAS_CONFIG="$tmp/registry.json" CODEX_HOME="$tmp/profile"
mkdir -p "$HOME/.claude" "$CODEX_HOME" "$tmp/bin" "$tmp/work"
export HUMAN_QUEUE_CLI="$HQ_T_CLI"
export HQ_FAKE_CODEX_LOG="$tmp/queued"
cat > "$tmp/bin/codex" <<'SH'
#!/bin/bash
printf '%s\n' "$CODEX_HOME" "$@" >> "$HQ_FAKE_CODEX_LOG"
SH
chmod +x "$tmp/bin/codex"
export PATH="$tmp/bin:$PATH" DESK_CODEX_BIN="$tmp/bin/codex"
git -C "$tmp/work" init -q
git -C "$tmp/work" symbolic-ref HEAD refs/heads/codex/issue-1762-fixture
git -C "$tmp/work" remote add origin https://example.invalid/owner/repo.git
jq -n --arg p "$CODEX_HOME" '{accounts:[
  {provider:"codex",label:"codex@example.invalid",nickname:"Codex Work",profile_dir:$p},
  {provider:"cursor",label:"cursor@example.invalid",nickname:"Cursor Work",profile_dir:""}]}' > "$AI_QUOTAS_CONFIG"
adapter() { python3 "$HQ_T_DESK_DIR/hooks/external_capture.py" "$@"; }
adapter init-route
"$HQ_T_CLI" migrate >/dev/null
"$HQ_T_CLI" register-control fixture-control >/dev/null
"$HQ_T_CLI" tick --session fixture-control >/dev/null

sid=11111111-aaaa-4aaa-8aaa-111111111111
cat > "$tmp/decision" <<'BLOCK'
Private surrounding message should not be persisted.
```desk-decision
{"question":"Ship the fixture?","options":["Ship","Wait"],"default":"Wait"}
```
BLOCK
jq -n --rawfile m "$tmp/decision" --arg w "$tmp/work" --arg s "$sid" \
  '{hook_event_name:"Stop",last_assistant_message:$m,cwd:$w,session_id:$s,turn_id:"turn-1",
    transcript_path:"/not/a/source"}' > "$tmp/codex.json"
jq -n --rawfile m "$tmp/decision" --arg w "$tmp/work" \
  '{hook_event_name:"afterAgentResponse",text:$m,workspace_roots:[$w],conversation_id:"cursor-1",
    generation_id:"generation-1",user_email:"CURSOR@example.invalid",transcript_path:"/not/a/source"}' > "$tmp/cursor.json"

check "Codex Stop accepts the explicit Decision without continuing" "$(adapter codex < "$tmp/codex.json")" '{}'
adapter cursor < "$tmp/cursor.json"
check "local fallback imports just the Decision" \
  "$(adapter import --repo owner/repo --key issue-1762 < "$tmp/decision")" D-3
"$HQ_T_CLI" add --kind decision --repo owner/repo --key issue-1762 --question 'Ship the fixture?' --option Ship --option Wait >/dev/null
rows=$("$HQ_T_CLI" list --kind decision --json)
check "mixed sources keep independent routing for the same question" \
  "$(jq -r 'sort_by(.id)|map([.id,.source_tool,.source_account,.session_id]|join(":"))|join("|")' <<< "$rows")" \
  "D-1:codex:Codex Work:$sid|D-2:cursor:Cursor Work:|D-3:local:unknown:|D-4:::"
check "all four questions fit the same desk menu with the canonical issue key" \
  "$(jq -L "$HQ_T_DESK_DIR/skill" -c 'include "desk"; desk_batch("";4).sets' <<< "$rows")" \
  '[["D-1","D-2","D-3","D-4"]]'
check "the Codex branch resolves to the portable issue key" \
  "$(jq -r '.[] | select(.source_tool=="codex") | .key' <<< "$rows")" issue-1762
check_absent "surrounding message was not stored" "$rows" 'Private surrounding message'
check_absent "registry email was not stored" "$rows" '@example.invalid'
profile_physical=$(cd -P "$CODEX_HOME" && pwd)
check_absent "profile directory was not stored" "$rows" "$profile_physical"
card=$(jq -L "$HQ_T_DESK_DIR/skill" -r 'include "desk"; .[] | select(.id=="D-2") | item_lines' <<< "$rows")
check_contains "desk card shows Cursor nickname" "$card" 'Source: cursor · Cursor Work'
check_contains "desk card says Cursor answer stays in the store" "$card" 'store only'

"$HQ_T_CLI" answer D-1 A >/dev/null
adapter codex < "$tmp/codex.json" >/dev/null
check "replaying an answered native event does not reopen it" \
  "$("$HQ_T_CLI" get D-1 --json | jq -r .status)" answered
check "replay did not add a fifth Decision" \
  "$("$HQ_T_CLI" list --kind decision --json | jq length)" 4
rc=0; DESK_CODEX_BIN=codex adapter wake D-1 || rc=$?
check "a PATH-only launcher is never executed" "$rc" 5
check "a refused launcher received no pointer" "$([ -f "$HQ_FAKE_CODEX_LOG" ] && echo yes || echo no)" no
adapter wake D-1
check "Codex gets only the pointer on the exact profile and thread" "$(cat "$HQ_FAKE_CODEX_LOG")" \
  "$(printf '%s\n' "$profile_physical" queue --thread "$sid" --message 'human-queue: D-1 answered')"
"$HQ_T_CLI" wake D-1 --result sent >/dev/null
mv "$HOME/.claude/desk-decision-route-id" "$tmp/original-route"
adapter init-route
rc=0; adapter wake D-1 || rc=$?
check "a different installation cannot route the Codex answer" "$rc" 5
check "failed route did not send another pointer" "$(hq_t_lines "$(cat "$HQ_FAKE_CODEX_LOG")")" 6

"$HQ_T_CLI" answer D-2 B >/dev/null
check "store-only answers park immediately and are not retried" \
  "$("$HQ_T_CLI" wake D-2 --result store-only --json | jq -r '[.status,.retries_left]|join(":")')" \
  'answer-parked:0'
check_contains "the next thread can retrieve the stored answer" \
  "$("$HQ_T_CLI" pending-for --repo owner/repo --key issue-1762 --json)" '"D-2"'
jq '.turn_id="turn-2"|.last_assistant_message="Plain prose is not a Decision."' "$tmp/codex.json" \
  | adapter codex >/dev/null
check "unmarked prose is never captured" "$("$HQ_T_CLI" list --kind decision --json | jq length)" 4
jq '.turn_id="turn-3"|.last_assistant_message |= sub("Ship the fixture[?]"; "unsafe\\u0000question")' \
  "$tmp/codex.json" | adapter codex > "$tmp/malformed-out" 2> "$tmp/malformed-err"
check "a malformed explicit block does not disrupt Codex Stop" "$(cat "$tmp/malformed-out")" '{}'
check "a malformed explicit block never adds a Decision" "$("$HQ_T_CLI" list --kind decision --json | jq length)" 4
check_absent "a malformed Decision is not printed in diagnostics" "$(cat "$tmp/malformed-err")" 'unsafe'
jq '.accounts |= . + [.[1]]' "$AI_QUOTAS_CONFIG" > "$tmp/ambiguous-registry"
mv "$tmp/ambiguous-registry" "$AI_QUOTAS_CONFIG"
jq '.generation_id="generation-2"' "$tmp/cursor.json" | adapter cursor
check "ambiguous account evidence stays unknown and has no return session" \
  "$("$HQ_T_CLI" get D-5 --json | jq -r '[.source_account,.session_id]|join(":")')" 'unknown:'
hq_t_finish "external-decision-sources.test.sh"
