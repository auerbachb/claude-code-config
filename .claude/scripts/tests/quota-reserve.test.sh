#!/usr/bin/env bash
# Tests for .claude/scripts/quota-reserve.sh (issue #1863).
# catalog: tests — Tests `quota-reserve.sh` offline — marker building from reported weekly usage (threshold, weekly-only, unknown, config and env precedence), refresh freshness/locking/failure handling, once-per-crossing notification, and the `--decide` matrix (launches, subagents, automated vs interactive turns, every fail-open path) plus turn classification
#
# Every case is offline: the quota reader is a stub that prints canned rows, the
# notifier is a stub that logs its message, and HOME is a sandbox, so nothing here
# touches the developer's real ~/.claude or any provider.
#
# The property under test throughout is the one the feature must never lose:
# the owner's own interactive turns are never blocked, and a reading that is not
# both fresh and known never stops work.
#
# Usage: bash .claude/scripts/tests/quota-reserve.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/quota-reserve.sh"

TMP="$(mktemp -d)"
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
unset QUOTA_RESERVE_THRESHOLD_PCT QUOTA_RESERVE_ENABLED CLAUDE_ACCOUNT_CONFIG CLAUDE_CONFIG_DIR
export QUOTA_RESERVE_DIR="$TMP/qr"
export QUOTA_RESERVE_CLAUDE_JSON="$TMP/session-claude.json"
export QUOTA_RESERVE_AI_QUOTAS_SH="$TMP/bin/ai-quotas.sh"
export QUOTA_RESERVE_NOTIFY_CMD="$TMP/bin/notify.sh"
export AI_QUOTAS_CONFIG="$TMP/quota-launchers.json"
mkdir -p "$TMP/bin"

PASS=0; FAILED=0
ok() { echo "ok   — $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
check_eq() { # <actual> <expected> <label>
  if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3 (want '$2', got '$1')"; fi
}
check_contains() { # <haystack> <needle> <label>
  if [[ "$1" == *"$2"* ]]; then ok "$3"; else fail "$3 (no '$2' in '$1')"; fi
}

[[ -x "$SCRIPT" ]] || { echo "FAIL: quota-reserve.sh missing or not executable" >&2; exit 1; }

# --- stubs -------------------------------------------------------------------
STUB_ROWS="$TMP/rows.json"; STUB_FAIL="$TMP/reader-fails"; READER_LOG="$TMP/reader.log"; NOTIFY_LOG="$TMP/notify.log"
cat > "$TMP/bin/ai-quotas.sh" <<EOF
#!/usr/bin/env bash
printf 'call history=%s source=%s args=%s\n' "\${AI_QUOTAS_HISTORY:-<unset>}" "\${AI_QUOTAS_SOURCE:-<unset>}" "\$*" >> "$READER_LOG"
[[ -f "$STUB_FAIL" ]] && exit 1
cat "$STUB_ROWS"
EOF
cat > "$TMP/bin/notify.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$NOTIFY_LOG"
EOF
chmod +x "$TMP/bin/ai-quotas.sh" "$TMP/bin/notify.sh"

row() { # <provider> <label> <nickname> <email> <window> <status> <used|null>
  jq -nc --arg p "$1" --arg l "$2" --arg n "$3" --arg e "$4" --arg w "$5" --arg s "$6" --argjson u "$7" \
    '{provider: $p, label: $l, nickname: $n, reported_email: $e, window: $w, status: $s, used_pct: $u, resets_at_epoch: 1800000000}'
}
rows() { local out="[" first=1 r; for r in "$@"; do [[ $first == 1 ]] || out+=","; out+="$r"; first=0; done; printf '{"rows": %s]}' "$out" | sed 's/\[\]/[]/' > "$STUB_ROWS"; }
state_of() { jq -r --arg l "$1" '.accounts[] | select(.label == $l) | .state' "$QUOTA_RESERVE_DIR/marker.json" 2>/dev/null; }
field_of() { jq -r --arg l "$1" --arg f "$2" '.accounts[] | select(.label == $l) | .[$f]' "$QUOTA_RESERVE_DIR/marker.json" 2>/dev/null; }
reset_state() { rm -rf "$QUOTA_RESERVE_DIR" "$READER_LOG" "$NOTIFY_LOG" "$STUB_FAIL" "$TMP/session-claude.json"; unset QUOTA_RESERVE_NOW QUOTA_RESERVE_THRESHOLD_PCT QUOTA_RESERVE_ENABLED; }
# Wait (bounded) for a background refresh to finish: a valid marker and no lock.
wait_refresh() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if jq -e '.accounts | type == "array"' "$QUOTA_RESERVE_DIR/marker.json" >/dev/null 2>&1 && [[ ! -d "$QUOTA_RESERVE_DIR/refresh.lock" ]]; then return 0; fi
    sleep 0.5
  done
  return 1
}
# Wait (bounded) until the reader log holds at least <n> calls. Polling beats a fixed sleep on a loaded runner.
wait_calls() {
  local _ n="$1"
  for _ in $(seq 1 40); do
    if [[ "$(reader_calls)" -ge "$n" ]]; then return 0; fi
    sleep 0.5
  done
  return 1
}
reader_calls() { [[ -f "$READER_LOG" ]] && wc -l < "$READER_LOG" | tr -d ' ' || echo 0; }
session_as() { jq -n --arg e "$1" '{oauthAccount: {emailAddress: $e}}' > "$QUOTA_RESERVE_CLAUDE_JSON"; }
decide() { # <payload-json> -> verdict line
  printf '%s' "$1" | "$SCRIPT" --decide 2>/dev/null
}
payload() { # <tool> [extra-json-object]
  local extra="${2:-}"
  [[ -n "$extra" ]] || extra='{}'
  jq -nc --arg t "$1" --argjson x "$extra" '{tool_name: $t, session_id: "sess-1", tool_input: {}, cwd: "/tmp"} + $x'
}

CLAUDE_A="a@example.com"; CLAUDE_B="b@example.com"; CLAUDE_D="d@example.com"

# ------------------------------------------------------------------------------
# 1. --refresh builds the marker from the reported weekly usage
# ------------------------------------------------------------------------------
reset_state
rows \
  "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 94)" \
  "$(row claude a@example.com 'Claude A' $CLAUDE_A 5-hour ok 99)" \
  "$(row claude b@example.com 'Claude B' $CLAUDE_B 7-day ok 95)" \
  "$(row claude b@example.com 'Claude B' $CLAUDE_B '7-day (opus)' ok 97)" \
  "$(row claude d@example.com 'Claude D' $CLAUDE_D 7-day needs-login null)" \
  "$(row claude e@example.com 'Claude E' e@example.com 7-day ok 95)" \
  "$(row codex c@example.com 'GPT C' c@example.com 7-day ok 20)" \
  "$(row cursor cu 'Cursor' cu@example.com cursor-models ok 100)"
"$SCRIPT" --refresh --force; RC=$?
check_eq "$RC" "0" "refresh exits 0"
check_eq "$(state_of a@example.com)" "ok" "94% is below the 95% default threshold"
check_eq "$(field_of a@example.com used_pct)" "94" "the five-hour 99% row is ignored; only the weekly window counts"
check_eq "$(state_of e@example.com)" "reserve" "exactly 95% on the weekly window alone is in reserve (at or above, not strictly above)"
check_eq "$(state_of b@example.com)" "reserve" "an account at 95% and 97% across two weekly rows is in reserve"
check_eq "$(field_of b@example.com used_pct)" "97" "the highest weekly row wins (the opus weekly row)"
check_eq "$(state_of d@example.com)" "unknown" "a needs-login account is unknown, never ok and never reserve"
check_eq "$(field_of d@example.com used_pct)" "null" "and carries no invented figure"
check_eq "$(state_of c@example.com)" "ok" "a Codex account is tracked in the marker"
check_eq "$(jq -r '[.accounts[].provider] | unique | join(",")' "$QUOTA_RESERVE_DIR/marker.json")" "claude,codex" \
  "Cursor is not in the marker: it has no hook surface"
check_eq "$(ls -l "$QUOTA_RESERVE_DIR/marker.json" | cut -c1-10)" "-rw-------" "the marker is private to the owner"
check_contains "$(cat "$READER_LOG")" "history=$QUOTA_RESERVE_DIR/reader-history.jsonl" \
  "the reader runs with its history redirected, so refreshes do not pollute the daily record"
check_contains "$(cat "$READER_LOG")" "source=manual" \
  "reserve refresh explicitly clears scheduled notification context"

# threshold: env, config, precedence, garbage
reset_state
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 94)"
QUOTA_RESERVE_THRESHOLD_PCT=90 "$SCRIPT" --refresh --force
check_eq "$(state_of a@example.com)" "reserve" "QUOTA_RESERVE_THRESHOLD_PCT=90 puts 94% in reserve"
reset_state
printf '## Quota reserve\n\n```ini\nthreshold_pct = 80\n```\n' > "$TMP/cfg.md"
CLAUDE_ACCOUNT_CONFIG="$TMP/cfg.md" "$SCRIPT" --refresh --force
check_eq "$(jq -r .threshold_pct "$QUOTA_RESERVE_DIR/marker.json")" "80" "the account config's threshold_pct is read"
reset_state
CLAUDE_ACCOUNT_CONFIG="$TMP/cfg.md" QUOTA_RESERVE_THRESHOLD_PCT=99 "$SCRIPT" --refresh --force
check_eq "$(jq -r .threshold_pct "$QUOTA_RESERVE_DIR/marker.json")" "99" "the environment wins over the config"
reset_state
OUT="$(QUOTA_RESERVE_THRESHOLD_PCT=abc "$SCRIPT" --refresh --force 2>&1)"
check_eq "$(jq -r .threshold_pct "$QUOTA_RESERVE_DIR/marker.json")" "95" "a non-numeric threshold falls back to 95"
check_contains "$OUT" "not 1-100" "and says so"
reset_state
QUOTA_RESERVE_THRESHOLD_PCT=0 "$SCRIPT" --refresh --force 2>/dev/null
check_eq "$(jq -r .threshold_pct "$QUOTA_RESERVE_DIR/marker.json")" "95" "a threshold of 0 would reserve everything, so it is refused"
printf '## Quota reserve\n\n<!--\nthreshold_pct = 10\n-->\n```ini\nthreshold_pct = 85\n```\n' > "$TMP/cfg2.md"
reset_state
CLAUDE_ACCOUNT_CONFIG="$TMP/cfg2.md" "$SCRIPT" --refresh --force
check_eq "$(jq -r .threshold_pct "$QUOTA_RESERVE_DIR/marker.json")" "85" "a value inside an HTML comment is a note, not a setting"
reset_state
QUOTA_RESERVE_ENABLED=false "$SCRIPT" --refresh --force
check_eq "$(jq -r .enabled "$QUOTA_RESERVE_DIR/marker.json")" "false" "enabled=false is recorded in the marker"

# ------------------------------------------------------------------------------
# 2. Freshness, locking, and failure handling
# ------------------------------------------------------------------------------
reset_state
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 10)"
export QUOTA_RESERVE_NOW=1000000
"$SCRIPT" --refresh
check_eq "$(reader_calls)" "1" "the first refresh reads the providers"
export QUOTA_RESERVE_NOW=1000100
"$SCRIPT" --refresh
check_eq "$(reader_calls)" "1" "a marker younger than 10 minutes is left alone"
"$SCRIPT" --refresh --force
check_eq "$(reader_calls)" "2" "--force refreshes regardless"
export QUOTA_RESERVE_NOW=1000800
"$SCRIPT" --refresh
check_eq "$(reader_calls)" "3" "a marker older than 10 minutes is refreshed"

# a failed read keeps the old marker and does not advance its read time
before="$(jq -r .read_at "$QUOTA_RESERVE_DIR/marker.json")"
touch "$STUB_FAIL"; export QUOTA_RESERVE_NOW=1002000
"$SCRIPT" --refresh --force 2>/dev/null; RC=$?
check_eq "$RC" "3" "a failed read exits 3"
check_eq "$(jq -r .read_at "$QUOTA_RESERVE_DIR/marker.json")" "$before" \
  "and leaves the previous marker untouched, so it keeps ageing toward stale"
rm -f "$STUB_FAIL"
printf 'not json' > "$STUB_ROWS"
"$SCRIPT" --refresh --force 2>/dev/null; RC=$?
check_eq "$RC" "3" "a reader that prints garbage exits 3"
check_eq "$(jq -r .read_at "$QUOTA_RESERVE_DIR/marker.json")" "$before" "and the marker is still the old one"
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 10)"

# locking
rm -rf "$READER_LOG"; mkdir -p "$QUOTA_RESERVE_DIR/refresh.lock"
"$SCRIPT" --refresh --force
check_eq "$(reader_calls)" "0" "a fresh lock means another refresh is running, so this one backs off"
touch -t 202001010000 "$QUOTA_RESERVE_DIR/refresh.lock"
"$SCRIPT" --refresh --force
check_eq "$(reader_calls)" "1" "a lock older than five minutes is a crashed run and is taken over"
check_eq "$([[ -d "$QUOTA_RESERVE_DIR/refresh.lock" ]] && echo present || echo gone)" "gone" "and the lock is released afterwards"

# ------------------------------------------------------------------------------
# 3. Notification: once per crossing, in either direction
# ------------------------------------------------------------------------------
reset_state
export QUOTA_RESERVE_NOW=2000000
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 90)"
"$SCRIPT" --refresh --force
check_eq "$([[ -f "$NOTIFY_LOG" ]] && wc -l < "$NOTIFY_LOG" | tr -d ' ' || echo 0)" "0" "the first reading notifies nobody"
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 96)"
"$SCRIPT" --refresh --force
check_eq "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" "1" "crossing the threshold notifies once"
check_contains "$(cat "$NOTIFY_LOG")" "Claude A is at 96%" "and names the account and the figure"
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 97)"
"$SCRIPT" --refresh --force
check_eq "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" "1" "staying in reserve does not notify again"
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 3)"
"$SCRIPT" --refresh --force
check_eq "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" "2" "dropping back under notifies once more"
check_contains "$(tail -n 1 "$NOTIFY_LOG")" "back under the limit" "saying work can resume"
# an unreadable reading is not a crossing in either direction
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day needs-login null)"
"$SCRIPT" --refresh --force
check_eq "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" "2" "ok to unknown is not announced"

# Real roster helper and launcher registry, synthetic quotas and notifier.
reset_state
export QUOTA_RESERVE_NOW=2000000
mkdir -p "$TMP/profile-a" "$TMP/profile-b" "$TMP/profile-d"
jq -n --arg p "$TMP" '{schema_version:"1.0",accounts:[
  {provider:"claude",label:"a@example.com",nickname:"Claude A",profile_dir:($p+"/profile-a")},
  {provider:"claude",label:"b@example.com",nickname:"Claude B",profile_dir:($p+"/profile-b")},
  {provider:"claude",label:"d@example.com",nickname:"Claude D",profile_dir:($p+"/profile-d")} ]}' > "$AI_QUOTAS_CONFIG"
a_week() { row claude "$CLAUDE_A" 'Claude A' "$CLAUDE_A" 7-day "${2:-ok}" "$1"; }
b_week() { row claude "$CLAUDE_B" 'Claude B' "$CLAUDE_B" 7-day "${2:-ok}" "$1"; }
d_week() { row claude "$CLAUDE_D" 'Claude D' "$CLAUDE_D" 7-day "${2:-ok}" "$1"; }
notices() { if [[ -f "$NOTIFY_LOG" ]]; then wc -l < "$NOTIFY_LOG" | tr -d ' '; else echo 0; fi; }
rows "$(a_week 90)" "$(b_week 25)" "$(d_week 45)"
"$SCRIPT" --refresh --force
rows "$(a_week 96)" "$(b_week 25)" "$(d_week 45)"
"$SCRIPT" --refresh --force
check_eq "$(notices)" 1 "the suggestion is part of the single crossing notice"
check_contains "$(cat "$NOTIFY_LOG")" "/go-on --resume-options --target claude-b" "the exact best alternate is passed to the manual list"
check_eq "$(reader_calls)" 2 "the suggestion makes no extra quota read"
session_as "$CLAUDE_A"
decide "$(payload Agent)" >/dev/null
decide "$(payload Bash)" >/dev/null
check_eq "$(notices)" 1 "tool calls do not send extra suggestions"
rows "$(a_week null unreachable)" "$(b_week 25)" "$(d_week 45)"
"$SCRIPT" --refresh --force
check_eq "$(state_of "$CLAUDE_A")" unknown "unreadable source still fails open in the guard"
check_eq "$(decide "$(payload Agent)")" "allow unknown" "remembered notice state does not pause an unreadable account"
check_eq "$(notices)" 1 "unreadable source does not send false recovery"
rows "$(a_week 97)" "$(b_week 25)" "$(d_week 45)"
"$SCRIPT" --refresh --force
check_eq "$(notices)" 1 "return to the same confirmed state is not a duplicate crossing"
rows "$(a_week 90)" "$(b_week 95)" "$(d_week null needs-login)"
"$SCRIPT" --refresh --force
check_contains "$(cat "$NOTIFY_LOG")" "Claude A is back under the limit" "confirmed recovery follows unreadable interval"
check_contains "$(tail -n 1 "$NOTIFY_LOG")" "--target claude-a" "a simultaneous B crossing binds its own source and suggestion"
rows "$(a_week 98)" "$(b_week 95)" "$(d_week null needs-login)"
"$SCRIPT" --refresh --force
check_contains "$(tail -n 1 "$NOTIFY_LOG")" "No other account has room" "definitively ineligible alternatives are distinguished"
rows "$(a_week 90)" "$(b_week 25)" "$(d_week null unreachable)"
"$SCRIPT" --refresh --force
rows "$(a_week 98)" "$(b_week 25)" "$(d_week null unreachable)"
"$SCRIPT" --refresh --force
check_contains "$(tail -n 1 "$NOTIFY_LOG")" "Next account unknown" "an unreadable alternative can conceal the best account"
rows "$(a_week 90)" "$(b_week 25)" "$(d_week 45 | jq '.resets_at_epoch = 1999999')"
"$SCRIPT" --refresh --force
rows "$(a_week 98)" "$(b_week 25)" "$(d_week 45 | jq '.resets_at_epoch = 1999999')"
"$SCRIPT" --refresh --force
check_contains "$(tail -n 1 "$NOTIFY_LOG")" "Next account unknown" "a spent provider window is not ranked"
printf '{"accounts":["invalid old entry"]}\n' > "$QUOTA_RESERVE_DIR/marker.json"
rows "$(a_week 90)" "$(b_week 25)" "$(d_week 45)"
"$SCRIPT" --refresh --force
check_eq "$(state_of "$CLAUDE_A")" ok "malformed old notice data cannot block a new guard reading"
# A renderer failure is visible, but the installed reading still guards.
QUOTA_TEST_REAL_JQ="$(command -v jq)"
export QUOTA_TEST_REAL_JQ
mkdir -p "$TMP/render-failure"
cat > "$TMP/render-failure/jq" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -nc && "$*" == *'--slurpfile n '* ]]; then exit 9; fi
exec "$QUOTA_TEST_REAL_JQ" "$@"
EOF
chmod +x "$TMP/render-failure/jq"
rows "$(a_week 98)" "$(b_week 25)" "$(d_week 45)"
render_failure=$(PATH="$TMP/render-failure:$PATH" "$SCRIPT" --refresh --force 2>&1)
check_contains "$render_failure" "could not prepare the reserve crossing notification" "notification renderer failure is visible"
check_eq "$(state_of "$CLAUDE_A")" reserve "renderer failure does not discard the new guard state"

# ------------------------------------------------------------------------------
# 4. --decide
# ------------------------------------------------------------------------------
reset_state
export QUOTA_RESERVE_NOW=3000000
rows \
  "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 96)" \
  "$(row claude b@example.com 'Claude B' $CLAUDE_B 7-day ok 40)" \
  "$(row claude d@example.com 'Claude D' $CLAUDE_D 7-day needs-login null)"
"$SCRIPT" --refresh --force
session_as "$CLAUDE_A"

# fail-open paths
check_eq "$(QUOTA_RESERVE_ENABLED=0 decide "$(payload Agent)")" "allow disabled" "disabled: allow"
check_eq "$(decide 'not json')" "allow unreadable hook payload" "a garbage payload is allowed"
check_eq "$(printf '' | "$SCRIPT" --decide 2>/dev/null)" "allow unreadable hook payload" "an empty payload is allowed"
rm -f "$QUOTA_RESERVE_CLAUDE_JSON"
check_eq "$(decide "$(payload Agent)")" "allow session account unknown" "an unreadable session account file is allowed"
session_as "stranger@example.com"
check_eq "$(decide "$(payload Agent)")" "allow account not in marker" "a session on an account the marker does not know is allowed"
session_as "$CLAUDE_B"
check_eq "$(decide "$(payload Agent)")" "allow ok" "a session on an account under the line is allowed, launches included"
session_as "$CLAUDE_D"
check_eq "$(decide "$(payload Agent)")" "allow unknown" "an account whose reading is unknown is allowed"
session_as "A@Example.COM"
check_contains "$(decide "$(payload Agent)")" "deny" "the account email match is case-insensitive"
export QUOTA_RESERVE_NOW=$(( 3000000 + 1801 ))
check_eq "$(QUOTA_RESERVE_REFRESH_SECONDS=99999999 decide "$(payload Agent)")" "allow stale reading" "a reading older than 30 minutes is ignored"
export QUOTA_RESERVE_NOW=3000000
printf 'garbage' > "$QUOTA_RESERVE_DIR/marker.json"
check_eq "$(decide "$(payload Agent)")" "allow unreadable marker" "an unreadable marker is allowed"
wait_refresh   # that decision started a repairing refresh in the background; let it finish
check_eq "$(jq -r '.accounts | type' "$QUOTA_RESERVE_DIR/marker.json" 2>/dev/null)" "array" "and the background refresh repairs the marker"
rm -f "$QUOTA_RESERVE_DIR/marker.json"
export QUOTA_RESERVE_NOW=$(( 3000000 + 200 ))   # past the spawn throttle that the previous case started
check_eq "$(decide "$(payload Agent)")" "allow no reading yet" "no marker yet is allowed"
# …and that first decision starts a background refresh that creates the marker.
wait_refresh
check_eq "$([[ -f "$QUOTA_RESERVE_DIR/marker.json" ]] && echo built || echo missing)" "built" \
  "and a missing marker starts a background refresh"

# a failing reader must not be retried on every tool call
rm -rf "$QUOTA_RESERVE_DIR" "$READER_LOG"; "$SCRIPT" --refresh --force
touch "$STUB_FAIL"; export QUOTA_RESERVE_NOW=$(( 3000000 + 5000 ))
decide "$(payload Read)" >/dev/null; wait_calls 2; sleep 0.5
C1="$(reader_calls)"
for _ in 1 2 3 4 5; do decide "$(payload Read)" >/dev/null; done
sleep 1
check_eq "$(reader_calls)" "$C1" "five more tool calls inside the throttle window start no further refresh attempts"
export QUOTA_RESERVE_NOW=$(( 3000000 + 5000 + 121 ))
decide "$(payload Read)" >/dev/null; wait_calls $(( C1 + 1 )); sleep 1
check_eq "$(reader_calls)" "$(( C1 + 1 ))" "and once the window passes, exactly one more attempt is made"
rm -f "$STUB_FAIL"; export QUOTA_RESERVE_NOW=3000000
rm -rf "$QUOTA_RESERVE_DIR"; "$SCRIPT" --refresh --force

# the account in reserve
"$SCRIPT" --refresh --force
session_as "$CLAUDE_A"
V="$(decide "$(payload Read)")"
check_eq "$V" "allow interactive turn" "reserve: the owner's own Read is allowed"
check_eq "$(decide "$(payload Edit)")" "allow interactive turn" "reserve: the owner's own Edit is allowed"
check_eq "$(decide "$(payload Bash '{"tool_input":{"command":"gh pr view 1"}}')")" "allow interactive turn" \
  "reserve: the owner's own foreground shell is allowed"
for t in Agent Workflow Monitor CronCreate ScheduleWakeup RemoteTrigger mcp__ccd_session__start_session mcp__ccd_session__spawn_task mcp__ccd_session__hand_off_to_session mcp__ccd_session__move_to_cloud mcp__scheduled-tasks__create_scheduled_task mcp__scheduled-tasks__run_scheduled_task mcp__scheduled-tasks__update_scheduled_task; do
  V="$(decide "$(payload "$t")")"
  check_contains "$V" "deny" "reserve: $t is a launch and is blocked even in an interactive turn"
done
V="$(decide "$(payload Bash '{"tool_input":{"command":"sleep 99","run_in_background":true}}')")"
check_contains "$V" "deny" "reserve: background shell is blocked"
check_contains "$(decide "$(payload Agent)")" "Claude A is at 96%" "the message names the account and the figure"
check_contains "$(decide "$(payload Agent)")" "Your own messages still work" "and tells the owner their turns are unaffected"

# automated turns and subagents
mkdir -p "$QUOTA_RESERVE_DIR/turns"; printf 'automated\n' > "$QUOTA_RESERVE_DIR/turns/sess-1"
check_contains "$(decide "$(payload Edit)")" "deny" "reserve, automated turn: an Edit is blocked"
check_contains "$(decide "$(payload Write)")" "deny" "reserve, automated turn: a Write is blocked"
check_contains "$(decide "$(payload Bash '{"tool_input":{"command":"gh pr view 1"}}')")" "deny" "reserve, automated turn: ordinary shell work is blocked"
check_contains "$(decide "$(payload mcp__Figma__get_design_context)")" "deny" "reserve, automated turn: an MCP tool is blocked"
check_eq "$(decide "$(payload Read)")" "allow read-only while reserved" "reserve, automated turn: reads still work"
check_eq "$(decide "$(payload Grep)")" "allow read-only while reserved" "reserve, automated turn: grep still works"
check_eq "$(decide "$(payload Bash '{"tool_input":{"command":"~/x/.claude/scripts/session-state.sh --set a=1"}}')")" "allow bookkeeping while reserved" \
  "reserve, automated turn: session-state bookkeeping still works, so a pipeline can checkpoint"
check_eq "$(decide "$(payload Bash '{"tool_input":{"command":"cd /r && .claude/scripts/handoff-state.sh --owner-repo o/r --path 4"}}')")" "allow bookkeeping while reserved" \
  "reserve, automated turn: handoff writing still works"
check_eq "$(decide "$(payload Bash '{"tool_input":{"command":"cd /r/.claude/scripts && ./handoff-state.sh --owner-repo o/r --path 4"}}')")" "allow bookkeeping while reserved" \
  "reserve, automated turn: cd into a scripts directory and run the script by name is also a plain call"
check_eq "$(decide "$(payload Bash '{"tool_input":{"command":"cd .claude/scripts && session-state.sh --get a"}}')")" "allow bookkeeping while reserved" \
  "reserve, automated turn: the relative form of that is fine too"
check_eq "$(decide "$(payload Bash '{"tool_input":{"command":"FOO=1 .claude/scripts/execution-pause.sh --status"}}')")" "allow bookkeeping while reserved" \
  "reserve, automated turn: a VAR=value prefix is fine"
check_eq "$(decide "$(payload Bash '{"tool_input":{"command":"~/.claude/skills-worktree/.claude/scripts/session-state.sh --get .prs[\"4\"]"}}')")" "allow bookkeeping while reserved" \
  "reserve, automated turn: a published-path invocation with a jq path argument is fine"
# Discriminating: each of these MENTIONS or CHAINS to a bookkeeping script and must not pass.
for bad in \
  'gh pr merge 1 # session-state.sh' \
  'rm -rf /tmp/x # handoff-state.sh' \
  'session-state.sh --get a; gh pr merge 1' \
  'session-state.sh --get a && gh pr merge 1' \
  'session-state.sh --get a || gh pr merge 1' \
  'echo hi | session-state.sh --set a=1' \
  'session-state.sh --get $(gh pr merge 1)' \
  'session-state.sh --get `gh pr merge 1`' \
  'session-state.sh --get a > /tmp/out' \
  'cat .claude/scripts/session-state.sh' \
  'bash -c "session-state.sh --get a"' \
  'cd /r; .claude/scripts/handoff-state.sh --path 4' \
  '/tmp/session-state.sh --get a' \
  'session-state.sh --get a' \
  './session-state.sh --get a' \
  '/tmp/scripts/session-state.sh --get a' \
  'cd /tmp && ./session-state.sh --get a' \
  '/tmp/not.claude/scripts/session-state.sh --get a' \
  'cd /tmp/not.claude/scripts && ./session-state.sh --get a' \
  'cd /tmp/x.claude/scripts/ && session-state.sh --get a' \
  'cd /r/.claude/scripts && ./other.sh --get a' \
  'cd /r/.claude/scripts && ./session-state.sh --get a; rm -rf x' \
  'cd /r/.claude/scripts && ./session-state.sh --get a && gh pr merge 1' \
  $'session-state.sh --get a\ngh pr merge 1' \
  $'session-state.sh --get a\r\ngh pr merge 1'; do
  V="$(decide "$(jq -nc --arg c "$bad" '{tool_name:"Bash", session_id:"sess-1", tool_input:{command:$c}}')")"
  check_contains "$V" "deny" "reserve, automated turn: '${bad:0:44}' is not a plain bookkeeping call"
done
check_contains "$(decide "$(payload Edit)")" "Park this work" "and the refusal tells the agent to park"
printf 'interactive\n' > "$QUOTA_RESERVE_DIR/turns/sess-1"
check_contains "$(decide "$(payload Edit '{"agent_id":"sub-9"}')")" "deny" "reserve, subagent call: blocked even inside an interactive turn"
check_eq "$(decide "$(payload Read '{"agent_id":"sub-9"}')")" "allow read-only while reserved" "reserve, subagent call: reads still work"
printf 'automated garbage\n' > "$QUOTA_RESERVE_DIR/turns/sess-1"
check_eq "$(decide "$(payload Edit)")" "allow interactive turn" "an unrecognised turn record is treated as interactive"
rm -f "$QUOTA_RESERVE_DIR/turns/sess-1"
check_eq "$(decide "$(payload Edit)")" "allow interactive turn" "no turn record is treated as interactive"
mkdir -p "$QUOTA_RESERVE_DIR/turns/.."  ; printf 'automated\n' > "$QUOTA_RESERVE_DIR/automated-decoy"
V="$(decide "$(jq -nc '{tool_name:"Edit", session_id:"../automated-decoy", tool_input:{}}')")"
check_eq "$V" "allow interactive turn" "a session id with path characters is ignored, so it cannot point at another file"

# it lifts by itself after the reset
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 2)"
"$SCRIPT" --refresh --force
printf 'automated\n' > "$QUOTA_RESERVE_DIR/turns/sess-1"
check_eq "$(decide "$(payload Agent)")" "allow ok" "after a reset the reading drops and everything is allowed again, with no manual step"

# ------------------------------------------------------------------------------
# 5. --classify-prompt
# ------------------------------------------------------------------------------
reset_state
classify() { printf '%s' "$1" | "$SCRIPT" --classify-prompt; }
kind() { head -n 1 "$QUOTA_RESERVE_DIR/turns/$1" 2>/dev/null || echo none; }
classify "$(jq -nc '{session_id:"s1", prompt:"please look at the failing test"}')"
check_eq "$(kind s1)" "interactive" "ordinary text is an interactive turn"
for lead in '<ci-monitor-event>x' '<task-notification>x' '<side-sessions-event>x' '[SYSTEM NOTIFICATION - NOT USER INPUT]' 'human-queue: D-4 answered' '[Artifact comment sent to Claude]'; do
  classify "$(jq -nc --arg p "$lead" '{session_id:"s2", prompt:$p}')"
  check_eq "$(kind s2)" "automated" "a prompt starting '${lead:0:28}' is an automated turn"
done
classify "$(jq -nc '{session_id:"s3", prompt:"\n\n   <task-notification>x"}')"
check_eq "$(kind s3)" "automated" "leading whitespace does not hide an automated wrapper"
classify "$(jq -nc --arg p "$(printf '%600s<ci-monitor-event>x' '')" '{session_id:"s6", prompt:$p}')"
check_eq "$(kind s6)" "automated" "600 characters of padding before the wrapper do not hide it"
classify "$(jq -nc '{session_id:"s4", prompt:"why does <ci-monitor-event> show up in the log?"}')"
check_eq "$(kind s4)" "interactive" "the marker text in the middle of a sentence does not make it automated"
classify "$(jq -nc '{session_id:"s2", prompt:"thanks, now do the next one"}')"
check_eq "$(kind s2)" "interactive" "each turn overwrites the last, so an owner turn after an automated one is interactive"
classify "$(jq -nc '{session_id:"../evil", prompt:"<ci-monitor-event>"}')"
check_eq "$([[ -e "$QUOTA_RESERVE_DIR/evil" ]] && echo wrote || echo ignored)" "ignored" "a session id with path characters writes nothing"
classify 'not json'; classify ''
ok "garbage input to the classifier is harmless"
touch -t 202001010000 "$QUOTA_RESERVE_DIR/turns/s1"
classify "$(jq -nc '{session_id:"s5", prompt:"hi"}')"
check_eq "$(kind s1)" "none" "turn records older than three days are removed"

# A clock rollback makes an otherwise reserved snapshot untrustworthy.
reset_state
export QUOTA_RESERVE_NOW=3000000
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 96)"
"$SCRIPT" --refresh --force
session_as "$CLAUDE_A"
export QUOTA_RESERVE_NOW=2999999
check_eq "$(decide "$(payload Agent)")" "allow future-dated reading" "a clock rollback cannot keep blocking on a future-dated reserve reading"
wait_calls 2
wait_refresh
check_eq "$(jq -r .read_at "$QUOTA_RESERVE_DIR/marker.json")" "2999999" "a future-dated reading requests a fresh provider snapshot"

# ------------------------------------------------------------------------------
# 6. --status and the command line
# ------------------------------------------------------------------------------
reset_state
check_contains "$("$SCRIPT" --status)" "No reserve marker yet" "status with no marker says so"
check_eq "$("$SCRIPT" --status --json | jq -r '.marker')" "null" "and --json reports a null marker"
export QUOTA_RESERVE_NOW=4000000
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 96)"
"$SCRIPT" --refresh --force
S="$("$SCRIPT" --status)"
check_contains "$S" "Claude A  [claude]  96%  reserve" "status lists each account with its state"
export QUOTA_RESERVE_NOW=$(( 4000000 + 4000 ))
check_contains "$("$SCRIPT" --status)" "STALE: ignored" "and flags a stale reading as ignored"
check_eq "$("$SCRIPT" --status --json | jq -r '.stale')" "true" "--json carries the stale flag"
"$SCRIPT" --bogus >/dev/null 2>&1; check_eq "$?" "2" "an unknown flag is a usage error"
"$SCRIPT" >/dev/null 2>&1; check_eq "$?" "2" "no action is a usage error"
"$SCRIPT" --refresh --status >/dev/null 2>&1; check_eq "$?" "2" "two actions are a usage error"
"$SCRIPT" --status --force >/dev/null 2>&1; check_eq "$?" "2" "--force with --status is a usage error"
"$SCRIPT" --decide --json </dev/null >/dev/null 2>&1; check_eq "$?" "2" "--json with --decide is a usage error"
OUT="$("$SCRIPT" --help)"; check_contains "$OUT" "FAILS OPEN" "--help documents the fail-open rule"

# ------------------------------------------------------------------------------
# 9. Last-known folder (#2280): gates never read or write it
# ------------------------------------------------------------------------------
# The refresh reads the reader with --no-last-known, so a saved figure cannot
# decide whether autonomous work may proceed.
reset_state
rows "$(row claude a@example.com 'Claude A' $CLAUDE_A 7-day ok 10)"
"$SCRIPT" --refresh --force
check_contains "$(cat "$READER_LOG")" "args=--json --no-last-known" \
  "the reserve refresh passes --no-last-known to the reader"
# The browser source (#2299, Claude included) is never requested by the reserve.
check_eq "$(grep -c -e '--browser' "$READER_LOG" || true)" "0" \
  "the reserve reader is never invoked with a browser flag"
check_eq "$(grep -c -e '--browser' "$REPO_ROOT/.claude/scripts/quota-reserve.sh" || true)" "0" \
  "quota-reserve.sh never names a browser flag"
# Static guard: neither gate script names the folder, its override, or the helper.
for gate in "$REPO_ROOT/.claude/scripts/quota-reserve.sh" "$REPO_ROOT/.claude/scripts/credit-budget.sh"; do
  check_eq "$(grep -c -e 'AI_QUOTAS_LAST_KNOWN_DIR' -e 'AI_QUOTAS_LAST_KNOWN_BIN' -e 'quotas-last-known.py' -e 'ai-quotas/last-known' "$gate" || true)" "0" \
    "$(basename "$gate") never references the last-known folder"
done

echo
echo "passed: $PASS   failed: $FAILED"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
