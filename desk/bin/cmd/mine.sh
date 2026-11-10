# shellcheck shell=bash
# summary: set or clear the operator's personal priority on an item, 1 (highest) to 5 (to-do layer)
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
human-queue.sh mine — the operator's personal priority on an item (issue #1769).

USAGE
  human-queue.sh mine ID PRIORITY [--json]
  human-queue.sh mine ID --clear [--json]

ARGUMENTS
  ID        any item id, for example D-43 or R-88 (d-43 is accepted)
  PRIORITY  1 (highest) to 5. It replaces any priority the item had.
  --clear   remove the priority
  --json    print the item's to-do fields after the call, as `tag --json`
            does; changed is false when nothing changed

BEHAVIOR
  The priority orders the operator's own list (`my list`: priority 1
  first, items with a note but no priority last, then oldest first), and an
  item with a priority is on it. It is about desk items (D-/R- ids) only:
  /pm's backlog order for GitHub issues is a separate thing (`top`, `bump`,
  `park`, `drop` at the desk; .claude/scripts/pm-priority.sh), and neither
  reads the other. The queue itself is unchanged: sets, the sweep, and
  wake-ups keep their own order. Setting the priority the item already has,
  or clearing an item that has none, changes nothing and records nothing.
  Otherwise one `prioritized` event, note the priority or `cleared`. Not a
  change `tick` reports.

OUTPUT
  The canonical item id on stdout (JSON with --json). Nothing on stderr on
  success.

EXIT CODES
  0  ok (including no change)
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  invalid id, a missing priority or one that is not 1 to 5, a priority
     with --clear, or a stray argument (before any connection attempt); no
     item has that id (after connecting)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

cmd_run() {
  local id="" raw="" prio="" n=0 json=0 clear=0 sql="" a
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
      *:-*) hq_die_validation "mine: unknown $(hq_flag_name "$a") (run human-queue.sh mine --help)" ;;
      0:*)
        raw="$a"
        n=1
        ;;
      1:*)
        prio="$a"
        n=2
        ;;
      *) hq_die_validation "mine: takes one item id and one priority" ;;
    esac
  done
  if [ "$n" -eq 0 ]; then
    hq_die_validation "mine: missing item id (run human-queue.sh mine --help)"
  fi
  hq_item_id id "$raw"
  if [ "$clear" -eq 1 ]; then
    if [ "$n" -eq 2 ]; then
      hq_die_validation "mine: give a priority or --clear, not both"
    fi
  else
    case "$prio" in
      [1-5]) ;;
      '') hq_die_validation "mine: missing priority, 1 (highest) to 5 (or --clear to remove it)" ;;
      *) hq_die_validation "mine: the priority must be 1 (highest) to 5" ;;
    esac
  fi

  sql=$(hq_sql_todo_write my_priority \
    "nullif(:'hq_prio', '')::smallint" \
    "NULL" \
    prioritized \
    "coalesce(u.my_priority::text, 'cleared')" \
    "$json")
  hq_todo_run mine "$json" "$sql" -v "hq_id=$id" -v "hq_prio=$prio"
}
