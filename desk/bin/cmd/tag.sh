# shellcheck shell=bash
# summary: add the operator's own tags to an item (to-do layer; untag removes them)
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
human-queue.sh tag — add the operator's own tags to an item (issue #1769).

USAGE
  human-queue.sh tag ID WORD... [--json]

ARGUMENTS
  ID     any item id, for example D-43 or R-88 (d-43 is accepted)
  WORD   a tag: lowercase letters and digits, words joined by single
         hyphens, at most 32 characters, with at least one letter (prd,
         call-back, q4). A leading # is dropped and capitals are folded, so
         #PRD is prd. Several words add several tags.
  --json print {"id", "changed", "my_priority", "my_tags", "my_note",
         "snoozed_until", "snoozed_until_local"}: the item's to-do fields
         after the call; changed is false when it already had every tag

BEHAVIOR
  The tags are the operator's own, for their to-do list (`my list --tag`):
  not the interrupt-tuning feedback tags (`feedback`). Added after the
  item's existing tags, in order; an item carries at most 10. A tag the
  item already has is skipped, and a call that adds none changes nothing and
  records nothing. Otherwise one `tagged` event, its note the tags added.
  Writing a tag is not a change `tick` reports. `untag` removes tags.

OUTPUT
  The canonical item id on stdout (JSON with --json). Nothing on stderr on
  success.

EXIT CODES
  0  ok (including tags the item already has)
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  invalid id, a missing or malformed tag, more than 10 tags, or a stray
     option (before any connection attempt); no item has that id, or the
     item would carry more than 10 tags (after connecting, nothing changed)
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
      -*) hq_die_validation "tag: unknown $(hq_flag_name "$a") (run human-queue.sh tag --help)" ;;
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
    hq_die_validation "tag: missing item id (run human-queue.sh tag --help)"
  fi
  hq_item_id id "$raw"
  hq_todo_tags tag tags ${words[@]+"${words[@]}"}

  sql=$(hq_sql_todo_write my_tags \
    "cur.my_tags || ARRAY(SELECT t FROM unnest(string_to_array(:'hq_tags', ',')) WITH ORDINALITY AS a(t, n)
                          WHERE NOT t = ANY (cur.my_tags) ORDER BY n)" \
    "CASE WHEN cardinality(nxt.v) > $HQ_TODO_MAX_TAGS
          THEN cur.id || ' would carry more than $HQ_TODO_MAX_TAGS tags (untag one first)' END" \
    tagged \
    "array_to_string(ARRAY(SELECT t FROM unnest(u.my_tags) AS t WHERE NOT t = ANY (cur.my_tags)), ', ')" \
    "$json")
  hq_todo_run tag "$json" "$sql" -v "hq_id=$id" -v "hq_tags=$tags"
}
