#!/usr/bin/env bash
# catalog: tests — Proves real state CAS, process recovery, and the two /subagent prompt gates against competing callers
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$root/.claude/scripts/tests/lib/skill-bash.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" REAL_PS="$(command -v ps)" TEST_UID="$(id -u)"
mkdir -p "$HOME/.claude" "$tmp/bin"
export PATH="$tmp/bin:$PATH"

# Stub only Claude process identity. Full snapshots contain real rows so the
# helper's check for its own PID remains exercised; add synthetic owner rows.
cat > "$tmp/bin/ps" <<'PS'
#!/usr/bin/env bash
set -eu
birth='Mon Nov  9 06:00:00 2026'
if [[ "$1" == -p && "$*" == *comm=* ]]; then
  if [[ "$2" == "$FAKE_OWNER" ]]; then
    printf '1 /fake/bin/claude\n'
  else
    printf '%s /bin/bash\n' "$FAKE_OWNER"
  fi
elif [[ "$1" == -p && "$2" == "$FAKE_OWNER" ]]; then
  printf '%s %s %s S\n' "$FAKE_OWNER" "$TEST_UID" "$birth"
elif [[ "$1" == -A ]]; then
  [[ "${FAKE_SNAPSHOT_UNKNOWN:-0}" != 1 ]] || exit 0
  "$REAL_PS" "$@"
  for pid in $FAKE_LIVE; do
    row_birth="$birth"
    if [[ "$pid" == "${FAKE_REUSED:-}" ]]; then row_birth='Mon Nov  9 07:00:00 2026'; fi
    printf '%s %s %s S\n' "$pid" "$TEST_UID" "$row_birth"
  done
else
  exec "$REAL_PS" "$@"
fi
PS
chmod +x "$tmp/bin/ps"

state="$root/.claude/scripts/session-state.sh"
helper="$root/.claude/scripts/prompt-reservation.sh"
owner1=90000001 owner2=90000002
export FAKE_LIVE="$owner1 $owner2"
pass=0
check() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s (expected %s; got %s)\n' "$label" "$expected" "$actual" >&2; exit 1
  fi
  pass=$((pass + 1)); printf 'ok — %s\n' "$label"
}
call() {
  local who="$1"; shift
  rc=0; out="$(FAKE_OWNER="$who" "$BASH" "$helper" "$@" 2>"$tmp/helper.err")" || rc=$?
}
read_slot() {
  "$state" --repo "$1" --get-json ".repos[\"$1\"].prompt_reservations[\"$2\"]" | jq -c .
}
call "$owner1" claim --repo Org/Prompt --kind leave
check 0 "$rc" 'first caller reserves repo leave menu'
token1="$out"
call "$owner1" verify --repo org/prompt --kind leave --generation "$token1"
check 0 "$rc" 'same live process and generation verify on a later command'
call "$owner1" claim --repo org/prompt --kind leave
check 10 "$rc" 'same process without its carried generation cannot reopen the prompt'
call "$owner2" claim --repo org/prompt --kind leave
check 10 "$rc" 'other caller sees occupied repo even with different repo capitalization'
check "" "$out" 'loser receives no generation'
call "$owner2" verify --repo org/prompt --kind leave --generation "$token1"
check 10 "$rc" 'a token does not authorize a different process'
call "$owner2" claim --repo org/other --kind leave
check 0 "$rc" 'a different repo has an independent leave slot'
call "$owner2" claim --repo org/prompt --kind overrun --issue 41
check 0 "$rc" 'overrun slot is independent of leave'
call "$owner1" claim --repo org/prompt --kind overrun --issue 42
check 0 "$rc" 'overrun slots are independent by issue'
view="$("$state" --repo org/prompt --session-view)"
check false "$(jq -r 'any(.. | objects; has("prompt_reservations"))' <<<"$view")" 'default session view hides reservation details'

run_racer() {
  local code=0
  FAKE_OWNER="$1" "$BASH" "$helper" claim --repo org/race --kind leave >"$tmp/token.$1" 2>"$tmp/race.$1.err" || code=$?
  printf '%s\n' "$code" >"$tmp/code.$1"
}
run_racer "$owner1" & first=$!
run_racer "$owner2" & second=$!
wait "$first"; wait "$second"
check '0 10 ' "$(sort -n "$tmp/code.$owner1" "$tmp/code.$owner2" | tr '\n' ' ')" 'concurrent real CAS produces exactly one winner'
if [[ "$(cat "$tmp/code.$owner1")" == 0 ]]; then race_token_file="$tmp/token.$owner1"; else race_token_file="$tmp/token.$owner2"; fi
check "$(cat "$race_token_file")" "$(read_slot org/race leave | jq -r .generation)" 'CAS stores only the winning generation'

saved="$(read_slot org/prompt leave)"
FAKE_LIVE="$owner2" FAKE_SNAPSHOT_UNKNOWN=1 call "$owner2" claim --repo org/prompt --kind leave
check 10 "$rc" 'unverifiable process snapshot retains the reservation'
check "$saved" "$(read_slot org/prompt leave)" 'unknown owner does not modify state'
slot_path='.repos["org/prompt"].prompt_reservations.leave'
damaged="$(jq -c '.owner.start="unverifiable"' <<<"$saved")"
"$state" --repo org/prompt --set "$slot_path=$damaged" >/dev/null
call "$owner2" claim --repo org/prompt --kind leave
check 20 "$rc" 'an invalid birth stamp is not proof that a live PID was reused'
check "$damaged" "$(read_slot org/prompt leave)" 'invalid birth stamp stays untouched'
"$state" --repo org/prompt --set "$slot_path=$saved" >/dev/null
FAKE_LIVE="$owner2" call "$owner2" claim --repo org/prompt --kind leave
check 0 "$rc" 'a provably dead owner is replaced on next attempt'
token2="$out"
call "$owner1" release --repo org/prompt --kind leave --generation "$token1"
check 10 "$rc" 'old generation cannot release replacement'
check "$token2" "$(read_slot org/prompt leave | jq -r .generation)" 'replacement remains durable'
call "$owner2" release --repo org/prompt --kind leave --generation "$token2"
check 0 "$rc" 'matching owner releases matching generation'
check null "$(read_slot org/prompt leave)" 'released slot is empty'

call "$owner1" claim --repo org/reuse --kind leave
check 0 "$rc" 'original process reserved before PID reuse'
FAKE_REUSED="$owner1" call "$owner2" claim --repo org/reuse --kind leave
check 0 "$rc" 'changed birth stamp proves PID reuse rather than a live prompt'
"$state" --repo org/prompt --set '.repos["org/prompt"].prompt_reservations.leave={"version":1}' >/dev/null
call "$owner2" claim --repo org/prompt --kind leave
check 20 "$rc" 'malformed reservation cannot authorize a prompt'
check '{"version":1}' "$(read_slot org/prompt leave)" 'malformed state remains untouched'

subagent="$root/.claude/skills/subagent/SKILL.md"
leaveby="$root/.claude/skills/leave-by/SKILL.md"
extract_skill_bash "$subagent" subagent-step7-leave-elicitation-gate > "$tmp/leave-read"
extract_skill_bash "$subagent" subagent-step7-leave-reservation > "$tmp/leave-reserve"
extract_skill_bash "$subagent" subagent-step7-overrun-decision > "$tmp/overrun-read"
extract_skill_bash "$subagent" subagent-step7-overrun-reservation > "$tmp/overrun-reserve"
extract_skill_bash "$subagent" subagent-step7-overrun-verify-reservation > "$tmp/overrun-verify"
extract_skill_bash "$leaveby" leave-by-elicit-verify-reservation > "$tmp/leave-verify"

leave_gate() (
  export FAKE_OWNER="$1"
  REPO_KEY="$2"; ATTENDED="${3:-true}"
  SESSION_STATE_SH="$state"; PROMPT_RESERVE_SH="${4-$helper}"
  source "$tmp/leave-read"; source "$tmp/leave-reserve"
  printf '%s|%s|%s\n' "$ELICIT_LEAVE_TIME" "$LEAVE_PROMPT_PENDING" "$LEAVE_PROMPT_GENERATION"
)
result="$(leave_gate "$owner1" org/gates)"
check 'true|false' "${result%|*}" 'first attended launch opens the leave gate'
gate_token="${result##*|}"
check 'false|true|' "$(leave_gate "$owner2" org/gates)" 'loser queues without opening a second leave menu'
check 'false|true|' "$(leave_gate "$owner1" org/nohelper true '')" 'missing helper cannot authorize an attended prompt'
check 'false|false|' "$(leave_gate "$owner1" org/unattended false '')" 'unattended path stays silent and does not reserve'
leave_verify() (
  export FAKE_OWNER="$1"
  REPO_KEY=org/gates PROMPT_RESERVE_SH="$helper" LEAVE_PROMPT_GENERATION="$gate_token"
  source "$tmp/leave-verify"
  printf '%s\n' "$ELICIT_RESERVATION_VERIFIED"
)
check true "$(leave_verify "$owner1")" 'nested leave menu verifies the original owner generation'
check false "$(leave_verify "$owner2")" 'nested leave menu rejects another process'
deadline=$(( $(date -u +%s) + 1200 ))
"$state" --repo org/gates --set ".repos[\"org/gates\"].window.deadline_epoch=$deadline" >/dev/null
check 'false|false|' "$(leave_gate "$owner2" org/gates)" 'later attempt adopts the published leave result'

# Force the first read to precede publication but the acquisition to follow it.
# A stale pre-check must not open a menu even when acquisition itself succeeds.
cat > "$tmp/publish-then-reserve" <<'INTERLEAVE'
#!/usr/bin/env bash
set -e
if [[ "$1" == claim ]]; then
  "$GATE_STATE" --repo org/interleave --set ".repos[\"org/interleave\"].window.deadline_epoch=$GATE_DEADLINE" >/dev/null
fi
exec "$GATE_HELPER" "$@"
INTERLEAVE
chmod +x "$tmp/publish-then-reserve"
export GATE_STATE="$state" GATE_HELPER="$helper" GATE_DEADLINE="$deadline"
check 'false|false|' "$(leave_gate "$owner1" org/interleave true "$tmp/publish-then-reserve")" 'winner rechecks after acquisition and skips a just-answered question'
check null "$(read_slot org/interleave leave)" 'unused winning generation was released'

overrun_gate() (
  export FAKE_OWNER="$1"
  REPO_KEY=org/gates; ISSUE_NUM="$2"; ATTENDED=true; DEADLINE_EPOCH="$deadline"
  LAUNCH_DECLINED=true; DECLINE_REASON='plan on 360'
  SESSION_STATE_SH="$state"; PROMPT_RESERVE_SH="$helper"
  source "$tmp/overrun-read"; source "$tmp/overrun-reserve"
  printf '%s|%s|%s\n' "$OVERRUN_ASK" "$LAUNCH_DECLINED" "$OVERRUN_PROMPT_GENERATION"
)
result="$(overrun_gate "$owner1" 88)"
check 'true|true' "${result%|*}" 'first caller opens this issue overrun menu'
overrun_token="${result##*|}"
overrun_verify() (
  export FAKE_OWNER="$1"
  REPO_KEY=org/gates ISSUE_NUM=88 OVERRUN_ASK=true DEADLINE_EPOCH="$deadline"
  SESSION_STATE_SH="$state" PROMPT_RESERVE_SH="$helper" OVERRUN_PROMPT_GENERATION="$overrun_token"
  source "$tmp/overrun-verify"
  printf '%s\n' "$OVERRUN_RESERVATION_VERIFIED"
)
check true "$(overrun_verify "$owner1")" 'winner proves the overrun generation before using the answer'
check false "$(overrun_verify "$owner2")" 'another session cannot use that overrun answer'
deadline_path='.repos["org/gates"].window.deadline_epoch'
"$state" --repo org/gates --set "$deadline_path=$((deadline + 60))" >/dev/null
check false "$(overrun_verify "$owner1")" 'answer for a superseded deadline cannot authorize a launch'
"$state" --repo org/gates --set "$deadline_path=$deadline" >/dev/null
check 'false|true|' "$(overrun_gate "$owner2" 88)" 'second caller keeps this issue declined without a duplicate menu'
result="$(overrun_gate "$owner2" 89)"
check 'true|true' "${result%|*}" 'a distinct issue can ask its own overrun question'
"$state" --repo org/gates --set ".repos[\"org/gates\"].window.launch_decisions[\"88\"]={\"decision\":\"launch_anyway\",\"deadline_epoch\":$deadline}" >/dev/null
check 'false|false|' "$(overrun_gate "$owner2" 88)" 'later caller honors the published matching decision without asking'

printf '\nPrompt reservation: %s assertions passed\n' "$pass"
