# shellcheck shell=bash
# summary: list items, filtered by kind and status: parked first, then impact, then age
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh list — list items.

USAGE
  human-queue.sh list [--kind decision|review] [--status STATUS] [--json]

FILTERS (each at most once; validated before any connection attempt)
  --kind decision|review
  --status open|answered|acknowledged|reviewed|flagged|closed
  With no filter every item is listed.

ORDER
  Parked items first, then by declared impact (high, medium, low, none), then
  oldest first.

OUTPUT
  Each item exactly as `get` prints it (the question in bold, the context as
  a numbered list), separated by blank lines. Nothing at all when no item
  matches. --json prints one JSON array of item objects instead ([] when
  none match). Listing records no event.

EXIT CODES
  0  ok (including when nothing matches)
  1  unexpected database failure
  4  invalid filter or argument, reported before any connection attempt
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__list_sql() {
  local where="(:'hq_kind' = '' OR i.kind = :'hq_kind') AND (:'hq_status' = '' OR i.status = :'hq_status')"
  if [ "$1" -eq 1 ]; then
    printf 'SELECT coalesce(jsonb_agg(%s ORDER BY\n' "$(hq_sql_item_json)"
    hq_sql_item_order
    printf '%s\n' "), '[]'::jsonb) FROM items i WHERE $where;"
  else
    # One row holding every rendered item, so items are separated by a blank
    # line; HAVING drops that row when nothing matched, so nothing prints.
    printf '%s\n' "SELECT string_agg(r.rendered, E'\\n\\n' ORDER BY r.n) FROM ("
    printf '%s\n' "  SELECT"
    hq_sql_render_item
    printf '%s\n' "  AS rendered, row_number() OVER (ORDER BY"
    hq_sql_item_order
    printf '%s\n' "  ) AS n FROM items i WHERE $where"
    printf '%s\n' ") r HAVING count(*) > 0;"
  fi
}

cmd_run() {
  local kind="" status="" json=0 seen=" " errf out rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json)
        json=1
        shift
        continue
        ;;
      --kind|--status)
        case "$seen" in
          *" $1 "*) hq_die_validation "list: $1 given more than once" ;;
        esac
        seen="$seen$1 "
        if [ "$#" -lt 2 ]; then hq_die_validation "list: $1 needs a value"; fi
        ;;
      *) hq_die_validation "list: unknown $(hq_flag_name "$1") (run human-queue.sh list --help)" ;;
    esac
    case "$1" in
      --kind)
        hq_is_kind "$2" || hq_die_validation "list: --kind must be decision or review"
        kind="$2"
        ;;
      --status)
        hq_is_status "$2" \
          || hq_die_validation "list: --status must be one of: $HQ_ITEM_STATUSES"
        status="$2"
        ;;
    esac
    shift 2
  done

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__list_sql "$json" \
    | hq_db_script -At -v "hq_kind=$kind" -v "hq_status=$status" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "list"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}
