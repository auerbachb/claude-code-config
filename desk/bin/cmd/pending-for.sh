# shellcheck shell=bash
# summary: list the answered Decisions a session asked and has not acknowledged yet
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh pending-for — answers waiting for a session to read them.

USAGE
  human-queue.sh pending-for SESSION [--json]

ARGUMENTS
  SESSION  the asking session's id, as given to add --session (one line,
           <= 200 characters)
  --json   print one JSON array of item objects instead ([] when none)

BEHAVIOR
  Lists the Decisions whose return address is SESSION and whose status is
  `answered`: answered and not yet acknowledged. The asking thread reads
  each answer, acts on it, then runs `ack ID` (ideally `ack ID --answer
  TEXT`); an acknowledged item no longer appears. An item answered again
  after it was acknowledged appears again. Oldest answer first. Reading
  records no event.

OUTPUT
  Each item exactly as `get` prints it (the question in bold, the context as
  a numbered list, then `Answer: ...`), separated by blank lines; nothing at
  all when no answer is waiting.

EXIT CODES
  0  ok (including when nothing is waiting)
  1  unexpected database failure
  4  missing or invalid session, or a stray argument (before any connection
     attempt)
  5  the session id looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# Answered, unacknowledged Decisions of one session; the latest `answered`
# event orders them, oldest first.
hq__pending_where() {
  printf '%s' "i.kind = 'decision' AND i.status = 'answered' AND i.session_id = :'hq_session'"
}

hq__pending_order() {
  cat <<'SQL'
(SELECT max(e.id) FROM events e WHERE e.item_id = i.id AND e.kind = 'answered') NULLS FIRST,
i.created_at, i.id
SQL
}

hq__pending_sql() {
  if [ "$1" -eq 1 ]; then
    printf 'SELECT coalesce(jsonb_agg(%s ORDER BY\n' "$(hq_sql_item_json)"
    hq__pending_order
    printf "), '[]'::jsonb) FROM items i WHERE %s;\n" "$(hq__pending_where)"
  else
    printf '%s\n' "SELECT string_agg(r.rendered, E'\\n\\n' ORDER BY r.n) FROM ("
    printf '%s\n' "  SELECT"
    hq_sql_render_item
    printf '%s\n' "  AS rendered, row_number() OVER (ORDER BY"
    hq__pending_order
    printf '  ) AS n FROM items i WHERE %s\n' "$(hq__pending_where)"
    printf '%s\n' ") r HAVING count(*) > 0;"
  fi
}

cmd_run() {
  local session="" have=0 json=0 errf out rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      -*) hq_die_validation "pending-for: unknown $(hq_flag_name "$1") (run human-queue.sh pending-for --help)" ;;
      *)
        if [ "$have" -eq 1 ]; then hq_die_validation "pending-for: takes one session id"; fi
        have=1
        session="$1"
        ;;
    esac
    shift
  done
  if [ "$have" -eq 0 ]; then
    hq_die_validation "pending-for: missing session id (run human-queue.sh pending-for --help)"
  fi
  hq_check_text "pending-for: the session id" "$session" 200
  # The session id reaches psql's argv: a secret-shaped one stops here.
  hq_refuse_secret "pending-for: the session id" "$session"

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__pending_sql "$json" | hq_db_script -At -v "hq_session=$session" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "pending-for"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}
