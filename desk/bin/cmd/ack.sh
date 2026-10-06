# shellcheck shell=bash
# summary: the asking thread acknowledges it has read a Decision's answer
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh ack — acknowledge that the asking thread has read an answer.

USAGE
  human-queue.sh ack ID [--answer TEXT]

ARGUMENTS
  ID             a Decision id, for example D-43 (d-43 is accepted)
  --answer TEXT  acknowledge only if the stored answer is still TEXT (compared
                 after dropping leading and trailing whitespace). Pass the
                 answer exactly as pending-for or get printed it, so a thread
                 never acknowledges an answer the operator replaced after it
                 read one.

BEHAVIOR
  An `answered` item becomes `acknowledged`, is no longer parked, and leaves
  pending-for; one `acknowledged` event is recorded, in one transaction.
  Acknowledging an item that is already acknowledged changes nothing and
  records nothing. A new answer returns it to `answered`.

OUTPUT
  The canonical item id on stdout. Nothing on stderr on success.

EXIT CODES
  0  ok (including an item already acknowledged)
  1  unexpected database failure
  4  invalid id, a Review id, or a bad argument (before any connection
     attempt); no item has that id, it has no answer yet, or --answer no
     longer matches (after connecting, nothing written)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__ack_sql() {
  hq_sql_lock_item UPDATE
  cat <<'SQL'
SELECT coalesce((
         SELECT CASE
                  WHEN i.answer IS NULL THEN i.id || ' has no answer to acknowledge yet'
                  WHEN :'hq_check' = '1' AND i.answer <> :'hq_expect'
                    THEN 'the answer on ' || i.id || ' changed after it was read; read it again (pending-for or get), then acknowledge'
                  ELSE ''
                END
           FROM items i
          WHERE i.id = :'hq_id'), 'no item ' || :'hq_id') AS hq_problem \gset
SELECT :'hq_problem' = '' AS hq_ok \gset
\if :hq_ok
WITH upd AS (
  UPDATE items SET status = 'acknowledged', parked = false
   WHERE id = :'hq_id' AND status = 'answered'
  RETURNING id
), ev AS (
  INSERT INTO events (item_id, kind) SELECT id, 'acknowledged' FROM upd
)
SELECT :'hq_id';
\else
SELECT '!' || :'hq_problem';
\endif
SQL
}

cmd_run() {
  local id="" raw_id="" expect="" have_id=0 check=0 errf out rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --answer)
        if [ "$check" -eq 1 ]; then hq_die_validation "ack: --answer given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "ack: --answer needs a value"; fi
        check=1
        expect="$2"
        shift 2
        ;;
      -*) hq_die_validation "ack: unknown $(hq_flag_name "$1") (run human-queue.sh ack --help)" ;;
      *)
        if [ "$have_id" -eq 1 ]; then hq_die_validation "ack: takes one item id"; fi
        have_id=1
        raw_id="$1"
        shift
        ;;
    esac
  done
  if [ "$have_id" -eq 0 ]; then
    hq_die_validation "ack: missing item id (run human-queue.sh ack --help)"
  fi
  hq_item_id id "$raw_id"
  hq_require_kind ack "$id" decision
  if [ "$check" -eq 1 ]; then
    hq_trim expect "$expect"
    hq_check_answer "ack: --answer" "$expect"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__ack_sql | hq_db_script -At -v "hq_id=$id" -v "hq_check=$check" \
    -v "hq_expect=$expect" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "ack: nothing was recorded"
  fi
  hq_problem_check ack "$out"
  if [ "$out" != "$id" ]; then
    hq_die_error "ack: the store returned no item id"
  fi
  printf '%s\n' "$out"
}
