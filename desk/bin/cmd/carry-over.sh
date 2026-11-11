# shellcheck shell=bash
# summary: carry existing installs over to explicit bindings (default config dir to public; each --profile to its settings.json queue)
#
# Sourced by desk/bin/human-queue.sh. Binds through `human-queue.sh bind` in a
# subprocess, so each step migrates and records exactly as `bind` does.
# Registry contract: lib/bindings.sh.

# shellcheck source=../lib/bindings.sh
. "$HQ_BIN_DIR/lib/bindings.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh carry-over — bind existing installs (issue #2183).

USAGE
  human-queue.sh carry-over [--profile <config dir>]... [--dry-run]

WHAT IT DOES
  1. The default config directory ($HOME/.claude) is bound to queue `public`
     as `personal`.
  2. Each --profile directory is bound to the queue named by its settings.json
     env.HUMAN_QUEUE_SCHEMA entry (the name is the queue). Only after that bind
     succeeds is the interim entry removed from that settings.json; every other
     key is kept, and the file's mode is kept.

  Preflight runs for every account before anything is written, including in a
  dry run. It refuses (exit 4) a profile with no interim entry that is not
  already bound, a queue name that cannot serve as an account name, and any
  account already bound to a different queue. A profile with no interim entry
  that is already bound to its queue is treated as complete. Nothing is guessed.

  --dry-run prints the plan and changes nothing.

  HOME (not CLAUDE_CONFIG_DIR) decides the default directory. Tests point HOME
  at a temp directory.

EXIT CODES
  0  carried over (or the dry run printed its plan)
  1  a migration or a settings write failed (earlier steps stay done)
  4  a profile has no interim entry, a conflict, or an argument is invalid
  7  the registry is unreadable, malformed, or the database is unreachable
EOF
}

# carry_check_bound DIR PLANNED_SCHEMA — the preflight for one account. Prints
# nothing; returns 0 when DIR is unbound or bound to PLANNED_SCHEMA, returns 4
# for a conflict, and exits 7 for an unreadable or malformed registry.
carry_check_bound() {
  local rc=0
  hqb_lookup "$1" || rc=$?
  case "$rc" in
    0)
      if [ "$HQB_SCHEMA" != "$2" ]; then
        hq_die_validation "carry-over: $1 is already bound to queue '$HQB_SCHEMA', not '$2'; resolve it with bind --rebind by hand"
      fi
      ;;
    3) ;;
    *) hq_die_unavailable "carry-over: $HQB_REASON" ;;
  esac
}

cmd_run() {
  local dry=0 profiles="" plan="" p schema settings rc=0 tab

  tab=$'\t'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)
        if [ "$#" -lt 2 ]; then
          hq_die_validation "carry-over: --profile needs a directory (run human-queue.sh carry-over --help)"
        fi
        case "$2" in
          /*) ;;
          *) hq_die_validation "carry-over: --profile must be an absolute path" ;;
        esac
        p="$2"
        while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do
          p="${p%/}"
        done
        if [ "$p" = "/" ]; then
          hq_die_validation "carry-over: --profile must name a directory below the root"
        fi
        profiles="$profiles$p
"
        shift 2
        ;;
      --dry-run)
        dry=1
        shift
        ;;
      *)
        hq_die_validation "carry-over: unexpected argument '$1' (run human-queue.sh carry-over --help)"
        ;;
    esac
  done

  if [ -z "${HOME:-}" ]; then
    hq_die_validation "carry-over: HOME is not set"
  fi

  # Preflight the whole plan before anything is written, so a refusal leaves
  # the registry and every settings file alone.
  carry_check_bound "$HOME/.claude" public

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    settings="$p/settings.json"
    if [ ! -f "$settings" ]; then
      hq_die_validation "carry-over: $p has no settings.json; bind it by hand with bind --config-dir"
    fi
    rc=0
    schema=$(python3 -I "$HQ_BIN_DIR/lib/settings_env.py" get "$settings") || rc=$?
    if [ "$rc" -ne 0 ]; then
      hq_die_validation "carry-over: $settings could not be read"
    fi
    if [ -z "$schema" ]; then
      # No interim entry: complete only when the account is already bound.
      rc=0
      hqb_lookup "$p" || rc=$?
      case "$rc" in
        0) continue ;;
        3) hq_die_validation "carry-over: $settings has no HUMAN_QUEUE_SCHEMA entry; bind it by hand with bind --config-dir" ;;
        *) hq_die_unavailable "carry-over: $HQB_REASON" ;;
      esac
    fi
    if ! hqb_valid_schema "$schema"; then
      hq_die_validation "carry-over: the HUMAN_QUEUE_SCHEMA in $settings is not a valid queue name"
    fi
    if ! hqb_valid_name "$schema"; then
      hq_die_validation "carry-over: the HUMAN_QUEUE_SCHEMA in $settings cannot be used as an account name (must start with a letter or digit); bind it by hand with bind --config-dir"
    fi
    carry_check_bound "$p" "$schema"
    plan="$plan$p$tab$schema
"
  done <<EOF
$profiles
EOF

  if [ "$dry" -eq 1 ]; then
    printf 'would bind %s to queue public as personal\n' "$HOME/.claude"
    while IFS="$tab" read -r p schema; do
      [ -n "$p" ] || continue
      printf 'would bind %s to queue %s as %s, then remove HUMAN_QUEUE_SCHEMA from %s/settings.json\n' \
        "$p" "$schema" "$schema" "$p"
    done <<EOF
$plan
EOF
    return 0
  fi

  rc=0
  bash "$HQ_BIN_DIR/human-queue.sh" bind --config-dir "$HOME/.claude" --name personal --schema public || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 7 ]; then
      hq_die_unavailable "carry-over: binding $HOME/.claude could not reach the store or the registry (exit 7); nothing else was changed"
    fi
    hq_die_error "carry-over: binding $HOME/.claude failed (exit $rc); nothing else was changed"
  fi
  printf 'carried over %s to queue public as personal\n' "$HOME/.claude"

  while IFS="$tab" read -r p schema; do
    [ -n "$p" ] || continue
    rc=0
    bash "$HQ_BIN_DIR/human-queue.sh" bind --config-dir "$p" --name "$schema" --schema "$schema" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 7 ]; then
        hq_die_unavailable "carry-over: binding $p could not reach the store or the registry (exit 7); its settings.json was not changed"
      fi
      hq_die_error "carry-over: binding $p failed (exit $rc); its settings.json was not changed"
    fi
    rc=0
    python3 -I "$HQ_BIN_DIR/lib/settings_env.py" drop "$p/settings.json" "$schema" || rc=$?
    if [ "$rc" -ne 0 ]; then
      hq_die_error "carry-over: $p is bound, but removing its interim entry failed (exit $rc); remove HUMAN_QUEUE_SCHEMA from its settings.json by hand"
    fi
    printf 'carried over %s to queue %s as %s; removed its interim HUMAN_QUEUE_SCHEMA entry\n' "$p" "$schema" "$schema"
  done <<EOF
$plan
EOF
}
