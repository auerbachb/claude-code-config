# shellcheck shell=bash
# summary: list items, filtered by kind and status: parked first, then impact, then age (--unreviewed: the Reviews backlog and its reading estimate)
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
  human-queue.sh list --kind reviews --unreviewed [--json]

FILTERS (each at most once; validated before any connection attempt)
  --kind decision|review    (decisions and reviews are accepted too)
  --status open|answered|acknowledged|reviewed|flagged|closed|answer-parked
  --unreviewed              the Reviews the operator has not looked at yet:
                            kind review, status open (a flagged Review was
                            read). Implies --kind review; cannot be combined
                            with --status or --kind decision
  With no filter every item is listed.

ORDER
  Parked items first, then by declared impact (high, medium, low, none), then
  oldest first.

OUTPUT
  Each item exactly as `get` prints it (the question in bold, the context as
  a numbered list), separated by blank lines. Nothing at all when no item
  matches. --json prints one JSON array of item objects instead ([] when
  none match). Listing records no event.
  With --unreviewed the items are followed (after a blank line, when there
  are any) by the backlog and its reading estimate at level 2, twenty lines
  an item: `3 unreviewed · ~60 lines at level 2`. --json then prints one
  object: {"count": N, "level2_lines": N*20, "today": "YYYY-MM-DD",
  "items": [...]}, whose items leave out summary_l2 (a cached summary is read
  with `summary get`) and carry one more field, synced_on: the day the
  Review was synced (its created_at). Both days are America/New_York
  calendar days, today on the database's clock, so the desk groups the
  backlog by day and `review --synced-today` marks the same "today".

EXIT CODES
  0  ok (including when nothing matches)
  1  unexpected database failure
  4  invalid filter or argument, reported before any connection attempt
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# Lines a level-2 summary takes to read (desk/DESIGN.md 2.8: the reading
# budget starts from 30 items x 20 lines).
HQ_LIST_L2_LINES=20

# hq__list_sql JSON UNREVIEWED — the query; with UNREVIEWED the items are
# followed by the count and the level-2 reading estimate.
hq__list_sql() {
  local where="(:'hq_kind' = '' OR i.kind = :'hq_kind') AND (:'hq_status' = '' OR i.status = :'hq_status')"
  if [ "$2" -eq 1 ]; then
    if [ "$1" -eq 1 ]; then
      printf "SELECT jsonb_build_object('count', count(*), 'level2_lines', count(*) * %s,\n" "$HQ_LIST_L2_LINES"
      # The desk's day (issue #1782): the view groups by it, and
      # `review --synced-today` reads the same one.
      printf '%s\n' "  'today', to_char(statement_timestamp() AT TIME ZONE :'hq_tz', 'YYYY-MM-DD'), 'items',"
      # The backlog leaves out cached level-2 summaries: listing is not
      # reading, and `summary get` returns one when the operator opens it.
      printf "  coalesce(jsonb_agg((%s - 'summary_l2')\n" "$(hq_sql_item_json)"
      printf '%s\n' "    || jsonb_build_object('synced_on', to_char(i.created_at AT TIME ZONE :'hq_tz', 'YYYY-MM-DD')) ORDER BY"
      hq_sql_item_order
      printf '%s\n' "), '[]'::jsonb)) FROM items i WHERE $where;"
    else
      printf '%s\n' "SELECT concat_ws(E'\\n\\n', string_agg(r.rendered, E'\\n\\n' ORDER BY r.n),"
      printf "  count(*) || ' unreviewed · ~' || count(*) * %s || ' lines at level 2') FROM (\n" "$HQ_LIST_L2_LINES"
      printf '%s\n' "  SELECT"
      hq_sql_render_item
      printf '%s\n' "  AS rendered, row_number() OVER (ORDER BY"
      hq_sql_item_order
      printf '%s\n' "  ) AS n FROM items i WHERE $where"
      printf '%s\n' ") r;"
    fi
    return 0
  fi
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
  local kind="" status="" json=0 unreviewed=0 seen=" " errf out rc

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
      --unreviewed)
        unreviewed=1
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
        kind="$2"
        case "$kind" in
          decisions) kind=decision ;;
          reviews) kind=review ;;
        esac
        hq_is_kind "$kind" || hq_die_validation "list: --kind must be decision or review (or decisions, reviews)"
        ;;
      --status)
        hq_is_status "$2" \
          || hq_die_validation "list: --status must be one of: $HQ_ITEM_STATUSES"
        status="$2"
        ;;
    esac
    shift 2
  done
  if [ "$unreviewed" -eq 1 ]; then
    if [ -n "$status" ]; then
      hq_die_validation "list: --unreviewed means status open; drop --status"
    fi
    if [ "$kind" = decision ]; then
      hq_die_validation "list: --unreviewed lists Reviews; it cannot take --kind decision"
    fi
    kind=review
    status=open
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__list_sql "$json" "$unreviewed" \
    | hq_db_script -At -v "hq_kind=$kind" -v "hq_status=$status" -v "hq_tz=$(hq_desk_tz)" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "list"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}
