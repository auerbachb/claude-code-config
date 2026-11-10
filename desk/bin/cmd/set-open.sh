# shellcheck shell=bash
# summary: number a batch of items 1 to n for the operator (a set; `shown` events)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

HQ_SET_MAX=99

cmd_usage() {
  cat <<'EOF'
human-queue.sh set-open — number a batch of items 1 to n.

USAGE
  human-queue.sh set-open ID [ID...] [--json]

ARGUMENTS
  ID      1 to 99 distinct item ids, in the order they are shown; the first
          is number 1. d-43 is accepted.
  --json  print {"set_id": N, "items": [{"n": 1, "id": "D-43"}, ...]}

BEHAVIOR
  Allocates a new set id and records each item at its number in `sets`, so
  the operator can reply "2: B" (see set-resolve) instead of typing ids.
  Numbering starts at 1 in every set. Each item gets one `shown` event
  (note `set N #k`); the items themselves are not changed, so `tick` does
  not report them again. The cap is 99: four per menu is the question tool's
  limit, not the store's, and longer batches (paper export) are numbered too.
  An unknown id writes nothing.

OUTPUT
  The set id on the first line (`set 12`), then one line per item:
  `1. D-43 **The question?**`. Nothing on stderr on success.

EXIT CODES
  0  ok
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  no ids, more than 99, a repeated or malformed id (before any connection
     attempt); an id with no item (after connecting, nothing written)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__set_open_sql N JSON — validate, allocate, record. Variables: hq_id_1 ..
# hq_id_N; only references are generated, never values.
hq__set_open_sql() {
  local k=1 rows="" input
  while [ "$k" -le "$1" ]; do
    rows="$rows${rows:+, }($k, :'hq_id_$k'::text)"
    k=$((k + 1))
  done
  input="input(n, id) AS (VALUES $rows)"
  printf '%s\n' "SET LOCAL lock_timeout TO '30s';"
  printf 'WITH %s,\n' "$input"
  cat <<'SQL'
locked AS (SELECT i.id FROM items i WHERE i.id IN (SELECT id FROM input) ORDER BY i.id FOR KEY SHARE)
SELECT coalesce((SELECT string_agg(inp.id, ', ' ORDER BY inp.n)
                   FROM input inp
                  WHERE inp.id NOT IN (SELECT id FROM locked)), '') AS hq_missing \gset
SELECT :'hq_missing' = '' AS hq_ok \gset
\if :hq_ok
SELECT nextval('sets_set_id_seq') AS hq_set_id \gset
SQL
  printf 'WITH %s,\n' "$input"
  cat <<'SQL'
ins AS (
  INSERT INTO sets (set_id, position, item_id)
  SELECT :hq_set_id, n, id FROM input
  RETURNING position
), shown AS (
  INSERT INTO events (item_id, kind, note)
  SELECT id, 'shown', 'set ' || :hq_set_id || ' #' || n FROM input ORDER BY n
  RETURNING item_id
)
SQL
  if [ "$2" -eq 1 ]; then
    cat <<'SQL'
SELECT jsonb_build_object('set_id', :hq_set_id, 'items',
         jsonb_agg(jsonb_build_object('n', inp.n, 'id', inp.id) ORDER BY inp.n))
  FROM input inp;
SQL
  else
    cat <<'SQL'
SELECT 'set ' || :hq_set_id || E'\n'
       || string_agg(inp.n || '. ' || i.id || ' **' || i.question || '**', E'\n' ORDER BY inp.n)
  FROM input inp
  JOIN items i ON i.id = inp.id;
SQL
  fi
  cat <<'SQL'
\else
SELECT '!no item ' || :'hq_missing' || '; no set was opened';
\endif
SQL
}

cmd_run() {
  local json=0 raw id n=0 k errf out rc
  local -a ids=() pv=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      -*) hq_die_validation "set-open: unknown $(hq_flag_name "$1") (run human-queue.sh set-open --help)" ;;
      *)
        raw="$1"
        hq_item_id id "$raw"
        k=0
        while [ "$k" -lt "$n" ]; do
          if [ "${ids[k]}" = "$id" ]; then
            hq_die_validation "set-open: $id is given twice"
          fi
          k=$((k + 1))
        done
        ids[n]="$id"
        n=$((n + 1))
        if [ "$n" -gt "$HQ_SET_MAX" ]; then
          hq_die_validation "set-open: at most $HQ_SET_MAX items per set"
        fi
        ;;
    esac
    shift
  done
  if [ "$n" -eq 0 ]; then
    hq_die_validation "set-open: missing item ids (run human-queue.sh set-open --help)"
  fi

  k=0
  while [ "$k" -lt "$n" ]; do
    pv[${#pv[@]}]=-v
    pv[${#pv[@]}]="hq_id_$((k + 1))=${ids[k]}"
    k=$((k + 1))
  done

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__set_open_sql "$n" "$json" | hq_db_script -At "${pv[@]}" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_fail_unmigrated "$rc" "$errf" "set-open: nothing was recorded" 'sets_set_id_seq'
  fi
  hq_problem_check set-open "$out"
  if [ -z "$out" ]; then
    hq_die_error "set-open: the store returned no set"
  fi
  printf '%s\n' "$out"
}
