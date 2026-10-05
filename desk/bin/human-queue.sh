#!/usr/bin/env bash
# human-queue.sh — CLI for the human-queue store (Neon Postgres), the one
# program that reads or writes it. Design: desk/DESIGN.md; contract: desk/README.md.
# catalog: utilities — Human-queue store CLI (`desk/bin/human-queue.sh`): auto-discovers subcommands in `desk/bin/cmd/`, applies `desk/schema/` migrations, and exits 7 within two seconds when the database is unset or unreachable so callers can fail open
#
# USAGE
#   human-queue.sh <subcommand> [args]
#   human-queue.sh --help              list subcommands (never touches the database)
#   human-queue.sh <subcommand> --help that subcommand's contract (offline too)
#
# SUBCOMMANDS
#   Each lives in its own file, desk/bin/cmd/<name>.sh, found at run time — a
#   new subcommand is a new file, never an edit to this dispatcher. A command
#   file carries a `# summary: <one line>` header and defines cmd_usage and
#   cmd_run. `--help` below lists whatever is on disk.
#
# ENVIRONMENT
#   HUMAN_QUEUE_DATABASE_URL  postgres:// URL of the store. Secret: never
#                             printed, logged, or put on a command line.
#   HUMAN_QUEUE_SCHEMA        schema to run in (default public). Tests point it
#                             at a throwaway schema.
#   HUMAN_QUEUE_PSQL          psql binary override (default
#                             /opt/homebrew/bin/psql, then psql on PATH).
#
# EXIT CODES
#   0  ok
#   1  unexpected failure (for example a migration's SQL error)
#   4  validation or usage error — reported before any connection attempt
#   5  secret refused (subcommands that accept free text)
#   7  database unset, unparseable, client missing, or unreachable: within
#      two seconds, exactly one line on stderr
#
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

# Resolve this file's real directory through any chain of symlinks, so a
# future link from .claude/ into desk/ still finds lib/, cmd/, and schema/.
# Portable: `readlink -f` is missing from older macOS.
hq__self="${BASH_SOURCE[0]}"
while [ -L "$hq__self" ]; do
  hq__link_dir=$(cd -P "$(dirname "$hq__self")" && pwd)
  hq__self=$(readlink "$hq__self")
  case "$hq__self" in
    /*) ;;
    *) hq__self="$hq__link_dir/$hq__self" ;;
  esac
done
HQ_BIN_DIR=$(cd -P "$(dirname "$hq__self")" && pwd)
HQ_DESK_DIR=$(dirname "$HQ_BIN_DIR")
export HQ_BIN_DIR HQ_DESK_DIR
unset hq__self hq__link_dir

# shellcheck source=lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"

hq__usage() {
  local f name summary LC_ALL=C
  cat <<'EOF'
human-queue.sh — CLI for the human-queue store (desk/).

USAGE
  human-queue.sh <subcommand> [args]
  human-queue.sh <subcommand> --help
  human-queue.sh --help

SUBCOMMANDS
EOF
  for f in "$HQ_BIN_DIR"/cmd/*.sh; do
    [ -f "$f" ] || continue
    name="${f##*/}"
    name="${name%.sh}"
    summary=$(sed -n 's/^# summary: //p' "$f" | sed -n '1p')
    printf '  %-12s %s\n' "$name" "${summary:-(no summary)}"
  done
  cat <<'EOF'

ENVIRONMENT
  HUMAN_QUEUE_DATABASE_URL  postgres:// URL of the store (secret; never printed)
  HUMAN_QUEUE_SCHEMA        schema to run in (default public)
  HUMAN_QUEUE_PSQL          psql binary override

EXIT CODES
  0  ok
  1  unexpected failure (for example a migration's SQL error)
  4  validation or usage error, reported before any connection attempt
  5  secret refused
  7  database unset, unparseable, client missing, or unreachable
     (within two seconds, one line on stderr, so callers can fail open)

See desk/README.md for provisioning and the full contract.
EOF
}

if [ "$#" -eq 0 ]; then
  hq_die_validation "missing subcommand (run human-queue.sh --help)"
fi

case "$1" in
  -h|--help|help)
    hq__usage
    exit 0
    ;;
esac

hq_sub="$1"
shift
case "$hq_sub" in
  ''|[!a-z]*|*[!a-z0-9-]*)
    hq_die_validation "invalid subcommand name (run human-queue.sh --help)"
    ;;
esac
hq_cmd_file="$HQ_BIN_DIR/cmd/$hq_sub.sh"
if [ ! -f "$hq_cmd_file" ]; then
  hq_die_validation "unknown subcommand '$hq_sub' (run human-queue.sh --help)"
fi

# shellcheck source=/dev/null
. "$hq_cmd_file"

case "${1:-}" in
  -h|--help)
    cmd_usage
    exit 0
    ;;
esac

cmd_run "$@"
