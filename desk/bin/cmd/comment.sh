# shellcheck shell=bash
# summary: add a short note to an item's history (a `commented` event)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh comment — add a short note to an item's history.

USAGE
  human-queue.sh comment ID TEXT

ARGUMENTS
  ID    any item id, for example D-43 or R-88 (d-43 is accepted)
  TEXT  the note: one line, <= 200 characters. Never a transcript or a
        diff. Quote it.

BEHAVIOR
  Records one `commented` event carrying TEXT. The item itself is not
  changed: its status stays, and `tick` does not report it again (comments
  are annotations written from the desk). Every call appends a comment.

OUTPUT
  The canonical item id on stdout. Nothing on stderr on success.

EXIT CODES
  0  ok
  1  unexpected database failure
  4  invalid id, a missing or blank comment, or a stray argument (before
     any connection attempt); no item has that id (after connecting)
  5  the comment looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__comment_sql() {
  cat <<'SQL'
WITH ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT id, 'commented', :'hq_text' FROM items WHERE id = :'hq_id'
  RETURNING item_id
)
SELECT coalesce((SELECT item_id FROM ev), '!no item ' || :'hq_id');
SQL
}

cmd_run() {
  local id="" text="" errf out rc
  hq_parse_id_value comment id text comment "$@"
  hq_check_text "comment: the comment" "$text" 200
  hq_refuse_secret "comment: the comment" "$text"

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__comment_sql | hq_db_script -At -v "hq_id=$id" -v "hq_text=$text" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "comment: nothing was recorded"
  fi
  hq_problem_check comment "$out"
  if [ "$out" != "$id" ]; then
    hq_die_error "comment: the store returned no item id"
  fi
  printf '%s\n' "$out"
}
