#!/usr/bin/env bash
# catalog: tests — Proves one away-handling decision for every record combination, a visible failed return, and no early expiry while a closing correction is pending
# Tests for issue #2294 (PR #2328 review round 4), trimmed by issue #2352:
#   1. the truth table: `unattended.sh is-active`, `presence.sh is-away` and `presence.sh status` read ONE
#      decision (lib/presence-decision.jq) for every combination of the unattended flag, the presence
#      declaration, their age relation and whether a window ran out;
#   3. a failed `presence.sh return` is reported to the model and recorded;
#   4. an expiry is never claimed while a closing-deadline correction is pending.
# (Section 2, the pending-delivery record that kept a marked list alive, is gone: a saved question is
# listed until it is answered or dismissed, so there is nothing to deliver or confirm. The rule and its
# kill tests are in unattended-mode.test.sh.)
#
# Every run uses a throwaway HOME. State is seeded straight into the throwaway session-state.json (the
# readers under test only read it) so the table runs fast; flows that WRITE state go through the real
# scripts.
set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PRESENCE="$REPO_ROOT/.claude/scripts/presence.sh"
UNATT="$REPO_ROOT/.claude/scripts/unattended.sh"
STATE="$REPO_ROOT/.claude/scripts/session-state.sh"
GUARD="$REPO_ROOT/.claude/hooks/unattended-question-guard.sh"
DIGEST="$REPO_ROOT/.claude/hooks/unattended-digest.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: presence-delivery.test.sh — jq is not installed"
  exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   — %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL — %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1 (found '$3')" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/presence-delivery-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$TMP/tr"
unset CLAUDE_SESSION_REPO UNATTENDED_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
SF="$HOME/.claude/session-state.json"

REPO_A="$TMP/repo-a"; git init -q "$REPO_A"; git -C "$REPO_A" remote add origin https://github.com/acme/widgets.git
REPO_B="$TMP/repo-b"; git init -q "$REPO_B"; git -C "$REPO_B" remote add origin https://github.com/acme/gadgets.git
P() { (cd "$REPO_A" && "$PRESENCE" "$@"); }
U() { (cd "$REPO_A" && "$UNATT" "$@"); }
UB() { (cd "$REPO_B" && "$UNATT" "$@"); }

for f in "$PRESENCE" "$UNATT" "$GUARD" "$DIGEST" "$REPO_ROOT/.claude/scripts/lib/presence-decision.jq"; do
  case "$f" in *.jq) continue ;; esac
  if bash -n "$f"; then ok "$(basename "$f") parses"; else bad "$(basename "$f") does not parse"; fi
done

# ============================================================================
printf '== 1. truth table: the unattended flag x the presence declaration x which is newer x ended or not\n'
NOW=$(date +%s)
PT=$((NOW - 1000))   # the presence declaration time of every row

# write_state UKIND PKIND REL  (REL only matters with the flag on)
write_state() {
  local ukind="$1" pkind="$2" rel="$3" ut pst pu uu
  case "$rel" in
    newer) ut=$((PT + 100)) ;;
    tie) ut=$PT ;;
    within) ut=$((PT - 2)) ;;
    older) ut=$((PT - 100)) ;;
    *) ut=$PT ;;
  esac
  case "$pkind" in
    none) pst="" ;; herelive|herelapsed|hereopen) pst=here ;; awaylive|awaylapsed|awayopen) pst=away ;;
  esac
  case "$pkind" in
    herelive|awaylive) pu=$((NOW + 3600)) ;; herelapsed|awaylapsed) pu=$((NOW - 60)) ;; *) pu=null ;;
  esac
  case "$ukind" in
    onlive) uu=$((NOW + 3600)) ;; onlapsed) uu=$((NOW - 60)) ;; *) uu=null ;;
  esac
  jq -n --arg pst "$pst" --argjson pt "$PT" --argjson pu "$pu" --arg uk "$ukind" --argjson ut "$ut" --argjson uu "$uu" '
    (if $pst == "" then {} else {presence: {state: $pst, until_epoch: $pu, declared_epoch: $pt, machine_on: true, declared_by: "operator-message"}} end)
    + (if $uk == "absent" then {}
       elif $uk == "off" then {unattended: {active: false, since_epoch: $ut, until_epoch: null}}
       else {unattended: {active: true, since_epoch: $ut, until_epoch: $uu}} end)' >"$SF"
}

# The table, written out independently of the jq it checks. Prints: <state> <lapsed yes|no> <away yes|no>
expect_row() { # UKIND PKIND REL
  local ukind="$1" pkind="$2" rel="$3" on=0 gov pend pstate ulapsed plapsed
  case "$ukind" in onlive|onlapsed|onopen) on=1 ;; esac
  case "$pkind" in none) pstate=none ;; here*) pstate=here ;; away*) pstate=away ;; esac
  case "$pkind" in *lapsed) plapsed=1 ;; *) plapsed=0 ;; esac
  case "$ukind" in onlapsed) ulapsed=1 ;; *) ulapsed=0 ;; esac
  if [ "$on" -eq 1 ]; then
    if [ "$pstate" = none ]; then gov=U
    else
      case "$rel" in
        newer|tie) gov=U ;;
        within) if [ "$pstate" = away ]; then gov=P; else gov=U; fi ;;   # not clearly newer: a here is away
        older) gov=P ;;
      esac
    fi
  else
    if [ "$pstate" = none ]; then gov=N; else gov=P; fi
  fi
  case "$gov" in
    N) echo "unset no no" ;;
    U) if [ "$ulapsed" -eq 1 ]; then echo "away yes yes"; else echo "away no yes"; fi ;;
    P)
      if [ "$pstate" = away ] && [ "$ukind" = off ] && [ "$plapsed" -eq 0 ]; then echo "here no no"; return; fi
      if [ "$plapsed" -eq 1 ] && { [ "$pstate" = here ] || { [ "$pstate" = away ] && [ "$on" -eq 1 ]; }; }; then
        echo "$pstate yes yes"
      elif [ "$pstate" = away ] && [ "$plapsed" -eq 0 ]; then echo "away no yes"
      else echo "$pstate no no"; fi ;;
  esac
}

ROWS=0
DISAGREE=0
MISMATCH=0
row() { # UKIND PKIND REL
  local want got ia isaway st fin
  write_state "$1" "$2" "$3"
  want=$(expect_row "$1" "$2" "$3")
  st=$(P status --json 2>/dev/null)
  got=$(printf '%s' "$st" | jq -r '[.state, (if .lapsed then "yes" else "no" end), (if .away then "yes" else "no" end)] | join(" ")')
  U is-active >/dev/null 2>&1; ia=$?
  P is-away >/dev/null 2>&1; isaway=$?
  ROWS=$((ROWS + 1))
  if [ "$ia" -ne "$isaway" ]; then DISAGREE=$((DISAGREE + 1)); bad "is-active ($ia) and is-away ($isaway) disagree for $1/$2/$3"; fi
  fin=no; [ "$ia" -eq 0 ] && fin=yes
  if [ "$got" != "$want" ] || [ "$fin" != "$(printf '%s' "$want" | awk '{print $3}')" ]; then
    MISMATCH=$((MISMATCH + 1)); bad "row $1/$2/$3: got '$got' (is-active $ia), want '$want'"
  fi
}
for p in none herelive herelapsed hereopen awaylive awaylapsed awayopen; do
  for u in off absent; do row "$u" "$p" same; done
  for u in onlive onlapsed onopen; do
    for r in newer tie within older; do row "$u" "$p" "$r"; done
  done
done
check "every row: is-active, is-away and status agree" "$DISAGREE" 0
check "every row matches the written-out table" "$MISMATCH" 0
ok "$ROWS rows checked"

printf '== 1b. the named cases that decide it\n'
# The regression this round fixes: a delayed `unattended.sh on` carrying an OLDER epoch than a newer
# `set away` leaves the flag on; away handling must stay in force, and the guard must still deny.
write_state onlive awaylive older
check "delayed unattended on under a newer away: is-active (away)" "$(U is-active; echo $?)" 0
check "and presence is-away agrees" "$(P is-away; echo $?)" 0
check "and the presence end governs" "$(P status --json | jq -r '[.state, .source] | join(",")')" "away,presence"
OUT=$(jq -cn --arg cwd "$REPO_A" '{session_id: "s", cwd: $cwd, tool_name: "AskUserQuestion", tool_input: {questions: [{question: "Q?", options: [{label: "A (Recommended)"}, {label: "B"}]}]}}' | "$GUARD")
check "the question guard denies the menu" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" deny
# The mirror bug stays fixed: an older flag does not override a clearly newer here.
write_state onlive herelive older
check "an older flag under a clearly newer here: not away" "$(U is-active; echo $?)" 1
OUT=$(jq -cn --arg cwd "$REPO_A" '{session_id: "s", cwd: $cwd, tool_name: "AskUserQuestion", tool_input: {questions: [{question: "Q?", options: [{label: "A"}]}]}}' | "$GUARD")
check "so the menu renders (guard silent)" "$OUT" ""
# Neither clearly newer: away. A tie, and a here only 2 s newer.
write_state onlive herelive tie
check "a tie of the two times: away" "$(U is-active; echo $?)" 0
write_state onlive herelive within
check "a here only 2 s newer than the flag is not clearly newer: away" "$(U is-active; echo $?)" 0
# Ended by hand.
write_state off awaylive same
check "unattended explicitly off under a live away: here (ended by hand)" "$(P status --json | jq -r '[.state, .source] | join(",")')" "here,unattended-off"
check "and no away handling" "$(U is-active; echo $?)" 1
write_state off awaylapsed same
check "off under an ended away: not away" "$(U is-active; echo $?)" 1
write_state absent awaylapsed same
check "an ended away with no unattended record cannot lapse: not away" "$(P is-away; echo $?)" 1
# A newer live unattended window over an older lapsed here.
write_state onlive herelapsed newer
check "a newer live unattended window over a lapsed here: away, not lapsed" "$(P status --json | jq -r '[.state, .lapsed] | join(",")')" "away,false"
# status line follows the governing end.
write_state onlive awaylive older
check "unattended status shows the presence end that governs" "$(U status)" "active until $(date -r $((NOW + 3600)) '+%a %H:%M %Z' 2>/dev/null || date -d "@$((NOW + 3600))" '+%a %H:%M %Z')"

printf '== 1c. is-active and is-away read the same RECONCILED inputs when a /leave-by time moves\n'
KEY='.repos["acme/widgets"]'
LV() { "$STATE" --repo acme/widgets "$@" >/dev/null; }
# Deadline extended past now: the stored end already passed, but /leave-by moved it into the future.
rm -f "$SF"
D1=$(( $(date +%s) + 3600 ))
LV --set "$KEY.leave.active=true" --set "$KEY.window.deadline_epoch=$D1"
P set closing --by operator-message >/dev/null
n=$(date +%s)
"$STATE" --set ".presence.until_epoch=$((n - 5))" --set ".presence.declared_epoch=$((n - 4000))" >/dev/null
LV --set "$KEY.window.deadline_epoch=$((n + 7200))"
check "extended past now: is-active (asked FIRST, before any presence call) says not away" "$(U is-active; echo $?)" 1
check "and is-away agrees" "$(P is-away; echo $?)" 1
# Deadline moved into the past: the stored end is still in the future, but /leave-by ended it.
rm -f "$SF"
LV --set "$KEY.leave.active=true" --set "$KEY.window.deadline_epoch=$((n + 3600))"
P set closing --by operator-message >/dev/null
LV --set "$KEY.window.deadline_epoch=$(( $(date +%s) - 5 ))"
check "moved into the past: is-active (asked FIRST) says away handling applies" "$(U is-active; echo $?)" 0
check "and is-away agrees" "$(P is-away; echo $?)" 0

# ============================================================================
# Hook harness: payloads carry a transcript path, as the harness sends them.
tpath() { printf '%s/tr/%s.jsonl' "$TMP" "$1"; }
prompt_payload() { # SID CWD PROMPT
  [ -f "$(tpath "$1")" ] || : >"$(tpath "$1")"
  jq -cn --arg sid "$1" --arg cwd "$2" --arg p "$3" --arg tp "$(tpath "$1")" \
    '{session_id: $sid, cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: $p, transcript_path: $tp}'
}
ask_payload() { # SID CWD
  [ -f "$(tpath "$1")" ] || : >"$(tpath "$1")"
  jq -cn --arg sid "$1" --arg cwd "$2" --arg tp "$(tpath "$1")" '{session_id: $sid, cwd: $cwd, hook_event_name: "PreToolUse",
    transcript_path: $tp, tool_name: "AskUserQuestion", tool_input: {questions: [{question: "Which provider?", header: "P",
    options: [{label: "Twilio (Recommended)", description: "x"}, {label: "Amazon", description: "y"}], multiSelect: false}]}}'
}
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }
operator() { # SID [CWD] -> hook output, delivered
  local out
  out=$(prompt_payload "$1" "${2:-$REPO_A}" "morning, I am back" | "$DIGEST")
  printf '%s' "$out"
}
K=0
seed() { # here|away: a window that has run out
  K=$((K + 1))
  local n gen; n=$(date +%s); gen=$((n - 100000 - K * 1000))
  rm -rf "$HOME/.claude/unattended"
  if [ "$1" = here ]; then
    jq -n --argjson g "$gen" --argjson e $((n - 5)) '{presence: {state: "here", until_epoch: $e, declared_epoch: $g, machine_on: true, declared_by: "operator-message"}, unattended: {active: false}}' >"$SF"
  else
    jq -n --argjson g "$gen" --argjson e $((n - 5)) '{presence: {state: "away", until_epoch: $e, declared_epoch: $g, machine_on: true, declared_by: "operator-message"}, unattended: {active: true, since_epoch: $g, until_epoch: $e}}' >"$SF"
  fi
}
sj() { jq -r "$1" "$SF"; }

# ============================================================================
printf '== 3. a failed return is reported, not swallowed\n'
seed here
U record --question "Behind a failed return?" --context "Test background: what this change is and why the operator is being asked" --recommended "y" >/dev/null
CAS_STUB="$TMP/cas-fail-state.sh"
cat >"$CAS_STUB" <<CASSTUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = --cas ] && exit 6; done
exec "$STATE" "\$@"
CASSTUB
chmod +x "$CAS_STUB"
OUT=$(prompt_payload s-1 "$REPO_A" "back" | PRESENCE_SESSION_STATE_SH="$CAS_STUB" "$DIGEST")
C=$(ctx "$OUT")
has "the model is told the return failed" "$C" "PRESENCE RETURN FAILED"
has "that away handling has not ended" "$C" "away handling has NOT ended"
has "and that other repos were not listed" "$C" "other repos have not been listed"
has "and that his next message retries" "$C" "next message retries"
lacks "no dialog is asked on a failed return" "$C" "PRESENCE DIALOG"
check "away handling is still in force" "$(U is-active; echo $?)" 0
has "the failure is recorded" "$(cat "$HOME/.claude/unattended/hook.log" 2>/dev/null)" "presence.sh return exited 11"
OUT=$(operator s-1)
# The failed-return turn already listed it in full to this session, so the retry carries the summary line.
has "his next message retries the return and lists it (summary: seen in full this session)" "$(ctx "$OUT")" "still unanswered (U-1)"
check "away handling ended" "$(U is-active; echo $?)" 1
# A benign no-op (the window was re-declared in between) is not reported as a failure.
seed here
OUT=$(prompt_payload s-1 "$REPO_A" "back" | "$DIGEST")
lacks "a normal return reports no failure" "$(ctx "$OUT")" "RETURN FAILED"

# ============================================================================
printf '== 4. no expiry is claimed while a closing correction is pending\n'
rm -f "$SF"; rm -rf "$HOME/.claude/unattended"
KEY='.repos["acme/widgets"]'
D1=$(( $(date +%s) + 3600 ))
"$STATE" --repo acme/widgets --set "$KEY.leave.active=true" --set "$KEY.window.deadline_epoch=$D1" >/dev/null
P set closing --by operator-message >/dev/null
# The stored end passes while /leave-by has since moved the deadline into the future: a correction is due.
n=$(date +%s)
"$STATE" --set ".presence.until_epoch=$((n - 5))" --set ".presence.declared_epoch=$((n - 4000))" >/dev/null
D2=$((n + 7200))
"$STATE" --repo acme/widgets --set "$KEY.window.deadline_epoch=$D2" >/dev/null
# Every attempt to correct the end fails (not the expiry claim itself).
FAIL_STUB="$TMP/until-fail-state.sh"
cat >"$FAIL_STUB" <<FSTUB
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in .presence.until_epoch=*) exit 6 ;; esac; done
exec "$STATE" "\$@"
FSTUB
chmod +x "$FAIL_STUB"
EXOUT=$( export PRESENCE_SESSION_STATE_SH="$FAIL_STUB"; P expire 2>&1; echo "rc=$?")
has "expire exits 11 while the correction cannot land" "$EXOUT" "rc=11"
lacks "and prints no notice" "$EXOUT" "window ended"
check "and stored no claim" "$(sj '.presence.expiry_claim')" null
check "probe offers nothing to act on" "$( export PRESENCE_SESSION_STATE_SH="$FAIL_STUB"; P probe)" none
RET=$( export PRESENCE_SESSION_STATE_SH="$FAIL_STUB"; P return >/dev/null 2>&1; echo $?)
check "return refuses too (the window may not have lapsed)" "$RET" 11
# Once the correction can land, the window is simply not over: nothing to expire, nothing claimed.
P expire >"$TMP/e.out"; ERC=$?
check "with the correction landed: nothing to expire" "$ERC" 1
check "the end was corrected to the leave time" "$(sj '.presence.until_epoch')" "$D2"
check "and still no claim" "$(sj '.presence.expiry_claim')" null
# When the corrected end really passes, the notice is not suppressed by an earlier claim.
n=$(date +%s)
"$STATE" --set ".presence.until_epoch=$((n - 5))" >/dev/null
"$STATE" --repo acme/widgets --set "$KEY.window.deadline_epoch=$((n - 5))" >/dev/null
check "the real end is now unclaimed" "$(P probe)" lapsed
has "and its notice is printed once" "$(P expire)" "your at-computer window ended"

printf '\npresence-delivery.test.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
