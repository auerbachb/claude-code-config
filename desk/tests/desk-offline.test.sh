#!/usr/bin/env bash
# desk/tests/desk-offline.test.sh — offline tests for the /desk control loop's
# shell side (issue #1779). Needs no database: the CLI is a stub
# (HUMAN_QUEUE_CLI) or the real one pointed at a TEST-NET address.
#
# Asserts:
#   wake          --help is offline; every usage error exits 4 before
#                 connecting (missing id or --result, a Review id, an unknown
#                 result, a multi-line or over-long note); a secret-shaped note
#                 exits 5 and is never echoed; valid calls reach the database
#                 step (exit 7, URL unset); --help lists wake
#   set-resolve   the parser takes `D-<n>:` pairs beside `N:` pairs (d-43
#                 accepted, canonical D-43), keeps a later `D-<n>:` inside
#                 free text only after a separator, and refuses the same id
#                 twice before connecting; mixed replies reach the database
#   desk-cli.sh   with the URL in the environment it runs the CLI with it;
#                 without, it takes the URL from an owner-only config file or
#                 a literal profile export (the capture hook's resolver); with
#                 none it exits 7 with one line; a group-readable config file
#                 is refused; --help needs no URL; the URL is never printed
#   wake-target   a running desktop session resolves to its local_ id, a
#                 running terminal session to its name; a dead pid, an
#                 unknown id, or a missing registry exits 3; local_ ids pass
#                 through; the .key files are never read; usage errors exit 4
#   desk-tick.sh  --once prints `desk-tick G new <ids>` for open Decisions
#                 only (Reviews and answered items print nothing), then
#                 `desk-tick G retry <ids>` for wake-due's answers (issue
#                 #1781; a failing wake-due is an error line, and the
#                 tick's new line is still printed), prints
#                 `replaced` and exits 0 when another session is registered,
#                 prints one `error` line per failure streak and one
#                 `recovered` line, sleeps first, validates its arguments
#   #1781 CLI     wake --json, wake-due --min-age, history --date, and
#                 pending-for --repo/--key validate before connecting (exit 4,
#                 a secret-shaped key 5, never echoed); valid calls reach the
#                 database step
#   skill         .claude/skills/desk is a relative symlink to desk/skill;
#                 SKILL.md declares name: desk and routes to decisions.md,
#                 wakeups.md, and history.md; the menu prefix decisions.md
#                 prescribes is the one the capture hook recognises as a
#                 re-render
#
# Cases run under `bash` and, when /bin/bash is 3.x (macOS), under /bin/bash.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

REPO_ROOT=$(dirname "$HQ_T_DESK_DIR")
BIN="$HQ_T_DESK_DIR/bin"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: desk-offline.test.sh — python3 is not installed (the desk scripts need it)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-desk-offline.XXXXXX")
SLEEPERS=""
cleanup() {
  local p
  for p in $SLEEPERS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

FAKE_PW='hunter2-SECRET-pw'
BLACKHOLE_URL="postgresql://u:${FAKE_PW}@192.0.2.1:5432/db?sslmode=require"
FAKE_URL="postgres://hq-desk-stub@db.invalid/hq?sslmode=require"
ALNUM36="abcdefghijklmnopqrstuvwxyz0123456789"
FAKE_GH="gh""p_$ALNUM36"
MINPATH="/usr/bin:/bin"

# run_cli SHELL ARGS... — the real CLI against the black-hole URL; sets OUT,
# ERR, RC, and whether it returned within a second (no connection attempt).
run_cli() {
  local sh="$1" start end
  shift
  start=$(hq_t_now)
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$sh" "$HQ_T_CLI" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  end=$(hq_t_now)
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
  FAST=0
  if hq_t_elapsed_under "$start" "$end" 1.0; then FAST=1; fi
}

expect_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  run_cli "$sh" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  if [ -n "$needle" ]; then check_contains "[$sh] $label: names it" "$ERR" "$needle"; fi
  check "[$sh] $label: no connection attempt" "$FAST" "1"
}

expect_db() {
  local sh="$1" label="$2" rc=0
  shift 2
  env -u HUMAN_QUEUE_DATABASE_URL "$sh" "$HQ_T_CLI" "$@" >/dev/null 2>"$TMP/err" </dev/null || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc" "7"
}

# The set-resolve parser, called directly: prints each pair as POS/REF=ANSWER.
cat > "$TMP/parse.sh" <<'EOF'
set -euo pipefail
HQ_BIN_DIR="$1"
. "$HQ_BIN_DIR/lib/common.sh"
. "$HQ_BIN_DIR/lib/db.sh"
. "$HQ_BIN_DIR/cmd/set-resolve.sh"
hq__sr_parse "$2"
k=0
while [ "$k" -lt "${#HQ_SR_ANS[@]}" ]; do
  printf '%s/%s=%s|' "${HQ_SR_POS[k]}" "${HQ_SR_REF[k]}" "${HQ_SR_ANS[k]}"
  k=$((k + 1))
done
EOF
parse() { "$1" "$TMP/parse.sh" "$BIN" "$2" 2>&1; }

for SH in $SHELLS; do
  printf '== %s: wake\n' "$SH"
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" wake --help 2>&1) || RC=$?
  check "[$SH] wake --help is offline: exit 0" "$RC" "0"
  check_contains "[$SH] wake --help documents the events" "$OUT" "wake-failed"
  expect_rc "$SH" 4 "wake with no id" "missing item id" wake
  expect_rc "$SH" 4 "wake with no --result" "missing --result" wake D-1
  expect_rc "$SH" 4 "wake on a Review" "is a Review" wake R-3 --result sent
  expect_rc "$SH" 4 "wake with an unknown result" "must be sent or failed" wake D-1 --result maybe
  expect_rc "$SH" 4 "wake with --result twice" "more than once" wake D-1 --result sent --result failed
  expect_rc "$SH" 4 "wake with a multi-line note" "single line" wake D-1 --result failed --note $'a\nb'
  expect_rc "$SH" 4 "wake with an over-long note" "longer than 200" wake D-1 --result failed --note "$(printf '%201s' '' | tr ' ' x)"
  expect_rc "$SH" 4 "wake with two ids" "takes one item id" wake D-1 D-2 --result sent
  expect_rc "$SH" 4 "wake with a malformed id" "invalid item id" wake X-1 --result sent
  expect_rc "$SH" 5 "wake with a token in the note" "looks like" wake D-1 --result failed --note "token $FAKE_GH"
  check_absent "[$SH] the token is never echoed" "$OUT$ERR" "$FAKE_GH"
  expect_db "$SH" "wake D-1 --result sent" wake D-1 --result sent
  expect_db "$SH" "wake d-1 --result failed --note" wake d-1 --result failed --note "no running session"
  # Issue #1781: --json, wake-due, history, pending-for --repo/--key.
  expect_rc "$SH" 4 "wake with --json twice" "--json given more than once" wake D-1 --result sent --json --json
  expect_db "$SH" "wake --json" wake D-1 --result failed --json

  printf '== %s: wake-due, history, pending-for --repo/--key\n' "$SH"
  for bad_age in x -1 86401 123456 ''; do
    expect_rc "$SH" 4 "wake-due --min-age '$bad_age'" "--min-age must be a whole number" wake-due --min-age "$bad_age"
  done
  expect_rc "$SH" 4 "wake-due --min-age without a value" "--min-age needs a value" wake-due --min-age
  expect_rc "$SH" 4 "wake-due --min-age twice" "--min-age given more than once" wake-due --min-age 1 --min-age 2
  expect_rc "$SH" 4 "wake-due with a stray argument" "takes no arguments" wake-due D-1
  expect_rc "$SH" 4 "wake-due with an unknown flag" "unknown option '--all'" wake-due --all
  expect_db "$SH" "wake-due" wake-due
  expect_db "$SH" "wake-due --min-age 60 --json" wake-due --min-age 60 --json
  for bad_date in 2026-02-30 2026-13-01 26-10-07 2026-10-7 today 2026-10-07T00:00 ''; do
    expect_rc "$SH" 4 "history --date '$bad_date'" "--date" history --date "$bad_date"
  done
  expect_rc "$SH" 4 "history --date without a value" "--date needs a value" history --date
  expect_rc "$SH" 4 "history --date twice" "--date given more than once" history --date 2026-10-06 --date 2026-10-07
  expect_rc "$SH" 4 "history with a stray argument" "takes no arguments" history today
  expect_db "$SH" "history" history
  expect_db "$SH" "history --date 2024-02-29 --json" history --date 2024-02-29 --json
  expect_rc "$SH" 4 "pending-for --repo without --key" "--repo and --key go together" pending-for --repo a/b
  expect_rc "$SH" 4 "pending-for --key without --repo" "--repo and --key go together" pending-for s --key issue-1
  expect_rc "$SH" 4 "pending-for --repo without a slash" "--repo must be OWNER/NAME" pending-for --repo ab --key issue-1
  expect_rc "$SH" 4 "pending-for --repo with a space" "--repo must be OWNER/NAME" pending-for --repo "a/b c" --key issue-1
  expect_rc "$SH" 4 "pending-for a two-line --key" "must be a single line" pending-for --repo a/b --key $'issue-1\nx'
  expect_rc "$SH" 4 "pending-for --key twice" "--key given more than once" pending-for --repo a/b --key k --key j
  expect_rc "$SH" 4 "pending-for --repo needs a value" "--repo needs a value" pending-for --repo
  expect_rc "$SH" 5 "pending-for with a token for a key" "--key looks like" pending-for --repo a/b --key "$FAKE_GH"
  check_absent "[$SH] the pending-for key token is never echoed" "$OUT$ERR" "$FAKE_GH"
  expect_db "$SH" "pending-for --repo --key" pending-for --repo a/b --key issue-1 --json
  expect_db "$SH" "pending-for SESSION --repo --key" pending-for sess-a --repo a/b --key issue-1

  printf '== %s: set-resolve ids\n' "$SH"
  check "[$SH] parse D-43: B" "$(parse "$SH" "D-43: B")" "/D-43=B|"
  check "[$SH] parse d-43 is canonical" "$(parse "$SH" "d-43 : b")" "/D-43=b|"
  check "[$SH] parse mixed numbers and ids" "$(parse "$SH" "1: A, D-7: C")" "1/=A|/D-7=C|"
  check "[$SH] parse keeps D-n inside free text" "$(parse "$SH" "1: see D-7 first")" "1/=see D-7 first|"
  check "[$SH] parse a new pair after a separator" "$(parse "$SH" $'1: yes\nD-7: no')" "1/=yes|/D-7=no|"
  check "[$SH] parse an R- id continues the answer" "$(parse "$SH" "1: A, R-4: x")" "1/=A, R-4: x|"
  expect_rc "$SH" 4 "set-resolve with an id twice" "D-7 is answered twice" set-resolve "D-7: A, d-7: B"
  expect_rc "$SH" 4 "set-resolve with an empty id answer" "the answer to D-7 is empty" set-resolve "D-7:  "
  expect_rc "$SH" 4 "set-resolve starting with an R- id" "expected a reply such as" set-resolve "R-4: A"
  expect_rc "$SH" 5 "set-resolve with a token in an id answer" "the answer to D-7 looks like" set-resolve "D-7: $FAKE_GH"
  expect_db "$SH" "set-resolve by id" set-resolve "D-7: B" --set 3
  expect_db "$SH" "set-resolve mixed" set-resolve "1: A, D-7: B"
done

HELP=$(bash "$HQ_T_CLI" --help 2>&1)
case "$HELP" in
  *$'\n  wake '*) ok "human-queue.sh --help lists wake" ;;
  *) bad "human-queue.sh --help does not list wake" ;;
esac
for c in wake-due history; do
  case "$HELP" in
    *$'\n  '"$c "*) ok "human-queue.sh --help lists $c" ;;
    *) bad "human-queue.sh --help does not list $c" ;;
  esac
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL bash "$HQ_T_CLI" "$c" --help 2>&1) || RC=$?
  check "$c --help is offline: exit 0" "$RC" "0"
  check_contains "$c --help documents its usage" "$OUT" "human-queue.sh $c"
  check_contains "$c --help documents exit codes" "$OUT" "EXIT CODES"
done

# ------------------------------------------------------------- desk-cli.sh
printf '== desk-cli.sh\n'
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
STUB="$STUB_DIR/cli.sh"
# The stub records whether it received the expected URL, never the URL.
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
if [ "${HUMAN_QUEUE_DATABASE_URL:-}" = "${STUB_EXPECT_URL:-x}" ]; then
  echo url-ok > "$STUB_DIR/url"
else
  echo url-bad > "$STUB_DIR/url"
fi
printf '%s\n' "$*" > "$STUB_DIR/args"
echo "stub ran"
EOF
chmod +x "$STUB"

H="$TMP/home"
mkdir -p "$H/.config/human-queue"

# dcli VAR=VALUE... -- ARGS... — desk-cli.sh with only that environment.
dcli() {
  local -a envs=()
  while [ "$1" != "--" ]; do envs[${#envs[@]}]="$1"; shift; done
  shift
  rm -f "$STUB_DIR/url" "$STUB_DIR/args"
  RC=0
  env -i HOME="$H" PATH="$MINPATH" TMPDIR="$TMP" STUB_DIR="$STUB_DIR" HUMAN_QUEUE_CLI="$STUB" \
    "${envs[@]}" bash "$BIN/desk-cli.sh" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
  URLSEEN=$(cat "$STUB_DIR/url" 2>/dev/null || echo none)
}

dcli HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" STUB_EXPECT_URL="$FAKE_URL" -- tick
check "env URL: the CLI runs" "$RC:$OUT" "0:stub ran"
check "env URL: the CLI gets it" "$URLSEEN" "url-ok"
check "env URL: arguments pass through" "$(cat "$STUB_DIR/args")" "tick"

dcli STUB_EXPECT_URL="$FAKE_URL" -- tick
check "no URL anywhere: exit 7" "$RC" "7"
check "no URL anywhere: one stderr line" "$(hq_t_lines "$ERR")" "1"
check_contains "no URL anywhere: says why" "$ERR" "desk-cli: "
check "no URL anywhere: the CLI never ran" "$URLSEEN" "none"

printf '%s\n' "$FAKE_URL" > "$H/.config/human-queue/database_url"
chmod 600 "$H/.config/human-queue/database_url"
dcli STUB_EXPECT_URL="$FAKE_URL" -- control-status --json
check "config file: the CLI runs" "$RC" "0"
check "config file: the CLI gets the URL" "$URLSEEN" "url-ok"
check_absent "config file: the URL is never printed" "$OUT$ERR" "db.invalid"

chmod 640 "$H/.config/human-queue/database_url"
dcli STUB_EXPECT_URL="$FAKE_URL" -- tick
check "group-readable config file: exit 7" "$RC" "7"
check_contains "group-readable config file: names the rule" "$ERR" "mode 600"
check "group-readable config file: the CLI never ran" "$URLSEEN" "none"
rm -f "$H/.config/human-queue/database_url"

printf "export HUMAN_QUEUE_DATABASE_URL='%s'\n" "$FAKE_URL" > "$H/.zprofile"
dcli STUB_EXPECT_URL="$FAKE_URL" -- tick
check "literal profile export: the CLI gets the URL" "$RC:$URLSEEN" "0:url-ok"
# A command substitution in the profile line, written literally into the file.
printf 'export HUMAN_QUEUE_DATABASE_URL="%s(cat /etc/secret)"\n' '$' > "$H/.zprofile"
dcli STUB_EXPECT_URL="$FAKE_URL" -- tick
check "a non-literal profile export: exit 7" "$RC" "7"
check_contains "a non-literal profile export: is not run" "$ERR" "not run"
rm -f "$H/.zprofile"

dcli -- tick --help
check "--help needs no URL: the CLI runs" "$RC:$OUT" "0:stub ran"
check_absent "desk-cli never prints the URL" "$OUT$ERR" "db.invalid"

# ----------------------------------------------------------- wake-target.sh
printf '== wake-target.sh\n'
REG="$TMP/sessions"
mkdir -p "$REG"
sleep 600 &
LIVE1=$!
sleep 600 &
LIVE2=$!
SLEEPERS="$LIVE1 $LIVE2"
sh -c 'exit 0' &
DEAD=$!
wait "$DEAD" 2>/dev/null || true
cat > "$REG/$LIVE1.json" <<EOF
{"pid": $LIVE1, "sessionId": "cli-aaa", "hostSessionId": "local_1111", "name": "Worker one", "updatedAt": 10}
EOF
cat > "$REG/$LIVE2.json" <<EOF
{"pid": $LIVE2, "sessionId": "cli-bbb", "name": "Terminal worker", "updatedAt": 10}
EOF
cat > "$REG/$DEAD.json" <<EOF
{"pid": $DEAD, "sessionId": "cli-ccc", "hostSessionId": "local_3333", "name": "Gone", "updatedAt": 10}
EOF
# A key file holding a matching id must never be read as a registry entry.
printf '{"pid": %s, "sessionId": "cli-key", "hostSessionId": "local_key"}\n' "$LIVE1" > "$REG/$LIVE1.abcdef.key"

wt() {
  RC=0
  env HUMAN_QUEUE_SESSIONS_DIR="$REG" bash "$BIN/wake-target.sh" "$@" >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
wt cli-aaa
check "a running desktop session: its local_ id" "$RC:$OUT" "0:local_1111"
wt cli-aaa --json
check "--json names the address and the route" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["address"], d["via"], d["name"], d["session"])')" \
  "local_1111 host Worker one cli-aaa"
wt cli-bbb
check "a running terminal session: its name" "$RC:$OUT" "0:Terminal worker"
wt cli-ccc
check "a dead pid: exit 3" "$RC" "3"
check_contains "a dead pid: says nobody is running" "$ERR" "no running session"
wt cli-zzz
check "an unknown id: exit 3" "$RC" "3"
wt cli-key
check "a .key file is never read: exit 3" "$RC" "3"
wt local_9999
check "a local_ id passes through" "$RC:$OUT" "0:local_9999"
RC=0
env HUMAN_QUEUE_SESSIONS_DIR="$TMP/nowhere" bash "$BIN/wake-target.sh" cli-aaa >/dev/null 2>&1 || RC=$?
check "no registry: exit 3" "$RC" "3"
# Running, but no local_ id and no name: alive and unreachable, never
# reported as gone (exit 3 would tell the operator the thread ended).
REG3="$TMP/sessions3"
mkdir -p "$REG3"
printf '{"pid": %s, "sessionId": "cli-anon", "updatedAt": 10}\n' "$LIVE1" > "$REG3/$LIVE1.json"
RC=0
env HUMAN_QUEUE_SESSIONS_DIR="$REG3" bash "$BIN/wake-target.sh" cli-anon >"$TMP/out" 2>"$TMP/err" || RC=$?
check "running with no messaging address: exit 5" "$RC" "5"
check_contains "running with no messaging address: says so" "$(cat "$TMP/err")" "running but has no messaging address"
# A registry file that cannot be parsed (a session's file mid-rewrite) is
# skipped; with no match elsewhere, the answer is exit 1, never a guessed 3.
REG2="$TMP/sessions2"
mkdir -p "$REG2"
cp "$REG/$LIVE1.json" "$REG2/"
printf '{"pid": %s, "sessionId": "cli-b' "$LIVE2" > "$REG2/$LIVE2.json"
RC=0
env HUMAN_QUEUE_SESSIONS_DIR="$REG2" bash "$BIN/wake-target.sh" cli-aaa >"$TMP/out" 2>"$TMP/err" || RC=$?
check "an unparsable file elsewhere: the match is still found" "$RC:$(cat "$TMP/out")" "0:local_1111"
RC=0
env HUMAN_QUEUE_SESSIONS_DIR="$REG2" bash "$BIN/wake-target.sh" cli-bbb >"$TMP/out" 2>"$TMP/err" || RC=$?
check "no match and an unparsable file: exit 1" "$RC" "1"
check_contains "no match and an unparsable file: says so" "$(cat "$TMP/err")" "1 could not be read or parsed"
if [ "$(id -u)" != "0" ]; then
  chmod 000 "$REG2"
  RC=0
  env HUMAN_QUEUE_SESSIONS_DIR="$REG2" bash "$BIN/wake-target.sh" cli-aaa >/dev/null 2>"$TMP/err" || RC=$?
  chmod 700 "$REG2"
  check "a registry that cannot be listed: exit 1" "$RC" "1"
  check_contains "a registry that cannot be listed: says so" "$(cat "$TMP/err")" "cannot be listed"
  # A parent that may not be searched hides whether the registry exists:
  # "cannot tell" (exit 1), never a confident "nobody is running" (exit 3).
  LOCKED="$TMP/locked-parent"
  mkdir -p "$LOCKED/sessions"
  cp "$REG/$LIVE1.json" "$LOCKED/sessions/"
  chmod 000 "$LOCKED"
  RC=0
  env HUMAN_QUEUE_SESSIONS_DIR="$LOCKED/sessions" bash "$BIN/wake-target.sh" cli-aaa >/dev/null 2>"$TMP/err" || RC=$?
  chmod 700 "$LOCKED"
  check "a registry under an unsearchable parent: exit 1, not 3" "$RC" "1"
fi
: > "$TMP/not-a-dir"
RC=0
env HUMAN_QUEUE_SESSIONS_DIR="$TMP/not-a-dir" bash "$BIN/wake-target.sh" cli-aaa >/dev/null 2>"$TMP/err" || RC=$?
check "a registry path that is a file: exit 1" "$RC" "1"
wt
check "no id: exit 4" "$RC" "4"
wt ""
check "a blank id: exit 4" "$RC" "4"
wt a b
check "two ids: exit 4" "$RC" "4"
wt $'a\nb'
check "a multi-line id: exit 4" "$RC" "4"
wt --bogus
check "an unknown option: exit 4" "$RC" "4"
wt --help
check "--help: exit 0" "$RC" "0"
check_contains "--help documents exit 3" "$OUT" "no running session"
check_contains "--help documents exit 5" "$OUT" "has no messaging address"

# ------------------------------------------------------------- desk-tick.sh
printf '== desk-tick.sh\n'
TSTUB="$STUB_DIR/loopcli.sh"
# Answers from files: $STUB_DIR/status (control-status JSON), $STUB_DIR/tick-N
# (the N-th tick's JSON, else tick-default); `fail-N` makes the N-th call of
# any subcommand exit 7, and `refuse-N` makes it exit 4 the way
# `tick --session` refuses a session that is no longer the control session.
# Every call's arguments are appended to $STUB_DIR/args. The end-of-day
# sweep's `sweep due` (issue #1784; plan-offline.test.sh tests it) answers
# nothing here and is neither counted nor logged, so the numbers above keep
# naming the loop's own calls whatever the clock says.
cat > "$TSTUB" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = sweep ]; then exit 0; fi
n=$(( $(cat "$STUB_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_DIR/calls"
printf '%s\n' "$*" >> "$STUB_DIR/args"
if [ -f "$STUB_DIR/fail-$n" ]; then
  echo "human-queue: database unreachable (stub)" >&2
  exit 7
fi
if [ -f "$STUB_DIR/refuse-$n" ]; then
  echo "human-queue: tick: this session is not the registered control session (stub)" >&2
  exit 4
fi
case "$1" in
  control-status)
    if [ -f "$STUB_DIR/status-$n" ]; then cat "$STUB_DIR/status-$n"; else cat "$STUB_DIR/status"; fi
    ;;
  tick)
    if [ -f "$STUB_DIR/tick-$n" ]; then cat "$STUB_DIR/tick-$n"; else cat "$STUB_DIR/tick-default"; fi
    ;;
  wake-due)
    if [ -f "$STUB_DIR/due-$n" ]; then cat "$STUB_DIR/due-$n"
    elif [ -f "$STUB_DIR/due-default" ]; then cat "$STUB_DIR/due-default"
    else echo '[]'; fi
    ;;
esac
EOF
chmod +x "$TSTUB"
treset() { rm -f "$STUB_DIR"/calls "$STUB_DIR"/args "$STUB_DIR"/fail-* "$STUB_DIR"/refuse-* "$STUB_DIR"/status-* "$STUB_DIR"/tick-* "$STUB_DIR"/due-*; }
OURS='{"session": "desk-1", "last_tick_at": "2026-10-07T07:00:00Z", "tick_age_seconds": 1}'
THEIRS='{"session": "desk-2", "last_tick_at": null, "tick_age_seconds": null}'
MIXED='[{"id": "R-9", "kind": "review", "status": "open"}, {"id": "D-4", "kind": "decision", "status": "open"}, {"id": "D-2", "kind": "decision", "status": "answered"}, {"id": "D-7", "kind": "decision", "status": "open"}]'
DUE='[{"id": "D-9", "session": "s9", "failures": 1, "retry": 1}, {"id": "D-2", "session": "s2", "failures": 3, "retry": 3}, {"id": "R-1"}, {"id": "D-x"}]'

dtick() {
  RC=0
  env STUB_DIR="$STUB_DIR" HUMAN_QUEUE_CLI="$TSTUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

for SH in $SHELLS; do
  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '%s\n' "$MIXED" > "$STUB_DIR/tick-default"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check "[$SH] --once: open Decisions only, in tick order" "$RC:$OUT" "0:desk-tick g1 new D-4 D-7"
  check "[$SH] --once: ticks as its own control session, honoring the policy's interrupt rule" \
    "$(sed -n 2p "$STUB_DIR/args")" "tick --session desk-1 --interrupts everything"
  check "[$SH] --once: then asks which answers are due a retry" "$(sed -n 3p "$STUB_DIR/args")" "wake-due --json"

  # Retries (issue #1781): wake-due's Decision ids on a `retry` line, after
  # the `new` line, in its order.
  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '%s\n' "$MIXED" > "$STUB_DIR/tick-default"
  printf '%s\n' "$DUE" > "$STUB_DIR/due-default"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check "[$SH] --once: new, then retry" "$RC:$OUT" "0:desk-tick g1 new D-4 D-7
desk-tick g1 retry D-9 D-2"
  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '[]\n' > "$STUB_DIR/tick-default"
  printf '%s\n' "$DUE" > "$STUB_DIR/due-default"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check "[$SH] --once: a retry alone" "$RC:$OUT:$ERR" "0:desk-tick g1 retry D-9 D-2:"
  # wake-due fails after the tick moved the watermark: one error line, and
  # the tick's `new` line is still printed.
  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '%s\n' "$MIXED" > "$STUB_DIR/tick-default"
  : > "$STUB_DIR/fail-3"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check "[$SH] wake-due unreachable: an error line, then the tick's new line" "$RC:$OUT" \
    "0:desk-tick g1 error wake-due exit 7: human-queue: database unreachable (stub)
desk-tick g1 new D-4 D-7"
  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '[]\n' > "$STUB_DIR/tick-default"
  printf 'not json\n' > "$STUB_DIR/due-default"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check_contains "[$SH] unreadable wake-due output: an error line" "$OUT" "desk-tick g1 error wake-due exit 1"
  check_absent "[$SH] unreadable wake-due output: no retry line" "$OUT" "retry"

  # A registration between control-status and tick (issue #1779): tick
  # --session refuses (call 2), and the re-check (call 3) names another desk.
  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '%s\n' "$THEIRS" > "$STUB_DIR/status-3"
  printf '%s\n' "$MIXED" > "$STUB_DIR/tick-default"
  : > "$STUB_DIR/refuse-2"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check "[$SH] replaced between the calls: tick refuses, one replaced line" "$RC:$OUT" "0:desk-tick g1 replaced"
  check "[$SH] replaced between the calls: confirmed with control-status" "$(sed -n 3p "$STUB_DIR/args")" "control-status --json"

  # A refusal while this session is still the control session is an error,
  # never a reason to stop.
  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '%s\n' "$MIXED" > "$STUB_DIR/tick-default"
  : > "$STUB_DIR/refuse-2"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check_contains "[$SH] refused but still the desk: an error line" "$OUT" "desk-tick g1 error tick exit 4: human-queue: tick: this session is not"
  check_absent "[$SH] refused but still the desk: never replaced" "$OUT" "replaced"

  treset
  printf '[{"id": "R-9", "kind": "review", "status": "open"}, {"id": "D-2", "kind": "decision", "status": "answered"}]\n' > "$STUB_DIR/tick-default"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check "[$SH] --once: Reviews and answers print nothing" "$RC:$OUT:$ERR" "0::"
  printf '[]\n' > "$STUB_DIR/tick-default"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check "[$SH] --once: a quiet tick prints nothing" "$RC:$OUT:$ERR" "0::"

  treset
  printf '%s\n' "$THEIRS" > "$STUB_DIR/status"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check "[$SH] replaced: one line, exit 0" "$RC:$OUT" "0:desk-tick g1 replaced"
  check "[$SH] replaced: tick never ran" "$(cat "$STUB_DIR/calls")" "1"

  treset
  printf 'not json\n' > "$STUB_DIR/status"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check_contains "[$SH] unreadable control-status: an error line" "$OUT" "desk-tick g1 error control-status exit 1"
  check_absent "[$SH] unreadable control-status: never read as replaced" "$OUT" "replaced"

  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf 'not json\n' > "$STUB_DIR/tick-default"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check_contains "[$SH] unreadable tick output: an error line" "$OUT" "desk-tick g1 error tick exit 1"

  # The loop: sleep first; calls 1-2 fail (one error line), call 3 is the
  # status of cycle 2 ... then recovery with a new item, then replaced.
  #   cycle 1: control-status(1) fails           -> error line
  #   cycle 2: control-status(2) fails           -> nothing (same streak)
  #   cycle 3: control-status(3) ok, tick(4) new,
  #            wake-due(5) none                  -> recovered + new D-4 D-7
  #   cycle 4: control-status(6) replaced        -> replaced, exit 0
  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '%s\n' "$MIXED" > "$STUB_DIR/tick-default"
  : > "$STUB_DIR/fail-1"
  : > "$STUB_DIR/fail-2"
  printf '%s\n' "$THEIRS" > "$STUB_DIR/status-6"
  # perl's alarm bounds the loop, so a regression that never exits fails
  # this case instead of hanging the suite.
  dtick perl -e 'alarm 20; exec @ARGV' env HUMAN_QUEUE_TICK_SECONDS=1 "$SH" "$BIN/desk-tick.sh" \
    --session desk-1 --generation g2 --cadence 5
  EXPECTED="desk-tick g2 error control-status exit 7: human-queue: database unreachable (stub)
desk-tick g2 recovered
desk-tick g2 new D-4 D-7
desk-tick g2 replaced"
  check "[$SH] the loop: one error per streak, recovered, new, replaced" "$OUT" "$EXPECTED"
  check "[$SH] the loop exits 0 when replaced" "$RC" "0"

  # A zero-second override would call the store back-to-back: refused.
  # 900 s is the default 15-minute live-desk bound: the override obeys it too.
  for bad_secs in 0 00 3601 x 900; do
    treset
    dtick env HUMAN_QUEUE_TICK_SECONDS="$bad_secs" "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
    check "[$SH] HUMAN_QUEUE_TICK_SECONDS=$bad_secs: exit 4, nothing called" \
      "$RC:$(cat "$STUB_DIR/calls" 2>/dev/null || echo 0)" "4:0"
  done
  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '[]\n' > "$STUB_DIR/tick-default"
  dtick env HUMAN_QUEUE_TICK_SECONDS=899 "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --once
  check "[$SH] HUMAN_QUEUE_TICK_SECONDS=899: under the bound, ticks" "$RC:$OUT:$ERR" "0::"

  dtick "$SH" "$BIN/desk-tick.sh" --generation g1 --once
  check "[$SH] no --session: exit 4" "$RC" "4"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --once
  check "[$SH] no --generation: exit 4" "$RC" "4"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation 'g 1' --once
  check "[$SH] a generation with a space: exit 4" "$RC" "4"
  for bad_cadence in 0 61 x 007 -5 15; do
    dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --cadence "$bad_cadence" --once
    check "[$SH] --cadence $bad_cadence: exit 4" "$RC" "4"
  done
  # The cadence stays under the capture hook's live-desk bound (issue #1779):
  # 15 minutes by default, or what desk/policy.json sets.
  treset
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '[]\n' > "$STUB_DIR/tick-default"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --cadence 15 --once
  check_contains "[$SH] --cadence 15: names the live-desk bound" "$ERR" "shorter than the live-desk bound (15 min"
  check "[$SH] --cadence 15: nothing was called" "$(cat "$STUB_DIR/calls" 2>/dev/null || echo 0)" "0"
  dtick "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --cadence 14 --once
  check "[$SH] --cadence 14: under the default bound, ticks" "$RC:$OUT:$ERR" "0::"
  printf '{"live_desk_max_tick_age_min": 30}\n' > "$TMP/policy30.json"
  dtick env HUMAN_QUEUE_POLICY="$TMP/policy30.json" "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --cadence 20 --once
  check "[$SH] --cadence 20 under a 30-minute policy: ticks" "$RC:$OUT:$ERR" "0::"
  dtick env HUMAN_QUEUE_POLICY="$TMP/policy30.json" "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g1 --cadence 30 --once
  check_contains "[$SH] --cadence 30 under a 30-minute policy: refused" "$RC:$ERR" "4:desk-tick: --cadence must be shorter than the live-desk bound (30 min"
  dtick "$SH" "$BIN/desk-tick.sh" --help
  check "[$SH] --help: exit 0" "$RC" "0"
done

# Sleep-first: with a 2-second cadence, nothing is called in the first second.
treset
printf '%s\n' "$OURS" > "$STUB_DIR/status"
printf '[]\n' > "$STUB_DIR/tick-default"
env STUB_DIR="$STUB_DIR" HUMAN_QUEUE_CLI="$TSTUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_TICK_SECONDS=2 \
  bash "$BIN/desk-tick.sh" --session desk-1 --generation g3 >/dev/null 2>&1 </dev/null &
LOOP=$!
SLEEPERS="$SLEEPERS $LOOP"
sleep 1
check "the loop sleeps before its first tick" "$(cat "$STUB_DIR/calls" 2>/dev/null || echo 0)" "0"
kill "$LOOP" 2>/dev/null || true

# ------------------------------------------------------------------- skill
printf '== skill layout\n'
LINK="$REPO_ROOT/.claude/skills/desk"
if [ -L "$LINK" ]; then ok ".claude/skills/desk is a symlink"; else bad ".claude/skills/desk is not a symlink"; fi
check ".claude/skills/desk points at desk/skill, relatively" "$(readlink "$LINK")" "../../desk/skill"
if [ -f "$LINK/SKILL.md" ] && [ -f "$LINK/decisions.md" ]; then
  ok "SKILL.md and decisions.md resolve through the link"
else
  bad "SKILL.md or decisions.md does not resolve through the link"
fi
SKILL=$(cat "$HQ_T_DESK_DIR/skill/SKILL.md")
DECISIONS=$(cat "$HQ_T_DESK_DIR/skill/decisions.md")
check "SKILL.md frontmatter names the skill desk" "$(sed -n '2p' "$HQ_T_DESK_DIR/skill/SKILL.md")" "name: desk"
for needle in "register-control \"\$SID\"" 'desk-tick.sh' 'persistent: true' 'decisions.md' 'control-status --json' \
              'CLAUDE_CODE_SESSION_ID' '#1780' '#1781' 'shorter than the live-desk bound' '--cadence <N> --once'; do
  check_contains "SKILL.md: $needle" "$SKILL" "$needle"
done
# The reply reaches set-resolve through a quoted here-document, never inside
# the command's own quotes (an operator's `$(...)` must not run).
RESOLVE_LINE="set-resolve \"\$(cat \"\$REPLY_FILE\")\" --set <set_id> --json"
for needle in 'set-open' "$RESOLVE_LINE" "<<'DESK_REPLY'" 'human-queue: D-<k> answered' \
              'wake-target.sh' 'wake D-43 --result sent' '(Recommended)' 'SendMessage'; do
  check_contains "decisions.md: $needle" "$DECISIONS" "$needle"
done
# The prefix decisions.md prescribes is the one capture.py skips as a re-render.
check_contains "decisions.md prescribes the <n>. [D-<k>] prefix" "$DECISIONS" '`<n>. [D-<k>] <the item'"'"'s question>`'
RERENDER=$(python3 - "$HQ_T_DESK_DIR/hooks/capture.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cap", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
cases = ["1. [D-43] Ship it? (acme/widgets · issue-77)", "4. [D-7] x", "12. [D-1] y",
         "D-43 Ship it?", "1. D-43 Ship it?", "0. [D-4] z", "1.[D-4] z", "1. [R-4] z"]
print(" ".join("y" if mod.RERENDER_RE.match(c) else "n" for c in cases))
PY
)
check "capture.py's re-render prefix: the desk's shape only" "$RERENDER" "y y y n n n n n"

# Issue #1781: retries, parked answers, show, and history are routed and
# written down; nothing is left as "the next increment".
WAKEUPS=$(cat "$HQ_T_DESK_DIR/skill/wakeups.md")
HISTORY=$(cat "$HQ_T_DESK_DIR/skill/history.md")
# contract LABEL TEXT — every line of stdin must appear in TEXT. The needles
# come from quoted here-documents, so backticks and `$` stay literal.
contract() {
  local label="$1" text="$2" needle
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    check_contains "$label: $needle" "$text" "$needle"
  done
}
contract SKILL.md "$SKILL" <<'NEEDLES'
`wakeups.md`
`history.md`
desk-tick <GEN> retry D-43 D-44
**`show D-<n>`** or **`history`**
006_answer_parked.sql
never a state line nobody asked for
NEEDLES
check_absent "SKILL.md: no deferred increment left" "$SKILL" "next increment"
check_absent "SKILL.md: no 'until #1781 lands'" "$SKILL" "Until #1781 lands"
contract wakeups.md "$WAKEUPS" <<'NEEDLES'
"$HQ" wake-due --json --min-age 30
up to three times
## The parked notice (shown once)
`parked` is true on exactly one call
Never skip the record
hold the notice
`wake-due` sees only recorded wake-ups
Run the same `wake` command (same id, `--result`, and `--note`) again at once.
Never send the pointer again for it
NEEDLES
check_absent "wakeups.md: an unrecorded wake-up is not left to the next tick" "$WAKEUPS" "it is retried at the next tick"
contract history.md "$HISTORY" <<'NEEDLES'
"$HQ" show D-43; echo "exit=$?"
"$HQ" history; echo "exit=$?"
America/New_York
state line
history --date 2026-10-06
NEEDLES
contract decisions.md "$DECISIONS" <<'NEEDLES'
wake D-43 --result failed --note "no running session" --json
`wakeups.md`, "The parked notice"
an unrecorded attempt is neither counted nor retried
NEEDLES
check_absent "decisions.md: no 'No retry in this increment'" "$DECISIONS" "No retry in this increment"

hq_t_finish "desk-offline.test.sh"
