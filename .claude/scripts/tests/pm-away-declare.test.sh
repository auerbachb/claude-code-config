#!/usr/bin/env bash
# catalog: tests — Proves /pm --away maps its value onto presence.sh set away through the existing parsers, and refuses unreadable values in one line
# covers: .claude/skills/pm/SKILL.md .claude/scripts/presence.sh .claude/scripts/window-plan.sh
# Issue #2479. Runs the real Step 0c block (test-anchor pm-away-declare) with a
# stub presence.sh that records its arguments, and the real window-plan.sh.
set -euo pipefail

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$test_dir/../../.." && pwd)
source "$test_dir/lib/skill-bash.sh"
block=$(extract_skill_bash "$root/.claude/skills/pm/SKILL.md" pm-away-declare)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pm-away-declare.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/.claude"
cd "$tmp"

stub="$tmp/presence.sh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = is-away ]; then [ "${PRESENCE_AWAY:-0}" = 1 ]; exit; fi
if [ "${1:-}" = status ]; then
  [ "${PRESENCE_STATUS_FAIL:-0}" = 1 ] && exit 1
  if [ "${PRESENCE_AWAY:-0}" = 1 ]; then echo '{"away":true}'; else echo '{"away":false}'; fi
  exit 0
fi
printf '%s\n' "$*" > "$PRESENCE_CALLS"
[ "${PRESENCE_FAIL:-0}" = 1 ] && exit 1
printf 'presence: away, until later\n'
STUB
chmod +x "$stub"
export PRESENCE_CALLS="$tmp/calls"
# Pin the clock so the clock-time cases do not depend on when the test runs.
# 10:00Z is 05:00 ET on 2026-01-15, before every clock time used below;
# 23:00Z is 18:00 ET, after them, for the next-occurrence case.
pin_window() {  # pin_window <path> <ISO now>
  printf '#!/usr/bin/env bash\nexec %q "$@" --now %q\n' \
    "$root/.claude/scripts/window-plan.sh" "$2" > "$1"
  chmod +x "$1"
}
window="$tmp/window-plan.sh"; pin_window "$window" 2026-01-15T10:00:00Z
evening="$tmp/window-plan-evening.sh"; pin_window "$evening" 2026-01-15T23:00:00Z

pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok   — %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL — %s\n' "$1"; }
run() {  # run <away value> [presence path] [window path]
  rm -f "$PRESENCE_CALLS"
  out=$(AWAY_STR="$1" PRESENCE_SH="${2-$stub}" WINDOW_PLAN_SH="${3-$window}" "$BASH" -u -c "$block") || bad "block exited non-zero for '$1'"
  calls=$(cat "$PRESENCE_CALLS" 2>/dev/null || true)
}
expect_call() {  # label, ERE the presence args must match
  if [[ "$calls" =~ $2 ]]; then ok "$1"; else bad "$1 (presence args: '$calls')"; fi
}
expect_refusal() {  # label, substring of the reason
  local lines; lines=$(printf '%s\n' "$out" | grep -c . || true)
  if [[ -z "$calls" && "$lines" == 1 && "$out" == "Away not set — "*"$2"*"; continuing attended." ]]; then ok "$1"
  else bad "$1 (out: '$out', presence args: '$calls')"; fi
}

run overnight;            expect_call 'overnight -> --rest-of-day' '^set away --by operator-message --rest-of-day$'
run Overnight;            expect_call 'case-insensitive' '^set away --by operator-message --rest-of-day$'
run 6h;                   expect_call '6h -> presence --for' '^set away --by operator-message --for 6h$'
run 90m;                  expect_call '90m -> presence --for' '^set away --by operator-message --for 90m$'
run open-ended;           expect_call 'open-ended -> --open-ended' '^set away --by operator-message --open-ended$'
run 'until 8:00 AM';      expect_call 'clock time -> --until-epoch' '^set away --by operator-message --until-epoch [0-9]+$'
run 'back at 10';         expect_call 'bare hour is padded' '^set away --by operator-message --until-epoch [0-9]+$'
run 'until 8am';          expect_call 'glued am/pm' '^set away --by operator-message --until-epoch [0-9]+$'
run 'until 8:00 AM' "$stub" "$evening"
                          expect_call 'passed clock time -> tomorrow 08:00 ET' '^set away --by operator-message --until-epoch 1768568400$'
# A bare hour with no am/pm takes its soonest future occurrence (2026-01-15/16 ET).
night="$tmp/wp-9pm.sh"; pin_window "$night" 2026-01-16T02:00:00Z    # Thu 9 PM ET
morning="$tmp/wp-8am.sh"; pin_window "$morning" 2026-01-15T13:00:00Z # Thu 8 AM ET
late="$tmp/wp-11pm.sh"; pin_window "$late" 2026-01-16T04:00:00Z     # Thu 11 PM ET
run 'back at 10' "$stub" "$night";   expect_call 'bare 10 at 9 PM -> 10 PM tonight' '^set away --by operator-message --until-epoch 1768532400$'
[[ "$out" == *'Away until Thu 10:00 PM ET.' ]] && ok 'resolved end time is printed' || bad "resolved time: '$out'"
run 'back at 10' "$stub" "$morning"; expect_call 'bare 10 at 8 AM -> 10 AM today' '^set away --by operator-message --until-epoch 1768489200$'
run 'back at 10' "$stub" "$late";    expect_call 'bare 10 at 11 PM -> 10 AM tomorrow' '^set away --by operator-message --until-epoch 1768575600$'
run 'until 22:00' "$stub" "$morning"; expect_call '24-hour value keeps its meaning' '^set away --by operator-message --until-epoch 1768532400$'
run 'until 8:00 AM' "$stub" "$night"; expect_call 'explicit AM keeps its meaning' '^set away --by operator-message --until-epoch 1768568400$'
run '6 hours';            expect_call 'spelled duration -> --until-epoch' '^set away --by operator-message --until-epoch [0-9]+$'
run '6h';                 [[ "$out" == 'presence: away, until later' ]] && ok 'presence output is printed for the operator' || bad "printed: '$out'"

run 'until 25:99';        expect_refusal 'impossible clock time refused' 'is not a return time I can read'
run 'whenever';           expect_refusal 'nonsense refused' 'is not a return time I can read'
run 'closing the laptop at 7'; expect_refusal 'laptop wording redirected' '/leave-by'
run 6h '';                if [[ "$out" == 'Away not set — presence.sh not found (checked all three paths); presence could not be checked, so any earlier away window stays in force.' ]]; then ok 'missing presence.sh refused without claiming attended'; else bad "missing presence.sh: '$out'"; fi
PRESENCE_STATUS_FAIL=1 run 'whenever'; if [[ -z "$calls" && "$out" == 'Away not set — '*'presence could not be checked, so any earlier away window stays in force.' ]]; then ok 'unreadable presence is not read as attended'; else bad "presence status failed: '$out'"; fi
AWAY_BARE=true run '';    expect_refusal 'bare --away refused' '--away needs a return time'
rm -f "$PRESENCE_CALLS"
out=$(env -u AWAY_STR AWAY_BARE=true PRESENCE_SH="$stub" WINDOW_PLAN_SH="$window" "$BASH" -u -c "$block" 2>&1) || bad 'bare --away with AWAY_STR unset exited non-zero'
calls=$(cat "$PRESENCE_CALLS" 2>/dev/null || true)
expect_refusal 'bare --away with AWAY_STR unset (set -u) refused' '--away needs a return time'
AWAY_BARE=true PRESENCE_AWAY=1 run ''; if [[ -z "$calls" && "$out" == 'Away not changed — --away needs a return time'*'stays in force.' ]]; then ok 'bare --away under an active window keeps it'; else bad "bare while away: '$out'"; fi
run 'until 8:00 AM' "$stub" ''; expect_refusal 'missing window-plan.sh refused' 'window-plan.sh not found'
PRESENCE_FAIL=1 run 6h;   if [[ "$out" == 'Away not set — presence.sh refused it (rc=1); continuing attended.' ]]; then ok 'presence refusal is one line'; else bad "presence refusal: '$out'"; fi
PRESENCE_FAIL=1 PRESENCE_AWAY=1 run 6h; if [[ "$out" == 'Away not changed — presence.sh refused it (rc=1); the earlier away window stays in force.' ]]; then ok 'refusal under an active window keeps it'; else bad "refusal while away: '$out'"; fi
PRESENCE_AWAY=1 run 'whenever'; if [[ -z "$calls" && "$out" == 'Away not changed — '*'is not a return time I can read'*'stays in force.' ]]; then ok 'unreadable value under an active window keeps it'; else bad "unreadable while away: '$out'"; fi

run '';                   if [[ -z "$out" && -z "$calls" ]]; then ok 'no --away: nothing printed, presence untouched'; else bad "empty value: out='$out' calls='$calls'"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
