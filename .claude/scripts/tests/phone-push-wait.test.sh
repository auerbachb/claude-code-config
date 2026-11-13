#!/usr/bin/env bash
# Offline tests for phone-push-wait.sh (issue #2291): the delay, once-only,
# answered-inside-the-delay, push-text and missed-push logic. No phone, network
# or real ~/.claude is touched; delivery to a phone is NOT tested here.
# catalog: tests — Tests for `phone-push-wait.sh`
# Run from repo root: bash .claude/scripts/tests/phone-push-wait.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/phone-push-wait.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PHONE_PUSH_DIR="$TMP/state"
export PHONE_PUSH_SETTINGS="$TMP/settings.json"
unset PHONE_PUSH_DELAY_SEC

PASS=0; FAIL=0
check_eq() { if [[ "$3" == "$2" ]]; then PASS=$((PASS+1)); echo "ok   — $1"; else FAIL=$((FAIL+1)); echo "FAIL — $1 (expected '$2', got '$3')"; fi; }
check_has() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); echo "ok   — $1"; else FAIL=$((FAIL+1)); echo "FAIL — $1 (no '$2' in '$3')"; fi; }
run() { out=$("$SCRIPT" "$@" 2>&1); rc=$?; }

# --- arm: default delay, monitor command, one push per question
run arm D-1 --thread "issue-9 worker" --question "Approve the paid review for PR 12?"
check_eq "arm exits 0" 0 "$rc"
check_has "arm prints the watch command" "phone-push-wait.sh watch D-1" "$out"
check_eq "default delay is 300s" 300 "$(jq -r .delay_sec "$PHONE_PUSH_DIR/D-1.json")"
check_eq "status starts waiting" waiting "$(jq -r .status "$PHONE_PUSH_DIR/D-1.json")"
run arm D-1 --thread x --question y
check_eq "re-arming the same key is refused" 3 "$rc"
check_eq "refused re-arm leaves one record" waiting "$(jq -r .status "$PHONE_PUSH_DIR/D-1.json")"

# --- delay knob: flag and env
run arm D-2 --thread t --question q --delay 90
check_eq "flag sets the delay" 90 "$(jq -r .delay_sec "$PHONE_PUSH_DIR/D-2.json")"
PHONE_PUSH_DELAY_SEC=45 run arm D-3 --thread t --question q
check_eq "env sets the delay" 45 "$(jq -r .delay_sec "$PHONE_PUSH_DIR/D-3.json")"
run arm D-4 --thread t --question q --delay 0
check_eq "delay 0 is refused" 2 "$rc"
check_eq "refused arm writes no record" no "$([ -f "$PHONE_PUSH_DIR/D-4.json" ] && echo yes || echo no)"
run arm 'bad key' --thread t --question q
check_eq "bad key is refused" 2 "$rc"

run arm D-4 --thread t --question q --delay 1501
check_eq "delay above the Monitor lifetime is refused" 2 "$rc"
run arm D-4 --thread t --question
check_eq "option with no value is a usage error (no loop)" 2 "$rc"
run missed D-1 --reason
check_eq "--reason with no value is a usage error" 2 "$rc"

# --- a lock left by a killed process is reclaimed
run arm D-12 --thread t --question q --delay 1
mkdir "$PHONE_PUSH_DIR/.lock"; printf '999999' >"$PHONE_PUSH_DIR/.lock/pid"
sleep 1
out=$("$SCRIPT" watch D-12 2>&1); rc=$?
check_has "stale lock: the push still comes due" "phone-push D-12 due" "$out"
check_eq "stale lock: lock is released after" no "$([ -d "$PHONE_PUSH_DIR/.lock" ] && echo yes || echo no)"

# --- concurrent recovery of one stale lock: still exactly one push line
run arm D-14 --thread t --question q --delay 1
mkdir "$PHONE_PUSH_DIR/.lock"; printf '999999' >"$PHONE_PUSH_DIR/.lock/pid"
sleep 1
( "$SCRIPT" watch D-14 >"$TMP/c1" 2>&1 ) & ( "$SCRIPT" watch D-14 >"$TMP/c2" 2>&1 ) & ( "$SCRIPT" watch D-14 >"$TMP/c3" 2>&1 ) & wait
check_eq "three watchers over a stale lock: one push line" 1 "$(cat "$TMP/c1" "$TMP/c2" "$TMP/c3" | grep -c 'phone-push D-14 due')"
check_eq "no stale lock left behind" 0 "$(ls -d "$PHONE_PUSH_DIR"/.lock* 2>/dev/null | wc -l | tr -d ' ')"

# --- push text: one line, under 200 chars, nothing sensitive
long=$(printf 'word %.0s' $(seq 1 120))
run arm D-5 --thread "a-very-long-thread-name-that-goes-on-and-on-and-on-forever" --question "$long"
text=$("$SCRIPT" text D-5)
[[ ${#text} -lt 200 ]]; check_eq "long text stays under 200 chars" 0 $?
check_eq "text is one line" 1 "$(printf '%s\n' "$text" | wc -l | tr -d ' ')"
run arm D-6 --thread t --question "See https://example.com/x?token=abc, mail a.b@example.org, file /Users/someone/secret.txt, key sk-abcdefghijklmnop1234 and ghp_ABCDEFGHIJKLMNOPQRSTUV012345"
text=$("$SCRIPT" text D-6)
for bad in "https://" "@example" "/Users" "sk-abcdef" "ghp_ABC"; do
  [[ "$text" != *"$bad"* ]]; check_eq "text drops $bad" 0 $?
done
check_has "text names the thread" "[t] waiting on you:" "$text"
run arm D-13 --thread t --question 'see (/Users/someone/a.txt) and `/etc/passwd` and "/var/log/x" now'
text=$("$SCRIPT" text D-13)
for bad in "/Users" "/etc" "/var/log" "someone"; do
  [[ "$text" != *"$bad"* ]]; check_eq "text drops quoted or bracketed path $bad" 0 $?
done
check_has "text keeps the words around a path" "and" "$text"
run arm D-7 --thread t --question ""
check_has "empty question still reads" "waiting on you for a decision" "$("$SCRIPT" text D-7)"

# --- answered inside the delay sends nothing
run arm D-8 --thread t --question q --delay 3
"$SCRIPT" answer D-8 >/dev/null
out=$("$SCRIPT" watch D-8 2>&1); rc=$?
check_eq "answered before the delay: watch is silent" "" "$out"
check_eq "answered before the delay: watch exits 0" 0 "$rc"
check_eq "status is answered" answered "$(jq -r .status "$PHONE_PUSH_DIR/D-8.json")"

# --- unanswered past the delay: exactly one line, once
run arm D-9 --thread t --question "Pick one" --delay 1
sleep 1
out=$("$SCRIPT" watch D-9 2>&1); rc=$?
check_eq "watch exits 0 at the delay" 0 "$rc"
check_eq "exactly one due line" 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
check_has "due line carries the push text" "[t] waiting on you: Pick one" "$out"
check_has "due line says to call PushNotification" "PushNotification" "$out"
out2=$("$SCRIPT" watch D-9 2>&1)
check_eq "a second watch prints nothing" "" "$out2"
check_eq "status is due" due "$(jq -r .status "$PHONE_PUSH_DIR/D-9.json")"

# --- two watchers racing: only one claims the push
run arm D-10 --thread t --question q --delay 1
sleep 1
( "$SCRIPT" watch D-10 >"$TMP/w1" 2>&1 ) & ( "$SCRIPT" watch D-10 >"$TMP/w2" 2>&1 ) & wait
check_eq "racing watchers print one line in total" 1 "$(cat "$TMP/w1" "$TMP/w2" | wc -l | tr -d ' ')"

# --- answering after the push was claimed does not rewrite history
out=$("$SCRIPT" answer D-9 2>&1)
check_has "late answer reports the status" "already due" "$out"

# --- outcome records: sent, missed (never silently dropped)
run sent D-9
check_eq "sent after due is recorded" 0 "$rc"
check_eq "status is sent" sent "$(jq -r .status "$PHONE_PUSH_DIR/D-9.json")"
run sent D-9
check_eq "sent twice is refused" 3 "$rc"
run missed D-10 --reason "Remote Control not connected"
check_eq "missed is recorded" 0 "$rc"
check_eq "miss keeps its reason" "Remote Control not connected" "$(jq -r .reason "$PHONE_PUSH_DIR/D-10.json")"
run missed D-10
check_eq "missed without a reason is refused" 2 "$rc"
run sent D-1
check_eq "sent on a waiting record is refused" 3 "$rc"
check_has "status lists the miss" "D-10 missed" "$("$SCRIPT" status)"
run status D-99
check_eq "unknown key exits 3" 3 "$rc"

# --- fail closed: an unwritable state dir arms nothing
chmod 500 "$TMP"; PHONE_PUSH_DIR="$TMP/ro/state" run arm D-11 --thread t --question q; chmod 700 "$TMP"
check_eq "unwritable state: arm fails" 1 "$rc"
[[ "$out" != *"watch D-11"* ]]; check_eq "unwritable state: no Monitor command printed" 0 $?

# --- doctor
printf '{"inputNeededNotifEnabled":true,"agentPushNotifEnabled":true}' >"$PHONE_PUSH_SETTINGS"
run doctor; check_eq "doctor passes with both toggles" 0 "$rc"
printf '{"agentPushNotifEnabled":true}' >"$PHONE_PUSH_SETTINGS"
run doctor; check_eq "doctor flags an unset toggle" 1 "$rc"
check_has "doctor names the toggle" "inputNeededNotifEnabled: unset" "$out"

run --help; check_has "--help prints usage" "USAGE" "$out"

echo "---"; echo "passed: $PASS failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
