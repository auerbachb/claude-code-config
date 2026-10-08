# shellcheck shell=bash
# summary: print the items new or changed since the last tick, as JSON
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"
# shellcheck source=../lib/interrupts.sh
. "$HQ_BIN_DIR/lib/interrupts.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh tick — the items new or changed since the last tick.

USAGE
  human-queue.sh tick [--session SESSION [--interrupts RULE]]

ARGUMENTS
  --session SESSION  tick only as the registered control session (issue
                     #1779): checked inside the tick's own transaction,
                     holding register-control's lock, so a desk that another
                     session has just replaced can never consume the change
                     feed. When SESSION is not the control session, nothing
                     is read, the watermark is not moved, tick_at is not
                     stamped, and the exit is 4. Without it, any caller ticks.
  --interrupts RULE  honor the operator's interrupt rule (issue #1783; see
                     `interrupt --help`): RULE (everything or away) is the
                     default when SESSION has set none, and the desk passes
                     desk/policy.json's interrupt_rule. Needs --session. While
                     the rule in force holds items back (away, or a focus
                     whose time has not come), the tick stamps tick_at, so
                     the desk stays live and worker questions are still
                     queued, prints [], and does not read or move the
                     watermark: the first tick after the hold reports
                     everything that changed during it, in the usual order.

OUTPUT
  One JSON array of item objects, the same shape as `list --json`, in list
  order (parked first, then impact, then age); [] when nothing changed, or
  while --interrupts holds items back. Nothing on stderr on success.

WHAT COUNTS AS A CHANGE
  An item is reported when its row was written: created by add, bumped,
  refreshed by a repeated add, answered, acknowledged, reviewed, or flagged.
  comment, feedback, and set-open's `shown` events are annotations the desk
  writes itself; they do not report the item again. The first tick ever (no
  watermark yet) reports every item.

THE WATERMARK
  Each tick stores, under the reserved state key tick_watermark, the database
  snapshot it read under, and reports exactly the items whose last write that
  stored snapshot could not see. So a tick reports every write that committed
  after the previous tick read, including a write whose transaction was
  already running then and committed later, and it never reports the same
  write twice. (A time watermark cannot promise that: a transaction's
  timestamp is its start, so one that commits after a tick can carry a time
  older than that tick.) Concurrent ticks are serialized; each write is
  reported by exactly one of them.

THE TICK TIME
  Each tick also stores its own time, UTC ISO 8601, under the reserved state
  key tick_at. `control-status` reads it: a control session that has ticked
  recently is a live desk, which is what the capture hook checks before it
  queues a question (desk/README.md, "Capture hook"). Registering a
  different control session clears it, so only a tick after that counts.

EXIT CODES
  0  ok (including when nothing changed)
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  a stray argument, a bad --session, or --interrupts without --session
     or with a rule other than everything or away (before any connection
     attempt); --session names a session that is not the registered control
     session (after connecting, nothing read or written)
  5  the --session value looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# One statement after the lock, so the stored snapshot is exactly the one the
# items were read under: under READ COMMITTED a statement reads with one
# snapshot, pg_current_snapshot() returns that snapshot, and the lock is taken
# in the statement before, so this statement sees what the previous tick
# committed. `prev` reads the old watermark before `mark` replaces it (a
# statement never sees its own writes). `stamp` records when this tick read,
# a different row of the same table, for control-status (issue #1755).
#
# hq__tick_sql GUARD [HOLD] — GUARD 1 (tick --session) first takes
# register-control's own advisory lock, after the tick lock (register-control
# never takes the tick lock, so the order cannot deadlock), then compares
# control_session with :'hq_session'. Holding that lock until commit, no
# registration can land between the check and the read: either it committed
# before (the check sees it) or it waits for this tick to commit (issue
# #1779). HOLD 1 (tick --interrupts) then reads the session's interrupt rule
# under the same locks; while it holds items back, only tick_at is stamped
# (issue #1783).
hq__tick_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:tick:' || :'hq_schema', 0)) AS hq_locked \gset
SQL
  if [ "$1" -eq 1 ]; then
    cat <<'SQL'
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:control:' || :'hq_schema', 0)) AS hq_control_locked \gset
SELECT coalesce((SELECT value FROM state WHERE key = 'control_session'), '') = :'hq_session' AS hq_ok \gset
\if :hq_ok
SQL
  fi
  if [ "${2:-0}" -eq 1 ]; then
    printf 'SELECT held AS hq_held FROM (\n'
    hq_sql_interrupt_row
    cat <<'SQL'
) ir \gset
\if :hq_held
INSERT INTO state (key, value)
  VALUES ('tick_at', to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SELECT '[]';
\else
SQL
  fi
  cat <<'SQL'
WITH prev AS (
  SELECT value::pg_snapshot AS snap FROM state WHERE key = 'tick_watermark'
), mark AS (
  INSERT INTO state (key, value) VALUES ('tick_watermark', pg_current_snapshot()::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
), stamp AS (
  INSERT INTO state (key, value)
    VALUES ('tick_at', to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
)
SQL
  printf 'SELECT coalesce(jsonb_agg(%s ORDER BY\n' "$(hq_sql_item_json)"
  hq_sql_item_order
  cat <<'SQL'
), '[]'::jsonb)
  FROM items i
 WHERE NOT EXISTS (SELECT 1 FROM prev)
    OR NOT pg_visible_in_snapshot(i.change_xid, (SELECT snap FROM prev));
SQL
  if [ "${2:-0}" -eq 1 ]; then
    printf '%s\n' '\endif'
  fi
  if [ "$1" -eq 1 ]; then
    cat <<'SQL'
\else
SELECT '!this session is not the registered control session; nothing was read and the watermark was not moved';
\endif
SQL
  fi
}

cmd_run() {
  local errf out rc session="" guard=0 hold=0 default_rule=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --session)
        if [ "$guard" -eq 1 ]; then hq_die_validation "tick: --session given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "tick: --session needs a value"; fi
        guard=1
        session="$2"
        shift 2
        ;;
      --interrupts)
        if [ "$hold" -eq 1 ]; then hq_die_validation "tick: --interrupts given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "tick: --interrupts needs a value"; fi
        hold=1
        default_rule="$2"
        shift 2
        ;;
      *) hq_die_validation "tick: unknown $(hq_flag_name "$1") (run human-queue.sh tick --help)" ;;
    esac
  done
  if [ "$hold" -eq 1 ]; then
    if ! hq_interrupt_rule_ok "$default_rule"; then
      hq_die_validation "tick: --interrupts must be everything or away"
    fi
    if [ "$guard" -eq 0 ]; then
      hq_die_validation "tick: --interrupts needs --session (the interrupt rule belongs to the desk session)"
    fi
  fi
  if [ "$guard" -eq 1 ]; then
    hq_check_text "tick: the session id" "$session" 200
    # The session id reaches psql's argv: a secret-shaped one stops here.
    hq_refuse_secret "tick: the session id" "$session"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__tick_sql "$guard" "$hold" | hq_db_script -At -v "hq_session=$session" \
          -v "hq_default=$default_rule" -v "hq_tz=$(hq_desk_tz)" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_fail_unmigrated "$rc" "$errf" "tick: the watermark was not moved" 'change_xid'
  fi
  hq_problem_check tick "$out"
  if [ -z "$out" ]; then
    hq_die_error "tick: the store returned nothing"
  fi
  printf '%s\n' "$out"
}
