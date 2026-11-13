#!/usr/bin/env bash
# Offline tests for phone-push-wait.sh (issue #2291): the delay, once-only,
# answered-inside-the-delay, push-text and missed-push logic. No phone, network
# or real ~/.claude is touched; delivery to a phone is NOT tested here.
# catalog: tests — Tests for `phone-push-wait.sh`
# Run from repo root: bash .claude/scripts/tests/phone-push-wait.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="${PHONE_PUSH_SCRIPT:-$REPO_ROOT/.claude/scripts/phone-push-wait.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PHONE_PUSH_DIR="$TMP/state"
export PHONE_PUSH_SETTINGS="$TMP/settings.json"
unset PHONE_PUSH_DELAY_SEC
export PHONE_PUSH_GRACE_SEC=100000   # lost-wake tests lower it per call

PASS=0; FAIL=0
check_eq() { if [[ "$3" == "$2" ]]; then PASS=$((PASS+1)); echo "ok   — $1"; else FAIL=$((FAIL+1)); echo "FAIL — $1 (expected '$2', got '$3')"; fi; }
check_has() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); echo "ok   — $1"; else FAIL=$((FAIL+1)); echo "FAIL — $1 (no '$2' in '$3')"; fi; }
run() { out=$("$SCRIPT" "$@" 2>&1); rc=$?; }

# --- arm: default delay, monitor command, one push per question
run arm D-1 --thread "issue-9 worker" --question "Approve the paid review for PR 12?"
check_eq "arm exits 0" 0 "$rc"
check_has "arm prints the watch command" "phone-push-wait.sh watch D-1" "$out"
check_eq "default delay is 300s" 300 "$(jq -r .delay_sec "$PHONE_PUSH_DIR/D-1.json")"
check_eq "status starts waiting" waiting "$("$SCRIPT" status D-1 | awk '{print $2}')"
run arm D-1 --thread x --question y
check_eq "re-arming the same key is refused" 3 "$rc"
check_eq "refused re-arm leaves one record" waiting "$("$SCRIPT" status D-1 | awk '{print $2}')"

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

# --- no lock exists: transitions are atomic marker creates, so a killed process
# can never wedge later commands (every call below is bounded by a watchdog).
bounded() { # SECONDS CMD... ; sets out/rc, rc=124 when the call hung
  local secs=$1 pid wd; shift
  "$@" >"$TMP/bounded.out" 2>&1 & pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & wd=$!
  wait "$pid" 2>/dev/null; rc=$?; kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ "$rc" -eq 137 ] && rc=124
  out=$(cat "$TMP/bounded.out")
}
st() { "$SCRIPT" status "$1" 2>/dev/null | awk '{print $2}'; }

# racing watchers over one due key, repeated: exactly one push line per round
race_bad=0
for r in 1 2 3 4 5 6; do
  k="D-R$r"
  "$SCRIPT" arm "$k" --thread t --question q --delay 1 >/dev/null 2>&1
  sleep 1
  for w in 1 2 3 4 5 6 7 8; do ( "$SCRIPT" watch "$k" >"$TMP/r$r.$w" 2>&1 ) & done; wait
  n=$(cat "$TMP"/r$r.* | grep -c "phone-push $k due")
  [ "$n" = 1 ] || race_bad=$((race_bad+1))
  "$SCRIPT" sent "$k" >/dev/null 2>&1
done
check_eq "racing watchers: exactly one push line every round" 0 "$race_bad"
check_eq "no lock or reclaim guard is ever created" 0 "$(ls -d "$PHONE_PUSH_DIR"/.lock* 2>/dev/null | wc -l | tr -d ' ')"

# a watcher killed just BEFORE it claims the push: later commands terminate and
# the push still comes exactly once
SH="$TMP/shim"; mkdir -p "$SH"; REAL_LN=$(command -v ln)
printf '#!/bin/sh\ncase "$2" in *.claim) kill -9 $PPID; exit 1 ;; esac\nexec %s "$@"\n' "$REAL_LN" >"$SH/ln"
chmod +x "$SH/ln"
"$SCRIPT" arm D-K1 --thread t --question q --delay 1 >/dev/null 2>&1; sleep 1
PATH="$SH:$PATH" "$SCRIPT" watch D-K1 >/dev/null 2>&1
check_eq "killed before claiming: still waiting" waiting "$(st D-K1)"
bounded 20 "$SCRIPT" status; check_eq "status terminates after the kill" 0 "$rc"
bounded 20 "$SCRIPT" watch D-K1; check_eq "next watch terminates" 0 "$rc"
check_eq "next watch pushes exactly once" 1 "$(printf '%s\n' "$out" | grep -c 'phone-push D-K1 due')"
bounded 20 "$SCRIPT" watch D-K1; check_eq "a further watch prints nothing" "" "$out"

# a watcher killed just AFTER it claims (before printing): no second push, and
# later commands still terminate
printf '#!/bin/sh\n%s "$@"; rc=$?\ncase "$2" in *.claim) kill -9 $PPID ;; esac\nexit $rc\n' "$REAL_LN" >"$SH/ln"
"$SCRIPT" arm D-K2 --thread t --question q --delay 1 >/dev/null 2>&1; sleep 1
PATH="$SH:$PATH" "$SCRIPT" watch D-K2 >/dev/null 2>&1
check_eq "killed after claiming: due" due "$(st D-K2)"
bounded 20 "$SCRIPT" watch D-K2
check_eq "no second push after a kill mid-transition" 0 "$(printf '%s\n' "$out" | grep -c 'phone-push D-K2 due')"
bounded 20 "$SCRIPT" answer D-K2
check_eq "answer terminates" 0 "$rc"
check_has "answer after the claim: already due" "already due" "$out"

# --- lost wake: due with neither sent nor missed past the grace period is
# recorded missed, once, and status/doctor surface it
"$SCRIPT" arm D-L1 --thread t --question q --delay 1 >/dev/null 2>&1; sleep 1
"$SCRIPT" watch D-L1 >/dev/null 2>&1
check_eq "within the grace period it stays due" due "$(st D-L1)"
sleep 2
for w in 1 2 3 4 5; do ( PHONE_PUSH_GRACE_SEC=1 "$SCRIPT" status D-L1 >"$TMP/l$w.out" 2>"$TMP/l$w.err" ) & done; wait
check_eq "lost wake: recorded missed" missed "$(st D-L1)"
check_has "status shows the wake-lost reason" "wake lost" "$("$SCRIPT" status D-L1)"
check_eq "lost wake is recorded exactly once" 1 "$(cat "$TMP"/l?.err | grep -c 'D-L1 missed: wake lost')"
run sent D-L1
check_eq "a late sent cannot overwrite the recorded miss" 3 "$rc"
bounded 20 "$SCRIPT" watch D-L1; check_eq "watch on a lost-wake record prints nothing" "" "$out"
printf '{"inputNeededNotifEnabled":true,"agentPushNotifEnabled":true}' >"$PHONE_PUSH_SETTINGS"
run doctor
check_eq "doctor fails when a wake was lost" 1 "$rc"
check_has "doctor names the lost-wake key" "D-L1 was recorded missed: wake lost" "$out"
# arm also settles a stale due record
"$SCRIPT" arm D-L2 --thread t --question q --delay 1 >/dev/null 2>&1; sleep 1
"$SCRIPT" watch D-L2 >/dev/null 2>&1; sleep 2
PHONE_PUSH_GRACE_SEC=1 "$SCRIPT" arm D-L3 --thread t --question q >/dev/null 2>&1
check_eq "arm settles a lost wake" missed "$(st D-L2)"
rm -f "$PHONE_PUSH_DIR"/D-L*.outcome "$PHONE_PUSH_DIR"/D-K*.outcome

# --- printed commands are shell-quoted (a path with a space stays one word)
mkdir -p "$TMP/dir with space"; cp "$SCRIPT" "$TMP/dir with space/phone-push-wait.sh"
out=$("$TMP/dir with space/phone-push-wait.sh" arm D-Q1 --thread t --question q 2>&1)
check_has "arm output quotes a spaced script path" 'dir\ with\ space/phone-push-wait.sh watch D-Q1' "$out"

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
run arm D-14 --thread t --question 'at location:/Users/someone/x, dir=/home/someone/y; and/or 1/2'
text=$("$SCRIPT" text D-14)
for bad in "/Users" "/home" "someone"; do
  [[ "$text" != *"$bad"* ]]; check_eq "text drops punctuation-led path $bad" 0 $?
done
check_has "text keeps and/or and 1/2" "and/or 1/2" "$text"
run arm D-7 --thread t --question ""
check_has "empty question still reads" "waiting on you for a decision" "$("$SCRIPT" text D-7)"

# --- answered inside the delay sends nothing
run arm D-8 --thread t --question q --delay 3
"$SCRIPT" answer D-8 >/dev/null
out=$("$SCRIPT" watch D-8 2>&1); rc=$?
check_eq "answered before the delay: watch is silent" "" "$out"
check_eq "answered before the delay: watch exits 0" 0 "$rc"
check_eq "status is answered" answered "$(st D-8)"

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
check_eq "status is due" due "$(st D-9)"

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
check_eq "status is sent" sent "$(st D-9)"
run sent D-9
check_eq "sent twice is refused" 3 "$rc"
run missed D-10 --reason "Remote Control not connected"
check_eq "missed is recorded" 0 "$rc"
check_has "miss keeps its reason" "Remote Control not connected" "$("$SCRIPT" status D-10)"
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

mkdir -p "$TMP/cfg"; printf '{"inputNeededNotifEnabled":true,"agentPushNotifEnabled":true}' >"$TMP/cfg/settings.json"
( unset PHONE_PUSH_SETTINGS; CLAUDE_CONFIG_DIR="$TMP/cfg" PHONE_PUSH_DIR="$TMP/emptystate" "$SCRIPT" doctor >"$TMP/dc" 2>&1 ); rc=$?
check_eq "doctor reads settings under CLAUDE_CONFIG_DIR" 0 "$rc"

run --help; check_has "--help prints usage" "USAGE" "$out"

echo "---"; echo "passed: $PASS failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
