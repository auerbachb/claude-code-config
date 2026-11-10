# shellcheck shell=bash
# summary: print one item followed by its events, oldest first
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh show — print one item and its events.

USAGE
  human-queue.sh show ID [--json]

ARGUMENTS
  ID      the item id, for example D-43 or R-88 (d-43 is accepted)
  --json  print {"item": {...}, "events": [{"kind", "at", "note"}, ...]}

OUTPUT
  The item exactly as `get` prints it, a blank line, then its events, oldest
  first (ties in time keep the order they were written):

    Events:
    - 2026-10-05 17:40:12 UTC  asked
    - 2026-10-05 17:52:03 UTC  bumped — optional note

  Events are state changes only (asked, bumped, ...), never transcripts or
  diffs. Reading an item records no event.

EXIT CODES
  0  ok
  1  unexpected database failure
  4  invalid id or argument (before any connection attempt), or no item has
     that id (after connecting)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# The item block, a blank line, then "Events:" and one line per event. An item
# with no events (only possible for rows written outside the CLI) prints the
# item alone.
hq__show_sql() {
  if [ "$1" -eq 1 ]; then
    printf "SELECT jsonb_build_object('item', %s, 'events',\n" "$(hq_sql_item_json)"
    hq_sql_events_json
    printf '%s\n' ") FROM items i WHERE i.id = :'hq_id';"
  else
    printf '%s\n' "SELECT concat_ws(E'\\n\\n',"
    hq_sql_render_item
    printf '%s\n' ", 'Events:' || E'\\n' ||"
    hq_sql_render_events
    printf '%s\n' ") FROM items i WHERE i.id = :'hq_id';"
  fi
}

cmd_run() {
  local id="" json=0 errf out rc
  hq_parse_id_args show id json "$@"

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__show_sql "$json" | hq_db_script -At -v "hq_id=$id" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "show"
  fi
  if [ -z "$out" ]; then
    hq_die_validation "show: no item $id"
  fi
  printf '%s\n' "$out"
}
