#!/usr/bin/env bash
# desk/tests/queue-owner-offline.test.sh — offline tests for the queue owner
# stamp (issue #2184): the owner subcommand's validation, the reserved state
# key, the binding name passed by desk-cli.sh and the capture hook, the test
# seam's name rule, bind's stamp call, the hook's one-line refusal, and the
# desk tick loop's stop. No database: the store is a stub CLI (HUMAN_QUEUE_CLI)
# that logs the schema and binding name of every call. Every run gets only the
# environment written here (env -i), and the registry is a file in a temp
# directory, so nothing under $HOME is read or written.
#
# The live half of the owner check (the SQL itself, in a throwaway schema) is
# desk/tests/queue-owner.test.sh.
#
# Asserts:
#   validation  owner get/set/transfer refuse bad arguments and bad names
#               (exit 4) and a secret-shaped name (exit 5), before connecting;
#               state set refuses queue_owner; a bad HUMAN_QUEUE_BINDING exits
#               4 before connecting
#   names       desk-cli.sh passes the registry's name as HUMAN_QUEUE_BINDING;
#               a hq_test_ name passes through the test seam, any other name
#               is cleared; an unnamed test call stays unnamed
#   bind        stamps the queue with the account's name through `owner set`
#               in the queue's own schema; a refused stamp writes no registry row
#   hook        a mismatch or an unstamped refusal from the store renders the
#               menu (empty stdout), prints exactly one warning line, and
#               passes the registry's name to the store
#   desk tick   a tick refused for ownership prints one `stopped` line and
#               exits 4, instead of retrying
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: queue-owner-offline.test.sh — python3 is not installed"
  exit 0
fi

BIN="$HQ_T_DESK_DIR/bin"
HOOK="$HQ_T_DESK_DIR/hooks/capture.sh"
DC="$BIN/desk-cli.sh"
DT="$BIN/desk-tick.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-queue-owner-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

MINPATH="/usr/bin:/bin"
HOMEDIR="$TMP/home"
mkdir -p "$HOMEDIR"
REG="$TMP/reg/bindings.tsv"
mkdir -p "$TMP/reg"
LOG="$TMP/stub.log"
: >"$LOG"
STUB="$TMP/stub/human-queue.sh"
mkdir -p "$TMP/stub"
FAKE_URL="postgres://user:secret@db.invalid/neondb"
DIR_A="$TMP/acct-a"
mkdir -p "$DIR_A"
T=$'\t'
ALNUM36="abcdefghijklmnopqrstuvwxyz0123456789"
FAKE_GH="gh""p_$ALNUM36"

# The stub logs `schema|binding|args` for every call. control-status reports
# the live control session desk-1. STUB_OWNER_MSG, when set, makes tick, add,
# and owner refuse with that line on stderr and exit 4 (the store's refusal).
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${HUMAN_QUEUE_SCHEMA:-<unset>}" "${HUMAN_QUEUE_BINDING:-<unset>}" "$*" >>"$STUB_LOG"
rc=0
case "${1:-}" in
  control-status)
    printf '{"session":"desk-1","tick_age_seconds":5}\n'
    ;;
  tick|add|owner)
    if [ "$1" = owner ] && [ "${2:-}" = get ] && [ -n "${STUB_OWNER_GET_ERR:-}" ]; then
      printf '%s\n' "$STUB_OWNER_GET_ERR" >&2
      rc=1
    elif [ "$1" = owner ] && [ "${2:-}" = get ] && [ -n "${STUB_OWNER_GET:-}" ]; then
      printf '%s\n' "$STUB_OWNER_GET"
    elif [ -n "${STUB_OWNER_MSG:-}" ] && ! { [ "$1" = owner ] && [ "${2:-}" = get ]; }; then
      printf '%s\n' "$STUB_OWNER_MSG" >&2
      rc=4
    elif [ "$1" = tick ]; then
      printf '[]\n'
    elif [ "$1" = add ]; then
      echo "D-7"
    fi
    ;;
  wake-due) printf '[]\n' ;;
  interrupt) printf '{"held":false}\n' ;;
  migrate) echo "nothing to apply" ;;
esac
exit "$rc"
STUBEOF
chmod 755 "$STUB"

# run_cli ARGS... — human-queue.sh itself, with the stub as the seam for the
# commands that would reach the store. Only the environment written here.
# Sets RC, OUT, ERR.
run_cli() {
  RC=0
  env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" \
    HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    bash "$BIN/human-queue.sh" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
  EXTRA_ENV=()
}

# run_dc ARGS... — desk-cli.sh, which execs the stub as the whole CLI.
run_dc() {
  RC=0
  env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" \
    HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" \
    HUMAN_QUEUE_BINDINGS_FILE="$REG" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    bash "$DC" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
  EXTRA_ENV=()
}

# run_hook SESSION — the capture hook with one AskUserQuestion, from DIR_A
# (its registry row, if any, comes from $REG). Sets RC, HOUT, HERR.
run_hook() {
  local session="$1" input
  input=$(printf '{"session_id":"%s","cwd":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Ship it?","header":"Ship","options":[{"label":"Yes (Recommended)","description":"go"},{"label":"No"}],"multiSelect":false}]}}' "$session" "$TMP")
  RC=0
  env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" \
    HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" \
    HUMAN_QUEUE_BINDINGS_FILE="$REG" CLAUDE_CONFIG_DIR="$DIR_A" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    bash "$HOOK" >"$TMP/hout" 2>"$TMP/herr" <<<"$input" || RC=$?
  HOUT=$(cat "$TMP/hout")
  HERR=$(cat "$TMP/herr")
  EXTRA_ENV=()
}

reset_log() { : >"$LOG"; }
last_log() { tail -n 1 "$LOG"; }

EXTRA_ENV=()

# ------------------------------------------------------------ validation
printf '== validation (before any store contact)\n'
EXTRA_ENV=()
run_cli owner
check "owner with no action exits 4" "$RC" "4"
run_cli owner frob
check "owner with an unknown action exits 4" "$RC" "4"
run_cli owner set
check "owner set with no NAME exits 4" "$RC" "4"
run_cli owner set "bad/name"
check "owner set with an invalid NAME exits 4" "$RC" "4"
check_contains "owner set names the NAME rule" "$ERR" "NAME must start with a letter or digit"
run_cli owner set "$FAKE_GH"
check "owner set with a secret-shaped NAME exits 5" "$RC" "5"
check_absent "owner set never echoes the secret-shaped NAME" "$ERR$OUT" "$FAKE_GH"
run_cli owner set personal --confirm
check "owner set refuses --confirm (only transfer takes it)" "$RC" "4"
run_cli owner transfer
check "owner transfer with no NAME exits 4" "$RC" "4"
run_cli owner get extra
check "owner get takes no arguments" "$RC" "4"
run_cli owner get --help
check "owner --help is offline and exits 0" "$RC" "0"
check_contains "owner --help documents transfer --confirm" "$OUT" "transfer NAME [--confirm]"
run_cli --help
check_contains "the subcommand list includes owner" "$OUT" "  owner"

EXTRA_ENV=("HUMAN_QUEUE_SCHEMA=hq_test_offline_owner")
reset_log
run_cli state set queue_owner personal
check "state set queue_owner is refused (exit 4)" "$RC" "4"
check_contains "state set queue_owner names owner set and transfer" "$ERR" "use owner set (first bind) or owner transfer"
run_cli state set queue_owner
check "state set queue_owner with no value is refused the same way" "$RC" "4"

EXTRA_ENV=("HUMAN_QUEUE_BINDING=bad name")
run_cli register-control desk-1
check "register-control with an invalid binding name exits 4" "$RC" "4"
check_contains "invalid binding name is named" "$ERR" "HUMAN_QUEUE_BINDING must be an account name"
EXTRA_ENV=("HUMAN_QUEUE_BINDING=bad/name")
run_cli add --kind decision --repo o/r --key k --question "Q?"
check "add with an invalid binding name exits 4" "$RC" "4"
EXTRA_ENV=("HUMAN_QUEUE_BINDING=$FAKE_GH")
run_cli register-control desk-1
check "a secret-shaped binding name exits 5 before connecting" "$RC" "5"
check_absent "a secret-shaped binding name is never echoed" "$ERR$OUT" "$FAKE_GH"
EXTRA_ENV=()

# ------------------------------------------------------------- names
printf '== the binding name reaches the store\n'
cat >"$REG" <<REGEOF
$DIR_A${T}personal${T}alpha_queue
REGEOF
chmod 600 "$REG"

reset_log
EXTRA_ENV=("CLAUDE_CONFIG_DIR=$DIR_A")
run_dc list
check "a registry account: desk-cli exits 0" "$RC" "0"
check "a registry account: the store sees its queue" "$(last_log | cut -d'|' -f1)" "alpha_queue"
check "a registry account: the store sees its name" "$(last_log | cut -d'|' -f2)" "personal"

reset_log
EXTRA_ENV=("CLAUDE_CONFIG_DIR=$DIR_A" "HUMAN_QUEUE_SCHEMA=hq_test_offline_names" "HUMAN_QUEUE_BINDING=hq_test_seam_name")
run_dc list
check "test seam: an hq_test_ name passes through" "$(last_log | cut -d'|' -f2)" "hq_test_seam_name"

reset_log
EXTRA_ENV=("CLAUDE_CONFIG_DIR=$DIR_A" "HUMAN_QUEUE_SCHEMA=hq_test_offline_names" "HUMAN_QUEUE_BINDING=personal")
run_dc list
check "test seam: a real-looking name is cleared, never honored" "$(last_log | cut -d'|' -f2)" "<unset>"

reset_log
EXTRA_ENV=("CLAUDE_CONFIG_DIR=$DIR_A" "HUMAN_QUEUE_SCHEMA=hq_test_offline_names")
run_dc list
check "test seam: an unnamed test call stays unnamed" "$(last_log | cut -d'|' -f2)" "<unset>"

# ------------------------------------------------------------- bind
printf '== bind stamps the queue\n'
reset_log
rm -f "$REG"
RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" \
  HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  bash "$BIN/human-queue.sh" bind --name personal --schema alpha_queue --config-dir "$DIR_A" \
  >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "bind exits 0" "$RC" "0"
check_contains "bind migrates in the queue's schema" "$(cat "$LOG")" "alpha_queue|<unset>|migrate"
check_contains "bind stamps the queue with the name, in its own schema" "$(cat "$LOG")" "alpha_queue|<unset>|owner set personal"
check "bind records the registry row after the stamp" "$(cut -f1-3 "$REG" | grep -c "^$DIR_A${T}personal${T}alpha_queue\$")" "1"

reset_log
rm -f "$REG"
RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" STUB_OWNER_MSG="human-queue: owner set: this queue belongs to 'work'; it cannot be set to 'personal'" \
  HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  bash "$BIN/human-queue.sh" bind --name personal --schema alpha_queue --config-dir "$DIR_A" \
  >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "bind refused by the owner check exits 4" "$RC" "4"
check_contains "bind refusal says nothing was recorded" "$(cat "$TMP/err")" "nothing was recorded"
check "bind refusal writes no registry row" "$(test -e "$REG" && grep -c "^$DIR_A$T" "$REG" || echo 0)" "0"

reset_log
rm -f "$REG"
RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" STUB_OWNER_GET="another_owner" \
  HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  bash "$BIN/human-queue.sh" bind --name personal --schema alpha_queue --config-dir "$DIR_A" \
  >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "bind of a queue owned by another name exits 4 before migrating" "$RC" "4"
check_contains "that refusal names the owner it found" "$(cat "$TMP/err")" "belongs to 'another_owner', not 'personal'"
check "that bind did not migrate the queue" "$(grep -c 'alpha_queue|<unset>|migrate' "$LOG")" "0"
check "that bind wrote no registry row" "$(test -e "$REG" && grep -c "^$DIR_A$T" "$REG" || echo 0)" "0"

# bind fails closed when the owner cannot be read (a real SQL error, not an
# unmigrated schema): nothing is migrated or recorded.
printf '== bind fails closed when the owner cannot be read\n'
reset_log
rm -f "$REG"
RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" STUB_OWNER_GET_ERR='ERROR:  permission denied for table state' \
  HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  bash "$BIN/human-queue.sh" bind --name personal --schema alpha_queue --config-dir "$DIR_A" \
  >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "bind exits nonzero when the owner read fails" "$RC" "1"
check_contains "that bind says the owner could not be read" "$(cat "$TMP/err")" "could not read the owner of 'alpha_queue'"
check "that bind did not migrate the queue" "$(grep -c 'alpha_queue|<unset>|migrate' "$LOG")" "0"
check "that bind did not stamp the queue" "$(grep -c 'owner set' "$LOG")" "0"
check "that bind wrote no registry row" "$(test -e "$REG" && grep -c "^$DIR_A$T" "$REG" || echo 0)" "0"

# A schema with no state table yet is still migrated: the owner read says
# "does not exist" and bind goes on to create it.
printf '== bind migrates a schema with no state table yet\n'
reset_log
rm -f "$REG"
RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" STUB_OWNER_GET_ERR='ERROR:  relation "state" does not exist' \
  HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  bash "$BIN/human-queue.sh" bind --name personal --schema alpha_queue --config-dir "$DIR_A" \
  >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "bind on an unmigrated schema exits 0" "$RC" "0"
check_contains "bind on an unmigrated schema migrates" "$(cat "$LOG")" "alpha_queue|<unset>|migrate"

# The test seam accepts a 64-character hq_test_ name, the registry's limit.
printf '== the test seam honors a 64-character hq_test_ name\n'
NAME64="hq_test_$(printf 'a%.0s' $(seq 1 56))"
SEAM_OUT=$(env -i PATH="$MINPATH" HUMAN_QUEUE_BINDING="$NAME64" python3 -I -c "import sys; sys.path.insert(0, '$HQ_T_DESK_DIR/hooks'); import capture; print(capture.test_binding())" </dev/null 2>"$TMP/seam_err" || true)
check "a 64-character hq_test_ name passes the seam" "$SEAM_OUT" "$NAME64"
SEAM_OUT=$(env -i PATH="$MINPATH" HUMAN_QUEUE_BINDING="${NAME64}a" python3 -I -c "import sys; sys.path.insert(0, '$HQ_T_DESK_DIR/hooks'); import capture; print(capture.test_binding())" </dev/null 2>"$TMP/seam_err" || true)
check "a 65-character hq_test_ name is cleared by the seam" "$SEAM_OUT" ""

# ------------------------------------------------------------- hook
printf '== the capture hook on a refusal\n'
cat >"$REG" <<REGEOF
$DIR_A${T}personal${T}alpha_queue
REGEOF
chmod 600 "$REG"

reset_log
EXTRA_ENV=("STUB_OWNER_MSG=human-queue: add: this queue belongs to 'work'; this caller is bound as 'personal', so nothing was written")
run_hook "other-session"
check "hook mismatch: exit 0" "$RC" "0"
check "hook mismatch: the menu renders (empty stdout)" "$HOUT" ""
check "hook mismatch: exactly one warning line" "$(printf '%s\n' "$HERR" | grep -c .)" "1"
check_contains "hook mismatch: the warning names the queue owner" "$HERR" "queue"
check "hook mismatch: the store saw the registry name" "$(last_log | cut -d'|' -f2)" "personal"

reset_log
EXTRA_ENV=("STUB_OWNER_MSG=human-queue: add: this queue has no owner yet; only bind records one, and nothing was written")
run_hook "other-session"
check "hook unstamped: exit 0" "$RC" "0"
check "hook unstamped: the menu renders (empty stdout)" "$HOUT" ""
check "hook unstamped: exactly one warning line" "$(printf '%s\n' "$HERR" | grep -c .)" "1"

reset_log
EXTRA_ENV=()
run_hook "other-session"
check "hook match: the question is queued and the menu is denied" "$(printf '%s' "$HOUT" | grep -c 'permissionDecision')" "1"
check "hook match: the store saw the registry name" "$(last_log | cut -d'|' -f2)" "personal"

# ------------------------------------------------------------- desk tick
printf '== desk tick stops on an ownership refusal\n'
reset_log
RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" \
  HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_SCHEMA=hq_test_offline_tick \
  HUMAN_QUEUE_BINDING=hq_test_offline_tick STUB_OWNER_MSG="human-queue: tick: this queue belongs to 'work'; this caller is bound as 'personal', so nothing was read" \
  bash "$DT" --session desk-1 --generation g1 --once >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "desk tick: an ownership refusal exits 4" "$RC" "4"
check "desk tick: exactly one stopped line" "$(grep -c 'desk-tick g1 stopped' "$TMP/out")" "1"
check_contains "desk tick: the stopped line names both sides" "$(cat "$TMP/out")" "this queue belongs to 'work'"
check "desk tick: no error line is printed for it" "$(grep -c ' error ' "$TMP/out")" "0"

RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" \
  HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_SCHEMA=hq_test_offline_tick \
  HUMAN_QUEUE_BINDING=hq_test_offline_tick \
  bash "$DT" --session desk-1 --generation g2 --once >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "desk tick: a healthy tick still exits 0" "$RC" "0"
check "desk tick: a healthy tick prints nothing" "$(cat "$TMP/out")" ""

hq_t_finish "queue-owner-offline.test.sh"
