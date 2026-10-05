#!/usr/bin/env bash
# desk/tests/items-cli.test.sh — offline contract tests for the item
# subcommands add, bump, get, list, and show (issue #1775). Needs no database
# and never connects to one: validation and secret refusal must happen before
# any connection attempt, which the black-hole URL below proves (a connection
# attempt would take the full 1.5 s connect deadline).
#
# Asserts:
#   - each subcommand's --help is offline (exit 0, stdout only), from the first
#     position and after other arguments, and human-queue.sh --help lists all five
#   - add: the first missing required field is named (exit 4), in the order
#     kind, repo, key, question; blank counts as missing (Test Plan 5.4)
#   - add: every triage-contract rule mirrored from 001 exits 4 without
#     connecting (kind, repo shape, one-line and length limits, context count
#     and total, options count and distinctness, default among the options,
#     --default-at shape, time zone, calendar validity, impact, repeated
#     flags, unknown flags, missing values)
#   - add: secret-shaped values exit 5 without connecting, and the value never
#     appears in the output (Test Plan 5.4); prose that merely mentions a
#     password or token is NOT refused
#   - bump/get/show: malformed ids and stray arguments exit 4; bump's note is
#     validated and secret-checked
#   - list: unknown kind or status exits 4
#   - a fully valid add with the URL unset gets past validation to exit 7
#
# Every case runs under `bash` on PATH and, when /bin/bash is 3.x (macOS),
# under /bin/bash too. Token-shaped test values are assembled at run time so
# this file never contains one verbatim.
set -uo pipefail

# shellcheck source=lib/testlib.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testlib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-items-cli-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

# Fake credentials, assembled so no scanner sees a literal token here.
ALNUM36="abcdefghijklmnopqrstuvwxyz0123456789"
FAKE_GH="gh""p_$ALNUM36"
FAKE_AWS="AK""IA""ABCDEFGHIJKLMNOP"
FAKE_SK="s""k-$ALNUM36"
FAKE_NPG="np""g_$ALNUM36"
FAKE_JWT="ey""JhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlc2lnbmF0dXJl"
FAKE_PEM="-----BEGIN RSA PRI""VATE KEY-----"
FAKE_URL="postgresql://alice:s3cr3t-pw""@db.example.test/app"
FAKE_BEARER="Authorization: Bear""er $ALNUM36"
FAKE_LABEL="pass""word=hunter2-SECRET-pw"

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

# expect_fast LABEL — the last run returned in under a second, so it never
# tried to connect.
expect_fast() {
  if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 1.0; then
    ok "$1 (no connection attempt)"
  else
    bad "$1 took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s — it tried to connect"
  fi
}

# expect_rc SHELL CODE LABEL NEEDLE ARGS... — runs, then checks the exit code,
# one stderr line containing NEEDLE, nothing on stdout, and no connection.
expect_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  run_cli "$sh" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  if [ -n "$needle" ]; then check_contains "[$sh] $label: names it" "$ERR" "$needle"; fi
  expect_fast "[$sh] $label"
}

# A valid base for add; each case appends or swaps one thing.
BASE=(--kind decision --repo auerbachb/claude-code-config --key pr-1775 --question "Ship it?")

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="

  # --- help is offline ------------------------------------------------------
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" --help 2>&1) || RC=$?
  check "[$SH] human-queue.sh --help exits 0" "$RC" "0"
  for c in add bump get list show; do
    check_contains "[$SH] --help lists $c" "$OUT" "  $c "
  done
  for c in add bump get list show; do
    RC=0
    OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" "$c" --help 2>"$TMP/err") || RC=$?
    check "[$SH] $c --help exits 0 without a database" "$RC" "0"
    check_contains "[$SH] $c --help documents exit codes" "$OUT" "EXIT CODES"
    check "[$SH] $c --help is silent on stderr" "$(cat "$TMP/err")" ""
  done
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" add --kind decision --help 2>/dev/null) || RC=$?
  check "[$SH] add --help after other flags exits 0" "$RC" "0"
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" get D-1 --help 2>/dev/null) || RC=$?
  check "[$SH] get ID --help exits 0" "$RC" "0"
  check_contains "[$SH] add --help states the dedupe key" \
    "$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" add --help)" "same kind, repo, key, and question"

  # --- add: required fields, first missing named (5.4) ----------------------
  expect_rc "$SH" 4 "add with nothing" "--kind" add
  expect_rc "$SH" 4 "add without --repo" "--repo" add --kind decision --key k --question q
  expect_rc "$SH" 4 "add without --key" "--key" add --kind decision --repo a/b --question q
  expect_rc "$SH" 4 "add without --question" "missing required --question" \
    add --kind decision --repo a/b --key k
  expect_rc "$SH" 4 "add with a blank --question" "missing required --question" \
    add --kind decision --repo a/b --key k --question "   "
  expect_rc "$SH" 4 "add missing several: the first is named" "--repo" add --kind review

  # --- add: triage contract -------------------------------------------------
  expect_rc "$SH" 4 "unknown kind" "--kind must be decision or review" \
    add --kind idea --repo a/b --key k --question q
  expect_rc "$SH" 4 "repo without a slash" "--repo must be OWNER/NAME" \
    add --kind decision --repo nope --key k --question q
  expect_rc "$SH" 4 "repo with two slashes" "--repo must be OWNER/NAME" \
    add --kind decision --repo a/b/c --key k --question q
  expect_rc "$SH" 4 "repo with a space" "--repo must be OWNER/NAME" \
    add --kind decision --repo "a /b" --key k --question q
  expect_rc "$SH" 4 "two-line question" "--question must be a single line" \
    add --kind decision --repo a/b --key k --question "$(printf 'one\ntwo')"
  expect_rc "$SH" 4 "question over 500 characters" "--question is longer than 500" \
    add --kind decision --repo a/b --key k --question "$(printf '%501s' x)"
  expect_rc "$SH" 4 "key over 200 characters" "--key is longer than 200" \
    add --kind decision --repo a/b --key "$(printf '%201s' x)" --question q
  expect_rc "$SH" 4 "four context lines" "at most 3 times" \
    add "${BASE[@]}" --context a --context b --context c --context d
  expect_rc "$SH" 4 "context over 600 characters in total" "600 characters in total" \
    add "${BASE[@]}" --context "$(printf '%300s' x)" --context "$(printf '%301s' y)"
  expect_rc "$SH" 4 "a two-line context entry" "--context 2 must be a single line" \
    add "${BASE[@]}" --context ok --context "$(printf 'a\rb')"
  expect_rc "$SH" 4 "an empty context entry" "--context 1 is empty" \
    add "${BASE[@]}" --context ""
  expect_rc "$SH" 4 "duplicate options" "--option 1 and --option 2 are the same" \
    add "${BASE[@]}" --option Yes --option Yes
  expect_rc "$SH" 4 "default not among the options" "--default must be one of the --option values" \
    add "${BASE[@]}" --option Yes --option No --default Maybe
  expect_rc "$SH" 4 "default-at without default" "--default-at needs --default" \
    add "${BASE[@]}" --default-at 2026-10-05T18:00Z
  expect_rc "$SH" 4 "default-at without a time zone" "ISO 8601 time with a time zone" \
    add "${BASE[@]}" --default go --default-at 2026-10-05T18:00
  expect_rc "$SH" 4 "default-at that is not a date" "ISO 8601" \
    add "${BASE[@]}" --default go --default-at tomorrow
  expect_rc "$SH" 4 "default-at on February 30" "not a real date" \
    add "${BASE[@]}" --default go --default-at 2026-02-30T18:00Z
  expect_rc "$SH" 4 "default-at on February 29 of a common year" "not a real date" \
    add "${BASE[@]}" --default go --default-at 2026-02-29T18:00Z
  expect_rc "$SH" 4 "default-at at hour 24" "not a real date" \
    add "${BASE[@]}" --default go --default-at 2026-10-05T24:00Z
  expect_rc "$SH" 4 "default-at with offset +16:00" "out-of-range time-zone offset" \
    add "${BASE[@]}" --default go --default-at 2026-10-05T18:00+16:00
  expect_rc "$SH" 4 "default-at with offset +14:01" "out-of-range time-zone offset" \
    add "${BASE[@]}" --default go --default-at 2026-10-05T18:00+14:01
  expect_rc "$SH" 4 "default-at with offset -15:30" "out-of-range time-zone offset" \
    add "${BASE[@]}" --default go --default-at 2026-10-05T18:00-1530
  expect_rc "$SH" 4 "unknown impact" "--impact must be low, medium, or high" \
    add "${BASE[@]}" --impact huge
  expect_rc "$SH" 4 "question given twice" "--question given more than once" \
    add "${BASE[@]}" --question again
  expect_rc "$SH" 4 "parked given twice" "--parked given more than once" \
    add "${BASE[@]}" --parked --parked
  expect_rc "$SH" 4 "unknown flag" "unknown option '--colour'" \
    add "${BASE[@]}" --colour red
  expect_rc "$SH" 4 "stray positional value is not echoed" "unknown argument" \
    add "${BASE[@]}" stray-free-text
  check_absent "[$SH] the stray value never reaches the message" "$ERR" "stray-free-text"
  expect_rc "$SH" 4 "flag without its value" "--impact needs a value" \
    add "${BASE[@]}" --impact

  # --- add: secrets refused with exit 5, never echoed (5.4) -----------------
  for pair in \
    "question:GitHub token:$FAKE_GH" \
    "question:AWS access key:$FAKE_AWS" \
    "question:sk-:$FAKE_SK" \
    "question:Neon password:$FAKE_NPG" \
    "question:JSON Web Token:$FAKE_JWT" \
    "question:private key:$FAKE_PEM" \
    "question:URL with credentials:$FAKE_URL" \
    "question:bearer token:$FAKE_BEARER" \
    "question:labeled credential:$FAKE_LABEL"; do
    field="${pair%%:*}"
    rest="${pair#*:}"
    class="${rest%%:*}"
    secret="${rest#*:}"
    expect_rc "$SH" 5 "$class in the $field" "$class" \
      add --kind decision --repo a/b --key k --question "Should I use $secret here?"
    check_absent "[$SH] $class: the secret is not echoed" "$OUT$ERR" "$secret"
  done
  expect_rc "$SH" 5 "a token in a context line names that line" "--context 2" \
    add "${BASE[@]}" --context fine --context "use $FAKE_GH"
  expect_rc "$SH" 5 "a token in an option names that option" "--option 1" \
    add "${BASE[@]}" --option "$FAKE_AWS" --option No
  expect_rc "$SH" 5 "a token in the key" "--key" \
    add --kind decision --repo a/b --key "$FAKE_GH" --question q
  expect_rc "$SH" 5 "a token in the session" "--session" \
    add "${BASE[@]}" --session "$FAKE_SK"
  expect_rc "$SH" 5 "a secret behind a harmless label is still found" "labeled credential" \
    add "${BASE[@]}" --cost "token: none, $FAKE_LABEL"

  # Prose that mentions credentials passes validation and the secret check,
  # and so reaches the (unset) database: exit 7, not 5.
  for prose in \
    "Should the password field be required?" \
    "Which token: GITHUB_TOKEN or a PAT?" \
    "Set token=\$GITHUB_TOKEN in the workflow?" \
    "Is password: required enough?" \
    "Use the sk-learn defaults?" \
    "Bearer auth or basic?"; do
    RC=0
    env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" add --kind decision --repo a/b --key k \
      --question "$prose" >/dev/null 2>"$TMP/err" </dev/null || RC=$?
    check "[$SH] prose is not a secret: $prose" "$RC" "7"
  done

  # --- a fully valid add reaches the database step ---------------------------
  RC=0
  env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" add "${BASE[@]}" --session s1 \
    --context one --context two --context three --option Yes --option No --default No \
    --default-at 2028-02-29T14:00-04:00 --impact high --parked --cost "~10 min" \
    --focus "no deep focus" >/dev/null 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] a valid add with every field passes validation (exit 7, URL unset)" "$RC" "7"
  RC=0
  env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" add "${BASE[@]}" \
    --context "$(printf '%300s' x)" --context "$(printf '%300s' y)" \
    >/dev/null 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] context of exactly 600 characters passes validation" "$RC" "7"

  # --- bump, get, show, list ---------------------------------------------------
  expect_rc "$SH" 4 "bump without an id" "missing item id" bump
  expect_rc "$SH" 4 "bump with a malformed id" "invalid item id" bump X-1
  expect_rc "$SH" 4 "bump with a zero-led id" "invalid item id" bump D-01
  expect_rc "$SH" 4 "bump with two ids" "takes one item id" bump D-1 D-2
  expect_rc "$SH" 4 "bump with an over-long note" "--note is longer than 200" \
    bump D-1 --note "$(printf '%201s' x)"
  expect_rc "$SH" 4 "bump with a two-line note" "--note must be a single line" \
    bump D-1 --note "$(printf 'a\nb')"
  expect_rc "$SH" 5 "bump with a secret note" "--note" bump D-1 --note "$FAKE_GH"
  expect_rc "$SH" 4 "get without an id" "missing item id" get
  expect_rc "$SH" 4 "get with a malformed id" "invalid item id" get 43
  expect_rc "$SH" 4 "get with an unknown flag" "unknown option '--yaml'" get D-1 --yaml
  expect_rc "$SH" 4 "show with two ids" "takes one item id" show D-1 R-1
  expect_rc "$SH" 4 "list with an unknown kind" "--kind must be decision or review" list --kind idea
  expect_rc "$SH" 4 "list with an unknown status" "--status must be one of" list --status pending
  expect_rc "$SH" 4 "list with a repeated filter" "--kind given more than once" \
    list --kind review --kind decision
  expect_rc "$SH" 4 "list with a stray argument" "unknown argument" list everything

  RC=0
  env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" get d-43 >/dev/null 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] a lowercase id is accepted (reaches the database step)" "$RC" "7"
  for long_id in D-9223372036854775807 R-99999999999999999999; do
    RC=0
    env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" bump "$long_id" >/dev/null 2>"$TMP/err" </dev/null || RC=$?
    check "[$SH] a ${#long_id}-character id is accepted (reaches the database step)" "$RC" "7"
  done
  for tz in +14:00 -14:00 +0545 -09; do
    RC=0
    env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" add "${BASE[@]}" --default go \
      --default-at "2026-10-05T18:00$tz" >/dev/null 2>"$TMP/err" </dev/null || RC=$?
    check "[$SH] default-at with offset $tz passes validation" "$RC" "7"
  done
  RC=0
  env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" list --kind review --status open --json \
    >/dev/null 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] valid list filters reach the database step" "$RC" "7"
done

hq_t_finish "items-cli.test.sh"
