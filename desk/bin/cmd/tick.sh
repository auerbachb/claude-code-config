# shellcheck shell=bash
# summary: print the items new or changed since the last tick, as JSON
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh tick — the items new or changed since the last tick.

USAGE
  human-queue.sh tick

OUTPUT
  One JSON array of item objects, the same shape as `list --json`, in list
  order (parked first, then impact, then age); [] when nothing changed.
  Nothing on stderr on success.

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
  queues a question (desk/README.md, "Capture hook").

EXIT CODES
  0  ok (including when nothing changed)
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  a stray argument (before any connection attempt)
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
hq__tick_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:tick:' || :'hq_schema', 0)) AS hq_locked \gset
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
}

cmd_run() {
  local errf out rc
  if [ "$#" -gt 0 ]; then
    hq_die_validation "tick: unknown $(hq_flag_name "$1") (run human-queue.sh tick --help)"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__tick_sql | hq_db_script -At 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_fail_unmigrated "$rc" "$errf" "tick: the watermark was not moved" 'change_xid'
  fi
  if [ -z "$out" ]; then
    hq_die_error "tick: the store returned nothing"
  fi
  printf '%s\n' "$out"
}
