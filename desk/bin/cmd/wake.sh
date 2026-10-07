# shellcheck shell=bash
# summary: record whether the desk woke the asking thread after an answer (a `woken` or `wake-failed` event)
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
human-queue.sh wake — record the result of waking the asking thread.

USAGE
  human-queue.sh wake ID --result sent|failed [--note TEXT]

ARGUMENTS
  ID              a Decision id, for example D-43 (d-43 is accepted)
  --result sent   the messaging tool confirmed it delivered (or queued) the
                  pointer message `human-queue: D-43 answered`
  --result failed it did not: no running session, no messaging tool, or the
                  send call failed
  --note TEXT     what happened, one line, <= 200 characters: the address and
                  the tool's own status word on success, the reason on
                  failure. Never the message body of anything but the pointer.

BEHAVIOR
  After the operator answers, /desk wakes the session that asked with a
  pointer message; the thread then reads its answer from the store
  (pending-for). This records the outcome as one event: `woken` for sent,
  `wake-failed` for failed. The item itself is not changed, so `tick` does
  not report it again. Every call appends an event: each attempt is a fact
  (issue #1781 retries count `wake-failed`). Only an answered item is woken
  for: a Decision with no answer exits 4 and records nothing.

OUTPUT
  The canonical item id on stdout. Nothing on stderr on success.

EXIT CODES
  0  ok
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  invalid id, a Review id, a missing or unknown --result, a bad note, or
     a stray argument (before any connection attempt); no item has that id
     or it has no answer yet (after connecting, nothing written)
  5  the note looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__wake_sql() {
  hq_sql_lock_item "NO KEY UPDATE"
  cat <<'SQL'
SELECT coalesce((SELECT CASE WHEN i.answer IS NULL
                             THEN i.id || ' has no answer yet; there is nothing to wake for'
                             ELSE '' END
                   FROM items i WHERE i.id = :'hq_id'), 'no item ' || :'hq_id') AS hq_problem \gset
SELECT :'hq_problem' = '' AS hq_ok \gset
\if :hq_ok
WITH ev AS (
  INSERT INTO events (item_id, kind, note)
  VALUES (:'hq_id', :'hq_kind', nullif(:'hq_note', ''))
  RETURNING item_id
)
SELECT item_id FROM ev;
\else
SELECT '!' || :'hq_problem';
\endif
SQL
}

cmd_run() {
  local raw_id="" id="" have_id=0 result="" have_result=0 note="" have_note=0 kind errf out rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --result)
        if [ "$have_result" -eq 1 ]; then hq_die_validation "wake: --result given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "wake: --result needs a value (sent or failed)"; fi
        have_result=1
        result="$2"
        shift 2
        ;;
      --note)
        if [ "$have_note" -eq 1 ]; then hq_die_validation "wake: --note given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "wake: --note needs a value"; fi
        have_note=1
        note="$2"
        shift 2
        ;;
      -*) hq_die_validation "wake: unknown $(hq_flag_name "$1") (run human-queue.sh wake --help)" ;;
      *)
        if [ "$have_id" -eq 1 ]; then hq_die_validation "wake: takes one item id"; fi
        have_id=1
        raw_id="$1"
        shift
        ;;
    esac
  done
  if [ "$have_id" -eq 0 ]; then
    hq_die_validation "wake: missing item id (run human-queue.sh wake --help)"
  fi
  hq_item_id id "$raw_id"
  hq_require_kind wake "$id" decision
  case "$have_result:$result" in
    1:sent) kind=woken ;;
    1:failed) kind=wake-failed ;;
    0:*) hq_die_validation "wake: missing --result (sent or failed)" ;;
    *) hq_die_validation "wake: --result must be sent or failed" ;;
  esac
  if [ "$have_note" -eq 1 ]; then
    hq_check_text "wake: the note" "$note" 200
    hq_refuse_secret "wake: the note" "$note"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__wake_sql | hq_db_script -At -v "hq_id=$id" -v "hq_kind=$kind" \
    -v "hq_note=$note" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Before migration 005 the event kinds refuse woken / wake-failed: a CHECK
    # violation, not a missing object, so hq_fail_unmigrated cannot see it.
    if [ "$rc" -ne 2 ] && [ "$rc" -ne 143 ] && grep -q 'events_kind_check' "$errf"; then
      hq_die_error "wake: the store is not migrated (run human-queue.sh migrate); nothing was recorded"
    fi
    hq_db_fail "$rc" "$errf" "wake: nothing was recorded"
  fi
  hq_problem_check wake "$out"
  if [ "$out" != "$id" ]; then
    hq_die_error "wake: the store returned no item id"
  fi
  printf '%s\n' "$out"
}
