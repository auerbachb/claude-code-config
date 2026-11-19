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
# Local HH:MM of an epoch: BSD date -r takes an epoch, GNU date -r takes a file (use -d @E there).
hhmm() {
  local t
  t=$(date -r "$1" +%H:%M 2>/dev/null) || t=$(date -d "@$1" +%H:%M 2>/dev/null) || t=""
  [ -n "$t" ] || { printf 'hhmm: neither date form worked for %s\n' "$1" >&2; return 1; }
  printf '%s\n' "$t"
}

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
# Issue #2352: the return key for question listing is .unattended.since_epoch. here and closing only
# clear `active`; only a new away arming writes a new one.
SINCE_1=$(jq -r '.unattended.since_epoch' "$HOME/.claude/session-state.json")
check "here left a since_epoch in place" "$(( SINCE_1 > 0 ))" 1
sleep 1
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].window.deadline_epoch=$(( $(date +%s) + 7200 ))" --set ".repos[\"acme/widgets\"].leave.active=true" >/dev/null
P $owner1 set closing --by operator-message; check "closing set from an armed deadline" "$rc" 0
check "closing keeps the since_epoch" "$(jq -r '.unattended.since_epoch' "$HOME/.claude/session-state.json")" "$SINCE_1"
P $owner1 set here --by operator-message --for 1h >/dev/null
check "here again keeps the since_epoch" "$(jq -r '.unattended.since_epoch' "$HOME/.claude/session-state.json")" "$SINCE_1"
P $owner1 set away --by operator-message --for 1h >/dev/null
SINCE_2=$(jq -r '.unattended.since_epoch' "$HOME/.claude/session-state.json")
check "a new away arming writes a new since_epoch (a new return)" "$(( SINCE_2 > SINCE_1 ))" 1
P $owner1 set here --by operator-message --for 1h >/dev/null
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

printf '== claims, late answers, atomic away, explicit repo\n'
"$UNATT" off >/dev/null 2>&1
jq 'del(.presence)' "$HOME/.claude/session-state.json" > "$tmp/s.json" && mv "$tmp/s.json" "$HOME/.claude/session-state.json"
# An explicit mixed-case --repo resolves to the lowercase state key.
future=$(( $(date +%s) + 3600 ))
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].window.deadline_epoch=$future" --set ".repos[\"acme/widgets\"].leave.active=true" >/dev/null
P $owner1 set closing --by operator-message --repo Acme/Widgets
check "an explicit mixed-case --repo finds the lowercase key" "$rc" 0
jq 'del(.presence)' "$HOME/.claude/session-state.json" > "$tmp/s.json" && mv "$tmp/s.json" "$HOME/.claude/session-state.json"
# A refused closing releases the dialog claim it was answering.
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].window.deadline_epoch=$(( $(date +%s) - 60 ))" >/dev/null
P $owner1 ask; tok1=$out; check "owner1 claims the dialog" "$rc" 0
P $owner1 set closing --by operator-message --generation "$tok1"
check "closing with no armed deadline is refused" "$rc" 3
P $owner2 ask; tok2=$out
check "the refused answer released the claim: another thread may ask" "$rc" 0
# A direct declaration without a token invalidates a pending claim; the late answer loses.
P $owner1 set here --by operator-message --for 1h; check "a direct declaration is stored" "$rc" 0
P $owner2 set away --by operator-message --for 2h --generation "$tok2"
check "the late answer under the invalidated token is refused" "$rc" 10
P $owner1 status --json; check "the late answer left the newer declaration alone" "$(field .state)" here
check "the late answer armed no unattended window" "$("$UNATT" is-active; echo $?)" 1
# away is one write: when it fails, unattended mode is not left armed.
cat > "$tmp/bin/ss-fail" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in *presence.state=away*) exit 5 ;; esac; done
exec "$STATE" "\$@"
EOF
chmod +x "$tmp/bin/ss-fail"
rc=0; (cd "$REPO" && FAKE_OWNER=$owner1 PRESENCE_SESSION_STATE_SH="$tmp/bin/ss-fail" "$PRESENCE" set away --by operator-message --for 1h >/dev/null 2>&1) || rc=$?
check "a failed away write exits 1" "$rc" 1
check "a failed away write leaves unattended mode off" "$("$UNATT" is-active; echo $?)" 1
P $owner1 status --json; check "a failed away write leaves presence as it was" "$(field .state)" here
# here clears unattended mode even when the flag was set between a read and the write.
"$UNATT" on --for 1h >/dev/null 2>&1
P $owner1 set here --by operator-message --for 1h >/dev/null
check "here clears an unattended window unconditionally" "$("$UNATT" is-active; echo $?)" 1

printf '== guard writes: fallback jq, visible release failure, newer-declaration CAS, dismissal CAS\n'
reset_presence() { jq 'del(.presence)' "$HOME/.claude/session-state.json" > "$tmp/s.json" && mv "$tmp/s.json" "$HOME/.claude/session-state.json"; }
# ask must work when jq is only at one of the script's fallback locations (children need it too).
mkdir -p "$tmp/nojq"
for f in /bin/* /usr/bin/*; do b=${f##*/}; [ "$b" = jq ] || ln -sf "$f" "$tmp/nojq/$b" 2>/dev/null; done
reset_presence
rc=0; out=$(cd "$REPO" && PATH="$tmp/bin:$tmp/nojq" FAKE_OWNER=$owner1 /bin/bash "$PRESENCE" ask 2>/dev/null) || rc=$?
check "ask works with jq only at a fallback location" "$rc" 0
P $owner1 release --generation "$out" >/dev/null
# A failed claim release is reported, not swallowed.
cat > "$tmp/bin/rs-fail" <<EOF
#!/bin/bash
[ "\$1" = release ] && exit 20
exec "$RESERVE" "\$@"
EOF
chmod +x "$tmp/bin/rs-fail"
reset_presence
P $owner1 ask; tok=$out
rc=0; err=$(cd "$REPO" && FAKE_OWNER=$owner1 PRESENCE_RESERVE_SH="$tmp/bin/rs-fail" "$PRESENCE" set closing --by operator-message --generation "$tok" 2>&1 >/dev/null) || rc=$?
check "a refused closing still exits 3" "$rc" 3
has "a failed claim release is reported" "$err" "claim not released"
P $owner1 release --generation "$tok" >/dev/null
# A set delayed before its write loses to a newer declaration instead of overwriting it.
reset_presence
P $owner1 set here --by operator-message --for 1h >/dev/null
cat > "$tmp/bin/ss-newer" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in *presence.state=here*) "$STATE" --set ".presence.declared_epoch=\$(( \$(date +%s) + 600 ))" >/dev/null; break ;; esac; done
exec "$STATE" "\$@"
EOF
chmod +x "$tmp/bin/ss-newer"
rc=0; (cd "$REPO" && FAKE_OWNER=$owner2 PRESENCE_SESSION_STATE_SH="$tmp/bin/ss-newer" "$PRESENCE" set here --by operator-message --for 2h >/dev/null 2>&1) || rc=$?
check "a delayed set loses to the newer declaration" "$rc" 10
check "the newer declaration time is kept" "$(jq '.presence.declared_epoch > (now + 300)' "$HOME/.claude/session-state.json")" true
# A dismissal is one compare-and-set with the reservation clear: a declaration that cleared the
# reservation first leaves no cooldown behind.
reset_presence
P $owner1 ask; tok=$out
cat > "$tmp/bin/ss-dis" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in *dismissed_until=*) "$STATE" --set ".presence.reservation=null" >/dev/null; break ;; esac; done
exec "$STATE" "\$@"
EOF
chmod +x "$tmp/bin/ss-dis"
(cd "$REPO" && FAKE_OWNER=$owner1 PRESENCE_SESSION_STATE_SH="$tmp/bin/ss-dis" "$PRESENCE" release --generation "$tok" --dismissed >/dev/null 2>&1)
check "a stale dismissal writes no cooldown" "$(jq -r '.presence.dismissed_until // 0' "$HOME/.claude/session-state.json")" 0
reset_presence

# A usage error after --generation still releases the claim.
reset_presence
P $owner1 ask; tok=$out
P $owner1 set here --by operator-message --generation "$tok" --bogus-flag
check "a bad flag after --generation is a usage error" "$rc" 2
P $owner2 ask; check "the claim was released after the usage error" "$rc" 0
P $owner2 release --generation "$out" >/dev/null
reset_presence

# A dialog-sourced set needs a valid generation; the stored source names the dialog.
reset_presence
P $owner1 set here --by operator-dialog --for 1h; check "dialog source without a token: usage error" "$rc" 2
P $owner1 set here --by operator-dialog --for 1h --generation 00000000000000000000000000000000
check "dialog source with a token that is not the live claim: refused" "$rc" 10
P $owner1 status --json; check "a refused dialog answer stores nothing" "$(field .state)" unset
P $owner1 ask; tok=$out
P $owner1 set here --by operator-dialog --for 1h --generation "$tok"; check "dialog source with the live token: stored" "$rc" 0
check "the stored source names the dialog" "$(jq -r .presence.declared_by "$HOME/.claude/session-state.json")" operator-dialog
reset_presence

# A dismissal whose claim cannot be verified reports failure, not success.
reset_presence
P $owner1 ask; tok=$out
cat > "$tmp/bin/rs-unverifiable" <<EOF
#!/bin/bash
[ "\$1" = verify ] && exit 20
exec "$RESERVE" "\$@"
EOF
chmod +x "$tmp/bin/rs-unverifiable"
rc=0; (cd "$REPO" && FAKE_OWNER=$owner1 PRESENCE_RESERVE_SH="$tmp/bin/rs-unverifiable" "$PRESENCE" release --generation "$tok" --dismissed >/dev/null 2>&1) || rc=$?
check "an unverifiable dismissal is not reported as success" "$rc" 20
P $owner1 release --generation "$tok" >/dev/null
reset_presence
# unattended.sh arms when jq is only at a fallback location.
rc=0; (cd "$REPO" && PATH="$tmp/bin:$tmp/nojq" /bin/bash "$UNATT" on --open-ended >/dev/null 2>&1) || rc=$?
check "unattended on works with jq only at a fallback location" "$rc" 0
"$UNATT" off >/dev/null 2>&1

printf '== rest of the day\n'
P $owner1 set here --by operator-message --rest-of-day >/dev/null
P $owner1 status --json
check "here rest-of-day ends at 23:59 local" "$(hhmm "$(field .until_epoch)")" 23:59
P $owner1 set away --by operator-message --rest-of-day >/dev/null
P $owner1 status --json
check "away rest-of-day ends at 08:00 local" "$(hhmm "$(field .until_epoch)")" 08:00
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

printf '== a leave-time cancel, re-declaration or retirement follows the closing window (#2339)\n'
"$UNATT" off >/dev/null 2>&1
jq 'del(.presence)' "$HOME/.claude/session-state.json" > "$tmp/s.json" && mv "$tmp/s.json" "$HOME/.claude/session-state.json"
d1=$(( $(date +%s) + 3 * 3600 ))
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].window.deadline_epoch=$d1" --set ".repos[\"acme/widgets\"].leave.active=true" >/dev/null
P $owner1 set closing --by operator-message; check "closing armed for the cancel case" "$rc" 0
# Cancel: the leave record goes inactive; the next reader settles the closing window.
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].leave.active=false" >/dev/null
P $owner2 status --json
check "cancelled leave: closing window cleared (state unset)" "$(field .state)" unset
check "cancelled leave: no machine-off window left" "$(field .machine_on)" true
check "cancelled leave: the stored state is no longer closing" "$(jq -r '.presence.state // "null"' "$HOME/.claude/session-state.json")" null
check "cancelled leave: the stored window end is cleared" "$(jq -r '.presence.until_epoch // "null"' "$HOME/.claude/session-state.json")" null

jq 'del(.presence)' "$HOME/.claude/session-state.json" > "$tmp/s.json" && mv "$tmp/s.json" "$HOME/.claude/session-state.json"
d2=$(( $(date +%s) + 2 * 3600 ))
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].window.deadline_epoch=$d2" --set ".repos[\"acme/widgets\"].leave.active=true" >/dev/null
P $owner1 set closing --by operator-message; check "closing armed for the re-declare case" "$rc" 0
d3=$(( $(date +%s) + 5 * 3600 ))
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].window.deadline_epoch=$d3" >/dev/null
P $owner2 status --json
check "re-declared leave: closing window end moves to the new deadline" "$(field .until_epoch)" "$d3"
check "re-declared leave: still closing (machine off)" "$(field .machine_on)" false

jq 'del(.presence)' "$HOME/.claude/session-state.json" > "$tmp/s.json" && mv "$tmp/s.json" "$HOME/.claude/session-state.json"
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].window.deadline_epoch=$d1" --set ".repos[\"acme/widgets\"].leave.active=true" >/dev/null
P $owner1 set here --by operator-message --for 2h; check "here window set" "$rc" 0
P $owner2 status --json; here_until=$(field .until_epoch)
"$STATE" --repo acme/widgets --set ".repos[\"acme/widgets\"].leave.active=false" >/dev/null
P $owner2 status --json
check "leave cancel leaves a here window untouched (state)" "$(field .state)" here
check "leave cancel leaves a here window untouched (end)" "$(field .until_epoch)" "$here_until"

printf '== afk trigger parsing and source gate (issue #2418)\n'
before=$(jq -c '.presence // null' "$HOME/.claude/session-state.json")
A() { P $owner1 afk-parse --by operator-message -- "$1"; }
A "/afk";                       check "/afk alone: asks" "$rc:$out" "4:ask"
A "afk";                        check "afk alone: asks" "$rc:$out" "4:ask"
A "going afk";                  check "going afk: asks" "$rc:$out" "4:ask"
A "/afk 30 min";                check "/afk 30 min" "$rc:$out" "0:--for 30m"
A "afk 30m";                    check "afk 30m" "$rc:$out" "0:--for 30m"
A "AFK for an hour.";           check "afk for an hour" "$rc:$out" "0:--for 1h"
A "going afk, back in 20 minutes"; check "going afk, back in 20 minutes" "$rc:$out" "0:--for 20m"
A "I'm afk for 2 hours";        check "I'm afk for 2 hours" "$rc:$out" "0:--for 2h"
A "afk half an hour";           check "afk half an hour" "$rc:$out" "0:--for 30m"
A "afk overnight";              check "afk overnight" "$rc:$out" "0:--rest-of-day"
A "afk until I say otherwise";  check "afk open-ended" "$rc:$out" "0:--open-ended"
A "afk 0m";                     check "zero duration: asks instead" "$rc:$out" "4:ask"
A "afk sometime later";         check "unreadable duration: asks" "$rc:$out" "4:ask"
A "afk, closing the laptop at 7"; check "laptop wording: routed to /leave-by" "$rc" 3
A "afk 30m, laptop stays on";   check "laptop mention without closing: not routed, asks" "$rc:$out" "4:ask"
A "the afk skill is broken";    check "afk mid-sentence: not a trigger" "$rc:$out" "1:"
A "afkx 3h";                    check "afk prefix of a word: not a trigger" "$rc" 1
P $owner1 afk-parse --by issue-body -- "afk 8h"
check "source gate: issue body refused" "$rc" 5
has "source gate: one refusal line" "$out" 'came from issue-body, not from you'
P $owner1 afk-parse --by task-prompt -- "/afk"; check "source gate: task prompt refused" "$rc" 5
P $owner1 afk-parse -- "afk 1h"; check "source gate: no --by is a usage error" "$rc" 2
check "afk-parse never writes presence" "$(jq -c '.presence // null' "$HOME/.claude/session-state.json")" "$before"

printf '== ask-now round: set away only while the captured declaration is still stored\n'
P $owner1 declared-epoch; captured="$out"
case "$captured" in [0-9]*:here:*:operator-message:*) ok "declared-epoch prints the stored identity" ;; *) bad "declared-epoch printed '$captured'" ;; esac
P $owner1 set away --by operator-message --for 30m --if-declared 1:here:null:operator-message; check "stale --if-declared: refused" "$rc" 10
check "stale --if-declared: nothing written" "$(jq -c '.presence // null' "$HOME/.claude/session-state.json")" "$before"
# Same second, different declaration: rewrite the stored state only, keeping declared_epoch.
sf="$HOME/.claude/session-state.json"
jq '.presence.state = "away"' "$sf" > "$tmp/s.json" && mv "$tmp/s.json" "$sf"
P $owner1 set away --by operator-message --for 30m --if-declared "$captured"; check "same-second different declaration: refused" "$rc" 10
jq '.presence.state = "here" | .presence.machine_on = false' "$sf" > "$tmp/s.json" && mv "$tmp/s.json" "$sf"
P $owner1 set away --by operator-message --for 30m --if-declared "$captured"; check "same-second move to closing (machine_on): refused" "$rc" 10
jq '.presence.machine_on = true' "$sf" > "$tmp/s.json" && mv "$tmp/s.json" "$sf"
P $owner1 set away --by operator-message --for 30m --if-declared ""; check "empty --if-declared: usage error" "$rc" 2
P $owner1 set away --by operator-message --for 30m --if-declared "$captured"; check "matching --if-declared: away set" "$rc" 0
P $owner2 status --json; check "matching --if-declared: reads away" "$(field .state)" away
P $owner1 declared-epoch
case "$out" in [0-9]*:away:[0-9]*:operator-message:*) ok "declared-epoch after a write names the new declaration" ;; *) bad "declared-epoch after write: '$out'" ;; esac
P $owner1 set here --by operator-message --for 1h --if-declared "$captured"; check "the earlier capture no longer matches" "$rc" 10

printf '== ask --afk: a live declaration does not block the operator'"'"'s own afk question\n'
P $owner1 ask --afk; check "ask --afk while already away: refused, the guard would deny the menu" "$rc" 12
P $owner1 set here --by operator-message --for 1h; check "back to here for the ask --afk checks" "$rc" 0
P $owner1 ask; check "plain ask with a live declaration: not asked" "$rc" 12
P $owner1 ask --afk; check "ask --afk: claim granted" "$rc" 0
tok="$out"
P $owner2 ask --afk; check "ask --afk: a second thread still loses the one-asker claim" "$rc" 10
P $owner1 release --generation "$tok"; check "ask --afk: claim released" "$rc" 0
P $owner1 ask --bogus; check "ask: unknown flag is a usage error" "$rc" 2

printf '== skill text: an "I'"'"'ll do it later" answer becomes a human task (issue #2562)\n'
pskill=$(tr '\n' ' ' < "$root/.claude/skills/presence/SKILL.md" | tr -s ' ')
askill=$(tr '\n' ' ' < "$root/.claude/skills/afk/SKILL.md" | tr -s ' ')
has "presence: owner-task.sh resolved as an optional helper" "$pskill" 'OWNER_TASK_SH=$(resolve_script owner-task.sh) || OWNER_TASK_SH=""'
has "presence: the menu offers a deferral option" "$pskill" "also offers \`I'll do it later\`"
has "presence: a deferred answer is saved with owner-task.sh add" "$pskill" '"$OWNER_TASK_SH" add --what "<the step>" --why "<reason>: <free text>" --source'
for reason in sign-in legal-agreement payment-detail secret-value physical-device judgment-call; do
  has "presence: reason list names $reason" "$pskill" "\`$reason\`"
done
has "presence: the receipt line is printed" "$pskill" '(`human task ht-<id> saved: <what> (<reason>)`)'
has "presence: the receipt prints before away is set" "$pskill" 'Save it, before step 5,'
has "presence: missing helper or non-zero add falls back" "$pskill" '`OWNER_TASK_SH` empty, or `add` exits non-zero'
has "presence: exit 1 checks the list before falling back" "$pskill" 'exit 1: run `list --json` first'
has "presence: exit 5 refused text goes nowhere" "$pskill" 'After an exit 5 the refused text goes nowhere'
has "presence: fallback records an open unattended question" "$pskill" 'unattended.sh record --question "Human task: <what>"'
has "presence: fallback says the task was not saved" "$pskill" 'not saved to the human-task list: <why> (owner-task.sh <not found|exit N>)'
has "presence: a failed record claims no U-<n>" "$pskill" 'If `record` also fails, claim no `U-<n>`'
has "afk: exit 1 checks the list like presence" "$askill" 'only if `list --json` does not show it'
has "presence: other answers keep their destinations" "$pskill" 'Every other answer is recorded as above.'
has "presence: existing answer destination unchanged" "$pskill" 'then `unattended.sh answer U-<n> --answer … --by operator`'
has "afk: deferred answer saved as a human task" "$askill" 'saved as a human task with `owner-task.sh add`'
has "afk: receipt printed before away" "$askill" 'its receipt is printed before away is set'
has "afk: fallback to an unattended question" "$askill" 'recorded as an open unattended question in the work'"'"'s repo (`unattended.sh record --repo`)'
has "afk: exit 5 retries once without the refused text" "$askill" 'after exit 5, only once a rewrite naming the variable is also refused, and never with the refused text'
has "presence: fallback question lands in the work's repo" "$pskill" '--did "not saved to the human-task list: <why>" --repo <owner/name of the work>'
has "afk: says the task was not saved" "$askill" 'the thread says the task was not saved'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
