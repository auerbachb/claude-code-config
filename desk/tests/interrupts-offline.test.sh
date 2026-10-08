#!/usr/bin/env bash
# desk/tests/interrupts-offline.test.sh — offline tests for the desk's policy,
# interrupt rule, and feedback tags (issue #1783). Needs no database and never
# connects to one: validation and secret refusal come before any connection
# attempt, which the black-hole URL proves (a connection attempt would take
# the full 1.5 s deadline).
#
# Asserts:
#   policy      desk-policy.sh over desk/policy.json and HUMAN_QUEUE_POLICY
#               files: the repo's file is the defaults; a missing file is the
#               defaults, silently; a partial file fills the rest; unknown
#               keys are ignored; each invalid shape (not JSON, not an
#               object, unreadable, every key out of range or of the wrong
#               type, a cadence at or past the live bound) is every default
#               plus exactly one warning line naming the problem.
#   desk-tick   passes the policy's interrupt rule to `tick --interrupts`
#               (everything after an invalid file), and sleeps the policy's
#               cadence unless --cadence overrides it.
#   CLI         interrupt get/set, tick --interrupts, feedback --set/--json,
#               and `state set interrupt`: every malformed call exits 4 (a
#               secret-shaped session 5) without a connection attempt; valid
#               calls reach the database step; --help documents the verbs.
#   desk.jq     desk_sets, desk_batch, desk_feedback on fixtures.
#   skill       interrupts.md's anchored blocks run as written against a stub
#               CLI: the policy's rule reaches `interrupt get --default`, a
#               focus time and a feedback message pass through quoted
#               here-documents untouched (nothing they hold runs); SKILL.md
#               routes the verbs and tags to interrupts.md before typed
#               replies; decisions.md sizes sets with desk_batch.
#
# Every CLI case runs under `bash` and, when /bin/bash is 3.x (macOS), under
# /bin/bash too; the skill's blocks also run under zsh when it is installed.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: interrupts-offline.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: interrupts-offline.test.sh — python3 is not installed (the policy parser needs it)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-interrupts-offline.XXXXXX")
cleanup() { chmod -R u+rw "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"
FAKE_URL="postgres://hq-desk-stub@db.invalid/hq?sslmode=require"
SKILL_DIR="$HQ_T_DESK_DIR/skill"
BIN="$HQ_T_DESK_DIR/bin"
FAKE_AWS="AK""IA""ABCDEFGHIJKLMNOP"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi
BLOCK_SHELLS="$SHELLS"
if command -v zsh >/dev/null 2>&1; then BLOCK_SHELLS="$BLOCK_SHELLS zsh"; fi

DEFAULTS='{"tick_cadence_min":5,"interrupt_rule":"everything","eod_time":"17:30","set_size":4,"live_desk_max_tick_age_min":15}'

# ------------------------------------------------------------------ policy
printf '== policy\n'

# policy FILE — desk-policy.sh reading FILE ("" for the repo's own); sets
# OUT (compact JSON), ERR, RC.
policy() {
  RC=0
  if [ -n "$1" ]; then
    env HUMAN_QUEUE_POLICY="$1" bash "$BIN/desk-policy.sh" >"$TMP/out" 2>"$TMP/err" || RC=$?
  else
    env -u HUMAN_QUEUE_POLICY bash "$BIN/desk-policy.sh" >"$TMP/out" 2>"$TMP/err" || RC=$?
  fi
  OUT=$(jq -c . "$TMP/out" 2>/dev/null || cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# bad_policy LABEL CONTENT NEEDLE — CONTENT is every default plus one warning
# line naming NEEDLE.
bad_policy() {
  printf '%s\n' "$2" > "$TMP/policy.json"
  policy "$TMP/policy.json"
  check "policy $1: exit 0" "$RC" "0"
  check "policy $1: every key takes its default" "$OUT" "$DEFAULTS"
  check "policy $1: one warning line" "$(hq_t_lines "$ERR")" "1"
  check_contains "policy $1: the warning names it" "$ERR" "desk-policy: "
  check_contains "policy $1: the warning says what" "$ERR" "$3"
}

policy ""
check "the repo's policy.json: exit 0" "$RC" "0"
check "the repo's policy.json is the defaults" "$OUT" "$DEFAULTS"
check "the repo's policy.json: no warning" "$ERR" ""
check "desk/policy.json holds every key" \
  "$(jq -c 'keys' "$HQ_T_DESK_DIR/policy.json")" \
  '["eod_time","interrupt_rule","live_desk_max_tick_age_min","set_size","tick_cadence_min"]'

policy "$TMP/missing.json"
check "a missing file: the defaults" "$RC:$OUT" "0:$DEFAULTS"
check "a missing file: silent" "$ERR" ""

printf '{"set_size": 2, "interrupt_rule": "away"}\n' > "$TMP/partial.json"
policy "$TMP/partial.json"
check "a partial file fills in the rest" "$OUT" \
  '{"tick_cadence_min":5,"interrupt_rule":"away","eod_time":"17:30","set_size":2,"live_desk_max_tick_age_min":15}'
check "a partial file: no warning" "$ERR" ""

printf '{"set_size": 3, "day_plan_style": "terse", "x": [1]}\n' > "$TMP/unknown.json"
policy "$TMP/unknown.json"
check "unknown keys are ignored" "$(printf '%s' "$OUT" | jq -c '[.set_size, (keys | length)]')" "[3,5]"
check "unknown keys: no warning" "$ERR" ""

printf '{"tick_cadence_min": 20, "live_desk_max_tick_age_min": 30, "eod_time": "09:05"}\n' > "$TMP/wide.json"
policy "$TMP/wide.json"
check "a longer cadence under a longer live bound" "$(printf '%s' "$OUT" | jq -c '[.tick_cadence_min, .live_desk_max_tick_age_min, .eod_time]')" '[20,30,"09:05"]'

bad_policy "not JSON" '{"set_size": 2' "not valid JSON"
bad_policy "an array" '[1, 2]' "not a JSON object"
bad_policy "a string" '"everything"' "not a JSON object"
bad_policy "tick_cadence_min 0" '{"tick_cadence_min": 0}' "tick_cadence_min must be"
bad_policy "tick_cadence_min 61" '{"tick_cadence_min": 61, "live_desk_max_tick_age_min": 100}' "tick_cadence_min must be"
bad_policy "tick_cadence_min as a string" '{"tick_cadence_min": "5"}' "tick_cadence_min must be"
bad_policy "tick_cadence_min 5.5" '{"tick_cadence_min": 5.5}' "tick_cadence_min must be"
bad_policy "tick_cadence_min true" '{"tick_cadence_min": true}' "tick_cadence_min must be"
bad_policy "a cadence at the live bound" '{"tick_cadence_min": 15}' "shorter than live_desk_max_tick_age_min"
bad_policy "a live bound under the default cadence" '{"live_desk_max_tick_age_min": 3}' "shorter than live_desk_max_tick_age_min"
bad_policy "interrupt_rule focus" '{"interrupt_rule": "focus"}' "interrupt_rule must be everything or away"
bad_policy "interrupt_rule Everything" '{"interrupt_rule": "Everything"}' "interrupt_rule must be"
bad_policy "eod_time 5:30" '{"eod_time": "5:30"}' "eod_time must be"
bad_policy "eod_time 24:00" '{"eod_time": "24:00"}' "eod_time must be"
bad_policy "eod_time as a number" '{"eod_time": 1730}' "eod_time must be"
bad_policy "set_size 5" '{"set_size": 5}' "set_size must be"
bad_policy "set_size 0" '{"set_size": 0}' "set_size must be"
bad_policy "live bound 0" '{"live_desk_max_tick_age_min": 0}' "live_desk_max_tick_age_min must be"
bad_policy "live bound 1441" '{"live_desk_max_tick_age_min": 1441}' "live_desk_max_tick_age_min must be"
bad_policy "one bad value among good ones" '{"set_size": 2, "interrupt_rule": "away", "eod_time": "late"}' "eod_time must be"

if [ "$(id -u)" -ne 0 ]; then
  printf '{"set_size": 2}\n' > "$TMP/unreadable.json"
  chmod 000 "$TMP/unreadable.json"
  policy "$TMP/unreadable.json"
  check "an unreadable file: the defaults" "$RC:$OUT" "0:$DEFAULTS"
  check "an unreadable file: one warning" "$(hq_t_lines "$ERR")" "1"
  check_contains "an unreadable file: says so" "$ERR" "unreadable"
  chmod 600 "$TMP/unreadable.json"
fi

RC=0
bash "$BIN/desk-policy.sh" extra >/dev/null 2>"$TMP/err" || RC=$?
check "desk-policy.sh with an argument: exit 4" "$RC" "4"
RC=0
OUT=$(bash "$BIN/desk-policy.sh" --help 2>&1) || RC=$?
check "desk-policy.sh --help: exit 0" "$RC" "0"
check_contains "desk-policy.sh --help names every key" "$OUT" "live_desk_max_tick_age_min"

# The capture hook reads its live-desk bound through the same parser.
RC=0
OUT=$(env HUMAN_QUEUE_POLICY="$TMP/wide.json" python3 -I - "$HQ_T_DESK_DIR/hooks/capture.py" <<'PY'
import importlib.util
import sys
import time

spec = importlib.util.spec_from_file_location("hq_capture", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
hook = mod.Hook(time.monotonic())
print(mod.policy_minutes(hook))
PY
) || RC=$?
check "the hook's live bound comes from the shared parser" "$RC:$OUT" "0:30"

# --------------------------------------------------------------- desk-tick
printf '== desk-tick.sh\n'
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR" "$TMP/sleepbin"
TSTUB="$STUB_DIR/loopcli.sh"
cat > "$TSTUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/args"
case "$1" in
  control-status) echo '{"session": "desk-1", "last_tick_at": null, "tick_age_seconds": null}' ;;
  tick|wake-due) echo '[]' ;;
esac
EOF
chmod +x "$TSTUB"
# A `sleep` that records how long the loop meant to sleep, then ends it.
cat > "$TMP/sleepbin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB_DIR/slept"
exit 1
EOF
chmod +x "$TMP/sleepbin/sleep"

# dtick POLICY ARGS... — desk-tick.sh for desk-1 with POLICY ("" for the
# repo's own) against the stub CLI.
dtick() {
  local pol="$1"
  shift
  rm -f "$STUB_DIR/args" "$STUB_DIR/slept"
  RC=0
  if [ -n "$pol" ]; then
    env STUB_DIR="$STUB_DIR" HUMAN_QUEUE_CLI="$TSTUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" \
      HUMAN_QUEUE_POLICY="$pol" PATH="$TMP/sleepbin:$PATH" \
      bash "$BIN/desk-tick.sh" --session desk-1 --generation g1 "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  else
    env -u HUMAN_QUEUE_POLICY STUB_DIR="$STUB_DIR" HUMAN_QUEUE_CLI="$TSTUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" \
      PATH="$TMP/sleepbin:$PATH" \
      bash "$BIN/desk-tick.sh" --session desk-1 --generation g1 "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  fi
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

dtick "" --once
check "the default policy: tick honors the everything rule" "$RC:$(sed -n 2p "$STUB_DIR/args")" \
  "0:tick --session desk-1 --interrupts everything"
printf '{"interrupt_rule": "away"}\n' > "$TMP/away.json"
dtick "$TMP/away.json" --once
check "interrupt_rule away reaches tick" "$RC:$(sed -n 2p "$STUB_DIR/args")" \
  "0:tick --session desk-1 --interrupts away"
printf '{"interrupt_rule": "away", "set_size": 9}\n' > "$TMP/away-bad.json"
dtick "$TMP/away-bad.json" --once
check "an invalid policy is the defaults: everything" "$RC:$(sed -n 2p "$STUB_DIR/args")" \
  "0:tick --session desk-1 --interrupts everything"
check "desk-tick.sh does not repeat the policy warning" "$ERR" ""

dtick ""
check "the loop sleeps the default cadence (5 min)" "$RC:$(cat "$STUB_DIR/slept" 2>/dev/null)" "0:300"
dtick "$TMP/wide.json"
check "the loop sleeps the policy's cadence (20 min)" "$RC:$(cat "$STUB_DIR/slept" 2>/dev/null)" "0:1200"
dtick "$TMP/wide.json" --cadence 7
check "--cadence overrides the policy's" "$RC:$(cat "$STUB_DIR/slept" 2>/dev/null)" "0:420"
dtick "$TMP/wide.json" --cadence 30
check_contains "--cadence at the policy's live bound: refused" "$RC:$ERR" "4:desk-tick: --cadence must be shorter than the live-desk bound (30 min"

# --------------------------------------------------------------------- CLI
printf '== CLI\n'

run_cli() {
  local sh="$1"
  shift
  ELAPSED_START=$(hq_t_now)
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$sh" "$HQ_T_CLI" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  ELAPSED_END=$(hq_t_now)
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# expect_rc SHELL CODE LABEL NEEDLE ARGS... — exit CODE, one stderr line
# naming NEEDLE, nothing on stdout, no connection attempt.
expect_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  run_cli "$sh" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  check_contains "[$sh] $label: names it" "$ERR" "$needle"
  if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 1.0; then
    ok "[$sh] $label (no connection attempt)"
  else
    bad "[$sh] $label took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s — it tried to connect"
  fi
}

# expect_db SHELL LABEL ARGS... — valid input reaches the database step (exit
# 7 with the URL unset).
expect_db() {
  local sh="$1" label="$2" rc=0
  shift 2
  env -u HUMAN_QUEUE_DATABASE_URL "$sh" "$HQ_T_CLI" "$@" >/dev/null 2>"$TMP/err" </dev/null || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc" "7"
}

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="

  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" --help 2>&1)
  check_contains "[$SH] human-queue.sh --help lists interrupt" "$HELP" "  interrupt    read or set the desk's interrupt rule"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" interrupt --help 2>&1)
  check_contains "[$SH] interrupt --help: set focus" "$HELP" "interrupt set focus --session SESSION (--until WHEN | --for MINUTES)"
  check_contains "[$SH] interrupt --help: the reserved key" "$HELP" "reserved state key \`interrupt\`"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" tick --help 2>&1)
  check_contains "[$SH] tick --help documents --interrupts" "$HELP" "tick [--session SESSION [--interrupts RULE]]"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" feedback --help 2>&1)
  check_contains "[$SH] feedback --help documents --set and --json" "$HELP" "feedback ID TAG [--set SET_ID] [--json]"
  check_contains "[$SH] feedback --help names migration 008" "$HELP" "008_event_session.sql"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" state --help 2>&1)
  check_contains "[$SH] state --help lists interrupt as reserved" "$HELP" "interrupt        the desk's interrupt rule"

  # --- interrupt ------------------------------------------------------------------
  expect_rc "$SH" 4 "interrupt with no action" "missing action" interrupt
  expect_rc "$SH" 4 "interrupt toggle" "unknown action" interrupt toggle
  expect_rc "$SH" 4 "interrupt --json first" "unknown option '--json'" interrupt --json
  expect_rc "$SH" 4 "interrupt set with no rule" "missing rule" interrupt set
  expect_rc "$SH" 4 "interrupt set --session first" "missing rule" interrupt set --session s1
  expect_rc "$SH" 4 "interrupt set busy" "must be everything, away, or focus" interrupt set busy --session s1
  expect_rc "$SH" 4 "interrupt get without --session" "missing --session" interrupt get
  expect_rc "$SH" 4 "interrupt set away without --session" "missing --session" interrupt set away
  expect_rc "$SH" 4 "interrupt --session twice" "--session given more than once" interrupt get --session a --session b
  expect_rc "$SH" 4 "interrupt --session with no value" "--session needs a value" interrupt get --session
  expect_rc "$SH" 4 "interrupt --default focus" "--default must be everything or away" interrupt get --session s1 --default focus
  expect_rc "$SH" 4 "interrupt --default twice" "--default given more than once" interrupt get --session s1 --default away --default away
  expect_rc "$SH" 4 "interrupt a stray argument" "unknown" interrupt get --session s1 extra
  expect_rc "$SH" 4 "interrupt get --until" "go only with set focus" interrupt get --session s1 --until 15:30
  expect_rc "$SH" 4 "interrupt set away --for" "go only with set focus" interrupt set away --session s1 --for 30
  expect_rc "$SH" 4 "focus with neither" "missing --until WHEN or --for MINUTES" interrupt set focus --session s1
  expect_rc "$SH" 4 "focus with both" "not both" interrupt set focus --session s1 --until 15:30 --for 30
  expect_rc "$SH" 4 "focus --until twice" "--until given more than once" interrupt set focus --session s1 --until 1 --until 2
  for bad_for in 0 1441 x 12345 -5 ''; do
    expect_rc "$SH" 4 "focus --for '$bad_for'" "--for must be a whole number of minutes from 1 to 1440" \
      interrupt set focus --session s1 --for "$bad_for"
  done
  for bad_until in 25:00 24 13pm 0am 3:60 3:5 'tomorrow' '' '3:30 pmx' 'ET' '2026-13-01T00:00Z' '2026-10-07T19:30'; do
    expect_rc "$SH" 4 "focus --until '$bad_until'" "--until" interrupt set focus --session s1 --until "$bad_until"
  done
  expect_rc "$SH" 5 "a secret-shaped session" "the session id" interrupt get --session "$FAKE_AWS"
  check_absent "[$SH] the secret-shaped session is not echoed" "$OUT$ERR" "$FAKE_AWS"
  expect_db "$SH" "interrupt get" interrupt get --session s1
  expect_db "$SH" "interrupt get --default away --json" interrupt get --session s1 --default away --json
  expect_db "$SH" "interrupt set everything" interrupt set everything --session s1
  expect_db "$SH" "interrupt set away --json" interrupt set away --session s1 --json
  for good_until in 15:30 9:05 0:15 3 3:30 3:30pm 3pm '9 am' '3:30 PM ET' ' 15:30 ' '15:30 et' 2026-10-07T19:30Z '2026-10-07T15:30-04:00'; do
    expect_db "$SH" "focus --until '$good_until'" interrupt set focus --session s1 --until "$good_until"
  done
  expect_db "$SH" "focus --for 45" interrupt set focus --session s1 --for 45
  expect_db "$SH" "focus --for 1440" interrupt set focus --session s1 --for 1440

  # --- tick --interrupts ------------------------------------------------------------
  expect_rc "$SH" 4 "tick --interrupts without --session" "--interrupts needs --session" tick --interrupts everything
  expect_rc "$SH" 4 "tick --interrupts focus" "--interrupts must be everything or away" tick --session s1 --interrupts focus
  expect_rc "$SH" 4 "tick --interrupts with no value" "--interrupts needs a value" tick --session s1 --interrupts
  expect_rc "$SH" 4 "tick --interrupts twice" "--interrupts given more than once" tick --session s1 --interrupts away --interrupts away
  expect_db "$SH" "tick --interrupts away" tick --session s1 --interrupts away
  expect_db "$SH" "tick --interrupts everything" tick --session s1 --interrupts everything

  # --- feedback --set / --json --------------------------------------------------------
  expect_rc "$SH" 4 "feedback by number without --set" "a number names an item only with --set" feedback 2 not-important
  expect_rc "$SH" 4 "feedback --set 0" "--set must be a set id" feedback 2 not-important --set 0
  expect_rc "$SH" 4 "feedback --set 012" "--set must be a set id" feedback 2 not-important --set 012
  expect_rc "$SH" 4 "feedback --set x" "--set must be a set id" feedback 2 not-important --set x
  expect_rc "$SH" 4 "feedback --set with 19 digits" "--set must be a set id" feedback 2 not-important --set 1234567890123456789
  expect_rc "$SH" 4 "feedback --set twice" "--set given more than once" feedback 2 not-important --set 1 --set 2
  expect_rc "$SH" 4 "feedback --set with no value" "--set needs a value" feedback 2 not-important --set
  expect_rc "$SH" 4 "feedback number 100" "invalid item id" feedback 100 not-important --set 1
  expect_rc "$SH" 4 "feedback number 0" "invalid item id" feedback 0 not-important --set 1
  expect_rc "$SH" 4 "feedback with no tag" "missing tag" feedback 2 --set 1
  expect_rc "$SH" 4 "feedback with no id" "missing item id" feedback
  expect_rc "$SH" 4 "feedback with three words" "one item id and one tag" feedback D-4 not important
  expect_rc "$SH" 4 "feedback with a flag-shaped tag" "the tag must be" feedback D-4 --not-important
  expect_rc "$SH" 4 "feedback with an unknown flag" "unknown" feedback --bogus D-4 good-interrupt
  expect_db "$SH" "feedback by number in a set" feedback 2 not-important --set 12
  expect_db "$SH" "feedback by id with --set" feedback d-4 good-interrupt --set 12 --json
  expect_db "$SH" "feedback by id --json" feedback D-4 should-have-defaulted --json
  expect_db "$SH" "feedback, the classic form" feedback R-9 good-interrupt

  # --- state set interrupt ------------------------------------------------------------
  expect_rc "$SH" 4 "state set interrupt" "interrupt is reserved: use interrupt set" state set interrupt '{"rule":"away"}'
done

# ------------------------------------------------------------------ desk.jq
printf '== desk.jq\n'
dj() { jq -c -L "$SKILL_DIR" "$@"; }

check "desk_sets: five ids in fours" "$(dj -n 'include "desk"; ["D-1","D-2","D-3","D-4","D-5"] | desk_sets(4)')" \
  '[["D-1","D-2","D-3","D-4"],["D-5"]]'
check "desk_sets: three ids are one set" "$(dj -n 'include "desk"; ["D-1","D-2","D-3"] | desk_sets(4)')" \
  '[["D-1","D-2","D-3"]]'
check "desk_sets: size 1" "$(dj -n 'include "desk"; ["D-1","D-2"] | desk_sets(1)')" '[["D-1"],["D-2"]]'
check "desk_sets: size 2" "$(dj -n 'include "desk"; ["D-1","D-2","D-3"] | desk_sets(2)')" '[["D-1","D-2"],["D-3"]]'
for bad_size in 0 5 2.5 '"3"' null; do
  check "desk_sets: size $bad_size is four" \
    "$(dj -n --argjson s "$bad_size" 'include "desk"; ["D-1","D-2","D-3","D-4","D-5"] | desk_sets($s)')" \
    '[["D-1","D-2","D-3","D-4"],["D-5"]]'
done
check "desk_sets: no ids, no sets" "$(dj -n 'include "desk"; [] | desk_sets(4)')" '[]'

# Three Decisions with no plan, a long-form one, a Review, and an answered one.
cat > "$TMP/items.json" <<'JSON'
[
  {"id":"D-11","kind":"decision","status":"open","repo":"acme/w","key":"pr-1","session_id":"s1","question":"Q1","options":["A","B"],"cost":null},
  {"id":"D-12","kind":"decision","status":"open","repo":"acme/w","key":"pr-2","session_id":"s2","question":"Q2","options":["A","B","C"],"cost":"~5 min"},
  {"id":"D-13","kind":"decision","status":"open","repo":"acme/w","key":"pr-3","session_id":"s3","question":"Q3","options":["Yes","No"],"cost":null},
  {"id":"D-14","kind":"decision","status":"open","repo":"acme/w","key":"pr-4","session_id":"s4","question":"Q4","options":[],"cost":null},
  {"id":"R-15","kind":"review","status":"open","repo":"acme/w","key":"pr-5","session_id":null,"question":"R","options":[],"cost":null},
  {"id":"D-16","kind":"decision","status":"answered","repo":"acme/w","key":"pr-6","session_id":"s6","question":"Q6","options":["A","B"],"cost":null}
]
JSON
check "desk_batch: three Decisions are one set" \
  "$(dj --arg ids "" 'include "desk"; desk_batch($ids; 4)' "$TMP/items.json")" \
  '{"simple":["D-11","D-12","D-13"],"longform":[["D-14"]],"sets":[["D-11","D-12","D-13"]]}'
check "desk_batch: a tick's ids, size 2" \
  "$(dj --arg ids "D-13 D-11 D-16" 'include "desk"; desk_batch($ids; 2)' "$TMP/items.json")" \
  '{"simple":["D-11","D-13"],"longform":[],"sets":[["D-11","D-13"]]}'
check "desk_batch: size 2 splits three" \
  "$(dj --arg ids "" 'include "desk"; desk_batch($ids; 2) | .sets' "$TMP/items.json")" \
  '[["D-11","D-12"],["D-13"]]'
check "desk_batch keeps desk_split's answer" \
  "$(dj --arg ids "" 'include "desk"; (desk_batch($ids; 4) | del(.sets)) == desk_split($ids)' "$TMP/items.json")" "true"

# fb MESSAGE — desk_feedback over MESSAGE as `jq -Rs` reads it (with the
# here-document's trailing newline).
fb() { printf '%s\n' "$1" | jq -c -Rs -L "$SKILL_DIR" 'include "desk"; desk_feedback'; }
check "feedback: 2: not important" "$(fb '2: not important')" '[{"ref":"2","tag":"not-important"}]'
check "feedback: should have defaulted" "$(fb '2: should have defaulted')" '[{"ref":"2","tag":"should-have-defaulted"}]'
check "feedback: good interrupt" "$(fb '2: good interrupt')" '[{"ref":"2","tag":"good-interrupt"}]'
check "feedback: any case, a trailing period, an id" "$(fb 'D-43: Not Important.')" '[{"ref":"D-43","tag":"not-important"}]'
check "feedback: a lowercase id, hyphens, a space before the colon" "$(fb 'd-7 : good-interrupt')" '[{"ref":"D-7","tag":"good-interrupt"}]'
check "feedback: several pairs, commas and semicolons" "$(fb '1: good interrupt, 3: not important; D-9: should have defaulted')" \
  '[{"ref":"1","tag":"good-interrupt"},{"ref":"3","tag":"not-important"},{"ref":"D-9","tag":"should-have-defaulted"}]'
check "feedback: pairs on separate lines" "$(fb "$(printf '1: good interrupt\n\n2: not important')")" \
  '[{"ref":"1","tag":"good-interrupt"},{"ref":"2","tag":"not-important"}]'
check "feedback: extra blank space" "$(fb '   2:    not   important   ')" '[{"ref":"2","tag":"not-important"}]'
check "feedback: an answer is not feedback" "$(fb '2: B')" 'null'
check "feedback: tags mixed with an answer are not feedback" "$(fb '2: not important, 3: B')" 'null'
check "feedback: an answer that mentions a tag is not feedback" "$(fb '2: it is not important to ship today')" 'null'
check "feedback: an unknown tag" "$(fb '2: great interrupt')" 'null'
check "feedback: no item" "$(fb 'not important')" 'null'
check "feedback: an empty message" "$(fb '')" 'null'
check "feedback: an interrupt verb" "$(fb 'away')" 'null'
check "feedback: number 100" "$(fb '100: good interrupt')" 'null'
check "feedback: number 0" "$(fb '0: good interrupt')" 'null'
check "feedback: a Review id" "$(fb 'R-4: good interrupt')" 'null'
check "feedback: two periods" "$(fb '2: not important..')" 'null'

# ------------------------------------------------------------------- skill
printf '== skill\n'
INTERRUPTS="$SKILL_DIR/interrupts.md"
SKILL="$SKILL_DIR/SKILL.md"
for anchor in desk-policy desk-interrupt-set desk-interrupt-focus desk-interrupt-get desk-release \
              desk-feedback-parse desk-feedback; do
  RC=0
  hq_t_skill_block "$INTERRUPTS" "$anchor" > "$TMP/block-$anchor.sh" 2>"$TMP/err" || RC=$?
  check "interrupts.md: anchor $anchor extracts" "$RC:$(cat "$TMP/err")" "0:"
done

# The stub CLI the blocks run against: it records its arguments, one per
# line, and prints a fixed answer.
HSTUB="$TMP/hq-stub.sh"
cat > "$HSTUB" <<'EOF'
#!/usr/bin/env bash
: > "$STUB_DIR/hq-args"
for a in "$@"; do printf '%s\n' "$a" >> "$STUB_DIR/hq-args"; done
echo '{"stub": true}'
EOF
chmod +x "$HSTUB"

# literal FILE FROM TO — FILE with every FROM replaced by TO, literally.
literal() { FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1"; }

# run_block SHELL FILE [POLICY] — runs FILE with the prelude's DESK, HQ, and
# SID set, in $TMP/run, with its own TMPDIR.
mkdir -p "$TMP/run" "$TMP/blocktmp"
run_block() {
  rm -f "$STUB_DIR/hq-args"
  (cd "$TMP/run" && env DESK="$HQ_T_DESK_DIR" HQ="$HSTUB" SID="desk-1" STUB_DIR="$STUB_DIR" \
     TMPDIR="$TMP/blocktmp" HUMAN_QUEUE_POLICY="${3:-$TMP/missing.json}" "$1" "$2") 2>&1
}
args() { tr '\n' ' ' < "$STUB_DIR/hq-args" 2>/dev/null | sed 's/ $//'; }

# A focus time and a message holding everything a shell could run.
HOSTILE='3:30pm $(touch focus-pwned) `touch focus-pwned-2` ${HOME} "quoted" '"'"'single'"'"
FB_HOSTILE='2: not important; $(touch fb-pwned) `touch fb-pwned-2` "x"'
awk -v ph='<the time, as typed after "focus until">' -v t="$HOSTILE" '$0 == ph { print t; next } { print }' \
  "$TMP/block-desk-interrupt-focus.sh" > "$TMP/focus-hostile.sh"
awk -v ph='<the time, as typed after "focus until">' '$0 == ph { print "3:30pm"; next } { print }' \
  "$TMP/block-desk-interrupt-focus.sh" > "$TMP/focus.sh"
awk -v ph="<the operator's message, verbatim>" -v t="$FB_HOSTILE" '$0 == ph { print t; next } { print }' \
  "$TMP/block-desk-feedback-parse.sh" > "$TMP/fb-hostile.sh"
awk -v ph="<the operator's message, verbatim>" '$0 == ph { print "1: good interrupt, D-43: Not important."; next } { print }' \
  "$TMP/block-desk-feedback-parse.sh" > "$TMP/fb.sh"
literal "$TMP/block-desk-interrupt-set.sh" "<away|everything>" "away" > "$TMP/set-away.sh"
literal "$TMP/block-desk-feedback.sh" "<ref> <tag> --set <latest set_id>" "2 not-important --set 12" > "$TMP/fb-write.sh"
literal "$TMP/block-desk-release.sh" "<GEN>" "g7" > "$TMP/release.sh"

for SH in $BLOCK_SHELLS; do
  OUT=$(run_block "$SH" "$TMP/block-desk-policy.sh" "$TMP/partial.json")
  check "[$SH] desk-policy block: the effective policy, then exit=0" "$OUT" \
    "$(printf '%s\nexit=0' '{"tick_cadence_min": 5, "interrupt_rule": "away", "eod_time": "17:30", "set_size": 2, "live_desk_max_tick_age_min": 15}')"
  printf '[1]\n' > "$TMP/array.json"
  OUT=$(run_block "$SH" "$TMP/block-desk-policy.sh" "$TMP/array.json")
  check_contains "[$SH] desk-policy block: the warning line comes through" "$OUT" "desk-policy: array.json is not a JSON object; using the defaults"

  OUT=$(run_block "$SH" "$TMP/set-away.sh")
  check "[$SH] desk-interrupt-set block: the command" "$(args)" "interrupt set away --session desk-1 --json"
  check "[$SH] desk-interrupt-set block: prints exit" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"

  OUT=$(run_block "$SH" "$TMP/focus.sh")
  check "[$SH] desk-interrupt-focus block: the time reaches --until" "$(args)" \
    "interrupt set focus --session desk-1 --until 3:30pm --json"
  check "[$SH] desk-interrupt-focus block: prints exit" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
  OUT=$(run_block "$SH" "$TMP/focus-hostile.sh")
  check "[$SH] desk-interrupt-focus block: a hostile time arrives as typed" "$(sed -n 7p "$STUB_DIR/hq-args")" "$HOSTILE"
  check "[$SH] desk-interrupt-focus block: nothing in it ran" "$(find "$TMP/run" -name '*pwned*' | wc -l | tr -d ' ')" "0"
  check "[$SH] desk-interrupt-focus block: removes its file" "$(find "$TMP/blocktmp" -type f | wc -l | tr -d ' ')" "0"

  OUT=$(run_block "$SH" "$TMP/block-desk-interrupt-get.sh")
  check "[$SH] desk-interrupt-get block: the default policy's rule" "$(args)" \
    "interrupt get --session desk-1 --default everything"
  OUT=$(run_block "$SH" "$TMP/block-desk-interrupt-get.sh" "$TMP/away.json")
  check "[$SH] desk-interrupt-get block: the policy's away" "$(args)" \
    "interrupt get --session desk-1 --default away"
  OUT=$(run_block "$SH" "$TMP/block-desk-interrupt-get.sh" "$TMP/array.json")
  check "[$SH] desk-interrupt-get block: an invalid policy is everything" "$(args)" \
    "interrupt get --session desk-1 --default everything"

  OUT=$(run_block "$SH" "$TMP/fb.sh")
  check "[$SH] desk-feedback-parse block: the tags" "$OUT" \
    "$(printf '%s\nexit=0' '[{"ref":"1","tag":"good-interrupt"},{"ref":"D-43","tag":"not-important"}]')"
  OUT=$(run_block "$SH" "$TMP/fb-hostile.sh")
  check "[$SH] desk-feedback-parse block: a hostile message is not feedback" "$OUT" "$(printf 'null\nexit=0')"
  check "[$SH] desk-feedback-parse block: nothing in it ran" "$(find "$TMP/run" -name '*pwned*' | wc -l | tr -d ' ')" "0"
  check "[$SH] desk-feedback-parse block: removes its file" "$(find "$TMP/blocktmp" -type f | wc -l | tr -d ' ')" "0"

  OUT=$(run_block "$SH" "$TMP/fb-write.sh")
  check "[$SH] desk-feedback block: the command" "$(args)" "feedback 2 not-important --set 12 --json"

  # The release is one desk-tick cycle with the recorded generation.
  check_contains "[$SH] desk-release block: one tick, now" "$(cat "$TMP/release.sh")" \
    '"$DESK/bin/desk-tick.sh" --session "$SID" --generation "g7" --once'
done

# The router and the files around it.
contract() {
  local name="$1" text="$2" needle
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    check_contains "$name: $needle" "$text" "$needle"
  done
}
contract SKILL.md "$(cat "$SKILL")" <<'NEEDLES'
| `interrupts.md` |
**An interrupt verb** as the whole message
`focus until <time>`, `focus for <N> min`, `focus off`, or `interrupts?`
→ load `interrupts.md`. Also at any time, and checked before any typed reply or long-form answer: a tag is never an answer.
block `desk-policy`
`008_event_session.sql`
never the interrupt rule unasked
NEEDLES
check_absent "SKILL.md: no 'no verb here yet' for #1783" "$(cat "$SKILL")" "Interrupts, policy, and feedback tags (#1783)"
contract decisions.md "$(cat "$SKILL_DIR/decisions.md")" <<'NEEDLES'
'include "desk"; desk_batch($ids; $size)'
`set_size`
NEEDLES
contract interrupts.md "$(cat "$INTERRUPTS")" <<'NEEDLES'
**never printed unasked**
<<'DESK_WHEN'
<<'DESK_MSG'
A tag is never an answer:
Acknowledge in one line
NEEDLES
contract discuss.md "$(cat "$SKILL_DIR/discuss.md")" <<'NEEDLES'
A tag is never this item's answer.
NEEDLES
contract longform.md "$(cat "$SKILL_DIR/longform.md")" <<'NEEDLES'
A tag is never this part's answer.
NEEDLES

hq_t_finish interrupts-offline.test.sh
