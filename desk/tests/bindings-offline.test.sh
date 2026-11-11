#!/usr/bin/env bash
# desk/tests/bindings-offline.test.sh — offline tests for the account-to-queue
# registry (issue #2183): desk/bin/lib/bindings.sh, the guard in desk-cli.sh,
# the capture hook's binding check, the bind / bindings / carry-over commands.
# No database: the store is a stub CLI (HUMAN_QUEUE_CLI) that logs every call
# with the HUMAN_QUEUE_SCHEMA it ran under. Every run gets only the environment
# written here (env -i), and the registry is a file in a temp directory
# (HUMAN_QUEUE_BINDINGS_FILE), so no real file under $HOME is read or written.
#
# Asserts:
#   guard       an unbound account: desk-cli.sh refuses (exit 4) with the
#               refusal sentence and the bind command, and the stub is never
#               called; a bound account runs under its own schema
#   isolation   two bound config directories each run under their own schema
#   bind        refuses a different queue without --rebind (before any store
#               contact); --rebind changes it; records names and schemas only
#   bindings    lists every account, prints no connection URL
#   env rule    HUMAN_QUEUE_SCHEMA=work is ignored; a hq_test_ schema is honored
#   hook        unbound: menu renders (empty stdout), one stderr line naming
#               the bind command, no store call; bound: queues under its schema
#   agreement   bash and python resolve the same config dir and row
#   corruption  a duplicate row fails closed (desk-cli exit 7, hook allows)
#   carry-over  --dry-run changes nothing; a real run binds the default
#               directory to public and the profile to its interim queue, then
#               removes only the interim settings entry, keeping other keys
#   modes       the registry directory is 700 and the file 600
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

BIN="$HQ_T_DESK_DIR/bin"
HOOK="$HQ_T_DESK_DIR/hooks/capture.sh"
DC="$BIN/desk-cli.sh"
LIB="$BIN/lib/bindings.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: bindings-offline.test.sh — python3 is not installed"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-bindings-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

MINPATH="/usr/bin:/bin"
T=$'\t'
HOMEDIR="$TMP/home"
mkdir -p "$HOMEDIR"
REG="$TMP/reg/bindings.tsv"
LOG="$TMP/stub.log"
STUB="$TMP/stub/human-queue.sh"
mkdir -p "$TMP/stub"
FAKE_URL="postgres://user:secret@db.invalid/neondb"
DIR_A="$TMP/acct-a"
DIR_B="$TMP/acct-b"
DIR_NEW="$TMP/acct-new"
mkdir -p "$DIR_A" "$DIR_B" "$DIR_NEW"

# The stub: logs HUMAN_QUEUE_SCHEMA and its arguments; answers the calls the
# desk makes. control-status reports a live desk when STUB_LIVE=1.
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s|%s\n' "${HUMAN_QUEUE_SCHEMA:-<unset>}" "$*" >>"$STUB_LOG"
case "${1:-}" in
  control-status)
    printf '{"session":"desk-1","tick_age_seconds":5}\n'
    ;;
  add) echo "D-7" ;;
  migrate) echo "nothing to apply" ;;
  register-control) echo "control session ${2:-?}" ;;
esac
exit 0
STUBEOF
chmod 755 "$STUB"

# run_env CLAUDE_CONFIG_DIR-or-empty -- ARGS...   (extra env via EXTRA array)
# Runs desk-cli.sh with only the environment written here.
dcli() {
  local cfg="$1"
  shift
  RC=0
  env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" \
    HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" \
    HUMAN_QUEUE_BINDINGS_FILE="$REG" ${cfg:+CLAUDE_CONFIG_DIR="$cfg"} \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    bash "$DC" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
  EXTRA_ENV=()
}

reset_log() { : >"$LOG"; }

# hqcli CLAUDE_CONFIG_DIR-or-empty -- ARGS...
# Runs human-queue.sh itself (bind, bindings) with the stub as its migrate
# seam. desk-cli.sh would exec the stub as the whole CLI, so it cannot be used
# for commands whose logic is the real script's.
hqcli() {
  local cfg="$1"
  shift
  RC=0
  env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" \
    HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" \
    HUMAN_QUEUE_BINDINGS_FILE="$REG" ${cfg:+CLAUDE_CONFIG_DIR="$cfg"} \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    bash "$BIN/human-queue.sh" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
  EXTRA_ENV=()
}

# hook_run CLAUDE_CONFIG_DIR SESSION  — the capture hook with one AskUserQuestion.
hook_run() {
  local cfg="$1" session="$2" input
  input=$(printf '{"session_id":"%s","cwd":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Ship it?","header":"Ship","options":[{"label":"Yes (Recommended)","description":"go"},{"label":"No"}],"multiSelect":false}]}}' "$session" "$TMP")
  RC=0
  env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" \
    HUMAN_QUEUE_CLI="$STUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" \
    HUMAN_QUEUE_BINDINGS_FILE="$REG" ${cfg:+CLAUDE_CONFIG_DIR="$cfg"} \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    bash "$HOOK" >"$TMP/hout" 2>"$TMP/herr" <<<"$input" || RC=$?
  HOUT=$(cat "$TMP/hout")
  HERR=$(cat "$TMP/herr")
  EXTRA_ENV=()
}

EXTRA_ENV=()
TEST_SCHEMA="hq_test_offline_$$"

# ------------------------------------------------------------- unbound guard
printf '== unbound account\n'
reset_log
dcli "$DIR_A" list
check "unbound: desk-cli exits 4" "$RC" "4"
check_contains "unbound: refusal sentence" "$ERR" "You can't run the desk here until you configure a queue for this account"
check_contains "unbound: names the bind command" "$ERR" "bind --name <name> --schema <schema>"
check_absent "unbound: no URL in output" "$OUT$ERR" "secret"
check "unbound: store never called" "$(cat "$LOG" 2>/dev/null | wc -l | tr -d ' ')" "0"

reset_log
dcli "$DIR_A" register-control desk-1
check "unbound: register-control refused, nothing registered" "$RC" "4"
check "unbound: no store call for register-control" "$(wc -l <"$LOG" | tr -d ' ')" "0"

reset_log
EXTRA_ENV=("HUMAN_QUEUE_SCHEMA=work")
dcli "$DIR_A" list
check "env rule: HUMAN_QUEUE_SCHEMA=work does not bypass the guard" "$RC" "4"

reset_log
EXTRA_ENV=("HUMAN_QUEUE_SCHEMA=$TEST_SCHEMA")
dcli "$DIR_A" list
check "env rule: a hq_test_ schema is honored for the throwaway tests" "$RC" "0"
check "env rule: the test schema reaches the CLI" "$(cut -d'|' -f1 "$LOG")" "$TEST_SCHEMA"

# ------------------------------------------------------------------- bind
printf '== bind\n'
reset_log
hqcli "" bind --name personal --schema alpha_queue --config-dir "$DIR_A"
check "bind: exits 0" "$RC" "0"
check_contains "bind: migrates the queue in its schema" "$(cat "$LOG")" "alpha_queue|migrate"
check_absent "bind: prints no URL" "$OUT$ERR" "secret"
check "bind: registry row written" "$(cut -f1-3 "$REG" | grep -c "^$DIR_A${T}personal${T}alpha_queue\$")" "1"

reset_log
hqcli "" bind --name work --schema beta_queue --config-dir "$DIR_B"
check "bind second account: exits 0" "$RC" "0"

reset_log
hqcli "" bind --name other --schema gamma_queue --config-dir "$DIR_A"
check "bind a bound account to another queue is refused" "$RC" "4"
check_contains "bind refusal names the current queue" "$ERR" "already bound to queue 'alpha_queue'"
check "bind refusal happens before any store contact" "$(wc -l <"$LOG" | tr -d ' ')" "0"
check "bind refusal leaves the registry unchanged" "$(grep -c "^$DIR_A$T" "$REG")" "1"

reset_log
hqcli "" bind --name other --schema gamma_queue --config-dir "$DIR_A" --rebind
check "bind --rebind changes the queue" "$RC" "0"
check "rebind: the row now names gamma_queue" "$(grep -c "^$DIR_A${T}other${T}gamma_queue\$" "$REG")" "1"
hqcli "" bind --name personal --schema alpha_queue --config-dir "$DIR_A" --rebind
check "rebind back to alpha_queue for the isolation checks" "$RC" "0"

hqcli "" bind --name bad/name --schema alpha_queue --config-dir "$DIR_NEW"
check "bind: an invalid name is refused (exit 4)" "$RC" "4"
hqcli "" bind --name ok --schema pg_catalog --config-dir "$DIR_NEW"
check "bind: a pg_ schema is refused (exit 4)" "$RC" "4"

# -------------------------------------------------------------- isolation
printf '== bound accounts\n'
reset_log
dcli "$DIR_A" list
check "bound A: desk-cli runs" "$RC" "0"
check "bound A: runs under its own queue" "$(cut -d'|' -f1 "$LOG")" "alpha_queue"

reset_log
dcli "$DIR_B" list
check "bound B: runs under its own queue" "$(cut -d'|' -f1 "$LOG")" "beta_queue"

reset_log
EXTRA_ENV=("HUMAN_QUEUE_SCHEMA=work")
dcli "$DIR_A" list
check "bound A: the env entry cannot redirect it" "$(cut -d'|' -f1 "$LOG")" "alpha_queue"

# ------------------------------------------------------------- bindings
printf '== bindings\n'
hqcli "$DIR_A" bindings
check "bindings: exits 0" "$RC" "0"
check_contains "bindings: lists account A" "$OUT" "$DIR_A"
check_contains "bindings: lists account B" "$OUT" "$DIR_B"
check_contains "bindings: shows the queue" "$OUT" "beta_queue"
check_contains "bindings: marks this account" "$OUT" "(this account)"
check_absent "bindings: no connection URL" "$OUT$ERR" "postgres://"
check_absent "bindings: no password" "$OUT$ERR" "secret"

# ---------------------------------------------------------------- hook
printf '== capture hook\n'
reset_log
hook_run "$DIR_NEW" worker-1
check "hook unbound: menu renders (empty stdout)" "$HOUT" ""
check "hook unbound: exit 0" "$RC" "0"
check_contains "hook unbound: one warning naming the bind command" "$HERR" "bind --name <name> --schema <schema>"
check "hook unbound: exactly one stderr line" "$(printf '%s\n' "$HERR" | grep -c .)" "1"
check "hook unbound: no store call at all" "$(wc -l <"$LOG" | tr -d ' ')" "0"

reset_log
EXTRA_ENV=("STUB_LIVE=1")
hook_run "$DIR_B" worker-1
check_contains "hook bound: a live desk queues the question (deny)" "$HOUT" "permissionDecision"
check "hook bound: its add runs under the account's queue" "$(grep '|add ' "$LOG" | cut -d'|' -f1 | sort -u)" "beta_queue"

# ------------------------------------------------------------ agreement
printf '== bash and python agree\n'
ROW_BASH=$(env -i HOME="$HOMEDIR" PATH="$MINPATH" CLAUDE_CONFIG_DIR="$DIR_A/" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  bash -c '. "$1"; d=$(hqb_config_dir) && hqb_lookup "$d" && printf "%s|%s|%s\n" "$d" "$HQB_NAME" "$HQB_SCHEMA"' _ "$LIB")
check "agreement: bash resolves the trailing-slash spelling to the bound row" "$ROW_BASH" "$DIR_A|personal|alpha_queue"
ROW_PY=$(env -i HOME="$HOMEDIR" PATH="$MINPATH" CLAUDE_CONFIG_DIR="$DIR_A/" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hq_capture", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
d = mod.config_dir()
name, schema = mod.lookup_binding(d)
print("%s|%s|%s" % (d, name, schema))
' "$HQ_T_DESK_DIR/hooks/capture.py")
check "agreement: python resolves the same row" "$ROW_PY" "$ROW_BASH"

# ---------------------------------------------------------- corruption
printf '== corrupt registry\n'
cp "$REG" "$REG.good"
printf '%s\tdup\tthird_queue\n' "$DIR_A" >>"$REG"
reset_log
dcli "$DIR_A" list
check "corrupt: a duplicate row fails closed in desk-cli (exit 7)" "$RC" "7"
check "corrupt: nothing reached the store" "$(wc -l <"$LOG" | tr -d ' ')" "0"
reset_log
EXTRA_ENV=("STUB_LIVE=1")
hook_run "$DIR_A" worker-1
check "corrupt: the hook allows the menu" "$RC" "0"
check "corrupt: the hook queues nothing" "$HOUT" ""
mv "$REG.good" "$REG"

# ---------------------------------------------------------- carry-over
printf '== carry-over\n'
PROFILE="$TMP/work-profile"
mkdir -p "$PROFILE"
printf '{\n  "model": "x",\n  "env": {"HUMAN_QUEUE_SCHEMA": "work", "OTHER": "kept"}\n}\n' >"$PROFILE/settings.json"
chmod 640 "$PROFILE/settings.json"

reset_log
RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" HUMAN_QUEUE_CLI="$STUB" \
  HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  bash "$BIN/human-queue.sh" carry-over --profile "$PROFILE" --dry-run >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "carry-over dry-run exits 0" "$RC" "0"
check_contains "carry-over dry-run plans the default directory" "$(cat "$TMP/out")" "would bind $HOMEDIR/.claude to queue public as personal"
check_contains "carry-over dry-run plans the profile" "$(cat "$TMP/out")" "would bind $PROFILE to queue work as work"
check "carry-over dry-run: the profile settings are untouched" "$(grep -c HUMAN_QUEUE_SCHEMA "$PROFILE/settings.json")" "1"
check "carry-over dry-run: no store call" "$(wc -l <"$LOG" | tr -d ' ')" "0"

# A profile with no interim entry is refused before anything is written.
mkdir -p "$TMP/bare-profile"
printf '{"env": {}}\n' >"$TMP/bare-profile/settings.json"
RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" HUMAN_QUEUE_CLI="$STUB" \
  HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  bash "$BIN/human-queue.sh" carry-over --profile "$TMP/bare-profile" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "carry-over refuses a profile with no interim entry (exit 4)" "$RC" "4"

# A profile already bound to another queue is refused in preflight, before any
# write: the registry keeps its row and the settings keep the interim entry.
CONFLICT_PROFILE="$TMP/conflict-profile"
mkdir -p "$CONFLICT_PROFILE"
printf '{"env": {"HUMAN_QUEUE_SCHEMA": "work"}}\n' >"$CONFLICT_PROFILE/settings.json"
printf '%s\tother\tdelta_queue\n' "$CONFLICT_PROFILE" >>"$REG"
REG_BEFORE=$(cat "$REG")
RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" HUMAN_QUEUE_CLI="$STUB" \
  HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  bash "$BIN/human-queue.sh" carry-over --profile "$CONFLICT_PROFILE" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "carry-over refuses a conflicting binding (exit 4)" "$RC" "4"
check "carry-over conflict: registry unchanged" "$(cat "$REG")" "$REG_BEFORE"
check "carry-over conflict: settings keep the interim entry" "$(grep -c HUMAN_QUEUE_SCHEMA "$CONFLICT_PROFILE/settings.json")" "1"

reset_log
RC=0
env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_LOG="$LOG" HUMAN_QUEUE_CLI="$STUB" \
  HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_BINDINGS_FILE="$REG" \
  bash "$BIN/human-queue.sh" carry-over --profile "$PROFILE" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "carry-over exits 0" "$RC" "0"
check "carry-over: the default directory is bound to public" "$(grep -c "^$HOMEDIR/.claude${T}personal${T}public\$" "$REG")" "1"
check "carry-over: the profile is bound to its interim queue" "$(grep -c "^$PROFILE${T}work${T}work\$" "$REG")" "1"
check "carry-over: the interim entry is removed" "$(grep -c HUMAN_QUEUE_SCHEMA "$PROFILE/settings.json")" "0"
check "carry-over: other settings keys are kept" "$(grep -c '"OTHER"' "$PROFILE/settings.json")" "1"
check "carry-over: the settings file keeps its mode" "$(stat -f '%Lp' "$PROFILE/settings.json" 2>/dev/null || stat -c '%a' "$PROFILE/settings.json")" "640"
check "carry-over: the store was migrated for both queues" "$(grep -c '|migrate' "$LOG")" "2"

# ------------------------------------------------------------ modes
printf '== modes\n'
check "modes: registry directory is 700" "$(stat -f '%Lp' "$(dirname "$REG")" 2>/dev/null || stat -c '%a' "$(dirname "$REG")")" "700"
check "modes: registry file is 600" "$(stat -f '%Lp' "$REG" 2>/dev/null || stat -c '%a' "$REG")" "600"

hq_t_finish "bindings-offline.test.sh"
