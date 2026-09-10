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

# Return every heredoc delimiter opened by an UNQUOTED `<<` on this line, in
# source order, \037-separated, each prefixed "D" (`<<-`: closer may be
# tab-indented) or "P" (plain `<<`: closer is the exact line) — "" when none.
# Walks the line tracking quote state, so `<<` inside a string is data; skips
# `<<<` (here-string) and anything inside `(( ... ))` / `$(( ... ))`
# (arithmetic: `<< width` is a shift, not a heredoc); accepts quoted tags and
# bare words (`END.txt`). Handles `cat <<A <<B` (two bodies, A first).
function opener_tags(s,    i, n, c, sq, dq, arith, j, tag, dash, out) {
  n = length(s); sq = 0; dq = 0; arith = 0; out = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && !sq) { i++; continue }
    if (sq) { if (c == "\047") sq = 0; continue }
    if (dq) { if (c == "\"") dq = 0; continue }
    if (c == "\047") { sq = 1; continue }
    if (c == "\"") { dq = 1; continue }
    if (c == "(" && substr(s, i + 1, 1) == "(") { arith++; i++; continue }
    if (c == ")" && substr(s, i + 1, 1) == ")" && arith > 0) { arith--; i++; continue }
    if (arith > 0) continue
    if (c == "<" && substr(s, i + 1, 1) == "<" && substr(s, i + 2, 1) != "<" && (i == 1 || substr(s, i - 1, 1) != "<")) {
      j = i + 2; dash = "P"
      if (substr(s, j, 1) == "-") { dash = "D"; j++ }
      while (j <= n && substr(s, j, 1) ~ /[[:space:]]/) j++
      c = substr(s, j, 1)
      tag = ""
      if (c != "" && c !~ /[[:space:];|&<>()]/) {
        # The delimiter is a whole shell WORD, read the way bash reads one:
        # it runs to whitespace or a metacharacter, quote characters are
        # removed, a backslash quotes the character after it (`<<\END.txt`
        # delimits on `END.txt`), and — the part a naive scan gets wrong — a
        # metacharacter INSIDE quotes is part of the word, so `<<E"OF;X"`
        # delimits on `EOF;X`, not `EOF`. Quoted or not makes no difference
        # to what is skipped: both body kinds are queued.
        wq = ""
        while (j <= n) {
          c = substr(s, j, 1)
          if (wq != "") { if (c == wq) wq = ""; else tag = tag c; j++; continue }
          if (c ~ /[[:space:];|&<>()]/) break
          if (c == "\\") { j++; c = substr(s, j, 1); if (c == "") break; tag = tag c; j++; continue }
          if (c == "\047" || c == "\"") { wq = c; j++; continue }
          tag = tag c; j++
        }
      }
      if (tag != "") out = out (out == "" ? "" : "\037") dash tag
      i = j - 1
      continue
    }
  }
  return out
}

# Split a logical line on its command separators — `;`, `&&`, `||`, `&` —
# but only where they are OUTSIDE double quotes (single-quoted spans were
# already blanked by the caller). A `;` inside `"set +o pipefail; x"` is text,
# not a separator, and splitting on it would let a quoted string disarm the
# scan for a live pipeline later on the same line. Fills segs[1..n], returns n.
function split_segments(s, segs,    i, n, c, dq, cur, k) {
  n = length(s); dq = 0; cur = ""; k = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && i < n) { cur = cur c substr(s, i + 1, 1); i++; continue }
    if (c == "\"") { dq = !dq; cur = cur c; continue }
    if (!dq) {
      if (c == ";") { segs[++k] = cur; cur = ""; continue }
      if (c == "&" && substr(s, i + 1, 1) == "&") { segs[++k] = cur; cur = ""; i++; continue }
      if (c == "|" && substr(s, i + 1, 1) == "|") { segs[++k] = cur; cur = ""; i++; continue }
      if (c == "&") { segs[++k] = cur; cur = ""; continue }
    }
    cur = cur c
  }
  segs[++k] = cur
  return k
}

# Blank out double-quoted spans (with `\"` honoured). Used ONLY for the
# pipefail-toggle test: a toggle is a bare command, never quoted text, so
# `echo "set +o pipefail"` must not read as a toggle. Pipeline matching keeps
# the quoted text, because the assert helpers eval their double-quoted strings.
function strip_double_quoted(s,    i, n, c, dq, out) {
  n = length(s); dq = 0; out = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && i < n) { if (!dq) out = out c substr(s, i + 1, 1); i++; continue }
    if (c == "\"") { dq = !dq; out = out c; continue }
    if (!dq) out = out c
  }
  return out
}

FNR == 1 {
  hd_n = 0            # heredoc bodies still to skip, queued by the opener line
  hd_i = 1
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
  # it, and never let a `set -o pipefail` inside it switch scanning on. Bodies
  # are tracked as a queue in source order (`cat <<A <<B` skips the A body,
  # then the B body). A plain `<<` closes only on the EXACT delimiter line; `<<-` also
  # accepts leading TABS (not spaces) — the same rules bash applies.
  if (hd_n > 0) {
    probe = raw
    if (hd_dash[hd_i]) sub(/^\t+/, "", probe)
    if (probe == hd_tag[hd_i]) {
      hd_i++
      if (hd_i > hd_n) { hd_n = 0; hd_i = 1 }
    }
    next
  }
  # Openers are found with a quote-aware walk over the DECOMMENTED line:
  # `<<EOF` inside a quoted argument (`printf '"'"'%s\n'"'"' '"'"'docs: <<EOF'"'"'`),
  # a commented-out opener, a `<<<"$var"` here-string and an arithmetic
  # `$(( 1 << width ))` all open nothing — treating any of them as an opener
  # would mute every live pipeline after it.
  tags = opener_tags(decomment(raw))
  if (tags != "") {
    hd_n = split(tags, hd_parts, "\037"); hd_i = 1
    for (k = 1; k <= hd_n; k++) {
      hd_dash[k] = (substr(hd_parts[k], 1, 1) == "D")
      hd_tag[k] = substr(hd_parts[k], 2)
    }
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

  # --- pipefail gate, per command segment ---------------------------------
  # A logical line is split on its command separators (`;`, `&&`, `||`, `&`)
  # and walked in SOURCE ORDER, so a toggle applies only to the segments after
  # it: `set -o pipefail; cmd | grep -q x` is live, while
  # `set -o pipefail; set +o pipefail; cmd | grep -q x` is not, and the reverse
  # order is. Combined (`-euo pipefail`) and separated (`-e -o pipefail`)
  # spellings both count. `|&` is a pipe for this purpose, so it is folded to
  # `|` first and never mistaken for a `&` separator. Single-quoted spans were
  # blanked above and double-quoted spans are honoured by the splitter, so a
  # `;` inside either cannot split a segment, and a quoted "set +o pipefail"
  # is text, not a toggle.
  work = strip_single_quoted(line)
  gsub(/\|&/, "|", work)
  delete segs
  nseg = split_segments(work, segs)
  for (si = 1; si <= nseg; si++) {
    seg = segs[si]
    tseg = strip_double_quoted(seg)
    if (tseg ~ /(^|[[:space:](])set[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*o[[:space:]]+pipefail([[:space:]]|$)/) {
      if (!scanning) {
        scanning = 1
        if (!counted) { counted = 1; files_scanned++ }
      }
      continue
    }
    if (tseg ~ /(^|[[:space:](])set[[:space:]]+([^;&|]*[[:space:]])?\+[a-zA-Z]*o[[:space:]]+pipefail([[:space:]]|$)/) {
      scanning = 0
      continue
    }
    if (!scanning) continue

    # Every `| grep …` in this segment, up to the end of that simple command:
    # a redirection, a closing paren, or the end of the segment.
    # `grep` may carry a prefix — `LC_ALL=C grep`, `command grep`, `env grep` —
    # a path (`/usr/bin/grep`), or be a variant basename (`egrep`, `ggrep`,
    # `zgrep`): same early exit, same SIGPIPE hazard.
    while (match(seg, /(^|[^|])\|[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]|]*|command|builtin|env)[[:space:]]+)*([^[:space:]|]*\/)?[a-z]*grep([[:space:]]|$)/)) {
      rest = substr(seg, RSTART + RLENGTH)
      args = rest
      if (match(args, /[<>()]/)) args = substr(args, 1, RSTART - 1)
      pipes_examined++
      if ((" " args " ") ~ /[[:space:]](-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)[[:space:]]/) {
        if (waived_here) {
          waived++
        } else {
          printf "FINDING\037%s\037%d\037grep-q\037%s\n", FILENAME, report_line, line
        }
      }
      seg = rest
    }
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
