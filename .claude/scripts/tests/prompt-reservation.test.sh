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

# Keep the visible PID and coarse ps time fixed while replacing its native stamp.
cat > "$tmp/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
[[ "${1##*/}" == prompt_process_stamp.py ]] || exit 1
case "$2" in
  90000001)
    if [[ -n "${CHANGING_STAMP_MARKER:-}" ]]; then
      if [[ -e "$CHANGING_STAMP_MARKER" ]]; then
        printf '%s\n' 'darwin-bsd:1794204000:000002'
      else
        : > "$CHANGING_STAMP_MARKER"
        printf '%s\n' 'darwin-bsd:1794204000:000001'
      fi
    else
      [[ -n "${PRECISE_STAMP:-}" ]] && printf '%s\n' "$PRECISE_STAMP"
    fi
    ;;
  90000002) printf '%s\n' 'darwin-bsd:1794204000:000003' ;;
  *) exit 1 ;;
esac
PYTHON
chmod +x "$tmp/bin/python3"
PRECISE_STAMP='darwin-bsd:1794204000:000001' call "$owner1" claim --repo org/precise --kind leave
check 0 "$rc" 'an available native process stamp is saved'
original_generation="$out"
check 'darwin-bsd:1794204000:000001' "$(read_slot org/precise leave | jq -r .process_stamp)" 'stored finer process evidence'
for stamp in '' 'invalid' 'darwin-bsd:1794204000:000001' 'darwin-bsd:1794204001:000001' 'linux-stat:11111111-1111-1111-1111-111111111111:1'; do
  PRECISE_STAMP="$stamp" call "$owner2" claim --repo org/precise --kind leave
  check 10 "$rc" 'missing, invalid, equal, or incompatible stamps retain the owner'
done
PRECISE_STAMP='darwin-bsd:1794204000:000002' call "$owner2" claim --repo org/precise --kind leave
check 0 "$rc" 'different native stamp proves same-second PID reuse'
new_generation="$out"
call "$owner1" release --repo org/precise --kind leave --generation "$original_generation"
check 10 "$rc" 'stale generation cannot clear the finer-stamp replacement'
check "$new_generation" "$(read_slot org/precise leave | jq -r .generation)" 'new reservation survives stale release'
CHANGING_STAMP_MARKER="$tmp/owner-raced" call "$owner1" claim --repo org/owner-raced --kind leave
check 20 "$rc" 'a process stamp changing around ancestor confirmation refuses the claim'
check "" "$out" 'the raced claim returns no generation'
if read_slot org/owner-raced leave >"$tmp/raced-slot"; then
  check null "$(cat "$tmp/raced-slot")" 'the raced claim publishes no reservation'
else
  check "" "$(cat "$tmp/raced-slot")" 'the raced claim publishes no reservation'
fi
rm "$tmp/bin/python3"

subagent="$root/.claude/skills/subagent/SKILL.md"
leaveby="$root/.claude/skills/leave-by/SKILL.md"
extract_skill_bash "$subagent" subagent-step7-leave-elicitation-gate > "$tmp/leave-read"
extract_skill_bash "$subagent" subagent-step7-leave-release > "$tmp/leave-release"
extract_skill_bash "$subagent" subagent-step7-leave-reservation > "$tmp/leave-reserve"
extract_skill_bash "$subagent" subagent-step7-overrun-decision > "$tmp/overrun-read"
extract_skill_bash "$subagent" subagent-step7-overrun-reservation > "$tmp/overrun-reserve"
extract_skill_bash "$subagent" subagent-step7-overrun-verify-reservation > "$tmp/overrun-verify"
extract_skill_bash "$leaveby" leave-by-elicit-verify-reservation > "$tmp/leave-verify"

leave_gate() (
  export FAKE_OWNER="$1"
  REPO_KEY="$2"; ATTENDED="${3:-true}"
  SESSION_STATE_SH="${5-$state}"; PROMPT_RESERVE_SH="${4-$helper}"
  source "$tmp/leave-release"; source "$tmp/leave-read"; source "$tmp/leave-reserve"
  printf '%s|%s|%s\n' "$ELICIT_LEAVE_TIME" "$LEAVE_PROMPT_PENDING" "$LEAVE_PROMPT_GENERATION"
)
result="$(leave_gate "$owner1" org/gates)"
check 'true|false' "${result%|*}" 'first attended launch opens the leave gate'
gate_token="${result##*|}"
check 'false|true|' "$(leave_gate "$owner2" org/gates)" 'loser queues without opening a second leave menu'
check 'false|true|' "$(leave_gate "$owner1" org/nohelper true '')" 'missing helper cannot authorize an attended prompt'
check 'false|false|' "$(leave_gate "$owner1" org/unattended false '')" 'unattended path stays silent and does not reserve'
cat > "$tmp/transient-state" <<'TRANSIENT'
#!/usr/bin/env bash
set -eu
case "$*" in
  *window.deadline_epoch*)
    case "$READ_CASE" in
      deadline) exit 6 ;;
      reread)
        if [[ -f "$READ_MARKER" ]]; then exit 6; else touch "$READ_MARKER"; fi
        ;;
      answered) printf '%s\n' "$READ_ARMED"; exit 0 ;;
    esac
    ;;
  *leave.no_deadline_until*)
    case "$READ_CASE" in no-deadline|answered) exit 6 ;; esac
    ;;
esac
printf 'null\n'
TRANSIENT
chmod +x "$tmp/transient-state"
export READ_MARKER="$tmp/read-marker" READ_ARMED=$(( $(date -u +%s) + 1200 ))
check 'false|true|' "$(READ_CASE=deadline leave_gate "$owner1" org/read-fail true "$helper" "$tmp/transient-state")" 'unreadable deadline keeps an attended launch pending'
check 'false|true|' "$(READ_CASE=no-deadline leave_gate "$owner1" org/read-fail true "$helper" "$tmp/transient-state")" 'unreadable suppression marker also keeps an attended launch pending'
check 'false|false|' "$(READ_CASE=deadline leave_gate "$owner1" org/read-fail false "$helper" "$tmp/transient-state")" 'unattended path does not wait for an interactive decision'
check 'false|false|' "$(READ_CASE=answered leave_gate "$owner1" org/read-fail true "$helper" "$tmp/transient-state")" 'an already armed deadline needs no question'
check 'false|true|' "$(READ_CASE=reread leave_gate "$owner1" org/recheck-fail true "$helper" "$tmp/transient-state")" 'failed recheck after claim keeps launch pending'
check null "$(read_slot org/recheck-fail leave)" 'failed recheck releases only the just-acquired generation'
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

# Inject lock/compare outcomes only on release; successful operations still
# use the actual writer and persisted slot.
mkdir "$tmp/release-helper"
cp "$helper" "$tmp/release-helper/prompt-reservation.sh"
cat > "$tmp/release-helper/session-state.sh" <<'RELEASE'
#!/usr/bin/env bash
set -eu
if [[ "$3" == --cas && "$4" == *=null ]]; then
  case "${RELEASE_MODE:-}" in
    timeout) exit 6 ;;
    once)
      if [[ ! -e "$RELEASE_MARKER" ]]; then : > "$RELEASE_MARKER"; exit 6; fi
      ;;
    replaced)
      "$GATE_STATE" --repo "$2" --set "${4%=null}=$REPLACEMENT_RECORD" >/dev/null
      # Fall through to the real CAS so the mismatch comes from the writer.
      ;;
  esac
fi
exec "$GATE_STATE" "$@"
RELEASE
chmod +x "$tmp/release-helper/session-state.sh"
release_helper="$tmp/release-helper/prompt-reservation.sh"
release_gate_fixture() {
  local saved_token saved_receipt other_token
  export FAKE_OWNER="$owner1"
  REPO_KEY=org/retained; ATTENDED=true
  PROMPT_RESERVE_SH="$release_helper"
  SESSION_STATE_SH="$tmp/transient-state"
  export READ_CASE=reread READ_MARKER="$tmp/release-read-marker" RELEASE_MODE=timeout
  unset LEAVE_RELEASE_RECEIPTS
  source "$tmp/leave-release"; source "$tmp/leave-read"; source "$tmp/leave-reserve"
  saved_token="$(read_slot org/retained leave | jq -r .generation)"
  [[ "$saved_token" =~ ^[0-9a-f]{32}$ ]] || return 1
  saved_receipt="org/retained:$saved_token"
  check "$saved_receipt" "$LEAVE_RELEASE_RECEIPTS" 'ambiguous release retains the exact repo and token'
  check 'false|true|' "$ELICIT_LEAVE_TIME|$LEAVE_PROMPT_PENDING|$LEAVE_PROMPT_GENERATION" 'release receipt cannot authorize the old menu'
  check "$saved_token" "$(read_slot org/retained leave | jq -r .generation)" 'ambiguous release preserves the durable reservation'

  # A different repo gets its own menu and can retain a second receipt.
  REPO_KEY=org/independent; SESSION_STATE_SH="$state"
  source "$tmp/leave-read"; source "$tmp/leave-reserve"
  check true "$ELICIT_LEAVE_TIME" 'a pending receipt does not block another repo menu'
  other_token="$LEAVE_PROMPT_GENERATION"
  if release_leave_prompt "$other_token"; then return 1; fi
  check "$saved_receipt"$'\n'"org/independent:$other_token" "$LEAVE_RELEASE_RECEIPTS" 'a second repo keeps its own receipt'
  REPO_KEY=org/retained

  # Later an independently published answer can be used after cleanup. It must
  # not be turned into another menu by recovery.
  "$state" --repo org/retained --set ".repos[\"org/retained\"].window.deadline_epoch=$deadline" >/dev/null
  SESSION_STATE_SH="$state"
  export RELEASE_MODE=once RELEASE_MARKER="$tmp/release-once"
  source "$tmp/leave-release"; source "$tmp/leave-read"; source "$tmp/leave-reserve"
  check "org/independent:$other_token" "$LEAVE_RELEASE_RECEIPTS" 'acknowledged release clears only its repo receipt'
  check 'false|false|' "$ELICIT_LEAVE_TIME|$LEAVE_PROMPT_PENDING|$LEAVE_PROMPT_GENERATION" 'recovery uses the published answer without reopening the menu'
  check null "$(read_slot org/retained leave)" 'a transient timeout recovers and frees the exact slot'
  check "$other_token" "$(read_slot org/independent leave | jq -r .generation)" 'recovering one repo does not clear the other reservation'
  REPO_KEY=org/independent
  export RELEASE_MODE=normal
  release_leave_prompt "$other_token"
  check "" "$LEAVE_RELEASE_RECEIPTS" 'the second repo can finish its independent recovery'
}
release_gate_fixture

call "$owner2" claim --repo org/replacement-fixture --kind leave
replacement_token="$out"
REPLACEMENT_RECORD="$(read_slot org/replacement-fixture leave)"
export REPLACEMENT_RECORD
call "$owner1" claim --repo org/release-lost --kind leave
original_token="$out"
(
  export FAKE_OWNER="$owner1" RELEASE_MODE=replaced
  REPO_KEY=org/release-lost PROMPT_RESERVE_SH="$release_helper"
  LEAVE_RELEASE_RECEIPTS="$REPO_KEY:$original_token"
  ATTENDED=false SESSION_STATE_SH="$state"
  source "$tmp/leave-release"; source "$tmp/leave-read"; source "$tmp/leave-reserve"
  [[ -z "$LEAVE_RELEASE_RECEIPTS" ]] || exit 1
)
check "$replacement_token" "$(read_slot org/release-lost leave | jq -r .generation)" 'compare loss discards the old receipt without clearing the replacement'

# The helper retains enough evidence even if a new /subagent invocation
# has no orchestration variables from the call that abandoned the menu.
call "$owner1" claim --repo org/fresh-release --kind leave
check 0 "$rc" 'fresh-invocation fixture owns the original menu'
fresh_old_token="$out"
fresh_receipt="$HOME/.claude/prompt-release-receipts/$fresh_old_token.json"
call "$owner2" release --repo org/fresh-release --kind leave --generation "$fresh_old_token"
check 10 "$rc" 'a different owner cannot release the known generation'
check false "$([[ -e "$fresh_receipt" ]] && echo true || echo false)" 'a different owner cannot publish an abandonment receipt'
fresh_rc=0
FAKE_OWNER="$owner1" RELEASE_MODE=timeout "$BASH" "$release_helper" \
  release --repo org/fresh-release --kind leave --generation "$fresh_old_token" \
  >"$tmp/fresh-release.out" 2>"$tmp/fresh-release.err" || fresh_rc=$?
check 20 "$fresh_rc" 'two lock timeouts leave a release pending'
check "$fresh_old_token" "$(jq -r .generation "$fresh_receipt")" 'the helper saved the receipt before the locked write'
unset LEAVE_RELEASE_RECEIPTS
check 'false|true|' "$(leave_gate "$owner2" org/fresh-release)" 'a different live owner cannot reclaim the abandoned generation'
fresh_result="$(leave_gate "$owner1" org/fresh-release)"
check 'true|false' "${fresh_result%|*}" 'a fresh same-owner attempt can open a new menu without carried shell state'
fresh_new_token="${fresh_result##*|}"
[[ "$fresh_new_token" =~ ^[0-9a-f]{32}$ && "$fresh_new_token" != "$fresh_old_token" ]] || exit 1
check false "$([[ -e "$fresh_receipt" ]] && echo true || echo false)" 'the successful claim retires the old receipt'
call "$owner1" release --repo org/fresh-release --kind leave --generation "$fresh_old_token"
check 10 "$rc" 'the old token cannot release the fresh generation'
check "$fresh_new_token" "$(read_slot org/fresh-release leave | jq -r .generation)" 'fresh reservation survives old release'

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

# Exercise the actual leave-by publication blocks with a competing direct
# declaration, including a write just before the guarded CAS reaches its lock.
extract_skill_bash "$leaveby" leave-by-elicit-snapshot > "$tmp/leave-snapshot"
extract_skill_bash "$leaveby" leave-by-arm-state > "$tmp/leave-arm"
extract_skill_bash "$leaveby" leave-by-no-deadline-until > "$tmp/leave-none"

snapshot_leave() (
  export FAKE_OWNER="$owner1"
  REPO_KEY="$1"; LEAVE_PROMPT_GENERATION="$2"; PROMPT_RESERVE_SH="$helper"
  source "$tmp/leave-snapshot"
  printf '%s\n' "$ELICIT_BASELINE"
)
write_arm() (
  export FAKE_OWNER="$owner1"
  REPO_KEY="$1"; LEAVE_PROMPT_GENERATION="$2"; ELICIT_BASELINE="$3"
  PROMPT_RESERVE_SH="$helper"; SESSION_STATE_SH="$state"
  unset LEAVE_WRITE_MODE LEAVE_ELICIT_MODE WINDDOWN_SCHEDULED
  if [[ -n "${4-elicited}" ]]; then LEAVE_WRITE_MODE="${4-elicited}"; fi
  DEADLINE_EPOCH="$deadline"; WINDOW_MINUTES=20; EFFECTIVE_WINDOW_MIN=15
  CHECKIN_EPOCH=$((deadline - 1800)); LEAD_MIN=30; WINDOW_STR='20 minutes'
  source "$tmp/leave-arm"
  printf '%s\n' "$ARM_RC"
)
write_none() (
  export FAKE_OWNER="$owner1"
  REPO_KEY="$1"; LEAVE_PROMPT_GENERATION="$2"; ELICIT_BASELINE="$3"; PROMPT_RESERVE_SH="$4"
  ND_SCOPE=dismissed
  source "$tmp/leave-none"
  printf '%s\n' "$NO_DEADLINE_RC"
)
read_schedule() {
  "$state" --repo "$1" --get-json ".repos[\"$1\"] | {window,leave}" | jq -c .
}
explicit_window='{"deadline_epoch":2147483000,"set_at":"explicit"}'
explicit_leave='{"active":true,"winddown_task_id":"monitor-live","winddown_generation":"explicit-gen"}'
write_explicit() {
  "$state" --repo "$1" --set ".repos[\"$1\"].window=$explicit_window" \
    --set ".repos[\"$1\"].leave=$explicit_leave" >/dev/null
}

call "$owner1" claim --repo org/explicit --kind leave
explicit_token="$out"
baseline="$(snapshot_leave org/explicit "$explicit_token")"
check '{"window":null,"leave":null}' "$baseline" 'capture deadline and leave identity before opening the menu'
write_explicit org/explicit
explicit_before="$(read_schedule org/explicit)"
check 10 "$(write_arm org/explicit "$explicit_token" "$baseline")" 'a timed menu answer cannot overwrite a direct declaration'
check "$explicit_before" "$(read_schedule org/explicit)" 'direct deadline and Monitor identity remain exact'
check "" "$(snapshot_leave org/explicit "$explicit_token")" 'an already active explicit Monitor prevents another menu'
check 20 "$(write_arm org/explicit '' '' '')" 'a fresh shell with no write mode cannot fall through to a direct declaration'
check "$explicit_before" "$(read_schedule org/explicit)" 'missing mode preserves the newer schedule'
check 20 "$(write_arm org/explicit '' '' elicited)" 'elicited mode without its carried proof cannot write'
check "$explicit_before" "$(read_schedule org/explicit)" 'missing elicitation proof preserves the newer schedule'
check 0 "$(write_arm org/direct '' '' direct)" 'an explicit direct declaration still writes'
check true "$(read_schedule org/direct | jq -r '.leave.winddown_scheduled')" 'direct declaration keeps Monitor scheduling enabled'

call "$owner1" claim --repo org/late --kind leave
late_token="$out"
baseline="$(snapshot_leave org/late "$late_token")"
mkdir -p "$tmp/race-helper"
cp "$helper" "$tmp/race-helper/prompt-reservation.sh"
cat > "$tmp/race-helper/session-state.sh" <<'INJECT'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" --expect-at "*)
    case "${RACE_MODE:-declaration}" in
      timeout-always) exit 6 ;;
      timeout-once)
        if [[ ! -e "$RACE_MARKER" ]]; then touch "$RACE_MARKER"; exit 6; fi
        exec "$RACE_STATE" "$@"
        ;;
    esac
    if [[ ! -e "$RACE_MARKER" ]]; then
      touch "$RACE_MARKER"
      "$RACE_STATE" --repo org/late --set ".repos[\"org/late\"].window=$RACE_WINDOW" \
        --set ".repos[\"org/late\"].leave=$RACE_LEAVE" >/dev/null
    fi
    ;;
esac
exec "$RACE_STATE" "$@"
INJECT
chmod +x "$tmp/race-helper/session-state.sh"
export RACE_STATE="$state" RACE_WINDOW="$explicit_window" RACE_LEAVE="$explicit_leave" RACE_MARKER="$tmp/injected"
check 10 "$(write_none org/late "$late_token" "$baseline" "$tmp/race-helper/prompt-reservation.sh")" 'a late direct write wins against the dismissal marker inside the CAS'
check "$explicit_before" "$(read_schedule org/late)" 'failed conditional dismissal changes neither field'

call "$owner1" claim --repo org/timeout --kind leave
timeout_token="$out"
baseline="$(snapshot_leave org/timeout "$timeout_token")"
check 20 "$(RACE_MODE=timeout-always write_none org/timeout "$timeout_token" "$baseline" "$tmp/race-helper/prompt-reservation.sh")" 'two lock timeouts report unavailable, not a competing declaration'
check "$baseline" "$(read_schedule org/timeout)" 'exhausted timeout leaves scheduling state unchanged'
check 0 "$(RACE_MODE=timeout-once RACE_MARKER="$tmp/one-timeout" write_none org/timeout "$timeout_token" "$baseline" "$tmp/race-helper/prompt-reservation.sh")" 'one lock timeout retries and stores the answer'

spent=$(( $(date -u +%s) - 60 ))
"$state" --repo org/spent --set ".repos[\"org/spent\"].window={\"deadline_epoch\":$spent,\"set_at\":\"spent\"}" \
  --set '.repos["org/spent"].leave={"active":true,"winddown_scheduled":false}' >/dev/null
call "$owner1" claim --repo org/spent --kind leave
spent_token="$out"
baseline="$(snapshot_leave org/spent "$spent_token")"
check "$spent" "$(jq -r .window.deadline_epoch <<<"$baseline")" 'expired planning-only record without a Monitor can be replaced'
"$state" --repo org/spent --set '.repos["org/spent"].window.launch_decisions={"12":{"decision":"skip"}}' \
  --set '.repos["org/spent"].refill={"paused":true}' >/dev/null
check 0 "$(write_none org/spent "$spent_token" "$baseline" "$helper")" 'same expired deadline can be retired despite an unrelated decision'
result="$(read_schedule org/spent)"
check true "$(jq -r '.window==null and .leave.active==false and .leave.no_deadline_until>0' <<<"$result")" 'suppression and old window removal commit together'
check true "$("$state" --repo org/spent --get-json '.repos["org/spent"].refill.paused')" 'conditional write preserves unrelated state'

call "$owner1" claim --repo org/allow --kind leave
allow_token="$out"
baseline="$(snapshot_leave org/allow "$allow_token")"
check 0 "$(write_arm org/allow "$allow_token" "$baseline")" 'current menu answer writes the deadline and planning-only leave'
check true "$(read_schedule org/allow | jq -r --argjson d "$deadline" '.window.deadline_epoch==$d and .leave.active==true and .leave.winddown_scheduled==false')" 'timed answer is stored without scheduling a Monitor'

printf '\nPrompt reservation: %s assertions passed\n' "$pass"
