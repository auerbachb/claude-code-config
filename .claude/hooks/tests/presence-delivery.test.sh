#!/usr/bin/env bash
# catalog: tests — Proves one away-handling decision for every record combination, listed questions that survive a killed hook, a visible failed return, and no early expiry while a closing correction is pending
# Tests for issue #2294 (PR #2328 review round 4):
#   1. the truth table: `unattended.sh is-active`, `presence.sh is-away` and `presence.sh status` read ONE
#      decision (lib/presence-decision.jq) for every combination of the unattended flag, the presence
#      declaration, their age relation and whether a window ran out;
#   2. pending delivery: a list is persisted before it is marked, shown again when the hook died before
#      the model had it, never reported as "none saved", and not repeated once it was delivered;
#   3. a failed `presence.sh return` is reported to the model and recorded;
#   4. an expiry is never claimed while a closing-deadline correction is still pending.
#
# Every run uses a throwaway HOME. State is seeded straight into the throwaway session-state.json (the
# readers under test only read it) so the table runs fast; flows that WRITE state go through the real
# scripts. The harness is simulated where it matters: `deliver` appends a hook's output to the session's
# fake transcript the way Claude Code records injected context, and a killed hook is a stub `jq` that
# dies on the hook's final emit.
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
REAL_JQ=$(command -v jq)

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
unset CLAUDE_SESSION_REPO UNATTENDED_DIR UNATTENDED_DELIVERY_REF UNATTENDED_DELIVERY_SESSION UNATTENDED_DELIVERY_TRANSCRIPT
SF="$HOME/.claude/session-state.json"
PEND="$HOME/.claude/unattended/pending"

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
# Hook harness: payloads carry a transcript path; deliver records a hook's output in it the way the
# harness does, so delivery can be verified.
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
deliver() { # SID HOOK_OUTPUT — what the harness records of injected context
  local c
  c=$(printf '%s' "$2" | jq -r '.hookSpecificOutput.additionalContext // .hookSpecificOutput.permissionDecisionReason // ""')
  [ -z "$c" ] || jq -cn --arg c "$c" '{type: "attachment", attachment: {type: "hook_additional_context", content: [$c]}}' >>"$(tpath "$1")"
}
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }
operator() { # SID [CWD] -> hook output, delivered
  local out
  out=$(prompt_payload "$1" "${2:-$REPO_A}" "morning, I am back" | "$DIGEST")
  deliver "$1" "$out"
  printf '%s' "$out"
}
operator_lost() { # SID [CWD]: the harness never records the output
  prompt_payload "$1" "${2:-$REPO_A}" "morning, I am back" | "$DIGEST"
}
# A hook that dies on its final emit: every other jq call passes through to the real jq.
STUB="$TMP/stubbin"; mkdir -p "$STUB"
cat >"$STUB/jq" <<STUBJQ
#!/usr/bin/env bash
case "\$*" in *hookEventName*) exit 137 ;; esac
exec "$REAL_JQ" "\$@"
STUBJQ
chmod +x "$STUB/jq"
operator_killed() { # SID [CWD]: killed after persisting and marking, before the output is emitted
  prompt_payload "$1" "${2:-$REPO_A}" "morning, I am back" | PATH="$STUB:$PATH" "$DIGEST"
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
npend() { ls "$PEND"/*.json 2>/dev/null | wc -l | tr -d ' '; }

printf '== 2a. killed after the list was persisted and marked: the next prompt shows it, never "none saved"\n'
seed here
U record --question "Rename the job?" --recommended "keep" >/dev/null
UB record --question "Gadgets: which DB?" --recommended "postgres" >/dev/null
OUT=$(operator_killed s-1)
check "the killed hook emitted nothing" "$OUT" ""
check "the marks were written (nothing unlisted is left)" "$(U pending)" 0
check "a record per repo block is on disk" "$(npend)" 2
check "the dialog waits (the winner never delivered)" "$(sj '.presence.return.dialog')" pending
OUT=$(operator s-1)
C=$(ctx "$OUT")
has "his next prompt shows this repo's question" "$C" "Rename the job?"
has "and the other repo's" "$C" "Gadgets: which DB?"
lacks "and does not report none saved" "$C" "No questions were saved"
has "the list says it was not confirmed shown" "$C" "not been confirmed shown"
has "the presence dialog follows the list" "$C" "PRESENCE DIALOG"
LIST_AT=$(printf '%s' "$C" | grep -n 'Rename the job' | head -1 | cut -d: -f1)
DLG_AT=$(printf '%s' "$C" | grep -n 'PRESENCE DIALOG' | head -1 | cut -d: -f1)
check "list first, dialog after" "$([ "$LIST_AT" -lt "$DLG_AT" ] && echo yes || echo no)" yes
OUT=$(operator s-1)
lacks "once the repeat was delivered it is not shown a third time" "$(ctx "$OUT")" "Rename the job?"
check "and no record is left" "$(npend)" 0

printf '== 2b. killed after the emit: delivered when the transcript has it, shown again when it does not\n'
seed here
U record --question "Emit delivered?" --recommended "y" >/dev/null
OUT=$(operator s-1)
has "the list went out with a delivery reference" "$(ctx "$OUT")" "Delivery reference pd-"
check "a record exists until its delivery is confirmed" "$(npend)" 1
OUT=$(operator s-1)
lacks "next prompt: the transcript has the ref, so it is not repeated" "$(ctx "$OUT")" "Emit delivered?"
check "and the record is dropped" "$(npend)" 0
seed here
U record --question "Emit dropped?" --recommended "y" >/dev/null
operator_lost s-1 >/dev/null
OUT=$(operator s-1)
has "the harness never recorded it: shown again" "$(ctx "$OUT")" "Emit dropped?"
OUT=$(operator s-1)
lacks "and settled once that repeat is recorded" "$(ctx "$OUT")" "Emit dropped?"

printf '== 2c. a takeover of a dead return winner never reports none saved over an undelivered list\n'
seed here
U record --question "Stranded?" --recommended "a" >/dev/null
operator_killed s-1 >/dev/null
# Rewind to what a winner that died BEFORE dialog-ready leaves: dialog still listing, 5 minutes old.
"$STATE" --set '.presence.return.dialog="listing"' --set ".presence.return.generation=$(( $(date +%s) - 300 ))" >/dev/null
check "probe: the dead winner is stale" "$(P probe)" listing-stale
OUT=$(operator s-2)
C=$(ctx "$OUT")
has "another session takes over and lists it" "$C" "Stranded?"
lacks "and does not say none were saved" "$C" "No questions were saved"
check "the dialog waits for his next message" "$(sj '.presence.return.dialog')" pending

printf '== 2d. the ordinary per-repo digest is closed the same way\n'
seed here
P return --no-dialog >/dev/null
U record --question "Ordinary digest?" --recommended "y" >/dev/null
OUT=$(operator_killed s-1)
check "killed: nothing emitted" "$OUT" ""
check "the question is marked listed" "$(U pending)" 0
OUT=$(operator s-1)
has "the next prompt shows it" "$(ctx "$OUT")" "Ordinary digest?"
OUT=$(operator s-1)
lacks "and then not again" "$(ctx "$OUT")" "Ordinary digest?"

printf '== 2e. another session waits out the grace window; the dialog waits for the list\n'
seed here
U record --question "In flight elsewhere?" --recommended "y" >/dev/null
operator_lost s-1 >/dev/null
check "dialog pending after the lost emission" "$(sj '.presence.return.dialog')" pending
OUT=$(operator s-2)
lacks "a live session's list is not taken over inside the grace window" "$(ctx "$OUT")" "In flight elsewhere?"
lacks "and the dialog does not jump ahead of it" "$(ctx "$OUT")" "PRESENCE DIALOG"
for rec in "$PEND"/*.json; do jq -c ".stamped_at = $(( $(date +%s) - 300 ))" "$rec" >"$rec.new" && mv "$rec.new" "$rec"; done
OUT=$(operator s-2)
has "after the grace window another session shows it" "$(ctx "$OUT")" "In flight elsewhere?"

printf '== 2f. an away-expiry list from the guard is persisted too\n'
seed away
U record --question "Saved before the end?" --recommended "go" >/dev/null
OUT=$(ask_payload s-g "$REPO_A" | "$GUARD")
R=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
has "the winner's deny carries the list" "$R" "Saved before the end?"
has "and its delivery reference" "$R" "Delivery reference pd-"
check "a record exists" "$(npend)" 1
deliver s-g "$OUT"
OUT=$(operator s-g)
lacks "the deny reached the transcript, so the list is not repeated" "$(ctx "$OUT")" "Saved before the end?"

printf '== 2g. no transcript path in the payload: still retained (never marked without a record)\n'
seed here
U record --question "No transcript?" --recommended "y" >/dev/null
nopath() { jq -cn --arg sid "$1" --arg cwd "$REPO_A" '{session_id: $sid, cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: "back"}' | "$DIGEST"; }
OUT=$(nopath s-n)
has "listed" "$(ctx "$OUT")" "No transcript?"
check "marked listed" "$(U pending)" 0
check "and a record is retained, since nothing can confirm it" "$(npend)" 1
OUT=$(nopath s-n)
lacks "the same session's next prompt is the only signal there is: not repeated" "$(ctx "$OUT")" "No transcript?"
check "and the record is retired" "$(npend)" 0
seed here
U record --question "No transcript, killed?" --recommended "y" >/dev/null
jq -cn --arg sid s-n --arg cwd "$REPO_A" '{session_id: $sid, cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: "back"}' | PATH="$STUB:$PATH" "$DIGEST" >/dev/null
for rec in "$PEND"/*.json; do jq -c ".stamped_at = $(( $(date +%s) - 300 ))" "$rec" >"$rec.new" && mv "$rec.new" "$rec"; done
OUT=$(nopath s-other)
has "killed before the emit, no path: another session shows it after the grace window" "$(ctx "$OUT")" "No transcript, killed?"

printf '== 2h. a list that cannot be persisted is not marked listed\n'
seed here
U record --question "Cannot persist?" --recommended "y" >/dev/null
: >"$HOME/.claude/unattended/pending"   # a file where the directory must go
OUT=$(operator s-1)
check "the question stays unlisted" "$(U pending)" 1
lacks "and nothing is claimed as listed" "$(ctx "$OUT")" "Cannot persist?"
rm -f "$HOME/.claude/unattended/pending"

printf '== 2i. a transcript path whose file does not exist yet still gets a record\n'
seed here
U record --question "Early first prompt?" --recommended "y" >/dev/null
NEWTP="$TMP/tr/not-yet.jsonl"
rm -f "$NEWTP"
OUT=$(jq -cn --arg cwd "$REPO_A" --arg tp "$NEWTP" '{session_id: "s-late", cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: "back", transcript_path: $tp}' | "$DIGEST")
has "the list is emitted" "$(ctx "$OUT")" "Early first prompt?"
check "a record was written although the transcript file was missing" "$(npend)" 1
check "and the question is marked listed" "$(U pending)" 0
# The harness never recorded it, and the file shows up empty: the next prompt shows the list again.
: >"$NEWTP"
OUT=$(jq -cn --arg cwd "$REPO_A" --arg tp "$NEWTP" '{session_id: "s-late", cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: "back", transcript_path: $tp}' | "$DIGEST")
has "undelivered: shown again on the next prompt" "$(ctx "$OUT")" "Early first prompt?"

printf '== 2j. an undelivered list never expires by age\n'
seed here
U record --question "Days later?" --recommended "y" >/dev/null
operator_lost s-1 >/dev/null
for rec in "$PEND"/*.json; do jq -c ".stamped_at = $(( $(date +%s) - 864000 )) | .staged_at = $(( $(date +%s) - 864000 ))" "$rec" >"$rec.new" && mv "$rec.new" "$rec"; done
OUT=$(operator s-2)
has "ten days on, another session still shows it" "$(ctx "$OUT")" "Days later?"

printf '== 2k. past the emission cap: shown once more with a plain note, then retired and logged (never silent)\n'
seed here
U record --question "Never confirmed?" --recommended "y" >/dev/null
operator_lost s-1 >/dev/null
for rec in "$PEND"/*.json; do jq -c '.emits = 5' "$rec" >"$rec.new" && mv "$rec.new" "$rec"; done
OUT=$(operator s-1)
has "the operator prompt shows it one last time" "$(ctx "$OUT")" "Never confirmed?"
has "with a plain note that it was never confirmed" "$(ctx "$OUT")" "emitted 5 times and the transcript never confirmed them"
check "then the record is retired" "$(npend)" 0
has "and the last emission is logged" "$(cat "$HOME/.claude/unattended/delivery.log" 2>/dev/null)" "last emission of a pending list after 5 unconfirmed emissions"

printf '== 2l. a record that cannot be read is kept and logged, never deleted\n'
seed here
U record --question "Unreadable record?" --recommended "y" >/dev/null
operator_lost s-1 >/dev/null
REC1=$(ls "$PEND"/*.json | head -1)
printf '{not json' >"$REC1"
operator s-1 >/dev/null
check "the unreadable record is still there" "$(npend)" 1
has "and the failure is logged" "$(cat "$HOME/.claude/unattended/delivery.log" 2>/dev/null)" "could not read pending record"
rm -f "$REC1"

printf '== 2m. invariant: once a question is marked listed, a record exists or delivery was confirmed (every path above)\n'
seed here
U record --question "Invariant A?" --recommended "y" >/dev/null
operator_killed s-1 >/dev/null
check "killed after the mark: marked and retained" "$(U pending)/$(npend)" "0/1"
operator s-1 >/dev/null
operator s-1 >/dev/null
check "confirmed by the transcript: marked and the record retired" "$(U pending)/$(npend)" "0/0"

# ============================================================================
printf '== 3. a failed return is reported, not swallowed\n'
seed here
U record --question "Behind a failed return?" --recommended "y" >/dev/null
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
has "the failure is recorded" "$(cat "$HOME/.claude/unattended/delivery.log" 2>/dev/null)" "presence.sh return exited 11"
OUT=$(operator s-1)
has "his next message retries the return and lists" "$(ctx "$OUT")" "Behind a failed return?"
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
