#!/usr/bin/env bash
# shell-lint: reject `<producer> | grep -q …` in shell files that enable
# `set -o pipefail` (issue #1648).
#
# === The defect this exists to prevent ===
#
# `grep -q` exits the moment it finds its first match. If the producer on the
# left of the pipe is still writing at that point — a multi-KB `printf '%s'
# "$big"`, a script echoing several lines, `git log`, `launchctl list` — its
# next write() hits a closed pipe, it dies of SIGPIPE (status 141), and under
# `set -o pipefail` that 141 becomes the PIPELINE's status. A match that
# SUCCEEDED reads as a failure, and `|| fail "…"` fires on a true assertion.
#
# It is a race, not a bug you can reproduce on demand: whether printf finishes
# before grep closes the pipe depends on the payload size relative to the
# stdio/pipe buffers and on scheduling. table-freshness.test.sh stayed green
# on macOS and on most Linux runs, then failed CI run 33950264712 with
# `printf: write error: Broken pipe` followed by a FAIL on an assertion whose
# pattern was present — blocking an unrelated PR (#1643). The memory note
# `pipefail-sigpipe-false-failure` records the same mechanism biting before.
#
# === The safe shape ===
#
# Give grep its input from something that cannot be killed mid-write:
#
#     grep -q pattern <<<"$big"                   # here-string
#     grep -q pattern <<<"$(producer …)"          # capture, then match
#     [[ "$(cut -f2 <<<"$line")" == "value" ]]    # exact-field compare
#
# A here-string is materialised (temp file, or a pipe pre-filled before grep
# starts) BEFORE grep runs, so there is no producer left to signal; the only
# status in play is grep's own.
#
# === Scan scope ===
#
# Tracked `*.sh` files, and only those that enable pipefail (`set -o pipefail`,
# `set -euo pipefail`, …). Without pipefail the pipeline's status is grep's
# alone and the producer's SIGPIPE is invisible, so the shape is harmless there
# and deliberately NOT flagged. The gate is evaluated in line order, after
# heredoc bookkeeping, so a `set -o pipefail` that is merely literal text inside
# a quoted heredoc (a script that writes another script) cannot switch scanning
# on.
#
# Only early-exit greps count: an option cluster carrying `q` (`-q`, `-qE`,
# `-Eq`, `-qxF`, …) or `--quiet` / `--silent` — on `grep` itself, a variant
# (`egrep`, `ggrep`, `zgrep`) or a prefixed call (`LC_ALL=C grep`, `command grep`). `grep -c`, `grep -v`, a plain
# `grep pattern` all read their input to EOF and cannot strand a producer.
#
# === Why quoted spans are stripped first ===
#
# Single-quoted spans and trailing comments are removed before matching, so a
# `| grep -q` that is DATA — a fixture command string handed to a classifier,
# an `sh -c '…'` body that runs under a shell without pipefail — is not a
# finding. Heredoc bodies (`<<'EOF'` and `<<EOF` alike) are skipped for the
# same reason — they are text this shell writes somewhere, not commands it runs. Double-quoted strings are NOT stripped: the repo's assert helpers
# `eval` their double-quoted condition string in the pipefail shell, so a
# pipeline inside one is live code (`assert "x" "printf '%s' \"\$out\" | grep
# -q y"` was a real flake site). The cost is a false positive on data that
# merely LOOKS like a pipeline — `echo "text | grep -q x"` — which is fixed in
# one edit with the waiver below; the miss it would otherwise trade for flakes
# CI at random. Lexically the two are indistinguishable, so the lint errs
# toward the finding.
#
# === Opt-out marker ===
#
#   # pipefail-grep-ok: <reason>
#
# On the same line as a deliberate use. The reason is mandatory — a bare marker
# is itself an error — because the waiver must record WHY this producer cannot
# outlive grep. No production line needs it today; the test fixtures use it to
# prove the escape hatch works.
#
# === Vacuity canary ===
#
# If discovery finds no shell files, if none of them enables pipefail, or if
# the scan examines zero `| grep` pipelines across them, the lint FAILS rather
# than passing green. A renamed directory, a broken gate regex, or a broken
# pipe regex would otherwise turn this into a silent no-op (the
# guards-that-pass-by-not-running failure mode).
#
# CI wiring: named .github/scripts/*-lint.sh, so run-doc-lints.sh discovers it
# with no workflow edit. Companion: .github/scripts/tests/pipefail-grep-q-lint.test.sh
#
# Usage: bash .github/scripts/pipefail-grep-q-lint.sh [--help]
# Exits 0 on a clean pass, 1 on any finding, 2 on a usage error.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: bash .github/scripts/pipefail-grep-q-lint.sh

  Scans tracked *.sh files that enable `set -o pipefail` for a producer piped
  into an early-exit grep (`-q`, `--quiet`, `--silent`). Under pipefail the
  producer's SIGPIPE turns a successful match into a failed pipeline.

  Fix by feeding grep a here-string instead:
      grep -q pattern <<<"$var"
      grep -q pattern <<<"$(producer …)"

  No options besides --help. Run from the repo root: discovery is relative to
  the current directory, which is what makes the lint testable against a
  hermetic fixture tree.

  Suppress one deliberate line with a trailing  # pipefail-grep-ok: <reason>
  marker; the reason is mandatory.

  Exit status:
    0  no findings
    1  at least one finding, or the vacuity canary tripped
    2  usage error (unknown flag)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "::error::pipefail-grep-q-lint.sh: unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

# --- discovery -------------------------------------------------------------
# Relative to the CURRENT directory (run-doc-lints.sh cds to the repo root
# first), so the hermetic fixture trees in the companion test can exercise it.
# git ls-files is authoritative for a checkout; find covers a plain directory.
FILES_RAW="$(mktemp)"
FILES_NORM="$(mktemp)"
SCAN_OUT="$(mktemp)"
trap 'rm -f "$FILES_RAW" "$FILES_NORM" "$SCAN_OUT"' EXIT

# --others --exclude-standard includes not-yet-committed scripts: a new file
# with the hazardous shape must be caught on the PR that introduces it.
if git -c core.quotePath=false ls-files --cached --others --exclude-standard -z -- '*.sh' > "$FILES_RAW" 2>/dev/null \
   && [ -s "$FILES_RAW" ]; then
  :
else
  find . -type d -name .git -prune -o -type f -name '*.sh' -print0 > "$FILES_RAW" 2>/dev/null || true
fi

# Every path is handed to awk with a `./` prefix so a dash-prefixed filename
# is read as a path, never as an option (BSD awk has no `--` after the program).
file_count=0
while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  case "$f" in ./*|/*) ;; *) f="./$f" ;; esac
  printf '%s\0' "$f"
  file_count=$((file_count + 1))
done < "$FILES_RAW" > "$FILES_NORM"

if [ "$file_count" -eq 0 ]; then
  echo "::error::pipefail-grep-q-lint: discovery found no shell files — a glob is broken"
  exit 1
fi

# --- scan ------------------------------------------------------------------
# awk emits one FINDING line per hit (FINDING<US>file<US>line<US>kind<US>raw),
# plus counter lines so the canary can tell "clean" apart from "never looked".
scan_awk='
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

# Strip a trailing comment. `#` opens one only at the start of a word — after
# whitespace or a control operator (`cmd;# note`) — AND outside quotes: `grep -q "#tag"` or `echo "$x # y" | grep -q z` must keep
# everything after the quoted `#`, or the live pipeline behind it goes unseen.
function decomment(s,    i, c, n, sq, dq, prev) {
  n = length(s); sq = 0; dq = 0; prev = " "
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && !sq) { i++; prev = "x"; continue }
    if (sq) { if (c == "\047") sq = 0; prev = c; continue }
    if (dq) { if (c == "\"") dq = 0; prev = c; continue }
    if (c == "\047") { sq = 1; prev = c; continue }
    if (c == "\"") { dq = 1; prev = c; continue }
    if (c == "#" && (i == 1 || prev ~ /[[:space:];&|()]/)) return substr(s, 1, i - 1)
    prev = c
  }
  return s
}

# Blank out single-quoted spans. Their contents are literal to THIS shell, so
# a pipeline inside one is data (a fixture string, an sh -c body), not code.
function strip_single_quoted(s) {
  gsub(/'"'"'[^'"'"']*'"'"'/, "'"'"''"'"'", s)
  return s
}

FNR == 1 {
  in_literal_heredoc = 0
  heredoc_tag = ""
  scanning = 0
  counted = 0
  joined = ""
  join_start = 0
}

{
  raw = $0

  # --- heredoc bookkeeping ---------------------------------------------
  # A heredoc body — quoted delimiter or not — is data to THIS shell (a script
  # writing another script, a usage block); nothing in it runs here, so skip
  # it, and never let a `set -o pipefail` inside it switch scanning on.
  if (in_literal_heredoc) {
    if (trim(raw) == heredoc_tag) { in_literal_heredoc = 0; heredoc_tag = "" }
    next
  }
  # `(^|[^<])` keeps a here-string (`<<<"$var"`) from being misread as a
  # quoted heredoc opener — that would skip the rest of the file. The opener
  # is looked for in the DECOMMENTED line for the same reason: a commented-out
  # `# cat <<'"'"'EOF'"'"'` opens nothing, and treating it as one would mute
  # every live pipeline after it.
  opener_line = decomment(raw)
  if (match(opener_line, /(^|[^<])<<-?[[:space:]]*("[^"]+"|'"'"'[^'"'"']+'"'"'|[A-Za-z_][A-Za-z0-9_]*)/)) {
    tag = substr(opener_line, RSTART, RLENGTH)
    gsub(/^[^<]*<<-?[[:space:]]*/, "", tag)
    gsub(/["'"'"']/, "", tag)
    in_literal_heredoc = 1
    heredoc_tag = tag
    # No `next`: the opener line itself is live code (`cat <<'"'"'EOF'"'"' | grep -q x`
    # pipes the body through a producer that can still die of SIGPIPE), so it
    # is scanned below; only the BODY lines that follow are skipped.
  }

  line = decomment(raw)
  comment = substr(raw, length(line) + 1)

  # --- waiver marker — recognised only in the real trailing comment, never
  #     inside a string literal or other source text ----------------------
  waived_here = 0
  if (comment ~ /^#[[:space:]]*pipefail-grep-ok/) {
    if (comment ~ /^#[[:space:]]*pipefail-grep-ok:[[:space:]]*[^[:space:]]/) {
      waived_here = 1
    } else {
      printf "FINDING\037%s\037%d\037bare-marker\037%s\n", FILENAME, FNR, raw
      next
    }
  }

  # --- line continuation: `producer \` + `| grep -q x` is ONE pipeline, and
  # so is `producer |` + newline + `grep -q x` (a newline after `|`, `|&`,
  # `&&` or `||` continues the command). Accumulate either shape into a
  # single logical line and report at the line where that logical line began.
  if (line ~ /\\$/) {
    joined = joined substr(line, 1, length(line) - 1) " "
    if (join_start == 0) join_start = FNR
    next
  }
  if (line ~ /(\|&?|&&)[[:space:]]*$/) {
    joined = joined line " "
    if (join_start == 0) join_start = FNR
    next
  }
  if (joined != "") {
    line = joined line
    report_line = join_start
    joined = ""; join_start = 0
  } else {
    report_line = FNR
  }

  if (line ~ /^[[:space:]]*$/) next

  # --- pipefail gate ----------------------------------------------------
  # Tracked in source order, both directions: `set -o pipefail` arms the scan
  # (the rest of THIS line included — `set -o pipefail; cmd | grep -q x` is
  # live), `set +o pipefail` disarms it until the next enable. Combined
  # (`-euo pipefail`) and separated (`-e -o pipefail`) spellings both count,
  # and `set` may follow a control operator directly (`cd x;set -o pipefail`).
  if (line ~ /(^|[[:space:];&|(])set[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*o[[:space:]]+pipefail([[:space:];&|]|$)/) {
    if (!scanning) {
      scanning = 1
      if (!counted) { counted = 1; files_scanned++ }
    }
  } else if (line ~ /(^|[[:space:];&|(])set[[:space:]]+([^;&|]*[[:space:]])?\+[a-zA-Z]*o[[:space:]]+pipefail([[:space:];&|]|$)/) {
    scanning = 0
    next
  }
  if (!scanning) next

  work = strip_single_quoted(line)

  # Every `| grep …` (not `||`, optionally `|&`) up to the end of that simple
  # command: a separator, a redirection, or a closing paren.
  # `grep` may carry a prefix — `LC_ALL=C grep`, `command grep`, `env grep` —
  # or be a variant basename (`egrep`, `ggrep`, `zgrep`): same early exit,
  # same SIGPIPE hazard.
  while (match(work, /(^|[^|])\|&?[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]|]*|command|builtin|env)[[:space:]]+)*[a-z]*grep([[:space:]]|$)/)) {
    rest = substr(work, RSTART + RLENGTH)
    args = rest
    if (match(args, /[;&|<>()]/)) args = substr(args, 1, RSTART - 1)
    pipes_examined++
    if ((" " args " ") ~ /[[:space:]](-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)[[:space:]]/) {
      if (waived_here) {
        waived++
      } else {
        printf "FINDING\037%s\037%d\037grep-q\037%s\n", FILENAME, report_line, line
      }
    }
    work = rest
  }
}

END {
  printf "SCANNED\037%d\n", files_scanned + 0
  printf "PIPES\037%d\n", pipes_examined + 0
  printf "WAIVED\037%d\n", waived + 0
}
'

# A file that vanished or cannot be read makes awk (and so xargs) exit
# non-zero; a scan that skipped input must never be reported as clean.
if ! xargs -0 awk "$scan_awk" < "$FILES_NORM" > "$SCAN_OUT"; then
  echo "::error::pipefail-grep-q-lint: the scan itself failed (awk/xargs exited non-zero) — refusing to report a result from a partial scan"
  exit 1
fi

errors=0
scanned=0
pipes=0
waived=0
while IFS=$'\037' read -r kind a b c d; do
  # Summed, not assigned: xargs may split a long file list across several awk
  # invocations, and each one prints its own END counters.
  case "$kind" in
    SCANNED) scanned=$((scanned + a)); continue ;;
    PIPES)   pipes=$((pipes + a)); continue ;;
    WAIVED)  waived=$((waived + a)); continue ;;
    FINDING) ;;
    *) continue ;;
  esac
  file="$a"; lineno="$b"; token="$c"; raw="$d"
  file="${file#./}"
  if [ "$token" = "bare-marker" ]; then
    echo "::error file=${file},line=${lineno}::${file}:${lineno}: '# pipefail-grep-ok' with no reason after the colon. The waiver must record WHY this producer cannot outlive grep, e.g. '# pipefail-grep-ok: single write, under 1 KB'. Line: ${raw}"
  else
    echo "::error file=${file},line=${lineno}::${file}:${lineno}: producer piped into an early-exit grep under 'set -o pipefail' — when grep -q exits on its first match the producer takes SIGPIPE (141), pipefail promotes that to the pipeline's status, and a SUCCESSFUL match reads as a failure (issue #1648). Feed grep a here-string instead: grep -q pattern <<<\"\$var\" or <<<\"\$(producer)\". Line: ${raw}"
  fi
  errors=$((errors + 1))
done < "$SCAN_OUT"

if [ "$scanned" -eq 0 ]; then
  echo "::error::pipefail-grep-q-lint: found ${file_count} shell file(s) but none enabled 'set -o pipefail' — the gate regex is broken; refusing to report a vacuous pass"
  exit 1
fi

if [ "$pipes" -eq 0 ]; then
  echo "::error::pipefail-grep-q-lint: scanned ${scanned} pipefail file(s) but examined 0 '| grep' pipelines — the pipe regex is broken; refusing to report a vacuous pass"
  exit 1
fi

if [ "$errors" -gt 0 ]; then
  echo "pipefail-grep-q-lint: ${errors} error(s) found across ${scanned} pipefail shell files (${pipes} grep pipelines examined, ${waived} waived)"
  exit 1
fi

echo "pipefail-grep-q-lint: OK (${scanned} pipefail shell files, ${pipes} grep pipelines examined, ${waived} waived)"
