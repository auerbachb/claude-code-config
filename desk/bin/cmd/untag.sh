# shellcheck shell=bash
# summary: remove the operator's own tags from an item (to-do layer)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"
# shellcheck source=../lib/todo.sh
. "$HQ_BIN_DIR/lib/todo.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh untag — remove the operator's own tags from an item (issue #1769).

USAGE
  human-queue.sh untag ID WORD... [--json]

ARGUMENTS
  ID     any item id, for example D-43 or R-88 (d-43 is accepted)
  WORD   a tag `tag` added (#PRD is prd, as there). Several words remove
         several tags.
  --json print the item's to-do fields after the call, as `tag --json`
         does; changed is false when it had none of the tags

BEHAVIOR
  Removes the tags; the others keep their order. A tag the item does not
  carry is skipped, and a call that removes none changes nothing and records
  nothing. Otherwise one `untagged` event, its note the tags removed. Not a
  change `tick` reports.

OUTPUT
  The canonical item id on stdout (JSON with --json). Nothing on stderr on
  success.

EXIT CODES
  0  ok (including tags the item does not carry)
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  invalid id, a missing or malformed tag, or a stray option (before any
     connection attempt); no item has that id (after connecting)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

cmd_run() {
  local id="" raw="" have_id=0 json=0 tags="" sql="" a
  local -a words=()
  for a in "$@"; do
    case "$a" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
    esac
  done
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      -*) hq_die_validation "untag: unknown $(hq_flag_name "$a") (run human-queue.sh untag --help)" ;;
      *)
        if [ "$have_id" -eq 0 ]; then
          have_id=1
          raw="$a"
        else
          words+=("$a")
        fi
        ;;
    esac
  done
  if [ "$have_id" -eq 0 ]; then
    hq_die_validation "untag: missing item id (run human-queue.sh untag --help)"
  fi
  hq_item_id id "$raw"
  hq_todo_tags untag tags ${words[@]+"${words[@]}"}

  sql=$(hq_sql_todo_write my_tags \
    "ARRAY(SELECT t FROM unnest(cur.my_tags) WITH ORDINALITY AS a(t, n)
            WHERE NOT t = ANY (string_to_array(:'hq_tags', ',')) ORDER BY n)" \
    "NULL" \
    untagged \
    "array_to_string(ARRAY(SELECT t FROM unnest(cur.my_tags) AS t WHERE NOT t = ANY (u.my_tags)), ', ')" \
    "$json")
  hq_todo_run untag "$json" "$sql" -v "hq_id=$id" -v "hq_tags=$tags"
}
