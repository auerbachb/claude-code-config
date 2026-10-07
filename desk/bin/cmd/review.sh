# shellcheck shell=bash
# summary: mark a Review as reviewed by the operator (a `reviewed` event)
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

ARGUMENTS
  ID              a Review id, for example R-88 (r-88 is accepted).
                  Decisions (D-n) are answered, not reviewed.
  --comment TEXT  what the operator thought: one line, <= 200 characters.
                  Never a transcript or a diff.

BEHAVIOR
  The item's status becomes `reviewed` and one `reviewed` event is recorded,
  carrying the comment when one is given, in one transaction. The item is
  kept. A flagged Review can be reviewed once its follow-up is handled.
  Reviewing an item that is already reviewed changes nothing and records
  nothing; with --comment it records the comment as one `commented` event
  and leaves the item as it is (as `comment` does).

OUTPUT
  The canonical item id on stdout. Nothing on stderr on success.

EXIT CODES
  0  ok (including an item already reviewed)
  1  unexpected database failure
  4  invalid id, a Decision id, a bad comment, or a stray argument (before
     any connection attempt); no item has that id (after connecting)
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

cmd_run() {
  local id="" raw_id="" comment="" have_id=0 have_comment=0 errf out rc

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
      -*) hq_die_validation "review: unknown $(hq_flag_name "$1") (run human-queue.sh review --help)" ;;
      *)
        if [ "$have_id" -eq 1 ]; then hq_die_validation "review: takes one item id (quote a comment with --comment)"; fi
        have_id=1
        raw_id="$1"
        shift
        ;;
    esac
  done
  if [ "$have_id" -eq 0 ]; then
    hq_die_validation "review: missing item id (run human-queue.sh review --help)"
  fi
  hq_item_id id "$raw_id"
  hq_require_kind review "$id" review
  if [ "$have_comment" -eq 1 ]; then
    hq_check_text "review: --comment" "$comment" 200
    hq_refuse_secret "review: --comment" "$comment"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
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
