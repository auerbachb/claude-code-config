#!/usr/bin/env bash
# desk/tests/cli.test.sh — offline contract tests for desk/bin/human-queue.sh
# (issue #1774). Needs no database and never connects to one: every "reachable"
# target here is a stub psql, a .invalid name, a refused local port, or a
# TEST-NET address. Runs in CI through .github/scripts/run-hook-tests.sh.
#
# Asserts:
#   - help is offline: `--help` and `migrate --help` exit 0 with the URL unset
#   - usage/validation errors exit 4, BEFORE any connection attempt (they
#     return instantly even when the URL points at a black hole)
#   - unset, malformed, or unsupported URL: exit 7, one stderr line
#   - unreachable database: exit 7 in under two seconds, one stderr line —
#     with a stub psql that hangs (deterministic) and, when a real psql is
#     installed, with a bogus .invalid host and a TEST-NET address
#   - the URL is parsed into libpq env for the psql child only: percent-decoded,
#     never on psql's argv, and the password never appears in any output
#   - a misnamed schema file exits 1 naming it
#   - the live suite skips with a notice and exits 0 when the URL is unset
#
# Every case runs under `bash` on PATH and, when /bin/bash is 3.x (macOS),
# under /bin/bash too, because the CLI must work on both.
set -uo pipefail

# shellcheck source=lib/testlib.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testlib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-cli-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FAKE_PW='hunter2-SECRET-pw'
BLACKHOLE_URL="postgresql://u:${FAKE_PW}@192.0.2.1:5432/db?sslmode=require"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

REAL_PSQL=""
if [ -x /opt/homebrew/bin/psql ]; then
  REAL_PSQL=/opt/homebrew/bin/psql
elif command -v psql >/dev/null 2>&1; then
  REAL_PSQL=$(command -v psql)
fi

# Stub psql that hangs: the watchdog must kill it.
cat > "$TMP/psql-hang" <<'EOF'
#!/bin/sh
exec sleep 10
EOF
# Stub psql that records what the probe saw, then fails like an unreachable
# server (exit 2) so the CLI stops after the probe.
cat > "$TMP/psql-record" <<'EOF'
#!/bin/sh
{
  printf 'argv:'
  for a in "$@"; do printf ' [%s]' "$a"; done
  printf '\n'
  printf 'PGHOST=%s\n' "${PGHOST-<unset>}"
  printf 'PGPORT=%s\n' "${PGPORT-<unset>}"
  printf 'PGUSER=%s\n' "${PGUSER-<unset>}"
  printf 'PGDATABASE=%s\n' "${PGDATABASE-<unset>}"
  printf 'PGSSLMODE=%s\n' "${PGSSLMODE-<unset>}"
  printf 'PGCHANNELBINDING=%s\n' "${PGCHANNELBINDING-<unset>}"
  printf 'PGCONNECT_TIMEOUT=%s\n' "${PGCONNECT_TIMEOUT-<unset>}"
  printf 'PGSERVICE=%s\n' "${PGSERVICE-<unset>}"
  if [ "${PGPASSWORD-}" = "$STUB_EXPECT_PW" ]; then
    printf 'PGPASSWORD=match\n'
  else
    printf 'PGPASSWORD=mismatch\n'
  fi
} > "$STUB_RECORD"
exit 2
EOF
chmod +x "$TMP/psql-hang" "$TMP/psql-record"

# run_cli SHELL [VAR=value | -u VAR]... -- ARGS...
# Runs the CLI under SHELL with an adjusted environment; sets OUT, ERR, RC,
# ELAPSED_START/ELAPSED_END.
run_cli() {
  local sh="$1"
  shift
  local -a envargs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envargs[${#envargs[@]}]="$1"
    shift
  done
  shift
  ELAPSED_START=$(hq_t_now)
  RC=0
  env ${envargs[@]+"${envargs[@]}"} "$sh" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  ELAPSED_END=$(hq_t_now)
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="

  # --- help is offline -----------------------------------------------------
  run_cli "$SH" -u HUMAN_QUEUE_DATABASE_URL -- --help
  check "[$SH] --help exits 0 without a database" "$RC" "0"
  check_contains "[$SH] --help lists the migrate subcommand" "$OUT" "migrate"
  check_contains "[$SH] --help states exit code 7" "$OUT" "7  database unset"
  check "[$SH] --help writes nothing to stderr" "$ERR" ""

  run_cli "$SH" -u HUMAN_QUEUE_DATABASE_URL -- migrate --help
  check "[$SH] migrate --help exits 0 without a database" "$RC" "0"
  check_contains "[$SH] migrate --help documents the ledger" "$OUT" "schema_migrations"

  # --- validation before connection (exit 4) ------------------------------
  # The URL is a black hole: a connection attempt would take 1.5 s, so a
  # sub-second exit 4 proves validation ran first.
  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=$BLACKHOLE_URL" --
  check "[$SH] no subcommand exits 4" "$RC" "4"
  check "[$SH] no subcommand: one stderr line" "$(hq_t_lines "$ERR")" "1"

  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=$BLACKHOLE_URL" -- no-such-cmd
  check "[$SH] unknown subcommand exits 4" "$RC" "4"
  check_contains "[$SH] unknown subcommand is named" "$ERR" "no-such-cmd"
  if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 1.0; then
    ok "[$SH] unknown subcommand rejected without connecting"
  else
    bad "[$SH] unknown subcommand took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s — it tried to connect"
  fi

  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=$BLACKHOLE_URL" -- ../lib/common
  check "[$SH] path-like subcommand exits 4" "$RC" "4"

  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=$BLACKHOLE_URL" -- migrate extra-arg
  check "[$SH] migrate with a stray argument exits 4" "$RC" "4"
  if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 1.0; then
    ok "[$SH] stray argument rejected without connecting"
  else
    bad "[$SH] stray argument took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s — it tried to connect"
  fi

  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=$BLACKHOLE_URL" "HUMAN_QUEUE_SCHEMA=Bad-Name" -- migrate
  check "[$SH] invalid HUMAN_QUEUE_SCHEMA exits 4" "$RC" "4"
  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=$BLACKHOLE_URL" "HUMAN_QUEUE_SCHEMA=pg_catalog" -- migrate
  check "[$SH] pg_* HUMAN_QUEUE_SCHEMA exits 4" "$RC" "4"

  # --- unset / unusable URL (exit 7, one line) ----------------------------
  run_cli "$SH" -u HUMAN_QUEUE_DATABASE_URL -- migrate
  check "[$SH] unset URL exits 7" "$RC" "7"
  check "[$SH] unset URL: exactly one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$SH] unset URL: nothing on stdout" "$OUT" ""
  check_contains "[$SH] unset URL names the variable" "$ERR" "HUMAN_QUEUE_DATABASE_URL is not set"

  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=" -- migrate
  check "[$SH] empty URL exits 7" "$RC" "7"

  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=mysql://u:${FAKE_PW}@h/db" -- migrate
  check "[$SH] non-postgres URL exits 7" "$RC" "7"
  check "[$SH] non-postgres URL: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check_absent "[$SH] non-postgres URL: password not echoed" "$OUT$ERR" "$FAKE_PW"

  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=postgresql://u:${FAKE_PW}@h1,h2/db" -- migrate
  check "[$SH] multi-host URL exits 7" "$RC" "7"

  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=postgresql://u:${FAKE_PW}@h/db?bogus=1" -- migrate
  check "[$SH] unsupported URL parameter exits 7" "$RC" "7"
  check_contains "[$SH] unsupported parameter is named" "$ERR" "bogus"

  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=postgresql://u:bad%zzescape@h/db" -- migrate
  check "[$SH] malformed percent-escape exits 7" "$RC" "7"

  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=$BLACKHOLE_URL" "HUMAN_QUEUE_PSQL=$TMP/no-such-psql" -- migrate
  check "[$SH] missing psql override exits 7" "$RC" "7"

  # --- unreachable: exit 7 within two seconds -----------------------------
  run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=$BLACKHOLE_URL" "HUMAN_QUEUE_PSQL=$TMP/psql-hang" -- migrate
  check "[$SH] hanging psql: exit 7" "$RC" "7"
  check "[$SH] hanging psql: exactly one stderr line" "$(hq_t_lines "$ERR")" "1"
  if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 2.0; then
    ok "[$SH] hanging psql: returned in $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s (< 2s)"
  else
    bad "[$SH] hanging psql: took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s (limit 2s)"
  fi

  # --- the URL reaches psql as env, never argv ----------------------------
  run_cli "$SH" \
    "HUMAN_QUEUE_DATABASE_URL=postgresql://us%40er:p%40ss%2Fw0rd%25x@db.example.test:6543/my%20db?sslmode=require&channel_binding=require" \
    "HUMAN_QUEUE_PSQL=$TMP/psql-record" \
    "STUB_RECORD=$TMP/record" \
    "STUB_EXPECT_PW=p@ss/w0rd%x" \
    "PGSERVICE=ambient-service-must-be-cleared" \
    -- migrate
  check "[$SH] probe failure (psql exit 2) maps to exit 7" "$RC" "7"
  REC=$(cat "$TMP/record" 2>/dev/null || true)
  check_contains "[$SH] host reaches psql as PGHOST" "$REC" "PGHOST=db.example.test"
  check_contains "[$SH] port reaches psql as PGPORT" "$REC" "PGPORT=6543"
  check_contains "[$SH] user is percent-decoded" "$REC" "PGUSER=us@er"
  check_contains "[$SH] dbname is percent-decoded" "$REC" "PGDATABASE=my db"
  check_contains "[$SH] sslmode reaches psql" "$REC" "PGSSLMODE=require"
  check_contains "[$SH] channel_binding reaches psql" "$REC" "PGCHANNELBINDING=require"
  check_contains "[$SH] connect timeout is set" "$REC" "PGCONNECT_TIMEOUT=2"
  check_contains "[$SH] ambient PGSERVICE is cleared" "$REC" "PGSERVICE=<unset>"
  check_contains "[$SH] password is percent-decoded into PGPASSWORD" "$REC" "PGPASSWORD=match"
  ARGV_LINE=$(grep '^argv:' "$TMP/record" 2>/dev/null || true)
  check_absent "[$SH] password never on psql argv (decoded)" "$ARGV_LINE" "p@ss"
  check_absent "[$SH] password never on psql argv (encoded)" "$ARGV_LINE" "p%40ss"
  check_absent "[$SH] URL never on psql argv" "$ARGV_LINE" "postgresql://"
  check_absent "[$SH] password never in CLI output" "$OUT$ERR" "p@ss"
  rm -f "$TMP/record"

  if [ -n "$REAL_PSQL" ]; then
    run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=postgresql://u:${FAKE_PW}@hq-bogus-host.invalid/db?sslmode=require" -- migrate
    check "[$SH] bogus .invalid host: exit 7" "$RC" "7"
    check "[$SH] bogus .invalid host: exactly one stderr line" "$(hq_t_lines "$ERR")" "1"
    if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 2.0; then
      ok "[$SH] bogus .invalid host: returned in $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s (< 2s)"
    else
      bad "[$SH] bogus .invalid host: took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s (limit 2s)"
    fi
    check_absent "[$SH] bogus host: password never in output" "$OUT$ERR" "$FAKE_PW"

    run_cli "$SH" "HUMAN_QUEUE_DATABASE_URL=$BLACKHOLE_URL" -- migrate
    check "[$SH] TEST-NET (black hole) host: exit 7" "$RC" "7"
    check "[$SH] TEST-NET host: exactly one stderr line" "$(hq_t_lines "$ERR")" "1"
    if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 2.0; then
      ok "[$SH] TEST-NET host: returned in $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s (< 2s)"
    else
      bad "[$SH] TEST-NET host: took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s (limit 2s)"
    fi
    check_absent "[$SH] TEST-NET host: password never in output" "$OUT$ERR" "$FAKE_PW"
  else
    echo "SKIP: [$SH] no psql installed — real-client unreachable cases skipped (stub cases above still ran)"
  fi
done

# --- a misnamed schema file is a packaging error (exit 1) ------------------
mkdir -p "$TMP/tree/desk"
cp -R "$HQ_T_DESK_DIR/bin" "$HQ_T_DESK_DIR/schema" "$TMP/tree/desk/"
: > "$TMP/tree/desk/schema/2_missing_digits.sql"
RC=0
ERR=$(env -u HUMAN_QUEUE_DATABASE_URL bash "$TMP/tree/desk/bin/human-queue.sh" migrate 2>&1 >/dev/null) || RC=$?
check "misnamed schema file exits 1" "$RC" "1"
check_contains "misnamed schema file is named" "$ERR" "2_missing_digits.sql"

# --- the live suite skips cleanly without a URL (Test Plan 5.3) ------------
RC=0
OUT=$(env -u HUMAN_QUEUE_DATABASE_URL bash "$HQ_T_TESTS_DIR/migrate.test.sh" 2>&1) || RC=$?
check "live suite exits 0 when HUMAN_QUEUE_DATABASE_URL is unset" "$RC" "0"
check_contains "live suite prints a skip notice" "$OUT" "SKIP:"

hq_t_finish "cli.test.sh"
