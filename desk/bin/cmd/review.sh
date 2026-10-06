# shellcheck shell=bash
# summary: mark a Review as reviewed by the operator (a `reviewed` event)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh review — mark a Review as reviewed.

USAGE
  human-queue.sh review ID

ARGUMENTS
  ID  a Review id, for example R-88 (r-88 is accepted). Decisions (D-n) are
      answered, not reviewed.

BEHAVIOR
  The item's status becomes `reviewed` and one `reviewed` event is recorded,
  in one transaction. The item is kept. A flagged Review can be reviewed
  once its follow-up is handled. Reviewing an item that is already reviewed
  changes nothing and records nothing. To leave a note, use comment.

OUTPUT
  The canonical item id on stdout. Nothing on stderr on success.

EXIT CODES
  0  ok (including an item already reviewed)
  1  unexpected database failure
  4  invalid id, a Decision id, or a stray argument (before any connection
     attempt); no item has that id (after connecting)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__review_sql() {
  hq_sql_lock_item UPDATE
  cat <<'SQL'
WITH upd AS (
  UPDATE items SET status = 'reviewed'
   WHERE id = :'hq_id' AND status <> 'reviewed'
  RETURNING id
), ev AS (
  INSERT INTO events (item_id, kind) SELECT id, 'reviewed' FROM upd
)
SELECT CASE WHEN :hq_n = 0 THEN '!no item ' || :'hq_id' ELSE :'hq_id' END;
SQL
}

cmd_run() {
  local id="" errf out rc
  hq_parse_one_id review id "$@"
  hq_require_kind review "$id" review

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__review_sql | hq_db_script -At -v "hq_id=$id" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "review: nothing was recorded"
  fi
  hq_problem_check review "$out"
  if [ "$out" != "$id" ]; then
    hq_die_error "review: the store returned no item id"
  fi
  printf '%s\n' "$out"
}
