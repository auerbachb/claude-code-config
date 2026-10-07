# shellcheck shell=bash
# desk/bin/lib/lifecycle.sh — shared code for the lifecycle, set, and control
# subcommands (answer, ack, review, flag, comment, feedback, pending-for,
# set-open, set-resolve, state, register-control, tick; issue #1776). Sourced
# by those command files after lib/common.sh, lib/db.sh, and lib/items.sh;
# never executed. Bash 3.2 compatible.
#
# PUBLIC FUNCTIONS
#   hq_trim VAR VALUE           VALUE without leading or trailing whitespace
#                               (newlines included), into VAR
#   hq_check_answer FIELD VALUE an answer: non-blank, at most HQ_ANSWER_MAX
#                               characters, may span lines, no other control
#                               characters (tab aside); exits 4 otherwise
#   hq_require_kind CMD ID KIND exits 4 unless the id's prefix is KIND's
#                               (D- decision, R- review): checked before
#                               connecting, because the prefix IS the kind
#   hq_parse_one_id CMD ID_VAR ARGS...
#                               parses `CMD ID`; exits 4 on anything else
#   hq_parse_id_value CMD ID_VAR VALUE_VAR VALUE_NAME ARGS...
#                               parses `CMD ID VALUE`; exits 4 on anything else
#   hq_problem_check CMD OUT [SUFFIX]
#                               exits 4 when OUT is a problem line (`!reason`),
#                               naming the reason; returns 0 otherwise
#   hq_fail_unmigrated RC ERRFILE CONTEXT OBJECT_RE
#                               like hq_db_fail, but names `migrate` when the
#                               error is a missing OBJECT_RE (a store that has
#                               not had migration 003 applied)
#   hq_sql_lock_item MODE       SQL locking item :'hq_id' (MODE: UPDATE or
#                               NO KEY UPDATE) and setting :hq_n to 0 or 1
#   hq_sql_answer MODE N JSON   the answer transaction behind `answer` (MODE
#                               id) and `set-resolve` (MODE set)
#
# THE PROBLEM PROTOCOL
#   A transaction that finds a reason to refuse after connecting (an unknown
#   id, an answer letter past the last option, an item with no answer to
#   acknowledge) writes nothing and prints exactly one line, `!<reason>`.
#   The reason is built only from ids, numbers, and letters, never from free
#   text. hq_problem_check turns it into exit 4. No successful output starts
#   with `!` (it is an id, a JSON value, or a line starting with a digit or a
#   word).
#
# LOCKING
#   Every write locks the rows it reads first, in a statement of its own, and
#   reads them again in the next statement. Under READ COMMITTED each
#   statement takes a new snapshot (hq_db_script pins that level, whatever the
#   URL's `options` default), so what it reads after the lock is what the
#   previous lock holder committed: two concurrent `ack` calls record one
#   `acknowledged` event, not two. Several items are locked in id order, so
#   two multi-item writes can never deadlock.

HQ_ANSWER_MAX=4000

hq_trim() {
  local hq__v="$2"
  hq__v="${hq__v#"${hq__v%%[![:space:]]*}"}"
  hq__v="${hq__v%"${hq__v##*[![:space:]]}"}"
  printf -v "$1" '%s' "$hq__v"
}

hq_check_answer() {
  case "$2" in
    *[![:space:]]*) ;;
    *) hq_die_validation "$1 is empty" ;;
  esac
  hq_refuse_control "$1" "$2" newline
  if [ "${#2}" -gt "$HQ_ANSWER_MAX" ]; then
    hq_die_validation "$1 is longer than $HQ_ANSWER_MAX characters"
  fi
}

hq_require_kind() {
  case "$3:$2" in
    decision:D-*|review:R-*) return 0 ;;
    decision:*) hq_die_validation "$1: $2 is a Review; only Decisions (D-n) take $1 (Reviews take review, flag, or comment)" ;;
    *) hq_die_validation "$1: $2 is a Decision; only Reviews (R-n) take $1 (Decisions take answer and ack)" ;;
  esac
}

hq_parse_one_id() {
  local hq__cmd="$1" hq__idvar="$2" hq__raw="" hq__have=0
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      -*) hq_die_validation "$hq__cmd: unknown $(hq_flag_name "$1") (run human-queue.sh $hq__cmd --help)" ;;
      *)
        if [ "$hq__have" -eq 1 ]; then hq_die_validation "$hq__cmd: takes one item id"; fi
        hq__have=1
        hq__raw="$1"
        ;;
    esac
    shift
  done
  if [ "$hq__have" -eq 0 ]; then
    hq_die_validation "$hq__cmd: missing item id (run human-queue.sh $hq__cmd --help)"
  fi
  hq_item_id "$hq__idvar" "$hq__raw"
}

# hq_parse_id_value CMD ID_VAR VALUE_VAR VALUE_NAME ARGS... — `CMD ID VALUE`,
# both required, in that order. -h/--help anywhere prints cmd_usage. A value
# that starts with a dash is still a value once the id is known, so a comment
# such as "-- see above" is accepted. Locals carry an hq__ prefix so the
# caller's variable names can never be shadowed.
hq_parse_id_value() {
  local hq__cmd="$1" hq__idvar="$2" hq__valvar="$3" hq__name="$4" hq__raw="" hq__val="" hq__n=0 hq__a
  shift 4
  for hq__a in "$@"; do
    case "$hq__a" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
    esac
  done
  while [ "$#" -gt 0 ]; do
    case "$hq__n:$1" in
      0:-*) hq_die_validation "$hq__cmd: unknown $(hq_flag_name "$1") (run human-queue.sh $hq__cmd --help)" ;;
      0:*) hq__raw="$1" ;;
      1:*) hq__val="$1" ;;
      *) hq_die_validation "$hq__cmd: takes one item id and one $hq__name (quote a $hq__name that has spaces)" ;;
    esac
    hq__n=$((hq__n + 1))
    shift
  done
  if [ "$hq__n" -eq 0 ]; then
    hq_die_validation "$hq__cmd: missing item id (run human-queue.sh $hq__cmd --help)"
  fi
  if [ "$hq__n" -eq 1 ]; then
    hq_die_validation "$hq__cmd: missing $hq__name (run human-queue.sh $hq__cmd --help)"
  fi
  hq_item_id "$hq__idvar" "$hq__raw"
  printf -v "$hq__valvar" '%s' "$hq__val"
}

hq_problem_check() {
  case "$2" in
    '!'*) hq_die_validation "$1: ${2#!}${3:-}" ;;
  esac
  return 0
}

hq_fail_unmigrated() {
  local rc="$1" errf="$2" context="$3" re="$4"
  if [ "$rc" -ne 2 ] && [ "$rc" -ne 143 ] \
    && grep -qE "$re" "$errf" && grep -q 'does not exist' "$errf"; then
    hq_die_error "$context: the store is not migrated (run human-queue.sh migrate)"
  fi
  hq_db_fail "$rc" "$errf" "$context"
}

# The SQL below lives in functions (not heredocs inside $(...)) because bash
# 3.2's command-substitution scanner does not understand here-documents.

hq_sql_lock_item() {
  printf '%s\n' "SET LOCAL lock_timeout TO '30s';"
  printf 'SELECT count(*) AS hq_n FROM (SELECT id FROM items WHERE id = %s FOR %s) l \\gset\n' \
    ":'hq_id'" "$1"
}

# hq__sql_answer_input MODE N — the `input(n, pos, ref, id, reply)` CTE.
#   id:  one row from :'hq_id_1' and :'hq_reply_1'; pos and ref are NULL.
#   set: one row per pair from :'hq_pos_K' (a number, or empty), :'hq_ref_K'
#        (an item id such as D-43, or empty; issue #1779) and :'hq_reply_K'.
#        The id and its number are looked up in set :hq_set_id by whichever
#        was given (both NULL when the set has no such number or item).
# Only variable references are generated; values never enter the SQL text.
hq__sql_answer_input() {
  local k=1 rows=""
  if [ "$1" = id ]; then
    printf '%s\n' "input(n, pos, ref, id, reply) AS (VALUES (1, NULL::int, NULL::text, :'hq_id_1'::text, :'hq_reply_1'::text))"
    return 0
  fi
  while [ "$k" -le "$2" ]; do
    rows="$rows${rows:+, }($k, nullif(:'hq_pos_$k', '')::int, nullif(:'hq_ref_$k', '')::text, :'hq_reply_$k'::text)"
    k=$((k + 1))
  done
  printf '%s\n' "input(n, pos, ref, id, reply) AS ("
  printf '%s\n' "  SELECT v.n, coalesce(s.position::int, v.pos), v.ref, s.item_id, v.reply"
  printf '    FROM (VALUES %s) AS v(n, pos, ref, reply)\n' "$rows"
  printf '%s\n' "    LEFT JOIN sets s ON s.set_id = :hq_set_id AND (s.position = v.pos OR s.item_id = v.ref))"
}

# The `r` CTE: each input row with its item. A reply that is a single letter
# naming one of the item's options (A = the first) is an answer by option.
hq__sql_answer_rows() {
  cat <<'SQL'
r AS (
  SELECT inp.n, inp.pos, inp.ref, inp.id, inp.reply, i.id AS found, i.kind, i.status,
         i.answer AS old_answer, i.session_id AS session, i.options,
         cardinality(i.options) AS n_options,
         CASE WHEN cardinality(i.options) > 0 AND inp.reply ~ '^[A-Za-z]$'
              THEN upper(inp.reply) END AS letter
    FROM input inp
    LEFT JOIN items i ON i.id = inp.id
)
SQL
}

# hq_sql_answer MODE N JSON — the whole answer transaction:
#   1. (set) resolve the set: --set, else the latest one
#   2. lock the target items, in id order
#   3. validate every pair; the first problem (in reply order) becomes the
#      `!reason` line and nothing is written
#   4. write: the answer (an option's text when given by letter), status
#      `answered` (which clears an earlier acknowledgement), and one
#      `answered` event per item that changed. Re-sending the answer an item
#      already holds changes nothing and records nothing.
# Output: `answer` prints the id, or with --json one object {"id", "answer",
# "changed", "session"}; `set-resolve` prints one line per pair, or one JSON
# object with --json.
hq_sql_answer() {
  local mode="$1" n="$2" json="$3" input rows note
  input=$(hq__sql_answer_input "$mode" "$n")
  rows=$(hq__sql_answer_rows)
  if [ "$mode" = set ]; then
    note="'set ' || :hq_set_id || ' #' || c.pos"
  else
    note="NULL"
  fi

  printf '%s\n' "SET LOCAL lock_timeout TO '30s';"
  if [ "$mode" = set ]; then
    cat <<'SQL'
SELECT coalesce(nullif(:'hq_set', '')::bigint, (SELECT max(set_id) FROM sets), 0) AS hq_set_id \gset
SELECT EXISTS (SELECT 1 FROM sets WHERE set_id = :hq_set_id) AS hq_set_exists \gset
SQL
  fi
  printf 'WITH %s,\n' "$input"
  printf '%s\n' "locked AS (SELECT i.id FROM items i WHERE i.id IN (SELECT id FROM input) ORDER BY i.id FOR UPDATE)"
  printf '%s\n' "SELECT count(*) AS hq_locked FROM locked \\gset"

  printf 'WITH %s,\n%s\n' "$input" "$rows"
  printf '%s\n' "SELECT"
  if [ "$mode" = set ]; then
    cat <<'SQL'
  CASE WHEN NOT :'hq_set_exists'::boolean THEN
         CASE WHEN :'hq_set' = '' THEN 'no set has been opened (run set-open first)'
              ELSE 'set ' || :'hq_set' || ' does not exist' END
  ELSE
SQL
  fi
  printf '%s\n' "  coalesce(("
  printf '%s\n' "    SELECT CASE"
  if [ "$mode" = set ]; then
    # Only a set lookup can leave the id empty; :hq_set_id exists only here.
    printf '%s\n' "             WHEN r.id IS NULL AND r.ref IS NOT NULL THEN r.ref || ' is not in set ' || :hq_set_id"
    printf '%s\n' "             WHEN r.id IS NULL THEN 'set ' || :hq_set_id || ' has no number ' || r.pos"
    # One item named by its number and by its id (issue #1779).
    printf '%s\n' "             WHEN (SELECT count(*) FROM r r2 WHERE r2.id = r.id) > 1 THEN 'number ' || r.pos || ' (' || r.id || ') is answered twice'"
  fi
  cat <<'SQL'
             WHEN r.found IS NULL THEN 'no item ' || r.id
             WHEN r.kind <> 'decision' THEN r.id || ' is a Review; Reviews take review or flag, not an answer'
             ELSE r.id || ' has options A-' || chr(64 + r.n_options) || '; ' || r.letter || ' is not one of them'
           END
      FROM r
     WHERE r.id IS NULL OR r.found IS NULL OR r.kind <> 'decision'
        OR (r.letter IS NOT NULL AND ascii(r.letter) - 64 > r.n_options)
        OR (SELECT count(*) FROM r r2 WHERE r2.id = r.id) > 1
     ORDER BY r.n
     LIMIT 1), '')
SQL
  if [ "$mode" = set ]; then
    printf '%s\n' "  END"
  fi
  printf '%s\n' "  AS hq_problem \\gset"

  printf '%s\n' "SELECT :'hq_problem' = '' AS hq_ok \\gset"
  printf '%s\n' "\\if :hq_ok"
  printf 'WITH %s,\n%s,\n' "$input" "$rows"
  cat <<'SQL'
d AS (
  SELECT r.n, r.pos, r.id, r.session, r.letter, r.status, r.old_answer,
         CASE WHEN r.letter IS NOT NULL THEN r.options[ascii(r.letter) - 64]
              ELSE r.reply END AS answer
    FROM r
),
c AS (
  SELECT d.*,
         NOT (d.status IN ('answered', 'acknowledged')
              AND d.old_answer IS NOT DISTINCT FROM d.answer) AS changed
    FROM d
),
upd AS (
  UPDATE items t SET answer = c.answer, status = 'answered'
    FROM c
   WHERE t.id = c.id AND c.changed
  RETURNING t.id
),
ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT c.id, 'answered',
SQL
  printf "         nullif(concat_ws(', ', %s, 'option ' || c.letter), '')\n" "$note"
  cat <<'SQL'
    FROM c
   WHERE c.changed
   ORDER BY c.n
  RETURNING item_id
)
SQL
  if [ "$mode" = id ] && [ "$json" -eq 1 ]; then
    # `answer --json` (issue #1780): the fields the desk's wake rule needs.
    cat <<'SQL'
SELECT jsonb_build_object('id', c.id, 'answer', c.answer,
                          'changed', c.changed, 'session', c.session)
  FROM c;
SQL
  elif [ "$mode" = id ]; then
    printf '%s\n' "SELECT c.id FROM c;"
  elif [ "$json" -eq 1 ]; then
    cat <<'SQL'
SELECT jsonb_build_object('set_id', :hq_set_id, 'answers',
         jsonb_agg(jsonb_build_object('n', c.pos, 'id', c.id, 'answer', c.answer,
                                      'changed', c.changed, 'session', c.session)
                   ORDER BY c.n))
  FROM c;
SQL
  else
    cat <<'SQL'
SELECT string_agg(c.pos || '. ' || c.id || CASE WHEN c.changed THEN ' answered'
                                                ELSE ' unchanged (it already had that answer)' END,
                  E'\n' ORDER BY c.n)
  FROM c;
SQL
  fi
  printf '%s\n' "\\else"
  printf '%s\n' "SELECT '!' || :'hq_problem';"
  printf '%s\n' "\\endif"
}
