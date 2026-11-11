# shellcheck shell=bash
# summary: bind an account (its config directory) to a named queue, migrating the queue first
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR. Registry contract: lib/bindings.sh.

# shellcheck source=../lib/bindings.sh
. "$HQ_BIN_DIR/lib/bindings.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh bind — link an account to a named queue (issue #2183).

USAGE
  human-queue.sh bind --name <name> --schema <schema> [--config-dir <dir>] [--rebind]

  --name        the account's name, for example personal or work
  --schema      the queue (a Postgres schema) the account uses
  --config-dir  the account's config directory (default: CLAUDE_CONFIG_DIR,
                else $HOME/.claude)
  --rebind      allowed only to change an account that is already bound to a
                different queue

BEHAVIOR
  1. Validates the name and schema (exit 4 before any connection attempt).
  2. Refuses a different existing binding unless --rebind is given (exit 4,
     before any connection attempt). Binding again to the same queue is fine.
  3. Runs `migrate` in the schema (creating it if missing), as a subprocess
     with HUMAN_QUEUE_SCHEMA set to that schema.
  4. Records the binding in the registry (names and schema only, never the
     connection URL). Nothing is recorded if the migration fails.

EXIT CODES
  0  bound (or already bound to the same queue)
  1  the migration failed (nothing recorded)
  4  invalid argument, or the account is bound to a different queue without --rebind
  7  the registry is unreadable or malformed, or the database is unreachable
EOF
}

cmd_run() {
  local name="" schema="" dir="" rebind=0 old_schema rc=0 cli

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name|--schema|--config-dir)
        if [ "$#" -lt 2 ]; then
          hq_die_validation "bind: $1 needs a value (run human-queue.sh bind --help)"
        fi
        case "$1" in
          --name) name="$2" ;;
          --schema) schema="$2" ;;
          --config-dir) dir="$2" ;;
        esac
        shift 2
        ;;
      --rebind)
        rebind=1
        shift
        ;;
      *)
        hq_die_validation "bind: unexpected argument '$1' (run human-queue.sh bind --help)"
        ;;
    esac
  done

  if ! hqb_valid_name "$name"; then
    hq_die_validation "bind: --name must start with a letter or digit and use only letters, digits, dot, underscore, or hyphen (at most 64)"
  fi
  if ! hqb_valid_schema "$schema"; then
    hq_die_validation "bind: --schema must be a lowercase identifier ([a-z_][a-z0-9_]*, not pg_*, at most 63)"
  fi
  if [ -z "$dir" ]; then
    if ! dir=$(hqb_config_dir); then
      hq_die_validation "bind: cannot resolve the config directory (neither CLAUDE_CONFIG_DIR nor HOME is set); pass --config-dir"
    fi
  fi
  case "$dir" in
    /*) ;;
    *) hq_die_validation "bind: --config-dir must be an absolute path" ;;
  esac
  while [ "${#dir}" -gt 1 ] && [ "${dir%/}" != "$dir" ]; do
    dir="${dir%/}"
  done
  case "$dir" in
    *$'\t'*|*$'\n'*) hq_die_validation "bind: the config directory path may not contain a tab or newline" ;;
  esac

  rc=0
  hqb_lookup "$dir" || rc=$?
  case "$rc" in
    0)
      old_schema="$HQB_SCHEMA"
      if [ "$old_schema" != "$schema" ] && [ "$rebind" -ne 1 ]; then
        hq_die_validation "bind: this account is already bound to queue '$old_schema'; pass --rebind to change it"
      fi
      ;;
    3) ;;
    *) hq_die_unavailable "bind: $HQB_REASON" ;;
  esac

  # The migration runs in its own process so the connection URL and the
  # schema stay scoped to it. HUMAN_QUEUE_CLI is the offline test seam.
  cli="${HUMAN_QUEUE_CLI:-$HQ_BIN_DIR/human-queue.sh}"
  rc=0
  if [ -x "$cli" ]; then
    HUMAN_QUEUE_SCHEMA="$schema" "$cli" migrate || rc=$?
  else
    HUMAN_QUEUE_SCHEMA="$schema" bash "$cli" migrate || rc=$?
  fi
  if [ "$rc" -eq 7 ]; then
    hq_die_unavailable "bind: the store is unreachable (migration in '$schema'); nothing was recorded"
  fi
  if [ "$rc" -ne 0 ]; then
    hq_die_error "bind: the migration in '$schema' failed (exit $rc); nothing was recorded"
  fi

  if ! hqb_store "$dir" "$name" "$schema"; then
    hq_die_unavailable "bind: $HQB_REASON"
  fi
  printf 'bound %s to queue %s as %s\n' "$dir" "$schema" "$name"
}
