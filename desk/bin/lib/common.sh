# shellcheck shell=bash
# desk/bin/lib/common.sh — shared helpers for human-queue.sh and its command
# files. Sourced, never executed. Bash 3.2 compatible (macOS /bin/bash): no
# associative arrays, no mapfile, no ${var,,}.
#
# Exit-code contract (desk/README.md is the canonical statement):
#   0  ok
#   1  unexpected failure (e.g. a migration's SQL error)
#   4  validation, including usage errors
#   5  secret refused (used by `add`, issue #1775)
#   7  database unset, unparseable, client missing, or unreachable — within two
#      seconds, with exactly one line on stderr, so callers can fail open

HQ_EXIT_ERROR=1
HQ_EXIT_VALIDATION=4
HQ_EXIT_SECRET=5
HQ_EXIT_UNAVAILABLE=7

# hq_die CODE MESSAGE...
# Prints exactly ONE line on stderr (embedded newlines are flattened, so a
# multi-line psql error can never break the one-line contract) and exits CODE.
hq_die() {
  local code="$1" msg
  shift
  msg="$*"
  msg="${msg//$'\r'/ }"
  msg="${msg//$'\n'/ }"
  printf 'human-queue: %s\n' "$msg" >&2
  exit "$code"
}

hq_die_error()       { hq_die "$HQ_EXIT_ERROR" "$@"; }
hq_die_validation()  { hq_die "$HQ_EXIT_VALIDATION" "$@"; }
hq_die_secret()      { hq_die "$HQ_EXIT_SECRET" "$@"; }
hq_die_unavailable() { hq_die "$HQ_EXIT_UNAVAILABLE" "$@"; }

# hq_bigint_ok DIGITS — true when DIGITS (digits only, no leading zero) is at
# most bigint's maximum, 9223372036854775807, the range of a bigint id such as
# sets_set_id_seq's: up to 19 digits. A 19-digit value is compared in two
# halves (10 + 9 digits), so bash arithmetic never sees a number past that
# maximum. Shared by set-resolve and feedback --set.
hq_bigint_ok() {
  local hi lo
  [ "${#1}" -lt 19 ] && return 0
  [ "${#1}" -eq 19 ] || return 1
  hi=$((10#${1:0:10}))
  lo=$((10#${1:10}))
  [ "$hi" -lt 9223372036 ] || { [ "$hi" -eq 9223372036 ] && [ "$lo" -le 854775807 ]; }
}

# hq_schema — prints the schema every statement runs in.
# HUMAN_QUEUE_SCHEMA selects it (default `public`). The value is applied with
# `SET LOCAL search_path` inside each transaction, so it holds on Neon's pooled
# endpoint too (the pooler drops startup options such as PGOPTIONS). Tests use
# it to run in a throwaway schema and never touch the live queue.
# Exits 4 on anything that is not a plain lowercase identifier.
hq_schema() {
  local s="${HUMAN_QUEUE_SCHEMA:-public}"
  case "$s" in
    ''|pg_*|[!a-z_]*|*[!a-z0-9_]*)
      hq_die_validation "HUMAN_QUEUE_SCHEMA must be a lowercase identifier ([a-z_][a-z0-9_]*, not pg_*)"
      ;;
  esac
  if [ "${#s}" -gt 63 ]; then
    hq_die_validation "HUMAN_QUEUE_SCHEMA is longer than 63 characters"
  fi
  printf '%s\n' "$s"
}

# Temp files created through hq_mktemp are removed on exit. Command files that
# need their own EXIT work should call hq__cleanup_tmp from their trap.
# Newline-separated, so a TMPDIR containing spaces still cleans up.
HQ_TMPFILES=""
hq__cleanup_tmp() {
  local hq__f
  while IFS= read -r hq__f; do
    if [ -n "$hq__f" ]; then rm -f "$hq__f"; fi
  done <<EOF
$HQ_TMPFILES
EOF
}
trap hq__cleanup_tmp EXIT

# hq_mktemp VAR — creates a private temp file and stores its path in VAR.
# Assigns rather than prints: a `$(hq_mktemp)` subshell would register the file
# for cleanup in the subshell only, leaking it. The locals carry an hq__ prefix
# so a caller's VAR can never be shadowed by one of them.
hq_mktemp() {
  local hq__dir="${TMPDIR:-/tmp}" hq__f
  case "${1:-}" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*|hq__dir|hq__f)
      hq_die_error "hq_mktemp: invalid variable name '${1:-}'"
      ;;
  esac
  hq__dir="${hq__dir%/}"
  hq__f=$(mktemp "$hq__dir/human-queue.XXXXXX") || hq_die_error "cannot create a temp file"
  HQ_TMPFILES="$HQ_TMPFILES
$hq__f"
  printf -v "$1" '%s' "$hq__f"
}
