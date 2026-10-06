#!/usr/bin/env bash
# desk/tests/lifecycle-cli.test.sh — offline contract tests for the lifecycle,
# set, and control subcommands: answer, ack, review, flag, comment, feedback,
# pending-for, set-open, set-resolve, state, register-control, tick (issue
# #1776). Needs no database and never connects to one: validation and secret
# refusal must happen before any connection attempt, which the black-hole URL
# below proves (a connection attempt would take the full 1.5 s deadline).
#
# Asserts:
#   - human-queue.sh --help lists every subcommand of parent #1754's 4.4 list
#     (AC 4.5), and each new subcommand's --help is offline: exit 0, stdout
#     only, documented exit codes, also after other arguments
#   - every usage and validation error exits 4 with one stderr line and no
#     connection attempt: missing or extra arguments, malformed ids, the id
#     prefix that is the wrong kind (answer/ack take D-, review/flag take R-),
#     blank or over-long text, control characters (escape, carriage return)
#     in answers, comments, and notes, never echoed; malformed feedback tags, set-open counts and
#     repeats, every malformed set-resolve reply, state actions and keys, and
#     the reserved state keys
#   - secret-shaped free text exits 5 without connecting and is never echoed,
#     including the values that only reach psql's argv (a state get key, a
#     pending-for session id); a state value too large for one Linux argument
#     exits 4; --set accepts any bigint set id and nothing past it; a reply
#     over 8000 characters exits 4, and one at the cap (thousands of leading
#     zeros or separators) still parses quickly
#   - the set-resolve parser, called directly: "2: B", "1: A, 2: C", commas
#     and line breaks kept inside an answer, `;` separators, leading zeros,
#     blank segments dropped, answers trimmed
#   - valid calls get past validation to the database step (exit 7, URL unset)
#
# Every case runs under `bash` on PATH and, when /bin/bash is 3.x (macOS),
# under /bin/bash too. Token-shaped values are assembled at run time so this
# file never contains one verbatim.
set -uo pipefail

# shellcheck source=lib/testlib.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testlib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-lifecycle-cli-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

ALNUM36="abcdefghijklmnopqrstuvwxyz0123456789"
FAKE_GH="gh""p_$ALNUM36"
FAKE_AWS="AK""IA""ABCDEFGHIJKLMNOP"

NEW_CMDS="answer ack review flag comment feedback pending-for set-open set-resolve state register-control tick"
# Parent #1754, AC 4.4: the store's complete subcommand list.
ALL_CMDS="add bump answer ack review flag comment feedback list get show set-open set-resolve state register-control pending-for tick migrate"

# run_cli SHELL ARGS... — runs the CLI against the black-hole URL; sets OUT,
# ERR, RC, ELAPSED_START, ELAPSED_END.
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
# containing NEEDLE, nothing on stdout, and no connection attempt.
expect_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  run_cli "$sh" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  if [ -n "$needle" ]; then check_contains "[$sh] $label: names it" "$ERR" "$needle"; fi
  if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 1.0; then
    ok "[$sh] $label (no connection attempt)"
  else
    bad "[$sh] $label took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s — it tried to connect"
  fi
}

# expect_db SHELL LABEL ARGS... — valid input reaches the database step: with
# the URL unset that is exit 7.
expect_db() {
  local sh="$1" label="$2" rc=0
  shift 2
  env -u HUMAN_QUEUE_DATABASE_URL "$sh" "$HQ_T_CLI" "$@" >/dev/null 2>"$TMP/err" </dev/null || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc" "7"
}

# The parser harness: sources the CLI's libraries and set-resolve's command
# file, then prints each parsed pair as `<n>=<answer>` with newlines shown as
# \n, so the parse is checked without a database.
cat > "$TMP/parse.sh" <<'EOF'
set -euo pipefail
HQ_BIN_DIR="$1"
. "$HQ_BIN_DIR/lib/common.sh"
. "$HQ_BIN_DIR/lib/db.sh"
. "$HQ_BIN_DIR/cmd/set-resolve.sh"
hq__sr_parse "$2"
k=0
while [ "$k" -lt "${#HQ_SR_POS[@]}" ]; do
  a="${HQ_SR_ANS[k]}"
  printf '%s=%s|' "${HQ_SR_POS[k]}" "${a//$'\n'/\\n}"
  k=$((k + 1))
done
EOF

# repeat CHAR N — CHAR repeated N times.
repeat() { printf "%${2}s" "" | tr ' ' "$1"; }

# repeat_str TEXT N — TEXT (any bytes, multi-byte included) repeated N times,
# by doubling, so it stays fast for large N.
repeat_str() {
  local out="" chunk="$1" n="$2"
  while [ "$n" -gt 0 ]; do
    if [ $((n % 2)) -eq 1 ]; then out="$out$chunk"; fi
    chunk="$chunk$chunk"
    n=$((n / 2))
  done
  printf '%s' "$out"
}

# parse SHELL REPLY — prints the parse, or the error line.
parse() { "$1" "$TMP/parse.sh" "$HQ_T_DESK_DIR/bin" "$2" 2>&1; }

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="

  # --- help (AC 4.2, 4.5) ----------------------------------------------------
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" --help 2>&1) || RC=$?
  check "[$SH] human-queue.sh --help exits 0" "$RC" "0"
  for c in $ALL_CMDS; do
    check_contains "[$SH] --help lists $c (#1754 4.4)" "$OUT" "  $c "
  done
  for c in $NEW_CMDS; do
    RC=0
    OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" "$c" --help 2>"$TMP/err") || RC=$?
    check "[$SH] $c --help exits 0 without a database" "$RC" "0"
    check_contains "[$SH] $c --help documents its usage" "$OUT" "human-queue.sh $c"
    check_contains "[$SH] $c --help documents exit codes" "$OUT" "EXIT CODES"
    check "[$SH] $c --help is silent on stderr" "$(cat "$TMP/err")" ""
  done
  help_after() {
    local rc=0
    env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || rc=$?
    check "[$SH] $* exits 0" "$rc" "0"
    check_contains "[$SH] $* prints the contract" "$(cat "$TMP/out")" "EXIT CODES"
  }
  help_after answer D-1 --help
  help_after ack D-1 --help
  help_after flag R-1 --note x --help
  help_after comment D-1 --help
  help_after feedback D-1 --help
  help_after pending-for s --help
  help_after set-open D-1 --help
  help_after set-resolve 1:A --help
  help_after state get --help
  help_after register-control s --help
  check_contains "[$SH] tick --help explains the in-flight case" \
    "$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" tick --help)" "already running then and committed later"
  check_contains "[$SH] feedback --help lists the starting tags" \
    "$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" feedback --help)" "should-have-defaulted"

  # --- answer ------------------------------------------------------------------
  expect_rc "$SH" 4 "answer without an id" "missing item id" answer
  expect_rc "$SH" 4 "answer without an answer" "missing answer" answer D-1
  expect_rc "$SH" 4 "answer with a malformed id" "invalid item id" answer X-1 yes
  expect_rc "$SH" 4 "answer to a Review" "R-3 is a Review" answer R-3 yes
  expect_rc "$SH" 4 "answer that is blank" "the answer is empty" answer D-1 "   "
  expect_rc "$SH" 4 "answer over 4000 characters" "longer than 4000" answer D-1 "$(repeat x 4001)"
  expect_rc "$SH" 4 "answer with a stray word" "one item id and one answer" answer D-1 yes please
  expect_rc "$SH" 4 "answer with an unknown flag" "unknown option '--fast'" answer --fast D-1 yes
  expect_rc "$SH" 5 "answer that is a token" "the answer looks like a GitHub token" answer D-1 "use $FAKE_GH"
  check_absent "[$SH] the answer token is not echoed" "$OUT$ERR" "$FAKE_GH"
  expect_db "$SH" "answer by letter" answer d-1 b
  expect_db "$SH" "a multi-line answer" answer D-1 "$(printf 'First line.\nSecond line.')"
  expect_db "$SH" "an answer of exactly 4000 characters" answer D-1 "$(repeat x 4000)"
  expect_db "$SH" "an answer that starts with a dash" answer D-1 "-- not now"
  expect_rc "$SH" 4 "an answer with a terminal escape" "the answer contains a control character" \
    answer D-1 "$(printf 'yes\033]52;c;eA==\007')"
  check_absent "[$SH] the escape in an answer is not echoed" "$OUT$ERR" "$(printf '\033')"
  expect_rc "$SH" 4 "an answer with a carriage return" "the answer contains a control character" \
    answer D-1 "$(printf 'fine\rFORGED')"
  expect_db "$SH" "an answer with tabs and line breaks" answer D-1 "$(printf 'a\tb\nc')"

  # --- ack ---------------------------------------------------------------------
  expect_rc "$SH" 4 "ack without an id" "missing item id" ack
  expect_rc "$SH" 4 "ack of a Review" "R-1 is a Review" ack R-1
  expect_rc "$SH" 4 "ack with two ids" "takes one item id" ack D-1 D-2
  expect_rc "$SH" 4 "ack --answer without a value" "--answer needs a value" ack D-1 --answer
  expect_rc "$SH" 4 "ack --answer twice" "--answer given more than once" ack D-1 --answer a --answer b
  expect_rc "$SH" 4 "ack --answer blank" "--answer is empty" ack D-1 --answer " "
  expect_rc "$SH" 4 "ack with an unknown flag" "unknown option '--force'" ack D-1 --force
  expect_db "$SH" "ack" ack D-1
  expect_db "$SH" "ack --answer" ack D-1 --answer "Wait for review"

  # --- review, flag --------------------------------------------------------------
  expect_rc "$SH" 4 "review of a Decision" "D-1 is a Decision" review D-1
  expect_rc "$SH" 4 "review with a stray argument" "takes one item id" review R-1 looks-good
  expect_rc "$SH" 4 "review without an id" "missing item id" review
  expect_db "$SH" "review" review r-1
  expect_rc "$SH" 4 "flag of a Decision" "D-1 is a Decision" flag D-1
  expect_rc "$SH" 4 "flag with an over-long note" "--note is longer than 200" flag R-1 --note "$(printf '%201s' x)"
  expect_rc "$SH" 4 "flag with a two-line note" "--note must be a single line" flag R-1 --note "$(printf 'a\nb')"
  expect_rc "$SH" 4 "flag with a bare note" "quote a note with --note" flag R-1 follow-up
  expect_rc "$SH" 5 "flag with a secret note" "--note" flag R-1 --note "key $FAKE_AWS"
  check_absent "[$SH] the flag note is not echoed" "$OUT$ERR" "$FAKE_AWS"
  expect_db "$SH" "flag with a note" flag R-1 --note "add a test for the empty case"
  expect_db "$SH" "flag without a note" flag R-1

  # --- comment, feedback -----------------------------------------------------------
  expect_rc "$SH" 4 "comment without text" "missing comment" comment D-1
  expect_rc "$SH" 4 "comment that is blank" "the comment is empty" comment D-1 ""
  expect_rc "$SH" 4 "comment over 200 characters" "longer than 200" comment D-1 "$(printf '%201s' x)"
  expect_rc "$SH" 4 "comment on two lines" "must be a single line" comment D-1 "$(printf 'a\nb')"
  expect_rc "$SH" 4 "comment with an escape" "the comment contains a control character" \
    comment D-1 "$(printf 'ok \033[31mred')"
  expect_rc "$SH" 4 "flag note with an escape" "--note contains a control character" \
    flag R-1 --note "$(printf 'x\033[0m')"
  expect_rc "$SH" 5 "comment with a token" "the comment looks like" comment D-1 "$FAKE_GH"
  expect_db "$SH" "comment" comment R-2 "looks right"
  expect_db "$SH" "comment that starts with dashes" comment R-2 "-- see the PR"
  for tag in "Not-Important" "not important" "not-important-" "-good" "good--interrupt" "$(repeat a 61)"; do
    expect_rc "$SH" 4 "feedback tag '$tag'" "lowercase words joined by hyphens" feedback D-1 "$tag"
  done
  expect_rc "$SH" 4 "feedback without a tag" "missing tag" feedback D-1
  for tag in not-important should-have-defaulted good-interrupt too-late-2; do
    expect_db "$SH" "feedback $tag" feedback D-1 "$tag"
  done

  # --- pending-for -------------------------------------------------------------------
  expect_rc "$SH" 4 "pending-for without a session" "missing session id" pending-for
  expect_rc "$SH" 4 "pending-for with two sessions" "takes one session id" pending-for a b
  expect_rc "$SH" 4 "pending-for with a two-line session" "must be a single line" pending-for "$(printf 'a\nb')"
  expect_rc "$SH" 4 "pending-for with an unknown flag" "unknown option '--all'" pending-for s --all
  expect_rc "$SH" 5 "pending-for with a token for a session" "the session id looks like" pending-for "$FAKE_GH"
  check_absent "[$SH] the pending-for token is not echoed" "$OUT$ERR" "$FAKE_GH"
  expect_db "$SH" "pending-for" pending-for sess-a --json

  # --- set-open --------------------------------------------------------------------
  expect_rc "$SH" 4 "set-open without ids" "missing item ids" set-open
  expect_rc "$SH" 4 "set-open with a repeated id" "D-1 is given twice" set-open D-1 D-2 d-1
  expect_rc "$SH" 4 "set-open with a malformed id" "invalid item id" set-open D-1 two
  expect_rc "$SH" 4 "set-open with an unknown flag" "unknown option '--size'" set-open D-1 --size
  IDS=()
  i=1
  while [ "$i" -le 99 ]; do
    IDS[${#IDS[@]}]="D-$i"
    i=$((i + 1))
  done
  expect_db "$SH" "set-open with 99 items" set-open "${IDS[@]}"
  expect_rc "$SH" 4 "set-open with 100 items" "at most 99 items" set-open "${IDS[@]}" D-100
  expect_db "$SH" "set-open mixing Decisions and Reviews" set-open D-1 R-1 --json

  # --- set-resolve ---------------------------------------------------------------------
  expect_rc "$SH" 4 "set-resolve without a reply" "missing reply" set-resolve
  expect_rc "$SH" 4 "set-resolve with two replies" "takes one reply" set-resolve "1: A" "2: B"
  expect_rc "$SH" 4 "set-resolve without numbers" "expected a reply such as" set-resolve "B"
  expect_rc "$SH" 4 "set-resolve that is blank" "expected a reply such as" set-resolve " , "
  expect_rc "$SH" 4 "set-resolve starting with free text" "expected a reply such as" set-resolve "yes, 2: B"
  expect_rc "$SH" 4 "set-resolve number 0" "from 1 to 99" set-resolve "0: A"
  expect_rc "$SH" 4 "set-resolve number 100" "from 1 to 99" set-resolve "100: A"
  expect_rc "$SH" 4 "set-resolve with a number twice" "number 2 is answered twice" set-resolve "2: A, 02: B"
  expect_rc "$SH" 4 "set-resolve with a blank answer" "the answer to 2 is empty" set-resolve "1: A, 2:  "
  expect_rc "$SH" 4 "set-resolve with an over-long answer" "the answer to 1 is longer than 4000" \
    set-resolve "1: $(repeat x 4001)"
  expect_rc "$SH" 4 "set-resolve with an escape in an answer" "the answer to 2 contains a control character" \
    set-resolve "$(printf '1: A, 2: B\033[2J')"
  expect_rc "$SH" 4 "set-resolve --set that is not a number" "--set must be a set id" set-resolve "1: A" --set abc
  expect_rc "$SH" 4 "set-resolve --set 0" "--set must be a set id" set-resolve "1: A" --set 0
  expect_rc "$SH" 4 "set-resolve --set twice" "--set given more than once" set-resolve "1: A" --set 1 --set 2
  expect_db "$SH" "set-resolve --set at bigint's maximum" set-resolve "1: A" --set 9223372036854775807
  expect_db "$SH" "set-resolve --set of 19 digits" set-resolve "1: A" --set 1000000000000000000
  expect_rc "$SH" 4 "set-resolve --set past the maximum in its high digits" "--set is not a set id" \
    set-resolve "1: A" --set 9223372037000000000
  expect_rc "$SH" 4 "set-resolve --set past bigint's maximum" "--set is not a set id" \
    set-resolve "1: A" --set 9223372036854775808
  expect_rc "$SH" 4 "set-resolve --set of 20 digits" "--set is not a set id" \
    set-resolve "1: A" --set 10000000000000000000
  expect_rc "$SH" 4 "set-resolve number 00" "from 1 to 99" set-resolve "00: A"
  expect_rc "$SH" 4 "set-resolve number 0100" "from 1 to 99" set-resolve "0100: A"
  expect_rc "$SH" 4 "set-resolve reply over 8000 characters" "the reply is longer than 8000" \
    set-resolve "1: A$(repeat , 7997)"
  check "[$SH] parse drops thousands of leading zeros" "$(parse "$SH" "$(repeat 0 7990)7: B")" "7=B|"
  P_START=$(hq_t_now)
  check "[$SH] parse of 8000 characters of separators" "$(parse "$SH" "1: A$(repeat , 7996)")" "1=A|"
  P_END=$(hq_t_now)
  if hq_t_elapsed_under "$P_START" "$P_END" 5.0; then
    ok "[$SH] a reply at the cap parses in under 5 s"
  else
    bad "[$SH] a reply at the cap took $(hq_t_elapsed "$P_START" "$P_END")s to parse"
  fi
  expect_rc "$SH" 5 "set-resolve with a token in an answer" "the answer to 2 looks like" \
    set-resolve "1: A, 2: try $FAKE_GH"
  check_absent "[$SH] the set-resolve token is not echoed" "$OUT$ERR" "$FAKE_GH"
  expect_db "$SH" "set-resolve \"2: B\"" set-resolve "2: B"
  expect_db "$SH" "set-resolve \"1: A, 2: C\" --set 12 --json" set-resolve "1: A, 2: C" --set 12 --json

  check "[$SH] parse \"2: B\"" "$(parse "$SH" "2: B")" "2=B|"
  check "[$SH] parse \"1: A, 2: C\"" "$(parse "$SH" "1: A, 2: C")" "1=A|2=C|"
  check "[$SH] parse keeps commas inside an answer" \
    "$(parse "$SH" "1: yes, but after CI, 3: use staging")" "1=yes, but after CI|3=use staging|"
  check "[$SH] parse splits on semicolons" "$(parse "$SH" "1:A;2:B ; 4 : free text")" "1=A|2=B|4=free text|"
  check "[$SH] parse splits on line breaks and keeps a multi-line answer" \
    "$(parse "$SH" "$(printf '1: first line\nstill the first answer\n2: B')")" \
    "1=first line\nstill the first answer|2=B|"
  check "[$SH] parse drops leading zeros" "$(parse "$SH" "02: B")" "2=B|"
  check "[$SH] parse drops blank segments" "$(parse "$SH" "1: A,, 2: B,")" "1=A|2=B|"
  check "[$SH] parse trims each answer" "$(parse "$SH" "  3 :   spaced out   ")" "3=spaced out|"
  check "[$SH] parse keeps a time inside an answer" "$(parse "$SH" "1: at 10:30 please")" "1=at 10:30 please|"
  check_contains "[$SH] parse refuses free text first" "$(parse "$SH" "B, 2: C")" "expected a reply such as"

  # --- state ---------------------------------------------------------------------------
  expect_rc "$SH" 4 "state without an action" "missing action" state
  expect_rc "$SH" 4 "state with an unknown action" "unknown action" state put k v
  expect_rc "$SH" 4 "state get without a key" "missing key" state get
  expect_rc "$SH" 4 "state get with a space in the key" "the key must be" state get "day plan"
  expect_rc "$SH" 4 "state get with an over-long key" "the key must be" state get "$(repeat k 201)"
  expect_rc "$SH" 4 "state get with two keys" "too many arguments" state get a b
  expect_rc "$SH" 4 "state set without a value" "missing value" state set day_plan
  expect_rc "$SH" 4 "state set with too many arguments" "too many arguments" state set day_plan a b
  expect_rc "$SH" 4 "state set tick_watermark" "only tick writes it" state set tick_watermark 1:1:
  expect_rc "$SH" 4 "state set control_session" "use register-control" state set control_session s
  expect_rc "$SH" 4 "state set over the value limit" "longer than 65536" state set k "$(printf '%65537s' x)"
  expect_rc "$SH" 5 "state set with a token value" "the value looks like" state set k "$FAKE_GH"
  check_absent "[$SH] the state token is not echoed" "$OUT$ERR" "$FAKE_GH"
  expect_rc "$SH" 5 "state get with a token for a key" "state get: the key looks like" state get "$FAKE_GH"
  check_absent "[$SH] the state get key is not echoed" "$OUT$ERR" "$FAKE_GH"
  # 43688 three-byte characters and one more byte: under 65536 characters, but
  # 131065 bytes — one argument still fits Linux's 131072, `hq_value=` + it
  # would not. (A C-locale shell counts bytes and stops at the character cap.)
  expect_rc "$SH" 4 "state set of a value too large for one psql argument" "state set: the value is l" \
    state set k "$(repeat_str '€' 43688)a"
  expect_db "$SH" "state get" state get day_plan:2026-10-05
  expect_db "$SH" "state get of a reserved key" state get tick_watermark
  expect_db "$SH" "state set" state set day_plan "$(printf 'PRD first\nthen four questions')"
  expect_db "$SH" "state set of an empty value" state set day_plan ""
  expect_db "$SH" "state set of a value that looks like a flag" state set note --help

  # --- register-control, tick ------------------------------------------------------------
  expect_rc "$SH" 4 "register-control without a session" "missing session id" register-control
  expect_rc "$SH" 4 "register-control with two sessions" "takes one session id" register-control a b
  expect_rc "$SH" 5 "register-control with a token" "the session id looks like" register-control "$FAKE_GH"
  expect_db "$SH" "register-control" register-control desk-session-1 --json
  expect_rc "$SH" 4 "tick with an argument" "unknown argument" tick everything
  expect_rc "$SH" 4 "tick with a flag" "unknown option '--reset'" tick --reset
  expect_db "$SH" "tick" tick
done

hq_t_finish "lifecycle-cli.test.sh"
