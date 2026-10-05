# shellcheck shell=bash
# summary: print one item: the question in bold, the context as a numbered list
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh get — print one item.

USAGE
  human-queue.sh get ID [--json]

ARGUMENTS
  ID      the item id, for example D-43 or R-88 (d-43 is accepted)
  --json  print the item as one JSON object (every column except the
          internal change marker `tick` reads) instead

OUTPUT
  The item as the operator reads it:

    D-43 · decision · open · owner/repo · pr-1775
    **The question, in bold?**
    1. first context line
    2. second context line
    Options: A. first · B. second
    Default: B. second, at 2026-10-05 18:00 UTC
    Asked 2026-10-05 17:40 UTC · Impact: high · Cost: ~10 min · Parked · Session: abc
    Answer: ...

  Lines with nothing to show are left out. Times are UTC. Reading an item
  records no event.

EXIT CODES
  0  ok
  1  unexpected database failure
  4  invalid id or argument (before any connection attempt), or no item has
     that id (after connecting)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__get_sql() {
  if [ "$1" -eq 1 ]; then
    printf 'SELECT %s FROM items i WHERE i.id = %s;\n' "$(hq_sql_item_json)" ":'hq_id'"
  else
    printf 'SELECT %s\n  FROM items i\n WHERE i.id = %s;\n' "$(hq_sql_render_item)" ":'hq_id'"
  fi
}

cmd_run() {
  local id="" json=0 errf out rc
  hq_parse_id_args get id json "$@"

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__get_sql "$json" | hq_db_script -At -v "hq_id=$id" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "get"
  fi
  if [ -z "$out" ]; then
    hq_die_validation "get: no item $id"
  fi
  printf '%s\n' "$out"
}
