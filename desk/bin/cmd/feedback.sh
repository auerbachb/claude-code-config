# shellcheck shell=bash
# summary: tag how an item's interrupt landed, to tune the desk (a `feedback` event)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh feedback — tag how an item's interrupt landed.

USAGE
  human-queue.sh feedback ID TAG [--set SET_ID] [--json]

ARGUMENTS
  ID   any item id, for example D-43 or R-88 (d-43 is accepted); with
       --set, also the item's number in that set (2), as the operator
       typed it
  TAG  a lowercase tag of words joined by hyphens, <= 60 characters. The
       starting tags are:
         not-important           this should not have interrupted me
         should-have-defaulted   the agent should have taken its default
         good-interrupt          this was worth the interruption
       Others are accepted, so the set can grow without a change here.
  --set SET_ID  resolve a number ID through this set (`set-open` printed its
       id). A full id is taken as it is; the set is not consulted for it.
  --json  print {"id", "tag", "session", "recorded"}: session is the asking
       thread (null for an item with no return address), recorded is false
       when the item already had the tag

BEHAVIOR
  Records one `feedback` event whose note is TAG and whose session_id is the
  item's return address, the thread that asked (issue #1783; migration
  008_event_session.sql). The desk reads these to tune when items reach the
  operator; the item itself is not changed and `tick` does not report it
  again. Giving an item a tag it already has changes nothing and records
  nothing; an item can carry several tags.

OUTPUT
  The canonical item id on stdout (JSON with --json). Nothing on stderr on
  success.

EXIT CODES
  0  ok (including a tag the item already has)
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  invalid id, a number without --set, a missing or malformed tag, a
     malformed --set, or a stray argument (before any connection attempt);
     no item has that id, or the set has no item at that number (after
     connecting)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__feedback_sql JSON — with :hq_by_pos, the item is first looked up by its
# number in set :'hq_set'. The event copies the item's session_id (the asking
# thread) in the statement that also checks the item still exists.
hq__feedback_sql() {
  cat <<'SQL'
\if :hq_by_pos
SELECT coalesce((SELECT item_id FROM sets
                  WHERE set_id = :'hq_set'::bigint AND position = :'hq_pos'::int), '') AS hq_id \gset
SELECT :'hq_id' <> '' AS hq_found \gset
\else
SELECT true AS hq_found \gset
\endif
\if :hq_found
SQL
  hq_sql_lock_item "NO KEY UPDATE"
  cat <<'SQL'
SELECT EXISTS (SELECT 1 FROM events
                WHERE item_id = :'hq_id' AND kind = 'feedback' AND note = :'hq_tag') AS hq_dup \gset
WITH ev AS (
  INSERT INTO events (item_id, kind, note, session_id)
  SELECT id, 'feedback', :'hq_tag', session_id FROM items
   WHERE id = :'hq_id' AND NOT :'hq_dup'::boolean
  RETURNING 1
)
SQL
  if [ "$1" -eq 1 ]; then
    cat <<'SQL'
SELECT CASE WHEN :hq_n = 0 THEN '!no item ' || :'hq_id'
            ELSE (SELECT jsonb_build_object('id', i.id, 'tag', :'hq_tag', 'session', i.session_id,
                                            'recorded', (SELECT count(*) FROM ev) > 0)::text
                    FROM items i WHERE i.id = :'hq_id') END;
SQL
  else
    cat <<'SQL'
SELECT CASE WHEN :hq_n = 0 THEN '!no item ' || :'hq_id' ELSE :'hq_id' END;
SQL
  fi
  cat <<'SQL'
\else
SELECT '!set ' || :'hq_set' || ' has no item ' || :'hq_pos';
\endif
SQL
}

# hq__feedback_tag_ok TAG — lowercase ASCII words joined by single hyphens.
# LC_ALL=C so [a-z] is a byte range, never a locale's collation range.
hq__feedback_tag_ok() {
  local LC_ALL=C re='^[a-z][a-z0-9]*(-[a-z0-9]+)*$'
  [ "${#1}" -le 60 ] && [[ $1 =~ $re ]]
}

cmd_run() {
  local id="" ref="" tag="" set_id="" have_set=0 json=0 pos="" by_pos=0 n=0 errf out rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      --set)
        if [ "$have_set" -eq 1 ]; then hq_die_validation "feedback: --set given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "feedback: --set needs a value"; fi
        have_set=1
        set_id="$2"
        shift
        ;;
      -*)
        # In the tag's place it is a (malformed) tag, refused below as one.
        if [ "$n" -ne 1 ]; then
          hq_die_validation "feedback: unknown $(hq_flag_name "$1") (run human-queue.sh feedback --help)"
        fi
        tag="$1"
        n=2
        ;;
      *)
        case "$n" in
          0) ref="$1" ;;
          1) tag="$1" ;;
          *) hq_die_validation "feedback: takes one item id and one tag (quote a tag that has spaces)" ;;
        esac
        n=$((n + 1))
        ;;
    esac
    shift
  done
  if [ "$n" -eq 0 ]; then
    hq_die_validation "feedback: missing item id (run human-queue.sh feedback --help)"
  fi
  if [ "$n" -eq 1 ]; then
    hq_die_validation "feedback: missing tag (run human-queue.sh feedback --help)"
  fi
  if [ "$have_set" -eq 1 ]; then
    case "$set_id" in
      ''|0*|*[!0-9]*) hq_die_validation "feedback: --set must be a set id (a whole number from 1)" ;;
    esac
    if ! hq_bigint_ok "$set_id"; then
      hq_die_validation "feedback: --set must be a set id (a whole number from 1)"
    fi
  fi
  case "$ref" in
    [1-9]|[1-9][0-9])
      if [ "$have_set" -eq 0 ]; then
        hq_die_validation "feedback: a number names an item only with --set (or give its id, for example D-43)"
      fi
      by_pos=1
      pos="$ref"
      ;;
    *) hq_item_id id "$ref" ;;
  esac
  if ! hq__feedback_tag_ok "$tag"; then
    hq_die_validation "feedback: the tag must be lowercase words joined by hyphens, <= 60 characters (for example should-have-defaulted)"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__feedback_sql "$json" | hq_db_script -At -v "hq_id=$id" -v "hq_tag=$tag" \
          -v "hq_by_pos=$by_pos" -v "hq_set=$set_id" -v "hq_pos=$pos" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_fail_unmigrated "$rc" "$errf" "feedback: nothing was recorded" 'session_id'
  fi
  hq_problem_check feedback "$out"
  if [ -z "$out" ]; then
    hq_die_error "feedback: the store returned no item id"
  fi
  if [ "$json" -eq 0 ]; then
    case "$out" in
      [DR]-[1-9]*) ;;
      *) hq_die_error "feedback: the store returned no item id" ;;
    esac
    if [ "$by_pos" -eq 0 ] && [ "$out" != "$id" ]; then
      hq_die_error "feedback: the store returned no item id"
    fi
  fi
  printf '%s\n' "$out"
}
