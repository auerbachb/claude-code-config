# shellcheck shell=bash
# summary: record that an item was asked about again (a `bumped` event)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh bump — record that an item was asked about again.

USAGE
  human-queue.sh bump ID [--note TEXT]

ARGUMENTS
  ID           the item id, for example D-43 or R-88 (d-43 is accepted)
  --note TEXT  optional short state-change note: one line, <= 200 characters.
               Never a transcript or a diff.

BEHAVIOR
  Refreshes the item's updated_at and records one `bumped` event, in one
  transaction. The item's status does not change. `add` bumps automatically
  when an open item already asks the same question.

OUTPUT
  The canonical item id on stdout. Nothing on stderr on success.

EXIT CODES
  0  ok
  1  unexpected database failure
  4  invalid id or argument (before any connection attempt), or no item has
     that id (after connecting)
  5  the note looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__bump_sql() {
  cat <<'SQL'
WITH bumped AS (
  UPDATE items SET updated_at = now() WHERE id = :'hq_id' RETURNING id
), bump AS (
  INSERT INTO events (item_id, kind, note)
  SELECT id, 'bumped', nullif(:'hq_note', '') FROM bumped
)
SELECT id FROM bumped;
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
        if [ "$have_note" -eq 1 ]; then hq_die_validation "bump: --note given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "bump: --note needs a value"; fi
        have_note=1
        note="$2"
        shift 2
        ;;
      -*) hq_die_validation "bump: unknown $(hq_flag_name "$1") (run human-queue.sh bump --help)" ;;
      *)
        if [ "$have_id" -eq 1 ]; then hq_die_validation "bump: takes one item id"; fi
        have_id=1
        raw_id="$1"
        shift
        ;;
    esac
  done
  if [ "$have_id" -eq 0 ]; then
    hq_die_validation "bump: missing item id (run human-queue.sh bump --help)"
  fi
  hq_item_id id "$raw_id"
  if [ "$have_note" -eq 1 ]; then
    hq_check_text "bump: --note" "$note" 200
    hq_refuse_secret "bump: --note" "$note"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__bump_sql | hq_db_script -At -v "hq_id=$id" -v "hq_note=$note" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "bump: nothing was recorded"
  fi
  if [ -z "$out" ]; then
    hq_die_validation "bump: no item $id"
  fi
  printf '%s\n' "$out"
}
