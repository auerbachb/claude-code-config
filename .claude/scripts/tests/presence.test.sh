#!/usr/bin/env bash
# catalog: tests — Proves the global presence state, one-asker dialog claim, closing-the-laptop routing, and the unattended-reads-as-away bridge
# Tests for issue #2293 (presence windows, increment 1): .claude/scripts/presence.sh,
# prompt-reservation.sh --kind presence, and unattended.sh on --open-ended.
# Every run uses a throwaway HOME; the live ~/.claude is never touched.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/presence-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" REAL_PS="$(command -v ps)" TEST_UID="$(id -u)"
mkdir -p "$HOME/.claude" "$tmp/bin"
export PATH="$tmp/bin:$PATH"
unset CLAUDE_SESSION_REPO UNATTENDED_DIR

# Stub only Claude process identity (same approach as prompt-reservation.test.sh).
cat > "$tmp/bin/ps" <<'PS'
#!/usr/bin/env bash
set -eu
birth='Mon Nov  9 06:00:00 2026'
if [[ "$1" == -p && "$*" == *comm=* ]]; then
  if [[ "$2" == "$FAKE_OWNER" ]]; then printf '1 /fake/bin/claude\n'; else printf '%s /bin/bash\n' "$FAKE_OWNER"; fi
elif [[ "$1" == -p && "$2" == "$FAKE_OWNER" ]]; then
  printf '%s %s %s S\n' "$FAKE_OWNER" "$TEST_UID" "$birth"
elif [[ "$1" == -A ]]; then
  "$REAL_PS" "$@"
  for pid in $FAKE_LIVE; do printf '%s %s %s S\n' "$pid" "$TEST_UID" "$birth"; done
else
  exec "$REAL_PS" "$@"
fi
PS
chmod +x "$tmp/bin/ps"

PRESENCE="$root/.claude/scripts/presence.sh"
UNATT="$root/.claude/scripts/unattended.sh"
STATE="$root/.claude/scripts/session-state.sh"
RESERVE="$root/.claude/scripts/prompt-reservation.sh"
owner1=90000001 owner2=90000002
export FAKE_LIVE="$owner1 $owner2"

REPO="$tmp/repo"
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/acme/widgets.git

pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok   — %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL — %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in: $2)" ;; esac; }
P() { local who="$1"; shift; rc=0; out=$(cd "$REPO" && FAKE_OWNER="$who" "$PRESENCE" "$@" 2>"$tmp/err") || rc=$?; }
field() { printf '%s' "$out" | jq -r "$1"; }

printf '== read: nothing declared\n'
P $owner1 status --json
check "unset state" "$(field .state)" unset
P $owner1 status
check "unset line" "$out" "unset (no presence declared)"
P $owner1 is-away; check "is-away: not away" "$rc" 1

printf '== source rule\n'
P $owner1 set here --for 2h; check "no --by: refused" "$rc" 2
P $owner1 set here --by issue-body --for 2h; check "wrong --by: refused" "$rc" 2
P $owner1 status --json; check "state unchanged after refusals" "$(field .state)" unset
P $owner1 set here --by operator-message; check "no duration: usage error" "$rc" 2
P $owner1 set here --by operator-message --for 2h --open-ended; check "two durations: usage error" "$rc" 2
P $owner1 set here --by operator-message --for 0m; check "zero duration: usage error" "$rc" 2
P $owner1 set here --by operator-message --until-epoch 5; check "end in the past: usage error" "$rc" 2

printf '== here about 2 hours; a second thread reads the same window\n'
P $owner1 set here --by operator-message --for 2h; check "set here" "$rc" 0
P $owner2 status --json
check "second thread: here" "$(field .state)" here
left=$(field .remaining_seconds)
if [ "$left" -ge 7100 ] && [ "$left" -le 7200 ]; then ok "second thread: about 2h left"; else bad "second thread: remaining $left"; fi
check "machine stays on" "$(field .machine_on)" true
check "declared by the operator" "$(jq -r .presence.declared_by "$HOME/.claude/session-state.json")" operator-message
P $owner1 is-away; check "here is not away" "$rc" 1

printf '== one asker: two threads at once, one menu\n'
# A live declaration means nobody asks.
P $owner1 ask; check "declared: ask exits 12" "$rc" 12
P $owner1 set here --by operator-message --open-ended >/dev/null
jq 'del(.presence)' "$HOME/.claude/session-state.json" > "$tmp/s.json" && mv "$tmp/s.json" "$HOME/.claude/session-state.json"
( cd "$REPO" && FAKE_OWNER=$owner1 "$PRESENCE" ask >"$tmp/a1" 2>/dev/null; echo $? >"$tmp/a1.rc" ) &
( cd "$REPO" && FAKE_OWNER=$owner2 "$PRESENCE" ask >"$tmp/a2" 2>/dev/null; echo $? >"$tmp/a2.rc" ) &
wait
check "exactly one asker wins" "$(sort -n "$tmp/a1.rc" "$tmp/a2.rc" | tr '\n' ' ')" "0 10 "
if [ "$(cat "$tmp/a1.rc")" = 0 ]; then winner=$owner1; loser=$owner2; token=$(cat "$tmp/a1"); else winner=$owner2; loser=$owner1; token=$(cat "$tmp/a2"); fi
check "the winner gets a token" "$(printf '%s' "$token" | grep -c -E '^[0-9a-f]{32}$')" 1
P $loser ask; check "the loser asking again still loses" "$rc" 10
P $loser status --json; check "the loser reads: still unset" "$(field .state)" unset
P $winner set here --by operator-message --for 30m --generation "$token"
check "the winner stores the answer" "$rc" 0
P $loser status --json; check "the loser now reads the answer" "$(field .state)" here
P $loser ask; check "after the answer nobody asks" "$rc" 12
P $winner release --generation "$token"; check "a released token is gone (idempotent)" "$rc" 0
P $loser set away --by operator-message --for 1h --generation "$token"
check "a released token cannot write a late answer" "$rc" 10
P $loser status --json; check "the late answer left the stored state alone" "$(field .state)" here

printf '== a dismissed dialog pauses re-asking for an hour\n'
jq 'del(.presence)' "$HOME/.claude/session-state.json" > "$tmp/s.json" && mv "$tmp/s.json" "$HOME/.claude/session-state.json"
P $owner1 ask; token=$out; check "asker claims" "$rc" 0
P $owner1 release --generation "$token" --dismissed; check "dismiss" "$rc" 0
P $owner2 ask; check "dismissed: ask exits 13" "$rc" 13
past=$(( $(date +%s) - 5 ))
"$STATE" --set ".presence.dismissed_until=$past" >/dev/null
P $owner2 ask; check "after the pause: ask works again" "$rc" 0
P $owner2 release --generation "$out" >/dev/null
# A stale or foreign token cannot start a cooldown.
P $owner1 ask; token=$out
P $owner2 release --generation "$token" --dismissed
check "foreign token dismissal is a no-op" "$(jq -r '.presence.dismissed_until' "$HOME/.claude/session-state.json")" "$past"
P $owner2 ask; check "holder still holds after a foreign release attempt" "$rc" 10
P $owner1 release --generation "$token" >/dev/null

printf '== closing the laptop routes to the armed leave-by deadline\n'
P $owner1 set closing --by operator-message; check "no deadline armed: refused" "$rc" 3
P $owner1 set closing --by operator-message --for 1h; check "closing takes no duration" "$rc" 2
deadline=$(( $(date +%s) + 3 * 3600 ))
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].window.deadline_epoch=$deadline" >/dev/null
P $owner1 set closing --by operator-message; check "a /pm --window deadline without /leave-by: refused" "$rc" 3
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].leave.active=true" >/dev/null
P $owner1 set closing --by operator-message; check "deadline armed: closing set" "$rc" 0
P $owner2 status --json
check "closing: the window ends at the deadline" "$(field .until_epoch)" "$deadline"
check "closing: the machine does not stay on" "$(field .machine_on)" false
check "closing: here until the laptop closes" "$(field .state)" here
past_deadline=$(( $(date +%s) - 60 ))
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].window.deadline_epoch=$past_deadline" >/dev/null
P $owner1 set closing --by operator-message; check "a spent deadline does not count" "$rc" 3

printf '== away arms the existing unattended switch; unattended reads as away\n'
P $owner1 set away --by operator-message --for 1h; check "set away" "$rc" 0
has "away prints the unattended pre-leave check" "$out" "confirm none is waiting on the user"
check "unattended is on" "$("$UNATT" is-active; echo $?)" 0
P $owner2 status --json
check "away reads away" "$(field .state)" away
away_until=$(field .until_epoch)
check "same end time as unattended" "$(jq -r .unattended.until_epoch "$HOME/.claude/session-state.json")" "$away_until"
P $owner2 is-away; check "is-away: yes" "$rc" 0
# The old switch alone, armed the old way, with nothing declared through presence.
jq 'del(.presence)' "$HOME/.claude/session-state.json" > "$tmp/s.json" && mv "$tmp/s.json" "$HOME/.claude/session-state.json"
"$UNATT" off >/dev/null
"$UNATT" on --for 3h >/dev/null
P $owner1 status --json
check "unattended alone reads away" "$(field .state)" away
check "unattended alone: source" "$(field .source)" unattended
check "unattended alone: end time" "$(field .until_epoch)" "$(jq -r .unattended.until_epoch "$HOME/.claude/session-state.json")"
# Newer declaration wins in both directions.
sleep 1
P $owner1 set here --by operator-message --for 1h
P $owner1 status --json; check "here after unattended: here" "$(field .state)" here
check "here turned unattended off" "$("$UNATT" is-active; echo $?)" 1
sleep 1
"$UNATT" on --for 1h >/dev/null
P $owner1 status --json; check "unattended after here: away" "$(field .state)" away
# Turning the old switch off by hand ends a presence-armed away early.
P $owner1 set away --by operator-message --for 3h >/dev/null
"$UNATT" off >/dev/null
P $owner1 status --json
check "unattended off ends away early" "$(field .state)" here

printf '== open-ended\n'
P $owner1 set away --by operator-message --open-ended; check "set open-ended away" "$rc" 0
P $owner2 status --json
check "open-ended: no end" "$(field .until_epoch)" null
check "open-ended: never expired" "$(field .expired)" false
check "open-ended: no remaining time" "$(field .remaining_seconds)" null
check "open-ended away: unattended is active" "$("$UNATT" is-active; echo $?)" 0
check "open-ended away: window never ends" "$("$UNATT" window-ended; echo $?)" 1
P $owner1 set here --by operator-message --open-ended >/dev/null
check "here ends the open-ended away" "$("$UNATT" is-active; echo $?)" 1
"$UNATT" on --open-ended --for 1h >/dev/null 2>&1; check "unattended: --open-ended with --for is a usage error" "$?" 2
"$UNATT" on --for 1h --until-epoch $(( $(date +%s) + 600 )) >/dev/null 2>&1; check "unattended: --for with --until-epoch still accepted" "$?" 0
"$UNATT" off >/dev/null
has "unattended --help lists --open-ended" "$("$UNATT" --help 2>&1)" "--open-ended"
has "presence --help lists the exit codes" "$("$PRESENCE" --help 2>&1)" "another thread holds the dialog"

printf '== rest of the day\n'
P $owner1 set here --by operator-message --rest-of-day >/dev/null
P $owner1 status --json
check "here rest-of-day ends at 23:59 local" "$(date -r "$(field .until_epoch)" +%H:%M)" 23:59
P $owner1 set away --by operator-message --rest-of-day >/dev/null
P $owner1 status --json
check "away rest-of-day ends at 08:00 local" "$(date -r "$(field .until_epoch)" +%H:%M)" 08:00
if [ "$(field .until_epoch)" -gt "$(date +%s)" ]; then ok "away rest-of-day ends in the future"; else bad "away rest-of-day ends in the past"; fi
"$UNATT" off >/dev/null

printf '== the global reservation slot\n'
rc=0; "$BASH" "$RESERVE" claim --kind presence --repo acme/widgets >/dev/null 2>&1 || rc=$?
check "presence takes no --repo" "$rc" 2
rc=0; "$BASH" "$RESERVE" claim --kind presence --issue 4 >/dev/null 2>&1 || rc=$?
check "presence takes no --issue" "$rc" 2
rc=0; FAKE_OWNER=$owner1 "$BASH" "$RESERVE" claim --kind leave --repo acme/widgets >/dev/null 2>&1 || rc=$?
check "the repo-scoped leave slot is unaffected" "$rc" 0
check "presence lives at .presence.reservation, not under .repos" \
  "$(jq -r '[.presence.reservation.generation | type] | .[0]' "$HOME/.claude/session-state.json")" null

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
