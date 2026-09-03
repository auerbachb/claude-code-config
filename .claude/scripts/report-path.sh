#!/usr/bin/env bash
# report-path.sh — Choose a report destination that cannot overwrite a prior one.
#
# PURPOSE
#   A monthly audit writes one report per run. Both /review-stack-audit and
#   /harness-audit used to derive that path from the calendar month alone, so
#   two audits landing in the same month resolved to the same file and the
#   second silently destroyed the first. That is not hypothetical: it happened
#   to /review-stack-audit in 2026-08 and PR #1338 had to invent a per-report
#   deviation to work around it (#1345, fixed by PR #1511; the /harness-audit
#   instance is #1519).
#
#   This script is that decision, made once and made testable. Given a target
#   directory, a month, and a series it returns the canonical name when that
#   name is free, and the first free counter-suffixed name when it is not.
#
#   It lives here rather than in either skill's directory because it now has two
#   consumers. .claude/scripts/ is where a helper shared across skills belongs —
#   the home the catalog, portability, and telemetry lints cover — and neither
#   audit should have to reach into the other's private directory to find it.
#
#   It is a pure function of the directory listing. It reaches no network and
#   CREATES NOTHING IN --dir — it only reads that directory and prints one path
#   to stdout. The caller does the writing.
#
#   (Like every script in this repo it appends one telemetry line to
#   $HOME/.claude/script-usage.log — the repo-wide convention enforced by
#   .github/scripts/script-usage-redirect-lint.sh, issue #1406. That write never
#   touches --dir and never affects the returned path.)
#
# NAMING
#   Base:       <series>-<month>.md          e.g. review-stack-audit-2026-08.md
#   On clash:   <series>-<month>-<N>.md      e.g. review-stack-audit-2026-08-2.md
#   N counts from 2 upward, so the first report of a month keeps the unsuffixed
#   name and reads exactly as it always has.
#
#   A name is "taken" if ANYTHING occupies it — a file, a directory, or a
#   symlink including a dangling one. All three would be clobbered or would
#   break a subsequent `mv`, so none of them is a free slot.
#
# FAIL CLOSED
#   A directory that cannot be listed cannot prove a name is free. Rather than
#   returning the base name on an unverifiable directory — laundering "I could
#   not check" into "no collision" — this exits 1 and prints no path. A missing
#   directory is the same refusal: callers create their target first (Step 0
#   does `mkdir -p`), so its absence means the caller and this script disagree
#   about where the report goes, which is exactly when guessing is worst.
#
# CONCURRENCY
#   The returned path is free at the moment of the check, and this script cannot
#   itself reserve it: it creates nothing, and any lock it took would be released
#   when it exits — before the caller writes. Atomicity therefore belongs to the
#   caller, and the caller claims the returned path immediately with O_EXCL
#   (`set -o noclobber`), so a simultaneous second audit finds it taken and is
#   handed the next suffix. `noclobber` refuses an existing file AND a dangling
#   symlink, matching this script's own definition of a taken name exactly.
#
# USAGE
#   report-path.sh --dir <directory> --month <YYYY-MM> --series <name>
#   report-path.sh --help | -h
#
#   --dir     Directory the report will be written into. Must already exist and
#             be readable and searchable.
#   --month   Report month, `YYYY-MM`.
#   --series  Filename series — the calling skill's own name, e.g.
#             `review-stack-audit` or `harness-audit`. REQUIRED, deliberately:
#             this engine serves more than one audit, and a default would let a
#             forgotten flag file one skill's report under another skill's
#             series. Writing into someone else's slot is the failure #1345
#             already had to undo by hand — it must not be the fallback.
#
# OUTPUT
#   One line on stdout: the chosen path, `<dir>/<name>.md`. Nothing else.
#
# EXIT STATUS
#   0  A free path was found and printed.
#   1  Environment error: the --dir DIRECTORY does not exist, is not a
#      directory, is not readable and searchable, or is not writable; or every
#      suffix up to the bound is taken. No path printed.
#   2  Usage error: a required FLAG is absent (--dir, --month, --series), a flag
#      value is empty, a flag is unknown, or --month/--series is malformed.
#   70  --help header extraction produced no output (internal defect).
#
# EXAMPLES
#   .claude/scripts/report-path.sh \
#     --dir ~/.claude/review-stack-audit --month 2026-08 --series review-stack-audit
#
#   .claude/scripts/report-path.sh \
#     --dir "$WORKTREE_ROOT/.claude/reference" --month 2026-08 --series harness-audit

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

usage_error() {
  echo "report-path.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

input_error() {
  echo "report-path.sh: $1" >&2
  exit 1
}

# Upper bound on the suffix search. Reaching it means something is very wrong
# with the directory, not that the next name is free — exhaustion is an error,
# never a wraparound onto an occupied path.
MAX_SUFFIX=999

DIR=""
MONTH=""
SERIES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --dir)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--dir requires a value"
      DIR="$2"; shift 2 ;;
    --dir=*)
      DIR="${1#--dir=}"; [[ -n "$DIR" ]] || usage_error "--dir value cannot be empty"; shift ;;
    --month)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--month requires a value"
      MONTH="$2"; shift 2 ;;
    --month=*)
      MONTH="${1#--month=}"; [[ -n "$MONTH" ]] || usage_error "--month value cannot be empty"; shift ;;
    --series)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--series requires a value"
      SERIES="$2"; shift 2 ;;
    --series=*)
      SERIES="${1#--series=}"; [[ -n "$SERIES" ]] || usage_error "--series value cannot be empty"; shift ;;
    --) shift; break ;;
    -*) usage_error "unknown flag: $1" ;;
    *)  usage_error "unexpected positional argument: $1" ;;
  esac
done

[[ $# -eq 0 ]] || usage_error "unexpected positional argument: $1"

[[ -n "$DIR"   ]] || usage_error "--dir is required"
[[ -n "$MONTH" ]] || usage_error "--month is required"

# No default series. Two skills call this, so a default would silently file one
# skill's report under the other's name on a forgotten flag — the same
# wrong-slot failure #1345 documents, arrived at from the other direction.
[[ -n "$SERIES" ]] || usage_error "--series is required (the calling skill's own name, e.g. review-stack-audit or harness-audit)"

# A malformed month would silently produce a name outside the series, which no
# later run would recognise as a month-mate — so it would stop colliding by
# being unfindable instead of by being distinct.
[[ "$MONTH" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] \
  || usage_error "--month must be YYYY-MM (got: $MONTH)"

# The series becomes a filename component. Anything with a slash, or a
# dot-leading name, would write somewhere other than --dir or produce a hidden
# file that the README index and every later run would miss.
[[ "$SERIES" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || usage_error "--series must start alphanumeric and contain only [A-Za-z0-9._-] (got: $SERIES)"

DIR="${DIR%/}"
[[ -n "$DIR" ]] || DIR="/"

[[ -e "$DIR" ]] || input_error "target directory does not exist: $DIR"
[[ -d "$DIR" ]] || input_error "target path is not a directory: $DIR"
[[ -r "$DIR" && -x "$DIR" ]] \
  || input_error "target directory is not readable and searchable, so a free name cannot be proven: $DIR"

# Writability is not needed to PROVE a name free, but a path in a directory the
# caller cannot write to is unusable, and failing here names the real problem.
# Step 7 claims the returned path with O_EXCL and retries on failure, so without
# this check a read-only directory would surface as "lost the claim race 5
# times" — a race that never happened.
[[ -w "$DIR" ]] \
  || input_error "target directory is not writable, so the returned path could not be claimed: $DIR"

# `-e` follows symlinks, so a DANGLING symlink reads as absent; `-L` catches it.
# Both occupy the name.
name_taken() {
  [[ -e "$1" || -L "$1" ]]
}

CANDIDATE="$DIR/$SERIES-$MONTH.md"
if ! name_taken "$CANDIDATE"; then
  printf '%s\n' "$CANDIDATE"
  exit 0
fi

for (( n = 2; n <= MAX_SUFFIX; n++ )); do
  CANDIDATE="$DIR/$SERIES-$MONTH-$n.md"
  if ! name_taken "$CANDIDATE"; then
    printf '%s\n' "$CANDIDATE"
    exit 0
  fi
done

input_error "every name from $SERIES-$MONTH.md through $SERIES-$MONTH-$MAX_SUFFIX.md is taken in $DIR"
