# shellcheck shell=bash
# summary: end an item's snooze, so my list shows it again now (to-do layer)
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
human-queue.sh unsnooze — end an item's snooze (issue #1769).

USAGE
  human-queue.sh unsnooze ID [--json]

ARGUMENTS
  ID      any item id, for example D-43 or R-88 (d-43 is accepted)
  --json  print the item's to-do fields after the call, as `tag --json`
          does; changed is false when the item was not snoozed

BEHAVIOR
  Clears the item's snooze, so `my list` shows it again now. An item with
  no snooze changes nothing and records nothing; a snooze whose time has
  passed is cleared like any other. Otherwise one `unsnoozed` event. Not a
  change `tick` reports.

OUTPUT
  The canonical item id on stdout (JSON with --json). Nothing on stderr on
  success.

EXIT CODES
  0  ok (including an item that was not snoozed)
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  invalid id or a stray argument (before any connection attempt); no
     item has that id (after connecting)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

cmd_run() {
  local id="" json=0 sql=""
  hq_parse_id_args unsnooze id json "$@"
  sql=$(hq_sql_todo_write snoozed_until "NULL::timestamptz" "NULL" unsnoozed "NULL" "$json")
  hq_todo_run unsnooze "$json" "$sql" -v "hq_id=$id"
}
