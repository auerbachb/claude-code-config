# shellcheck shell=bash
# summary: list every account and its queue, or --current for this account's queue (no connection URL is read or shown)
#
# Sourced by desk/bin/human-queue.sh. Reads the registry only; never contacts
# the store, so it works in an unbound account and with no database URL.

# shellcheck source=../lib/bindings.sh
. "$HQ_BIN_DIR/lib/bindings.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh bindings — list accounts and their queues (issue #2183).

USAGE
  human-queue.sh bindings
  human-queue.sh bindings --current

OUTPUT
  Without --current: one line per account: its config directory, name, and
  queue, marked "(this account)" for the config directory in use here.
  With --current: one line, "account: <name>  queue: <schema>", for the
  account in use here. The connection URL is never read or printed, and the
  store is never contacted.

EXIT CODES
  0  listed (or no accounts are bound yet); --current found this account's queue
  4  --current and this account is not bound to a queue (the refusal names the
     bind command)
  7  the registry is unreadable or malformed
EOF
}

# --current: this account's name and queue, from the registry alone (issue
# #2185). The desk-start block runs it first, so an unbound account is refused
# before migrate, the hold read, or any control registration.
current_run() {
  local dir cli_path rc=0
  if ! dir=$(hqb_config_dir); then
    hq_die_unavailable "bindings: neither CLAUDE_CONFIG_DIR nor HOME is set, so this account cannot be identified"
  fi
  hqb_lookup "$dir" || rc=$?
  case "$rc" in
    0)
      printf 'account: %s  queue: %s\n' "$HQB_NAME" "$HQB_SCHEMA"
      return 0
      ;;
    3)
      printf -v cli_path '%q' "$HQ_BIN_DIR/desk-cli.sh"
      printf "desk-cli: You can't run the desk here until you configure a queue for this account. Bind it with: %s bind --name <name> --schema <schema>\n" "$cli_path" >&2
      exit 4
      ;;
    *) hq_die_unavailable "bindings: $HQB_REASON" ;;
  esac
}

cmd_run() {
  local file dir name schema line rc=0 here mark n=0

  if [ "${1:-}" = "--current" ]; then
    shift
    if [ "$#" -gt 0 ]; then
      hq_die_validation "bindings: unexpected argument '$1' (run human-queue.sh bindings --help)"
    fi
    current_run
    return 0
  fi

  if [ "$#" -gt 0 ]; then
    hq_die_validation "bindings: unexpected argument '$1' (run human-queue.sh bindings --help)"
  fi

  # The registry is read by lib/bindings.sh's lookup for validation first, so
  # a malformed file fails here the same way it fails for every desk command.
  file=$(hqb_file)
  if [ -e "$file" ]; then
    rc=0
    hqb_lookup "" || rc=$?
    if [ "$rc" -eq 7 ]; then
      hq_die_unavailable "bindings: $HQB_REASON"
    fi
  fi

  here=$(hqb_config_dir 2>/dev/null) || here=""
  printf '%-48s  %-16s  %s\n' "ACCOUNT (config directory)" "NAME" "QUEUE"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|'#'*) continue ;;
      esac
      dir="${line%%$'\t'*}"
      name="${line#*$'\t'}"
      schema="${name#*$'\t'}"
      name="${name%%$'\t'*}"
      mark=""
      if [ "$dir" = "$here" ]; then mark="  (this account)"; fi
      printf '%-48s  %-16s  %s%s\n' "$dir" "$name" "$schema" "$mark"
      n=$((n + 1))
    done < "$file"
  fi
  if [ "$n" -eq 0 ]; then
    printf '(no accounts are bound yet; bind this one with: desk-cli.sh bind --name <name> --schema <schema>)\n'
  fi
}
