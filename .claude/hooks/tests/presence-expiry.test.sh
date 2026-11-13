#!/usr/bin/env bash
# catalog: tests — Proves quiet window expiry (one notice for all threads), return on the operator's message, list-then-dialog ordering, and closing-deadline reconciliation
# Tests for issue #2294 (presence windows, increment 2): .claude/scripts/presence.sh
# (expire, return, dialog-claim, push-result, probe, reconcile), unattended.sh digest --all and
# is-active, and the two hooks that evaluate expiry lazily (unattended-question-guard.sh,
# unattended-digest.sh).
#
# Every run uses a throwaway HOME; the live ~/.claude is never touched. The clock is stubbed the way
# unattended-mode.test.sh does it: a window is declared through presence.sh, then its stored epochs
# are moved into the past with session-state.sh, so the real evaluation code runs against an
# elapsed window without waiting. Nothing here can exercise a real phone push or a real operator
# (live tests: issues #2304 and #2308).
set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PRESENCE="$REPO_ROOT/.claude/scripts/presence.sh"
UNATT="$REPO_ROOT/.claude/scripts/unattended.sh"
STATE="$REPO_ROOT/.claude/scripts/session-state.sh"
GUARD="$REPO_ROOT/.claude/hooks/unattended-question-guard.sh"
DIGEST="$REPO_ROOT/.claude/hooks/unattended-digest.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: presence-expiry.test.sh — jq is not installed"
  exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   — %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL — %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1 (found '$3')" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/presence-expiry-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
unset CLAUDE_SESSION_REPO UNATTENDED_DIR
SF="$HOME/.claude/session-state.json"

REPO_A="$TMP/repo-a"; git init -q "$REPO_A"; git -C "$REPO_A" remote add origin https://github.com/acme/widgets.git
REPO_B="$TMP/repo-b"; git init -q "$REPO_B"; git -C "$REPO_B" remote add origin https://github.com/acme/gadgets.git

P() { (cd "$REPO_A" && "$PRESENCE" "$@"); }
U() { (cd "$REPO_A" && "$UNATT" "$@"); }
UB() { (cd "$REPO_B" && "$UNATT" "$@"); }

# Hook payloads. SID distinguishes the "threads".
ask_payload() { # SID CWD
  jq -cn --arg sid "$1" --arg cwd "$2" '{session_id: $sid, cwd: $cwd, hook_event_name: "PreToolUse",
    tool_name: "AskUserQuestion", tool_input: {questions: [{question: "Which provider?", header: "P",
    options: [{label: "Twilio (Recommended)", description: "x"}, {label: "Amazon", description: "y"}], multiSelect: false}]}}'
}
prompt_payload() { # SID CWD PROMPT
  jq -cn --arg sid "$1" --arg cwd "$2" --arg p "$3" '{session_id: $sid, cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: $p}'
}
guard() { ask_payload "$1" "${2:-$REPO_A}" | "$GUARD"; }          # prints the hook JSON
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }
operator() { prompt_payload "$1" "${2:-$REPO_A}" "morning, I am back" | "$DIGEST"; }   # SID [CWD]
automated() { prompt_payload "$1" "${2:-$REPO_A}" "<task-notification>agent done</task-notification>" | "$DIGEST"; }

K=0
# Declare a window, then move its stored epochs into the past so it has run out. K keeps each
# window's generation (its declaration time) distinct, as separate real declarations would be.
lapse() { # here|away [extra flags: --by ... already added]
  K=$((K + 1))
  local n; n=$(date +%s)
  P set "$1" --by operator-message --for 30m >/dev/null
  "$STATE" --set ".presence.declared_epoch=$((n - 100000 - K * 1000))" --set ".presence.until_epoch=$((n - 5))" \
    --set ".unattended.since_epoch=$((n - 100000 - K * 1000))" --set ".unattended.until_epoch=$((n - 5))" >/dev/null
}
sj() { jq -r "$1" "$SF"; }                    # read a field of the state file
qcount() { jq -s '[.[] | select(.type == "question")] | length' "$HOME/.claude/unattended/$1.jsonl" 2>/dev/null || echo 0; }

for f in "$PRESENCE" "$UNATT" "$GUARD" "$DIGEST"; do
  if bash -n "$f"; then ok "$(basename "$f") parses"; else bad "$(basename "$f") does not parse"; fi
done

# ----------------------------------------------------------------------------
printf '== an at-computer window runs out: threads record, nothing opens, one notice\n'
lapse here
check "probe: an unclaimed window end is waiting" "$(P probe)" lapsed
check "status says it ran out" "$(P status | grep -c 'threads record questions')" 1
check "is-away: lapsed counts as away handling" "$(P is-away; echo $?)" 0
check "unattended is-active: lapsed counts" "$(U is-active; echo $?)" 0
P ask >/dev/null 2>&1; check "ask: no question on a timer (exit 12)" "$?" 12
OUT=$(guard s-1)
check "a question is denied, not opened" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" deny
R1=$(reason "$OUT")
has "the winner's deny names the ended window" "$R1" "your at-computer window ended"
has "the winner is told to push once, with exact text" "$R1" "call the PushNotification tool with exactly this text: Presence window ended"
has "the winner is told where to record the result" "$R1" "push-result sent|missed --generation"
has "the question is still recorded" "$R1" "Recorded for his return: U-1"
OUT=$(guard s-2)
R2=$(reason "$OUT")
check "another thread's question is denied too" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" deny
lacks "but it gets no second notice" "$R2" "window ended"
lacks "and no second push instruction" "$R2" "PushNotification"
check "both questions recorded" "$(qcount acme__widgets)" 2
check "the claim is stored once" "$(sj '.presence.expiry_claim.kind')" here

printf '== concurrent expiry: one notice in total\n'
lapse here
for i in 1 2 3 4 5 6; do ( P expire >"$TMP/exp.$i" 2>/dev/null ) & done
wait
WINNERS=0
for i in 1 2 3 4 5 6; do [ -s "$TMP/exp.$i" ] && WINNERS=$((WINNERS + 1)); done
check "exactly one of six threads got the notice" "$WINNERS" 1
check "a later expire prints nothing" "$(P expire)" ""
GEN=$(sj '.presence.expiry_claim.generation')

printf '== stale generation: a re-declared window gets its own notice; an old push result is ignored\n'
lapse here
check "a new window, a new unclaimed end" "$(P probe)" lapsed
NEW=$(P expire)
has "the new window's expiry prints a notice" "$NEW" "your at-computer window ended"
P push-result sent --generation "$GEN" >/dev/null
check "a stale generation's push result is ignored" "$(sj '.presence.expiry_claim.push')" null
GEN2=$(sj '.presence.expiry_claim.generation')
P push-result sent --generation "$GEN2" >/dev/null
check "the current generation's push result is stored" "$(sj '.presence.expiry_claim.push')" sent
P push-result missed --generation "$GEN2" >/dev/null
check "a second result cannot overwrite the first" "$(sj '.presence.expiry_claim.push')" sent
P push-result maybe --generation "$GEN2" >/dev/null 2>&1; check "a bad result word is a usage error" "$?" 2
# A window re-declared between probe and claim: the claim guards on the declaration it read.
lapse here
P set here --by operator-message --for 2h >/dev/null
check "a live re-declaration leaves nothing to expire" "$(P expire)" ""

printf '== any live message returns him: list first from every repo, dialog after\n'
rm -rf "$HOME/.claude/unattended"
lapse here
U record --question "Rename the job?" --recommended "keep" >/dev/null
UB record --question "Gadgets: which DB?" --recommended "postgres" >/dev/null
OUT=$(operator s-1)
C=$(ctx "$OUT")
has "the list covers this repo" "$C" "[acme/widgets] Questions recorded while you were away (1)"
has "the list covers another repo" "$C" "[acme/gadgets] Questions recorded while you were away (1)"
has "he is told menus work again" "$C" "menus work again"
has "and not to ask the presence question this turn" "$C" "Do NOT ask the presence question in this turn"
lacks "the dialog is not in the list turn" "$C" "PRESENCE DIALOG"
check "away handling ended" "$(U is-active; echo $?)" 1
check "presence reads unset" "$(P status)" "unset (no presence declared)"
check "the dialog is pending after the list" "$(sj '.presence.return.dialog')" pending
OUT=$(guard s-1)
check "after the return a menu renders (guard silent)" "$OUT" ""
OUT=$(operator s-2)
has "his next message, in any thread, asks the dialog" "$(ctx "$OUT")" "PRESENCE DIALOG"
has "with the one-asker gate named" "$(ctx "$OUT")" "presence.sh' ask"
check "the dialog is now claimed" "$(sj '.presence.return.dialog')" asked
OUT=$(operator s-3)
lacks "a third message does not ask it again" "$(ctx "$OUT")" "PRESENCE DIALOG"

printf '== the dialog is claimed once across concurrent sessions\n'
lapse here
check "no questions saved this time" "$(U pending)" 0
OUT=$(operator s-1)
has "nothing saved: the dialog comes in the same turn" "$(ctx "$OUT")" "PRESENCE DIALOG"
lapse here
U record --question "Q?" --recommended "y" >/dev/null
OUT=$(operator s-1)
has "something saved: list only" "$(ctx "$OUT")" "Q?"
for i in 1 2 3 4; do ( operator "s-$i" >"$TMP/dlg.$i" 2>/dev/null ) & done
wait
DLG=0
for i in 1 2 3 4; do grep -q 'PRESENCE DIALOG' "$TMP/dlg.$i" && DLG=$((DLG + 1)); done
check "four simultaneous messages: the dialog goes out once" "$DLG" 1
check "dialog-claim is spent" "$(P dialog-claim; echo $?)" 1

printf '== while the return winner is still listing, nobody else lists or asks\n'
rm -rf "$HOME/.claude/unattended"
lapse here
U record --question "Still listing?" --recommended "y" >/dev/null
P return >/dev/null
check "the dialog waits for the list" "$(sj '.presence.return.dialog')" listing
check "probe: a return is in progress" "$(P probe)" returning
check "no dialog claim yet" "$(P dialog-claim; echo $?)" 1
OUT=$(operator s-9)
check "another hook adds nothing in the meantime (no list, no dialog)" "$OUT" ""
check "and did not consume the saved question" "$(U pending)" 1
P dialog-ready >/dev/null; check "the winner finishes listing" "$?" 0
check "the dialog is now pending for the next message" "$(sj '.presence.return.dialog')" pending
P dialog-ready >/dev/null; check "dialog-ready is not repeatable" "$?" 1
# A winner that died mid-list is given up on after two minutes: listing resumes, nothing stays stuck.
lapse here
P return >/dev/null
"$STATE" --set ".presence.return.generation=$(( $(date +%s) - 300 ))" >/dev/null
check "a stuck return stops blocking" "$(P probe)" none
OUT=$(operator s-9)
has "so the next message lists again" "$(ctx "$OUT")" "Still listing?"

printf '== concurrent returns: one session handles the return\n'
rm -rf "$HOME/.claude/unattended"
lapse here
U record --question "Concurrent?" --recommended "y" >/dev/null
for i in 1 2 3 4; do ( operator "r-$i" >"$TMP/ret.$i" 2>/dev/null ) & done
wait
LISTED=0
for i in 1 2 3 4; do grep -q 'Concurrent?' "$TMP/ret.$i" && LISTED=$((LISTED + 1)); done
check "the saved question is listed exactly once" "$LISTED" 1
check "away handling ended" "$(U is-active; echo $?)" 1

printf '== a declaration answers the pending dialog\n'
lapse here
U record --question "Pending dialog?" --recommended "y" >/dev/null
operator s-1 >/dev/null
check "the dialog is pending" "$(sj '.presence.return.dialog')" pending
P set here --by operator-message --for 1h >/dev/null
check "declaring presence clears it" "$(sj '.presence.return')" null
OUT=$(operator s-2)
lacks "so the next message does not ask" "$(ctx "$OUT")" "PRESENCE DIALOG"

printf '== an away window runs out: listed without a menu, away handling continues\n'
rm -rf "$HOME/.claude/unattended"
U record --question "Saved before the end?" --recommended "go" >/dev/null
lapse away
check "unattended flag is still on after the end" "$(sj '.unattended.active')" true
check "away is-active after the end" "$(U is-active; echo $?)" 0
check "probe: unclaimed away end" "$(P probe)" lapsed
OUT=$(automated m-1)
C=$(ctx "$OUT")
has "an automated prompt (Monitor wake) carries the away notice" "$C" "your away window ended"
has "and the saved questions" "$C" "Saved before the end?"
lacks "and no push instruction (away sends none)" "$C" "PushNotification"
lacks "and no menu or dialog" "$C" "PRESENCE DIALOG"
check "a second automated prompt prints nothing" "$(automated m-2)" ""
OUT=$(guard s-1)
check "a new question is still denied and recorded" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" deny
check "recorded as the second question" "$(qcount acme__widgets)" 2
check "still away handling: no return without a message" "$(U is-active; echo $?)" 0
check "status says away ended" "$(P status | grep -c 'away, ended')" 1
OUT=$(operator s-1)
has "his message lists what was saved since the list" "$(ctx "$OUT")" "Which provider?"
check "then away handling ends" "$(U is-active; echo $?)" 1

printf '== automated prompts never return him\n'
lapse here
automated m-1 >/dev/null
automated m-2 >/dev/null
check "still lapsed after automated prompts" "$(U is-active; echo $?)" 0
check "return not recorded" "$(sj '.presence.return')" null
P return >/dev/null; check "return itself acts (the hook only calls it on operator prompts)" "$?" 0
P return >/dev/null; check "a second return has nothing to return from" "$?" 1

printf '== windows that must not expire\n'
P set here --by operator-message --open-ended >/dev/null
check "open-ended here: probe none" "$(P probe)" none
check "open-ended here: expire prints nothing" "$(P expire)" ""
P set away --by operator-message --open-ended >/dev/null
check "open-ended away: probe none" "$(P probe)" none
check "open-ended away: expire prints nothing" "$(P expire)" ""
OUT=$(operator s-1)
check "open-ended away: a message changes nothing" "$(U is-active; echo $?)" 0
P set here --by operator-message --for 2h >/dev/null
check "unexpired here: probe none" "$(P probe)" none
OUT=$(operator s-1)
lacks "unexpired here: a message does not return him" "$(ctx "$OUT")" "back"
P return >/dev/null; check "unexpired here: return has nothing to do" "$?" 1
check "unexpired here: the window stands" "$(P status --json | jq -r .state)" here

printf '== turning unattended off ends a lapsed window\n'
lapse here
check "lapsed: away handling" "$(U is-active; echo $?)" 0
U off >/dev/null
check "off ends it" "$(U is-active; echo $?)" 1
check "and clears the window" "$(P status)" "unset (no presence declared)"

lapse here
U on --for 1h >/dev/null
check "a newer live unattended window over an older lapsed one: away" "$(U is-active; echo $?)" 0
U off >/dev/null
check "off ends both, not just the newer window" "$(U is-active; echo $?)" 1

printf '== a tie of the two declaration times: unattended wins, and its end still lapses\n'
n=$(date +%s)
"$STATE" --set ".presence={\"state\":\"here\",\"until_epoch\":null,\"declared_epoch\":$((n - 900)),\"machine_on\":true}" \
  --set ".unattended={\"active\":true,\"since_epoch\":$((n - 900)),\"until_epoch\":$((n - 5))}" >/dev/null
check "probe sees the tied, expired unattended window" "$(P probe)" lapsed
check "status agrees (away, ended)" "$(P status --json | jq -r '[.state, .lapsed] | join(",")')" "away,true"
P return >/dev/null; check "and it can be returned from" "$?" 0

printf '== a plain unattended window (no presence record) behaves the same\n'
rm -f "$SF"
n=$(date +%s)
U on --for 1h >/dev/null
"$STATE" --set ".unattended.since_epoch=$((n - 7200))" --set ".unattended.until_epoch=$((n - 5))" >/dev/null
check "plain window ran out: still away handling" "$(U is-active; echo $?)" 0
check "probe sees it" "$(P probe)" lapsed
has "expire speaks for it" "$(P expire)" "your away window ended"
OUT=$(operator s-1)
check "his message ends it" "$(U is-active; echo $?)" 1

printf '== a stored closing window follows the /leave-by record\n'
rm -f "$SF"
KEY='.repos["acme/widgets"]'
D1=$(( $(date +%s) + 3600 ))
"$STATE" --repo acme/widgets --set "$KEY.leave.active=true" --set "$KEY.window.deadline_epoch=$D1" >/dev/null
P set closing --by operator-message >/dev/null
check "closing is stored with its end" "$(P status --json | jq -r .until_epoch)" "$D1"
check "and remembers whose leave time it follows" "$(sj '.presence.closing_repo')" acme/widgets
D2=$((D1 + 1800))
"$STATE" --repo acme/widgets --set "$KEY.window.deadline_epoch=$D2" >/dev/null
check "the leave time moved: the window end is corrected on the next read" "$(P status --json | jq -r .until_epoch)" "$D2"
check "the stored record is corrected, not just the display" "$(sj '.presence.until_epoch')" "$D2"
"$STATE" --repo acme/widgets --set "$KEY.leave.active=false" >/dev/null
check "the leave time was cancelled: the window is cleared" "$(P status)" "unset (no presence declared)"
check "and no longer holds a closing repo" "$(sj '.presence.closing_repo')" null
check "nothing is left to expire" "$(P expire)" ""
# Cancelled and changed from the expiry path too, not only from status.
"$STATE" --repo acme/widgets --set "$KEY.leave.active=true" --set "$KEY.window.deadline_epoch=$D1" >/dev/null
P set closing --by operator-message >/dev/null
"$STATE" --repo acme/widgets --set "$KEY.leave.active=false" >/dev/null
check "probe reconciles a cancelled leave time" "$(P probe)" none
check "and the window is gone" "$(sj '.presence.state')" null
# A deadline that has already passed is a real end, not a stale one: the expiry handling stands.
"$STATE" --repo acme/widgets --set "$KEY.leave.active=true" --set "$KEY.window.deadline_epoch=$((D1))" >/dev/null
P set closing --by operator-message >/dev/null
n=$(date +%s)
"$STATE" --set ".presence.until_epoch=$((n - 5))" --set ".presence.declared_epoch=$((n - 4000))" >/dev/null
"$STATE" --repo acme/widgets --set "$KEY.leave.active=false" >/dev/null
check "a spent closing deadline with its record gone still lapses" "$(P probe)" lapsed
has "and its expiry prints the notice" "$(P expire)" "your at-computer window ended"

printf '== guard and digest hooks do nothing without state\n'
rm -rf "$HOME/.claude/session-state.json" "$HOME/.claude/unattended"
check "guard: silent with no state" "$(guard s-1)" ""
check "digest: silent with no state" "$(operator s-1)" ""

printf '\npresence-expiry.test.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
