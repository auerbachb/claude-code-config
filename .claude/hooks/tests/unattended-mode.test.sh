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
#   AC3  the operator's next message lists the recorded questions once, each
#        with its recommended option and what was done; the next message does
#        not list them again; an automated prompt lists them only once the
#        window has ended
#   script  on/off/status/is-active/window-ended, record ids, update, digest
#        --mark watermark, per-repo files, usage errors
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
unset CLAUDE_SESSION_REPO UNATTENDED_DIR

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
prompt_payload() { # CWD PROMPT
  jq -cn --arg cwd "$1" --arg p "$2" '{session_id: "s-1", cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: $p}'
}

# ---------------------------------------------------------------- registration
printf '== registration\n'
REG=$(jq -r '[.hooks | to_entries[] | .key as $e | .value[] | (.matcher // "") as $m | .hooks[]
  | select(.command | test("/unattended-")) | "\($e) \($m) \(.command | split("/") | last)"] | sort | join(";")' "$SETTINGS")
check "both hooks registered once" "$REG" \
  "PreToolUse AskUserQuestion unattended-question-guard.sh;UserPromptSubmit  unattended-digest.sh"
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
OUT=$(prompt_payload "$REPO_A" "hello" | "$DIGEST"; echo "rc=$?")
check "digest hook: nothing to list" "$OUT" "rc=0"

# ---------------------------------------------------------------- usage
printf '== usage\n'
U bogus >/dev/null 2>&1; check "unknown subcommand exits 2" "$?" "2"
U on --for 3x >/dev/null 2>&1; check "bad --for exits 2" "$?" "2"
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
has "guard: and says to record it" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "unattended.sh record"

# ---------------------------------------------------------------- script
printf '== record / update / per repo\n'
ID=$(U record --question "Rename the job?" --recommended "keep the name" --did "kept the name")
check "agent record gets the next id" "$ID" "U-3"
U update U-2 --did "parked the merge" ; check "update exits 0" "$?" "0"
IDB=$( (cd "$REPO_B" && "$SCRIPT" record --question "B?" ) )
check "another repo has its own ids" "$IDB" "U-1"
check "pending in repo A" "$(U pending)" "3"

# ---------------------------------------------------------------- AC3: listed once
printf '== AC3: listed once on the operator'"'"'s next message\n'
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
check "now nothing pending" "$(U pending)" "0"
OUT=$(prompt_payload "$REPO_A" "and now?" | "$DIGEST")
check "the next operator prompt lists nothing again" "$OUT" ""

printf '== window end\n'
U record --question "Late question?" --recommended "yes" >/dev/null
OUT=$(prompt_payload "$REPO_A" "<ci-monitor-event>tick</ci-monitor-event>" | "$DIGEST")
check "automated prompt before the end: nothing" "$OUT" ""
# End the window: rewrite the flag through session-state.sh, as `on` does.
"$REPO_ROOT/.claude/scripts/session-state.sh" --set ".unattended.until_epoch=$(( $(date +%s) - 1 ))" >/dev/null
check "is-active after the end" "$(U is-active; echo $?)" "1"
check "window-ended after the end" "$(U window-ended; echo $?)" "0"
OUT=$(ask_payload "$REPO_A" | "$GUARD")
check "guard after the end: menu renders" "$OUT" ""
OUT=$(prompt_payload "$REPO_A" "<ci-monitor-event>window over</ci-monitor-event>" | "$DIGEST")
has "automated prompt after the end lists them" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')" "Late question?"

printf '== off\n'
U on --for 1h >/dev/null
U record --question "Q at off?" >/dev/null
OFF=$(U off)
has "off: switches off" "$OFF" "unattended: off"
has "off: prints the digest" "$OFF" "Q at off?"
check "off: marks it listed" "$(U pending)" "0"
check "status after off" "$(U status)" "inactive"

printf '\nunattended-mode.test.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
