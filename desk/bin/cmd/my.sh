# shellcheck shell=bash
# summary: my list: the operator's own to-do list of items, by personal priority then age (to-do layer)
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
human-queue.sh my — the operator's own to-do list (issue #1769).

USAGE
  human-queue.sh my list [--tag WORD] [--all] [--snoozed] [--json]

WHAT IS ON IT
  Every item with a personal priority (`mine`) or a note (`note`); with
  --tag WORD, every item carrying that tag (`tag`) instead, with or without
  either. Only items still waiting on the operator: status open (a Decision
  not yet answered, a Review not yet read) or flagged (a Review whose
  follow-up is open); --all lists every status. An item snoozed until a
  time still ahead (`snooze`) is left out and counted; at that time it is
  back. --snoozed lists the snoozed ones too, marked. Reading the list
  records nothing.

ORDER
  Personal priority, 1 first, items without one last; then oldest first.

OUTPUT
  A header line, then one line per item (unnumbered, so a line is never
  mistaken for a set number such as `2: B`), and the note under it:

    My list · 3 items · 1 snoozed (next back Fri Oct 9 09:00 ET)
    - P1 · D-44 · Retry the flaky upload test once? (widgets · pr-12) · tags: prd, urgent
      Note: ask Sam before answering
    - P3 · R-9 · Add the export command (claude-code-config · pr-1820) · flagged
    - D-50 · Which bucket? (widgets · issue-7)
      Note: waiting on the vendor

  A status other than open is named; times are the desk's calendar
  (America/New_York). With nothing on it: `My list is empty`, and the same
  snoozed count when there is one. With --json one object:
    {"now": "<UTC>", "count": N, "snoozed": K, "next_back": "<UTC>"|null,
     "items": [...]}
  items in the list's order, each the item's JSON (as `get --json`, without
  summary_l2) plus "snoozed": true|false; snoozed counts the items left out
  for their snooze, and next_back is the soonest of their times.

EXIT CODES
  0  ok (including an empty list)
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  a missing or unknown action, a malformed --tag, or a stray argument
     (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__my_list_sql JSON — the list, as text or JSON. :'hq_all', :'hq_snoozed'
# are 1 or 0; :'hq_tag' is a tag or empty.
hq__my_list_sql() {
  cat <<'SQL'
WITH m AS (
  SELECT i.*,
         (i.snoozed_until IS NOT NULL AND i.snoozed_until > statement_timestamp()) AS snoozed
    FROM items i
   WHERE (:'hq_all' = '1' OR i.status IN ('open', 'flagged'))
     AND CASE WHEN :'hq_tag' <> '' THEN :'hq_tag' = ANY (i.my_tags)
              ELSE i.my_priority IS NOT NULL OR i.my_note IS NOT NULL END
), shown AS (
  SELECT * FROM m WHERE NOT m.snoozed OR :'hq_snoozed' = '1'
), hidden AS (
  SELECT * FROM m WHERE m.snoozed AND :'hq_snoozed' <> '1'
)
SQL
  if [ "$1" -eq 1 ]; then
    cat <<'SQL'
SELECT jsonb_build_object(
         'now', to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'count', (SELECT count(*) FROM shown),
         'snoozed', (SELECT count(*) FROM hidden),
         'next_back', (SELECT to_char(min(h.snoozed_until) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                         FROM hidden h),
         'items', coalesce((SELECT jsonb_agg(to_jsonb(s) - 'change_xid' - 'summary_l2'
                                             ORDER BY s.my_priority NULLS LAST, s.created_at, s.id)
                              FROM shown s), '[]'::jsonb))::text;
SQL
  else
    cat <<'SQL'
SELECT concat_ws(E'\n',
         (SELECT CASE WHEN count(*) = 0 THEN 'My list is empty'
                      ELSE 'My list · ' || count(*) || CASE WHEN count(*) = 1 THEN ' item' ELSE ' items' END
                 END
            FROM shown)
         || CASE WHEN :'hq_tag' <> '' THEN ' · tag ' || :'hq_tag' ELSE '' END
         || CASE WHEN :'hq_all' = '1' THEN ' · every status' ELSE '' END
         || coalesce((SELECT ' · ' || count(*) || ' snoozed (next back '
                             || to_char(min(h.snoozed_until) AT TIME ZONE :'hq_tz', 'Dy Mon FMDD HH24:MI') || ' ET)'
                        FROM hidden h HAVING count(*) > 0), ''),
         (SELECT string_agg(x.line, E'\n' ORDER BY x.my_priority NULLS LAST, x.created_at, x.id)
            FROM (SELECT s.my_priority, s.created_at, s.id,
                         '- ' || coalesce('P' || s.my_priority || ' · ', '') || s.id || ' · ' || s.question
                         || ' (' || split_part(s.repo, '/', 2) || ' · ' || s.key || ')'
                         || CASE WHEN s.status <> 'open' THEN ' · ' || s.status ELSE '' END
                         || CASE WHEN cardinality(s.my_tags) > 0
                                 THEN ' · tags: ' || array_to_string(s.my_tags, ', ') ELSE '' END
                         || CASE WHEN s.snoozed
                                 THEN ' · snoozed until '
                                      || to_char(s.snoozed_until AT TIME ZONE :'hq_tz', 'Dy Mon FMDD HH24:MI') || ' ET'
                                 ELSE '' END
                         || coalesce(E'\n  Note: ' || s.my_note, '') AS line
                    FROM shown s) x));
SQL
  fi
}

cmd_run() {
  local action="" all=0 snoozed=0 json=0 tag="" have_tag=0 errf out rc=0
  case "${1:-}" in
    -h|--help)
      cmd_usage
      exit 0
      ;;
    list) action=list ;;
    '') hq_die_validation "my: missing action: list (run human-queue.sh my --help)" ;;
    -*) hq_die_validation "my: unknown $(hq_flag_name "$1") (run human-queue.sh my --help)" ;;
    *) hq_die_validation "my: unknown action (expected list)" ;;
  esac
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      --all) all=1 ;;
      --snoozed) snoozed=1 ;;
      --tag)
        if [ "$have_tag" -eq 1 ]; then hq_die_validation "my list: --tag given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "my list: --tag needs a value"; fi
        have_tag=1
        hq_todo_tag "my list" tag "$2"
        shift
        ;;
      *) hq_die_validation "my list: unknown $(hq_flag_name "$1") (run human-queue.sh my --help)" ;;
    esac
    shift
  done

  hq_db_connect
  hq_mktemp errf
  out=$(hq__my_list_sql "$json" | hq_db_script -At -v "hq_all=$all" -v "hq_snoozed=$snoozed" \
          -v "hq_tag=$tag" -v "hq_tz=$(hq_desk_tz)" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_fail_unmigrated "$rc" "$errf" "my $action" 'my_tags|my_note|my_priority|snoozed_until'
  fi
  if [ -z "$out" ]; then
    hq_die_error "my $action: the store returned nothing"
  fi
  printf '%s\n' "$out"
}
