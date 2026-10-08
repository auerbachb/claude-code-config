# shellcheck shell=bash
# summary: set or clear the operator's own note on an item (to-do layer)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"
# shellcheck source=../lib/todo.sh
. "$HQ_BIN_DIR/lib/todo.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh note — set or clear the operator's own note on an item (issue #1769).

USAGE
  human-queue.sh note ID TEXT [--json]
  human-queue.sh note ID --clear [--json]

ARGUMENTS
  ID       any item id, for example D-43 or R-88 (d-43 is accepted)
  TEXT     the note: one line, <= 1000 characters. Quote it. It replaces
           any note the item had.
  --clear  remove the note
  --json   print the item's to-do fields after the call, as `tag --json`
           does; changed is false when nothing changed

BEHAVIOR
  The note is the operator's own, about what to do with the item: `my list`
  shows it under the item, and so do `get`, `show`, and the end-of-day
  paper copy. An item with a note is on `my list`. Setting the note it
  already has, or clearing an item that has none, changes nothing and
  records nothing. Otherwise one `noted` event, note `set` or `cleared`: the
  text lives on the item, never in its history. Not a change `tick` reports.

OUTPUT
  The canonical item id on stdout (JSON with --json). Nothing on stderr on
  success.

EXIT CODES
  0  ok (including no change)
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  invalid id, a missing, blank, multi-line, or over-long note, a note
     with --clear, or a stray argument (before any connection attempt); no
     item has that id (after connecting)
  5  the note looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

cmd_run() {
  local id="" raw="" text="" n=0 json=0 clear=0 sql="" a
  for a in "$@"; do
    case "$a" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
    esac
  done
  for a in "$@"; do
    case "$n:$a" in
      *:--json) json=1 ;;
      *:--clear) clear=1 ;;
      0:-*) hq_die_validation "note: unknown $(hq_flag_name "$a") (run human-queue.sh note --help)" ;;
      0:*)
        raw="$a"
        n=1
        ;;
      1:--[a-z]*)
        # A note may start with a dash ("-- see above"), but not look like
        # a mistyped option.
        if [[ $a =~ ^--[a-z][a-z-]*$ ]]; then
          hq_die_validation "note: unknown $(hq_flag_name "$a") (run human-queue.sh note --help)"
        fi
        text="$a"
        n=2
        ;;
      1:*)
        text="$a"
        n=2
        ;;
      *) hq_die_validation "note: takes one item id and one note (quote a note that has spaces)" ;;
    esac
  done
  if [ "$n" -eq 0 ]; then
    hq_die_validation "note: missing item id (run human-queue.sh note --help)"
  fi
  hq_item_id id "$raw"
  if [ "$clear" -eq 1 ]; then
    if [ "$n" -eq 2 ]; then
      hq_die_validation "note: give a note or --clear, not both"
    fi
  else
    if [ "$n" -eq 1 ]; then
      hq_die_validation "note: missing note (or --clear to remove it; run human-queue.sh note --help)"
    fi
    hq_todo_check_note "$text"
  fi

  sql=$(hq_sql_todo_write my_note \
    "nullif(:'hq_note', '')" \
    "NULL" \
    noted \
    "CASE WHEN u.my_note IS NULL THEN 'cleared' ELSE 'set' END" \
    "$json")
  hq_todo_run note "$json" "$sql" -v "hq_id=$id" -v "hq_note=$text"
}
