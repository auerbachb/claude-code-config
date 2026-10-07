# shellcheck shell=bash
# summary: mark a Review as reviewed by the operator (a `reviewed` event); --synced-today marks every unreviewed Review synced today
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh review — mark a Review as reviewed.

USAGE
  human-queue.sh review ID [--comment TEXT]
  human-queue.sh review --synced-today [--comment TEXT]

ARGUMENTS
  ID              a Review id, for example R-88 (r-88 is accepted).
                  Decisions (D-n) are answered, not reviewed.
  --synced-today  instead of an id: every Review synced today that is still
                  unreviewed (status open), the desk's "reviewed all today".
                  Today is the America/New_York calendar day on the
                  database's clock, the day `list --unreviewed --json`
                  groups by. Flagged Reviews keep their flag (a flag is an
                  open follow-up); reviewed ones are already done.
  --comment TEXT  what the operator thought: one line, <= 200 characters.
                  Never a transcript or a diff. With --synced-today it rides
                  on every `reviewed` event written.

BEHAVIOR
  The item's status becomes `reviewed` and one `reviewed` event is recorded,
  carrying the comment when one is given, in one transaction. The item is
  kept. A flagged Review can be reviewed once its follow-up is handled.
  Reviewing an item that is already reviewed changes nothing and records
  nothing; with --comment it records the comment as one `commented` event
  and leaves the item as it is (as `comment` does).
  --synced-today locks every matching Review (in id order) and writes them
  all in one transaction: one `reviewed` event per item it marks, none for
  anything else.

OUTPUT
  The canonical item id on stdout. With --synced-today, the id of every item
  it marked, one per line, oldest first, and nothing at all when none
  matched. Nothing on stderr on success.

EXIT CODES
  0  ok (including an item already reviewed, or nothing synced today)
  1  unexpected database failure
  4  invalid id, a Decision id, both an id and --synced-today or neither, a
     bad comment, or a stray argument (before any connection attempt); no
     item has that id (after connecting)
  5  the comment looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# Every CTE reads the snapshot from before `upd`, so `cm` sees the status the
# item had: it comments only on an item that was already reviewed.
hq__review_sql() {
  hq_sql_lock_item UPDATE
  cat <<'SQL'
WITH upd AS (
  UPDATE items SET status = 'reviewed'
   WHERE id = :'hq_id' AND status <> 'reviewed'
  RETURNING id
), ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT id, 'reviewed', nullif(:'hq_comment', '') FROM upd
), cm AS (
  INSERT INTO events (item_id, kind, note)
  SELECT i.id, 'commented', :'hq_comment' FROM items i
   WHERE i.id = :'hq_id' AND i.status = 'reviewed' AND :'hq_comment' <> ''
)
SELECT CASE WHEN :hq_n = 0 THEN '!no item ' || :'hq_id' ELSE :'hq_id' END;
SQL
}

# `review --synced-today` (issue #1782). The first statement locks today's
# unreviewed Reviews in id order and keeps their ids (FOR UPDATE re-checks
# the WHERE on a row a concurrent writer changed, so one reviewed or flagged
# meanwhile drops out); the second writes exactly those that are still open
# and prints the ids it changed, oldest first (a shorter id is a smaller
# number: ids have no leading zeros). Nothing matched → no row, no output.
hq__review_today_sql() {
  printf '%s\n' "SET LOCAL lock_timeout TO '30s';"
  cat <<'SQL'
SELECT coalesce(string_agg(l.id, ',' ORDER BY l.id), '') AS hq_ids
  FROM (SELECT i.id FROM items i
         WHERE i.kind = 'review' AND i.status = 'open'
           AND (i.created_at AT TIME ZONE :'hq_tz')::date
               = (statement_timestamp() AT TIME ZONE :'hq_tz')::date
         ORDER BY i.id
           FOR UPDATE) l \gset
WITH upd AS (
  UPDATE items SET status = 'reviewed'
   WHERE id = ANY (string_to_array(:'hq_ids', ',')) AND status = 'open'
  RETURNING id
), ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT id, 'reviewed', nullif(:'hq_comment', '') FROM upd
)
SELECT string_agg(id, E'\n' ORDER BY length(id), id) FROM upd HAVING count(*) > 0;
SQL
}

cmd_run() {
  local id="" raw_id="" comment="" have_id=0 have_comment=0 today=0 errf out rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --comment)
        if [ "$have_comment" -eq 1 ]; then hq_die_validation "review: --comment given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "review: --comment needs a value"; fi
        have_comment=1
        comment="$2"
        shift 2
        ;;
      --synced-today)
        today=1
        shift
        ;;
      -*) hq_die_validation "review: unknown $(hq_flag_name "$1") (run human-queue.sh review --help)" ;;
      *)
        if [ "$have_id" -eq 1 ]; then hq_die_validation "review: takes one item id (quote a comment with --comment)"; fi
        have_id=1
        raw_id="$1"
        shift
        ;;
    esac
  done
  if [ "$today" -eq 1 ] && [ "$have_id" -eq 1 ]; then
    hq_die_validation "review: give an item id or --synced-today, not both"
  fi
  if [ "$have_id" -eq 0 ] && [ "$today" -eq 0 ]; then
    hq_die_validation "review: missing item id (or --synced-today; run human-queue.sh review --help)"
  fi
  if [ "$today" -eq 0 ]; then
    hq_item_id id "$raw_id"
    hq_require_kind review "$id" review
  fi
  if [ "$have_comment" -eq 1 ]; then
    hq_check_text "review: --comment" "$comment" 200
    hq_refuse_secret "review: --comment" "$comment"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  if [ "$today" -eq 1 ]; then
    out=$(hq__review_today_sql \
      | hq_db_script -At -v "hq_tz=$(hq_desk_tz)" -v "hq_comment=$comment" 2>"$errf") || rc=$?
    if [ "$rc" -ne 0 ]; then
      hq_db_fail "$rc" "$errf" "review --synced-today: nothing was recorded"
    fi
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    fi
    return 0
  fi
  out=$(hq__review_sql | hq_db_script -At -v "hq_id=$id" -v "hq_comment=$comment" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "review: nothing was recorded"
  fi
  hq_problem_check review "$out"
  if [ "$out" != "$id" ]; then
    hq_die_error "review: the store returned no item id"
  fi
  printf '%s\n' "$out"
}
