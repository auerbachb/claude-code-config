# shellcheck shell=bash
# summary: the queue's owner stamp: get, set NAME (first bind), transfer NAME [--confirm] (issue #2184)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR. The stamp is the account NAME (see
# lib/bindings.sh), stored under the reserved state key queue_owner. Every
# guarded write (register-control, tick --session, add) compares it with the
# caller's binding name; this file is the only writer.

# shellcheck source=../lib/bindings.sh
. "$HQ_BIN_DIR/lib/bindings.sh"
# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh owner — the account that owns this queue (issue #2184).

USAGE
  human-queue.sh owner get
  human-queue.sh owner set NAME
  human-queue.sh owner transfer NAME [--confirm]

ARGUMENTS
  NAME       the account name (for example personal or work), the same name
             bind records in the registry

BEHAVIOR
  get       prints the owner, or "no owner" for a queue that has never been
            bound. Read-only.
  set       stamps a queue that has no owner yet, under an exclusive lock.
            Setting the owner it already has changes nothing. A different
            owner is refused (exit 4) and names both: use transfer instead.
            `bind` runs set, so a queue is stamped only by bind (and by
            carry-over, which runs bind). Nothing else stamps it.
  transfer  moves the queue to another owner. This is the explicit rebind
            for the queue side; bind --rebind changes only the account side.
            Without --confirm it writes nothing and prints the owner it would
            replace and the number of open items the queue carries. With
            --confirm it writes the new owner in the same transaction, and
            clears tick_at and the control session, so the previous owner's
            desk is no longer live until the new owner registers and ticks.
            No event is recorded: the stamp is not an item.

  The desk never calls transfer. After a transfer, the account that should
  keep this queue binds it again (bind --name NAME --schema SCHEMA), which
  then matches the new stamp.

OUTPUT
  get: the owner, one line. set and transfer: one line saying what happened.

EXIT CODES
  0  ok (including a transfer without --confirm, which changed nothing)
  1  unexpected database failure
  4  a missing or invalid NAME or argument; set on a queue with a different
     owner; transfer on a queue with no owner (before or after connecting,
     nothing written)
  5  the name looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__owner_get_sql() {
  printf '%s\n' "SELECT coalesce((SELECT value FROM state WHERE key = 'queue_owner'), 'no owner');"
}

# hq__owner_set_sql — the first stamp, or the no-op or refusal for a stamp that
# is already there. The exclusive lock makes the read and the insert one step.
hq__owner_set_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:owner:' || :'hq_schema', 0)) AS hq_owner_locked \gset
SELECT coalesce((SELECT value FROM state WHERE key = 'queue_owner'), '') AS hq_owner \gset
SELECT (:'hq_owner' = '') AS hq_stamp \gset
\if :hq_stamp
INSERT INTO state (key, value) VALUES ('queue_owner', :'hq_name');
SELECT 'queue owner set to ' || :'hq_name';
\else
SELECT CASE WHEN :'hq_owner' = :'hq_name'
            THEN 'queue owner is already ' || :'hq_name'
            ELSE '!this queue belongs to ''' || :'hq_owner' || '''; it cannot be set to ''' || :'hq_name'
                 || ''' (owner transfer moves a queue, and changes nothing here)'
       END;
\endif
SQL
}

# hq__owner_transfer_sql — the explicit rebind. Without --confirm it only
# reports; the write is one UPDATE, under the same exclusive lock.
hq__owner_transfer_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:owner:' || :'hq_schema', 0)) AS hq_owner_locked \gset
SELECT coalesce((SELECT value FROM state WHERE key = 'queue_owner'), '') AS hq_owner \gset
SELECT count(*) AS hq_open FROM items WHERE status = 'open' \gset
SELECT (:'hq_owner' <> '' AND :'hq_owner' <> :'hq_name' AND :'hq_confirm' = '1') AS hq_write \gset
\if :hq_write
UPDATE state SET value = :'hq_name' WHERE key = 'queue_owner';
-- The previous owner's desk is no longer live: its last tick and its control
-- registration go, so the capture hook stops queueing questions for an account
-- that is no longer this queue's owner, and the new owner starts from no
-- control session. The new owner's register-control and tick stamp it again.
DELETE FROM state WHERE key IN ('tick_at', 'control_session');
\endif
SELECT CASE
  WHEN :'hq_owner' = '' THEN '!this queue has no owner to transfer; the first bind stamps it'
  WHEN :'hq_owner' = :'hq_name' THEN 'queue owner is already ' || :'hq_name' || '; nothing changed'
  WHEN :'hq_confirm' = '1' THEN 'transferred this queue from ''' || :'hq_owner' || ''' to ''' || :'hq_name'
       || ''' (' || :'hq_open' || ' open items)'
  ELSE 'would transfer this queue from ''' || :'hq_owner' || ''' to ''' || :'hq_name' || ''' ('
       || :'hq_open' || ' open items); run again with --confirm to transfer it'
END;
SQL
}

cmd_run() {
  local action="" name="" confirm=0 arg rc=0 out errf

  case "${1:-}" in
    -h|--help)
      cmd_usage
      exit 0
      ;;
  esac
  if [ "$#" -eq 0 ]; then
    hq_die_validation "owner: missing action: get, set, or transfer (run human-queue.sh owner --help)"
  fi
  action="$1"
  shift
  case "$action" in
    get|set|transfer) ;;
    -*) hq_die_validation "owner: unknown $(hq_flag_name "$action") (run human-queue.sh owner --help)" ;;
    *) hq_die_validation "owner: unknown action (expected get, set, or transfer)" ;;
  esac

  for arg in "$@"; do
    case "$arg" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
    esac
  done

  if [ "$action" = get ]; then
    if [ "$#" -gt 0 ]; then hq_die_validation "owner get: takes no arguments"; fi
  else
    if [ "$#" -lt 1 ]; then hq_die_validation "owner $action: missing NAME (run human-queue.sh owner --help)"; fi
    name="$1"
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --confirm)
          if [ "$action" != transfer ]; then hq_die_validation "owner set: --confirm applies only to owner transfer"; fi
          confirm=1
          ;;
        -*) hq_die_validation "owner $action: unknown $(hq_flag_name "$1") (run human-queue.sh owner --help)" ;;
        *) hq_die_validation "owner $action: unexpected argument '$1' (run human-queue.sh owner --help)" ;;
      esac
      shift
    done
    if ! hqb_valid_name "$name"; then
      hq_die_validation "owner $action: NAME must start with a letter or digit and use only letters, digits, dot, underscore, or hyphen (at most 64)"
    fi
    hq_refuse_secret "owner $action: the name" "$name"
  fi

  hq_db_connect
  hq_mktemp errf
  case "$action" in
    get)
      out=$(hq__owner_get_sql | hq_db_script -At 2>"$errf") || rc=$?
      ;;
    set)
      out=$(hq__owner_set_sql | hq_db_script -At -v "hq_name=$name" 2>"$errf") || rc=$?
      ;;
    transfer)
      out=$(hq__owner_transfer_sql | hq_db_script -At -v "hq_name=$name" -v "hq_confirm=$confirm" 2>"$errf") || rc=$?
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "owner $action: nothing was changed"
  fi
  if [ -z "$out" ]; then
    hq_die_error "owner $action: the store returned nothing"
  fi
  hq_problem_check "owner $action" "$out"
  printf '%s\n' "$out"
}
