#!/usr/bin/env bash
# Tests for unattended mode (issue #2283): .claude/scripts/unattended.sh,
# .claude/hooks/unattended-question-guard.sh (PreToolUse AskUserQuestion) and
# .claude/hooks/unattended-digest.sh (UserPromptSubmit).
#
# Every run uses a throwaway HOME; the live ~/.claude is never touched.
#
# Asserts:
#   AC1  unattended on: an AskUserQuestion call is denied (no menu opens), its
#        questions are recorded with the first option as the recommended one,
#        and the reason names the receipt and says to keep working; off or
#        expired: the hook prints nothing and the menu renders as before
#   AC3  the operator's next message lists the recorded questions, each
#        with its recommended option and what was done; an automated prompt
#        lists them only once the window has ended
#   issue #2352  a question is listed until it is answered or dismissed and
#        listing never hides it; a session sees a question in full once per
#        return and then as one summary line; a hook killed at any point
#        before it emits loses nothing; every question can be listed whatever
#        was shown
#   script  on/off/status/is-active/window-ended, record ids, update, digest,
#        answer/dismiss/list, per-repo files, usage errors
#   registration  global-settings.json carries both hooks once
set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/unattended.sh"
GUARD="$REPO_ROOT/.claude/hooks/unattended-question-guard.sh"
DIGEST="$REPO_ROOT/.claude/hooks/unattended-digest.sh"
SETTINGS="$REPO_ROOT/global-settings.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: unattended-mode.test.sh — jq is not installed"
  exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   — %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL — %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1 (found '$3')" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/unattended-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
unset CLAUDE_SESSION_REPO UNATTENDED_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

# A git repo whose origin names owner/name, so the repo key resolves.
REPO_A="$TMP/repo-a"
git init -q "$REPO_A"
git -C "$REPO_A" remote add origin https://github.com/acme/widgets.git
REPO_B="$TMP/repo-b"
git init -q "$REPO_B"
git -C "$REPO_B" remote add origin https://github.com/acme/gadgets.git

U() { (cd "$REPO_A" && "$SCRIPT" "$@"); }

ask_payload() { # CWD
  jq -cn --arg cwd "$1" '{session_id: "s-1", cwd: $cwd, hook_event_name: "PreToolUse",
    tool_name: "AskUserQuestion",
    tool_input: {questions: [
      {question: "Which SMS provider should item F use?", header: "SMS",
       options: [{label: "Twilio (Recommended)", description: "existing adapter"},
                 {label: "Amazon", description: "AWS"}], multiSelect: false},
      {question: "Merge now?", header: "Merge", options: [], multiSelect: false}]}}'
}
session_payload() { # CWD
  jq -cn --arg cwd "$1" '{session_id: "s-1", cwd: $cwd, hook_event_name: "PreToolUse",
    tool_name: "mcp__ccd_session__start_session", tool_input: {title: "item F", initiation: "own_initiative"}}'
}
prompt_payload() { # CWD PROMPT
  jq -cn --arg cwd "$1" --arg p "$2" '{session_id: "s-1", cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: $p}'
}

# ---------------------------------------------------------------- registration
printf '== registration\n'
REG=$(jq -r '[.hooks | to_entries[] | .key as $e | .value[] | (.matcher // "") as $m | .hooks[]
  | select(.command | test("/unattended-")) | "\($e) \($m) \(.command | split("/") | last)"] | sort | join(";")' "$SETTINGS")
check "both hooks registered once" "$REG" \
  "PreToolUse AskUserQuestion|mcp__ccd_session__start_session unattended-question-guard.sh;UserPromptSubmit  unattended-digest.sh"
for f in "$SCRIPT" "$GUARD" "$DIGEST"; do
  if [ -x "$f" ]; then ok "$(basename "$f") is executable"; else bad "$(basename "$f") is not executable"; fi
  if bash -n "$f"; then ok "$(basename "$f") parses"; else bad "$(basename "$f") does not parse"; fi
done

# ---------------------------------------------------------------- attended
printf '== attended (mode off)\n'
check "is-active: off" "$(U is-active; echo $?)" "1"
check "status: inactive" "$(U status)" "inactive"
OUT=$(ask_payload "$REPO_A" | "$GUARD"; echo "rc=$?")
check "guard: prints nothing, menu renders" "$OUT" "rc=0"
check "guard: nothing recorded" "$(ls "$HOME/.claude/unattended" 2>/dev/null | wc -l | tr -d ' ')" "0"
OUT=$(session_payload "$REPO_A" | "$GUARD"; echo "rc=$?")
check "guard: start_session runs when attended" "$OUT" "rc=0"
OUT=$(prompt_payload "$REPO_A" "hello" | "$DIGEST"; echo "rc=$?")
check "digest hook: nothing to list" "$OUT" "rc=0"

# ---------------------------------------------------------------- usage
printf '== usage\n'
U bogus >/dev/null 2>&1; check "unknown subcommand exits 2" "$?" "2"
U on --for 3x >/dev/null 2>&1; check "bad --for exits 2" "$?" "2"
U on --for 1+2h >/dev/null 2>&1; check "an arithmetic --for exits 2" "$?" "2"
U record >/dev/null 2>&1; check "record without --question exits 2" "$?" "2"
U on --until-epoch 5 >/dev/null 2>&1; check "a window end in the past exits 2" "$?" "2"

# ---------------------------------------------------------------- AC1: no menu
printf '== AC1: unattended, AskUserQuestion is denied and recorded\n'
ON=$(U on --for 2h)
has "on: names the window" "$ON" "unattended: on until"
has "on: prints the pre-leave check" "$ON" "confirm none is waiting on the user"
has "on: prints the window-end watch" "$ON" "persistent Monitor"
check "is-active: on" "$(U is-active; echo $?)" "0"
OUT=$(ask_payload "$REPO_A" | "$GUARD")
check "guard: denies the call (no AskUserQuestion runs)" \
  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
REASON=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
has "reason: names both ids" "$REASON" "U-1, U-2"
has "reason: the exact receipt" "$REASON" "questions U-1, U-2 recorded for the operator's return"
has "reason: the recommended option" "$REASON" "U-1: Twilio (Recommended)"
has "reason: keep working" "$REASON" "keep working"
QF="$HOME/.claude/unattended/acme__widgets.jsonl"
check "recorded in the repo's file" "$(jq -s '[.[] | select(.type == "question")] | length' "$QF")" "2"
check "recommended = first option" "$(jq -rs '.[0].recommended' "$QF")" "Twilio (Recommended)"
check "options kept" "$(jq -rs '.[0].options | join("|")' "$QF")" "Twilio (Recommended)|Amazon"
check "no options: recommended null" "$(jq -rs '.[1].recommended' "$QF")" "null"
check "source hook" "$(jq -rs '.[0].source' "$QF")" "hook"

# A payload with no questions is still denied while unattended.
OUT=$(jq -cn --arg cwd "$REPO_A" '{cwd: $cwd, tool_input: {}}' | "$GUARD")
check "guard: an empty call is still denied" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
has "guard: and says to record it" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "unattended.sh' record"

# start_session can wait on the operator: denied, nothing recorded.
OUT=$(session_payload "$REPO_A" | "$GUARD")
check "guard: start_session is denied while unattended" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
has "guard: and says to use a sub-agent" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "sub-agent"
check "guard: start_session records no question" "$(jq -s '[.[] | select(.type == "question")] | length' "$QF")" "2"
has "reason: names the script by full path" "$REASON" "'$SCRIPT' update"
has "reason: asks for the background at once (issue #2592)" "$REASON" "update <id> --context"

# ---------------------------------------------------------------- script
printf '== record / update / per repo\n'
ID=$(U record --question "Rename the job?" --context "Test background: what this change is and why the operator is being asked" --recommended "keep the name" --did "kept the name")
check "agent record gets the next id" "$ID" "U-3"
U update U-2 --did "parked the merge" ; check "update exits 0" "$?" "0"
IDB=$( (cd "$REPO_B" && "$SCRIPT" record --question "B?" --context "Test background: what this change is and why the operator is being asked" ) )
check "another repo has its own ids" "$IDB" "U-1"
check "pending in repo A" "$(U pending)" "3"

# ---------------------------------------------------------------- AC3: listed on the next message
printf '== AC3: listed on the operator'"'"'s next message\n'
OUT=$(prompt_payload "$REPO_A" "<task-notification>agent done</task-notification>" | "$DIGEST")
check "automated prompt mid-window: nothing" "$OUT" ""
OUT=$(prompt_payload "$REPO_A" "  morning, what happened?" | "$DIGEST")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
check "operator prompt: UserPromptSubmit context" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "UserPromptSubmit"
has "lists the count" "$CTX" "Questions recorded while you were away (3)"
has "item 1 with its recommended option" "$CTX" "Recommended: Twilio (Recommended) (options: Twilio (Recommended) | Amazon)"
has "item 2 with what was done (update wins)" "$CTX" "Meanwhile: parked the merge"
has "item 3 with what was done" "$CTX" "Meanwhile: kept the name"
lacks "another repo's question is not listed" "$CTX" "B?"
check "listing hid nothing: still pending" "$(U pending)" "3"
OUT=$(prompt_payload "$REPO_A" "and now?" | "$DIGEST")
SCTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
has "the same session's next prompt gets a one-line summary with the count and ids" "$SCTX" "3 saved questions still unanswered (U-1, U-2, U-3)"
lacks "the summary is not the full list again" "$SCTX" "Recommended:"

printf '== window end\n'
U record --question "Late question?" --context "Test background: what this change is and why the operator is being asked" --recommended "yes" >/dev/null
OUT=$(prompt_payload "$REPO_A" "<ci-monitor-event>tick</ci-monitor-event>" | "$DIGEST")
check "automated prompt before the end: nothing" "$OUT" ""
# End the window: rewrite the flag through session-state.sh, as `on` does.
"$REPO_ROOT/.claude/scripts/session-state.sh" --set ".unattended.until_epoch=$(( $(date +%s) - 1 ))" >/dev/null
# Issue #2294: the end of an away window changes nothing for threads. They stay in away handling
# (the guard still denies, questions are still recorded) until the operator speaks.
check "is-active after the end: away handling continues" "$(U is-active; echo $?)" "0"
check "window-ended after the end" "$(U window-ended; echo $?)" "0"
check "status after the end says so" "$(U status | cut -c1-20)" "active (window ended"
OUT=$(ask_payload "$REPO_A" | "$GUARD")
check "guard after the end: still denies, no menu" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
GR=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
has "guard after the end: the winner also gets the away list" "$GR" "your away window ended"
has "guard after the end: list covers every repo" "$GR" "[acme/gadgets]"
OUT=$(prompt_payload "$REPO_A" "<ci-monitor-event>window over</ci-monitor-event>" | "$DIGEST")
check "automated prompt after the end: the notice was already claimed, nothing more" "$OUT" ""
OUT=$(prompt_payload "$REPO_A" "I'm back" | "$DIGEST")
RCTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
has "the operator's message returns him and lists what was saved since" "$RCTX" "U-5: Which SMS provider"
has "the return notice points him at /back" "$RCTX" "/back gives the whole return"
check "after the return: away handling has ended" "$(U is-active; echo $?)" "1"
OUT=$(ask_payload "$REPO_A" | "$GUARD")
check "after the return: the menu renders" "$OUT" ""

printf '== origin-less repos, failed writes\n'
NO_A="$TMP/no-origin-a"; NO_B="$TMP/no-origin-b"
git init -q "$NO_A"; git init -q "$NO_B"
(cd "$NO_A" && "$SCRIPT" record --question "A only?" --context "Test background: what this change is and why the operator is being asked" >/dev/null)
check "two repos without an origin do not share a file" "$( (cd "$NO_B" && "$SCRIPT" pending) )" "0"
check "the first still has its question" "$( (cd "$NO_A" && "$SCRIPT" pending) )" "1"
# A jq that dies after printing partial JSON: no receipt, nothing appended.
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
cat >"$FAKE/jq" <<'FAKEJQ'
#!/bin/sh
printf '{"type":"question"'
exit 137
FAKEJQ
chmod +x "$FAKE/jq"
BEFORE=$(wc -l <"$QF" | tr -d ' ')
OUT=$( (cd "$REPO_A" && PATH="$FAKE:$PATH" "$SCRIPT" record --question "Killed?" --context "Test background: what this change is and why the operator is being asked" 2>/dev/null); echo "rc=$?")
check "a killed jq prints no receipt" "$OUT" "rc=1"
check "and appends nothing" "$(wc -l <"$QF" | tr -d ' ')" "$BEFORE"

printf '== off\n'
U on --for 1h >/dev/null
U record --question "Q at off?" --context "Test background: what this change is and why the operator is being asked" >/dev/null
PEND_BEFORE_OFF=$(U pending)
OFF=$(U off)
has "off: switches off" "$OFF" "unattended: off"
has "off: prints the digest" "$OFF" "Q at off?"
check "off: marks nothing (the question is still unresolved)" "$(U pending)" "$PEND_BEFORE_OFF"
has "off: a later digest still lists it" "$(U digest)" "Q at off?"
check "status after off" "$(U status)" "inactive"

# ---------------------------------------------------------------- issue #2352
# Everything below runs in repos of its own so the ids above stay put.
printf '== issue #2352: listing never hides a question\n'
export TMPDIR="$TMP/tmpdir"; mkdir -p "$TMPDIR"
SESSION_STATE="$REPO_ROOT/.claude/scripts/session-state.sh"
UDIR="$HOME/.claude/unattended"
exists() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
REPO_C="$TMP/repo-c"; git init -q "$REPO_C"; git -C "$REPO_C" remote add origin https://github.com/acme/sprockets.git
UC() { (cd "$REPO_C" && "$SCRIPT" "$@"); }
QC="$UDIR/acme__sprockets.jsonl"
SEEN_C="$UDIR/seen/acme__sprockets"
sprompt() { # CWD SESSION_OR_EMPTY — the hook's additionalContext for an operator prompt
  jq -cn --arg cwd "$1" --arg sid "$2" '{cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: "what is waiting?"}
    + (if $sid == "" then {} else {session_id: $sid} end)' | "$DIGEST" | jq -r '.hookSpecificOutput.additionalContext // ""'
}
"$SCRIPT" on --for 6h >/dev/null
UC record --question "Pick the region?" --context "Test background: what this change is and why the operator is being asked" --recommended "us-east" >/dev/null
UC record --question "Rename the table?" --context "Test background: what this change is and why the operator is being asked" --recommended "keep" >/dev/null
BEFORE=$(wc -l <"$QC" | tr -d ' ')
D1=$(UC digest); D2=$(UC digest --mark)
has "digest lists both" "$D1" "U-2: Rename the table?"
check "digest --mark (deprecated) prints the same" "$D2" "$D1"
check "a digest appends nothing to the questions file" "$(wc -l <"$QC" | tr -d ' ')" "$BEFORE"
check "and writes no listed record" "$(grep -c '"type":"listed"' "$QC")" "0"

C1=$(sprompt "$REPO_C" s-c1)
has "first prompt: full list, question 1" "$C1" "U-1: Pick the region?"
has "first prompt: full list, question 2" "$C1" "U-2: Rename the table?"
RKEY=$(jq -r '.unattended.since_epoch' "$HOME/.claude/session-state.json")
check "the session's shown record holds both ids under the return key" \
  "$(jq -r '[.key, (.ids | join(","))] | join("|")' "$SEEN_C/s-c1.json")" "$RKEY|U-1,U-2"
C2=$(sprompt "$REPO_C" s-c1)
has "same session: one summary line with the count and both ids" "$C2" "2 saved questions still unanswered (U-1, U-2), listed in full earlier this session"
lacks "same session: no second full listing" "$C2" "Recommended:"
check "still pending after being shown twice" "$(UC pending)" "2"

UC record --question "Third thing?" --context "Test background: what this change is and why the operator is being asked" --recommended "yes" >/dev/null
C3=$(sprompt "$REPO_C" s-c1)
has "a question saved after the first listing appears in full" "$C3" "U-3: Third thing?"
has "and the header counts only the new one" "$C3" "Questions recorded while you were away (1)"
has "the older two are one summary line" "$C3" "2 saved questions still unanswered (U-1, U-2)"
lacks "the older two are not repeated in full" "$C3" "Pick the region?"
C4=$(sprompt "$REPO_C" s-c2)
has "a new session gets the full list (1)" "$C4" "U-1: Pick the region?"
has "a new session gets the full list (3)" "$C4" "U-3: Third thing?"

"$SESSION_STATE" --set ".unattended.since_epoch=424242" >/dev/null
C5=$(sprompt "$REPO_C" s-c1)
has "a new return lists everything in full again, same session" "$C5" "U-2: Rename the table?"
check "and the session record now carries the new return key" "$(jq -r .key "$SEEN_C/s-c1.json")" "424242"

N_SEEN=$(ls "$SEEN_C" | wc -l | tr -d ' ')
N1=$(sprompt "$REPO_C" ""); N2=$(sprompt "$REPO_C" "")
has "no session id: full list" "$N1" "U-2: Rename the table?"
has "no session id: full list again, never a summary" "$N2" "U-2: Rename the table?"
B1=$(sprompt "$REPO_C" "../escape")
has "an unusable session id: full list" "$B1" "U-1: Pick the region?"
check "no session id and a bad one write no record" "$(ls "$SEEN_C" | wc -l | tr -d ' ')" "$N_SEEN"
check "nothing escaped the seen directory" "$(find "$HOME/.claude" -name "*escape*" | wc -l | tr -d " ")" "0"
E1=$(jq -cn --arg cwd "$REPO_C" '{cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: "hi"}' | CLAUDE_CODE_SESSION_ID=s-env "$DIGEST" | jq -r '.hookSpecificOutput.additionalContext')
has "the session id may come from the environment" "$E1" "U-1: Pick the region?"
check "and is recorded under that id" "$(exists "$SEEN_C/s-env.json")" present

printf '== issue #2352: answering and dismissing are the only things that remove a question\n'
BEFORE=$(wc -l <"$QC" | tr -d ' ')
UC answer U-99 --answer x >/dev/null 2>&1; check "answer: an unknown id fails" "$?" "1"
UC answer U-1x --answer x >/dev/null 2>&1; check "answer: a malformed id is a usage error" "$?" "2"
UC answer U-1 >/dev/null 2>&1; check "answer without --answer is a usage error" "$?" "2"
check "failed answers append nothing" "$(wc -l <"$QC" | tr -d ' ')" "$BEFORE"
check "answer prints a receipt" "$(UC answer U-1 --answer 'us-west' --by operator)" "U-1 answered"
check "answered record: id|answer|by|at" "$(jq -rs '[.[] | select(.type == "answered")][0] | [.id, .answer, .by, (.at | type)] | join("|")' "$QC")" "U-1|us-west|operator|number"
UC answer U-1 --answer again >/dev/null 2>&1; check "answer: an already-resolved id fails" "$?" "1"
check "and appends nothing" "$(jq -s '[.[] | select(.type == "answered")] | length' "$QC")" "1"
check "pending counts the unresolved ones" "$(UC pending)" "2"
R1=$(sprompt "$REPO_C" s-c9)
lacks "answered: no longer listed" "$R1" "Pick the region?"
has "the other is still listed" "$R1" "U-2: Rename the table?"

BEFORE=$(wc -l <"$QC" | tr -d ' ')
UC dismiss U-2 U-99 >/dev/null 2>&1; check "dismiss: one bad id in the set fails" "$?" "1"
check "and nothing is written, not even the good id" "$(wc -l <"$QC" | tr -d ' ')" "$BEFORE"
check "dismiss: the same id twice is one act" "$(UC dismiss U-2 U-2 --reason 'moot')" "U-2 dismissed"
check "dismissed record: id|reason|by" "$(jq -rs '[.[] | select(.type == "dismissed")][0] | [.id, .reason, .by] | join("|")' "$QC")" "U-2|moot|operator"
UC dismiss U-2 >/dev/null 2>&1; check "dismiss: an already-dismissed id fails" "$?" "1"
check "dismiss another id" "$(UC dismiss U-3 --reason 'stale' | tr '\n' ' ')" "U-3 dismissed "
check "all resolved: pending 0" "$(UC pending)" "0"
check "all resolved: the hook lists nothing" "$(sprompt "$REPO_C" s-c10)" ""
check "all resolved: digest prints nothing" "$(UC digest)" ""
UC record --question "Fourth?" --context "Test background: what this change is and why the operator is being asked" >/dev/null
UC record --question "Fifth?" --context "Test background: what this change is and why the operator is being asked" >/dev/null
check "dismiss several ids in one act" "$(UC dismiss U-4 U-5 --reason 'bulk' | tr '\n' ' ')" "U-4 dismissed U-5 dismissed "
check "and both are recorded" "$(jq -s '[.[] | select(.type == "dismissed" and .reason == "bulk")] | length' "$QC")" "2"

LA=$(UC list)
has "list: still shows the answered one with its answer" "$LA" "U-1 [answered]: Pick the region?"
has "list: its answer" "$LA" "Answer: us-west"
has "list: the dismissed one with its reason" "$LA" "Dismissed: moot"
has "list --all: spans repos and labels them" "$(UC list --all)" "[acme/sprockets] Recorded questions (5):"
has "list --all: includes another repo's questions" "$(UC list --all)" "[acme/widgets]"
LJ=$(UC list --json)
check "list --json: one array of every question" "$(printf '%s' "$LJ" | jq -r 'length')" "5"
check "list --json: status and repo per question" "$(printf '%s' "$LJ" | jq -r '.[0] | [.id, .status, .repo] | join("|")')" "U-1|answered|acme/sprockets"
check "list --all --json: spans repos" "$(UC list --all --json | jq -r '[.[].repo] | unique | (index("acme/widgets") != null and index("acme/sprockets") != null)')" "true"

printf '== issue #2352: records written before this change\n'
REPO_D="$TMP/repo-d"; git init -q "$REPO_D"; git -C "$REPO_D" remote add origin https://github.com/acme/legacy.git
(cd "$REPO_D" && "$SCRIPT" record --question "Old one?" --context "Test background: what this change is and why the operator is being asked" >/dev/null && "$SCRIPT" record --question "Old two?" --context "Test background: what this change is and why the operator is being asked" >/dev/null)
printf '%s\n' '{"type":"listed","through":2,"at":1}' >>"$UDIR/acme__legacy.jsonl"
check "an old listed watermark hides nothing: pending" "$( (cd "$REPO_D" && "$SCRIPT" pending) )" "2"
has "and both are listed" "$( (cd "$REPO_D" && "$SCRIPT" digest) )" "U-2: Old two?"
(cd "$REPO_D" && "$SCRIPT" dismiss U-1 U-2 >/dev/null)
check "dismiss clears the old ones" "$( (cd "$REPO_D" && "$SCRIPT" pending) )" "0"

printf '== issue #2352: a hook killed at any point before it emits loses nothing\n'
REPO_K="$TMP/repo-k"; git init -q "$REPO_K"; git -C "$REPO_K" remote add origin https://github.com/acme/killme.git
UK() { (cd "$REPO_K" && "$SCRIPT" "$@"); }
UK record --question "Kill A?" --context "Test background: what this change is and why the operator is being asked" --recommended "a" >/dev/null
UK record --question "Kill B?" --context "Test background: what this change is and why the operator is being asked" --recommended "b" >/dev/null
SEEN_K="$UDIR/seen/acme__killme"
REAL_JQ=$(command -v jq); REAL_SCRIPT="$SCRIPT"
export REAL_JQ REAL_SCRIPT KPID="$TMP/hook.pid" KMARK="$TMP/kill.marks"
mkdir -p "$TMP/killjq"
cat >"$TMP/killjq/jq" <<'SHIM'
#!/bin/sh
# Kills the hook when it builds its output JSON: after the digest was read, before anything is printed.
for a in "$@"; do
  case "$a" in *hookSpecificOutput*)
    if [ -n "${KILL_AT_OUTPUT:-}" ]; then echo output >>"$KMARK"; kill -9 "$(cat "$KPID")"; sleep 1; exit 137; fi ;;
  esac
done
exec "$REAL_JQ" "$@"
SHIM
cat >"$TMP/kill-unattended.sh" <<'SHIM'
#!/bin/sh
# Wraps unattended.sh for the hook: kills the hook right after `digest` has read the questions (before
# the hook emits), or when it is about to record what was shown (after the hook emitted).
case "$1" in
  digest) if [ -n "${KILL_AT_DIGEST:-}" ]; then "$REAL_SCRIPT" "$@" >/dev/null 2>&1; echo digest >>"$KMARK"; kill -9 "$(cat "$KPID")"; sleep 1; exit 137; fi ;;
  seen) if [ -n "${KILL_AT_SEEN:-}" ]; then echo seen >>"$KMARK"; kill -9 "$(cat "$KPID")"; sleep 1; exit 137; fi ;;
esac
exec "$REAL_SCRIPT" "$@"
SHIM
chmod +x "$TMP/killjq/jq" "$TMP/kill-unattended.sh"
# hook_run SESSION [KILLVAR]: the hook's stdout. The hook is exec'd by a shell that wrote its pid, so
# the shims can SIGKILL it for real.
hook_run() {
  local sid="$1" kv="${2:-}"
  : >"$KMARK"
  jq -cn --arg cwd "$REPO_K" --arg sid "$sid" '{cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: "back"}
    + (if $sid == "" then {} else {session_id: $sid} end)' |
    env ${kv:+"$kv=1"} UNATTENDED_SH="$TMP/kill-unattended.sh" PATH="$TMP/killjq:$PATH" \
      bash -c 'echo $$ >"$KPID"; exec "$0"' "$DIGEST"
}
ctx_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
both_in_full() { # LABEL OUTPUT
  local c; c=$(ctx_of "$2")
  has "$1: question A in full" "$c" "U-1: Kill A?"
  has "$1: question B in full" "$c" "U-2: Kill B?"
  has "$1: with its recommended option" "$c" "Recommended: b"
}

OUT=$(hook_run s-k KILL_AT_DIGEST)
check "killed between reading and emitting: nothing was printed" "$OUT" ""
has "(the kill really fired)" "$(cat "$KMARK")" "digest"
check "killed after the read: no shown record" "$(exists "$SEEN_K")" absent
both_in_full "after a kill during the read, the next prompt" "$(hook_run s-k)"
rm -rf "$SEEN_K"

OUT=$(hook_run s-k KILL_AT_OUTPUT)
check "killed while building the output: nothing was printed" "$OUT" ""
has "(that kill really fired)" "$(cat "$KMARK")" "output"
check "killed while building the output: no shown record" "$(exists "$SEEN_K")" absent
both_in_full "after a kill during output construction, the next prompt" "$(hook_run s-k)"
rm -rf "$SEEN_K"

OUT=$(hook_run s-k3 KILL_AT_SEEN)
both_in_full "killed after emitting, before recording what was shown: that prompt" "$OUT"
check "that kill left no shown record" "$(exists "$SEEN_K/s-k3.json")" absent
both_in_full "and the next prompt repeats the full list (a repeat, never a loss)" "$(hook_run s-k3)"
rm -rf "$SEEN_K"

# PR #2328's two residual paths: a kill at the fifth unconfirmed emission, and a kill before
# emission with no transcript path. The payloads here never carry a transcript_path.
for i in 1 2 3 4; do
  OUT=$(hook_run s-k5 KILL_AT_SEEN)
  both_in_full "emission $i (recorded nowhere)" "$OUT"
done
OUT=$(hook_run s-k5 KILL_AT_OUTPUT)
check "the fifth is killed before emission" "$OUT" ""
both_in_full "the sixth prompt still lists both questions in full" "$(hook_run s-k5)"
check "no pending-delivery directory exists" "$(exists "$UDIR/pending")" absent
check "no delivery log exists" "$(exists "$UDIR/delivery.log")" absent
rm -rf "$SEEN_K"
OUT=$(hook_run s-k6 KILL_AT_OUTPUT)
check "no transcript path, with a session id: killed before emission, nothing printed" "$OUT" ""
both_in_full "no transcript path, with a session id: the next prompt" "$(hook_run s-k6)"
OUT=$(hook_run "" KILL_AT_OUTPUT)
check "no transcript path, no session id: killed before emission, nothing printed" "$OUT" ""
both_in_full "no transcript path, no session id: the next prompt" "$(hook_run "")"
both_in_full "no session id: and every prompt after it" "$(hook_run "")"
check "and the questions file is untouched by all of it" "$(grep -c '"type":"question"' "$UDIR/acme__killme.jsonl")" "2"
check "...with no other record type added" "$(jq -s '[.[] | select(.type != "question")] | length' "$UDIR/acme__killme.jsonl")" "0"

printf '== issue #2352: answer text that looks like a global option is kept verbatim\n'
UC record --question "Option-looking answer?" --context "Test background: what this change is and why the operator is being asked" --recommended "x" >/dev/null
OPTQ=$(UC pending >/dev/null; jq -rs '[.[] | select(.type == "question")] | last | .id' "$QC")
check "answer text starting with --repo is kept" "$(UC answer "$OPTQ" --answer '--repo oops' --by operator)" "$OPTQ answered"
check "...and stored as the answer, not read as a global option" "$(jq -rs --arg i "$OPTQ" '[.[] | select(.type == "answered" and .id == $i)][0].answer' "$QC")" "--repo oops"

# ---------------------------------------------------------------- issue #2592: background at the source
printf '== issue #2592: --context\n'
REPO_X="$TMP/repo-ctx"; mkdir -p "$REPO_X"; (cd "$REPO_X" && git init -q && git remote add origin https://github.com/acme/ctx.git)
UX() { (cd "$REPO_X" && "$SCRIPT" "$@"); }
UX record --question "No background?" >/dev/null 2>&1; check "agent record without --context: usage error" "$?" "2"
UX record --question "Thin?" --context "PR #12" >/dev/null 2>&1; check "context that is only a ref: usage error" "$?" "2"
CX=$(UX record --question "Merge PR #12?" --context "PR #12 changes how the nightly lead import treats salespeople, and merging it starts refusing whole files")
check "agent record with context gets an id" "$CX" "U-1"
check "context stored" "$(UX list --json | jq -r '.[0].context')" "PR #12 changes how the nightly lead import treats salespeople, and merging it starts refusing whole files"
HX=$(UX record --source hook --question "Captured menu?")
check "hook record may arrive without context" "$HX" "U-2"
has "missing context is flagged in the digest" "$(UX digest)" "Context: missing: recorded without background"
UX update "$HX" --context "The menu asked whether to keep the old job name, which three dashboards still link to by name" >/dev/null
check "update --context fills it in" "$(UX list --json | jq -r --arg i "$HX" '.[] | select(.id == $i) | .context')" "The menu asked whether to keep the old job name, which three dashboards still link to by name"
UX update "$HX" --did "kept the name" >/dev/null
check "a later --did update keeps the context" "$(UX list --json | jq -r --arg i "$HX" '.[] | select(.id == $i) | "\(.did)|\(.context | length > 0)"')" "kept the name|true"
check "eight words with a one-letter word count" "$(UX update "$HX" --context "This change adds a retry for failed imports" >/dev/null 2>&1; echo $?)" "0"
UX update "$HX" --context "issue #1 issue #2 issue #3 issue #4 issue #5 issue #6 issue #7 issue #8" >/dev/null 2>&1; check "lowercase refs only: usage error" "$?" "2"
UX update "$HX" --context "https://github.com/acme/widgets/pull/12 https://github.com/acme/widgets/issues/34" >/dev/null 2>&1; check "URLs only: usage error" "$?" "2"
UX update "$HX" --context "acme/widgets#12 acme/widgets#13 acme/widgets#14 acme/widgets#15" >/dev/null 2>&1; check "owner/repo#N refs only: usage error" "$?" "2"
UX update "$HX" --context "too thin" >/dev/null 2>&1; check "update with thin context: usage error" "$?" "2"
UX update "$HX" >/dev/null 2>&1; check "update with neither field: usage error" "$?" "2"

printf '\nunattended-mode.test.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
