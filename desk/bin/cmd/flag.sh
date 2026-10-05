# shellcheck shell=bash
# summary: flag a Review for follow-up (a `flagged` event with what to follow up)
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
human-queue.sh flag — flag a Review for follow-up.

USAGE
  human-queue.sh flag ID [--note TEXT]

ARGUMENTS
  ID           a Review id, for example R-88 (r-88 is accepted). Decisions
               (D-n) are answered, not flagged; tune their interrupts with
               feedback.
  --note TEXT  what to follow up: one line, <= 200 characters. Never a
               transcript or a diff.

BEHAVIOR
  The item's status becomes `flagged` and one `flagged` event carrying the
  note is recorded, in one transaction. Turning a flag into a follow-up issue
  is the desk's job, not the store's. Flagging an item again records another
  `flagged` event only when the note differs from the last flag's note;
  repeating the same flag changes nothing and records nothing. `review`
  clears a flag once it is handled.

OUTPUT
  The canonical item id on stdout. Nothing on stderr on success.

EXIT CODES
  0  ok (including a repeated flag)
  1  unexpected database failure
  4  invalid id, a Decision id, or a bad argument (before any connection
     attempt); no item has that id (after connecting)
  5  the note looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__flag_sql() {
  hq_sql_lock_item UPDATE
  cat <<'SQL'
SELECT coalesce((
         SELECT i.status = 'flagged'
                AND coalesce((SELECT e.note FROM events e
                                WHERE e.item_id = i.id AND e.kind = 'flagged'
                                ORDER BY e.id DESC LIMIT 1), '') = :'hq_note'
           FROM items i
          WHERE i.id = :'hq_id'), false) AS hq_same \gset
WITH upd AS (
  UPDATE items SET status = 'flagged'
   WHERE id = :'hq_id' AND NOT :'hq_same'::boolean
  RETURNING id
), ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT id, 'flagged', nullif(:'hq_note', '') FROM upd
)
SELECT CASE WHEN :hq_n = 0 THEN '!no item ' || :'hq_id' ELSE :'hq_id' END;
SQL
}

cmd_run() {
  local id="" raw_id="" note="" have_id=0 have_note=0 errf out rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --note)
        if [ "$have_note" -eq 1 ]; then hq_die_validation "flag: --note given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "flag: --note needs a value"; fi
        have_note=1
        note="$2"
        shift 2
        ;;
      -*) hq_die_validation "flag: unknown $(hq_flag_name "$1") (run human-queue.sh flag --help)" ;;
      *)
        if [ "$have_id" -eq 1 ]; then hq_die_validation "flag: takes one item id (quote a note with --note)"; fi
        have_id=1
        raw_id="$1"
        shift
        ;;
    esac
  done
  if [ "$have_id" -eq 0 ]; then
    hq_die_validation "flag: missing item id (run human-queue.sh flag --help)"
  fi
  hq_item_id id "$raw_id"
  hq_require_kind flag "$id" review
  if [ "$have_note" -eq 1 ]; then
    hq_check_text "flag: --note" "$note" 200
    hq_refuse_secret "flag: --note" "$note"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__flag_sql | hq_db_script -At -v "hq_id=$id" -v "hq_note=$note" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "flag: nothing was recorded"
  fi
  hq_problem_check flag "$out"
  if [ "$out" != "$id" ]; then
    hq_die_error "flag: the store returned no item id"
  fi
  printf '%s\n' "$out"
}
