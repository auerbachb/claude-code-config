#!/usr/bin/env bash
# doc-lint: reject zsh-special variable names in runnable Markdown shell blocks
# (issue #1556).
#
# === The defect this exists to prevent ===
#
# The Bash tool an agent runs is the session's shell, which on macOS is zsh.
# In zsh, lowercase `path` is a special ARRAY parameter tied to the scalar
# `PATH`. Assigning a plain string to it — even as a `local` inside a function —
# replaces PATH with that single element:
#
#     f() { local path; path="/tmp/x"; typeset -p path; }
#     f   ->   typeset -aT PATH path=( /tmp/x )
#
# Every subsequent command in that function then fails to resolve, and anything
# with a `#!/usr/bin/env bash` shebang dies with the misleading
# `env: bash: No such file or directory`. That is exactly what the `run_script()`
# helper in all four .claude/agents/ templates did: it assigned the resolved
# script path to `local path` and then tried to exec `"$path"`, which could
# never work under zsh. The identical text is harmless under bash, so the bug
# is invisible to every .sh file in this repo and to CI.
#
# === Measured hazard tiers (zsh 5.9, probed — not assumed) ===
#
#   severe  path
#             ONLY this one destroys PATH: `local path; path=/tmp/x` leaves
#             `${#PATH}` == 6. Command lookup is gone for the rest of the
#             function body.
#   tied    cdpath fpath manpath mailpath module_path fignore psvar watch argv
#             Silently overwrite their tied counterpart (CDPATH, FPATH, …) or,
#             for argv, the positional parameters. No error, wrong behaviour.
#   special commands functions aliases options parameters dirstack
#           pipestatus signals funcstack histchars
#             Reserved zsh state (command hash table, function table, shell
#             options, …). A scalar assignment silently rewrites shell state.
#   fatal   status LINENO SECONDS RANDOM EUID UID GID
#             zsh refuses the assignment: `read-only variable: status`,
#             `bad math expression: operand expected at '/tmp/x'`. Loud, but it
#             still aborts a pasted snippet mid-way.
#
# === Scan scope ===
#
# Markdown only, and only inside fenced blocks whose info string marks them as
# shell (bash / sh / shell / zsh / console / shellsession, plus untagged
# fences). Markdown is where the hazard lives: those blocks are copied into the
# zsh-backed Bash tool verbatim. The repo's ~289 .sh files all carry a bash
# shebang (`#!/usr/bin/env bash` or `#!/bin/bash`) and zero carry a zsh one, so
# `local path="$1"` in a .sh file is an ordinary scalar and is deliberately NOT
# flagged — renaming those would be churn with no defect behind it.
#
# === Why command-position parsing, not a grep ===
#
# A bare `grep -n 'path='` over Markdown false-positives on jq programs
# (`status=\(.mergeStateStatus)` inside a format string), on `--path=` flags, on
# `log_path=`, and on prose. This lint instead strips quoted spans and trailing
# comments, splits each line on `; | & && ||`, and only inspects tokens in
# COMMAND POSITION — the leading run of keywords and `VAR=value` prefixes before
# the command word. `jq`'s `path()`, a `--path N` flag, a `path:` YAML key and
# every `$path` read are not assignments, so none of them can match.
#
# === Declared-name forms recognised ===
#
#   local/declare/typeset/export/readonly [-flags] NAME[=…] …
#   NAME=… in command position (including after if/then/while/! and env-prefixes)
#   for NAME in …
#   read [-flags] NAME …
#
# === Opt-out marker ===
#
#   # zsh-special-name-ok
#
# On the same line as a deliberate use — for example a doc block whose whole
# point is to SHOW the broken form. No production file needs it today; the test
# fixtures use it to prove the escape hatch works.
#
# === Vacuity canary ===
#
# If discovery yields no Markdown files, or the scan enters zero shell fences,
# the lint FAILS instead of passing green. A renamed directory or a broken
# fence regex would otherwise turn this into a silent no-op (the
# guards-that-pass-by-not-running failure mode).
#
# CI wiring: named .github/scripts/*-lint.sh, so run-doc-lints.sh discovers it
# with no workflow edit. Companion: .github/scripts/tests/zsh-special-name-lint.test.sh
#
# Usage: bash .github/scripts/zsh-special-name-lint.sh [--help]
# Exits 0 on a clean pass, 1 on any finding, 2 on a usage error.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: bash .github/scripts/zsh-special-name-lint.sh

  Scans tracked Markdown for shell-fenced code that assigns a zsh-special
  variable name (path, cdpath, status, ...). Such a snippet silently corrupts
  PATH or shell state when pasted into a zsh-backed Bash tool.

  No options besides --help. Run from the repo root: discovery is relative to
  the current directory, which is what makes the lint testable against a
  hermetic fixture tree.

  Suppress one deliberate line with a trailing  # zsh-special-name-ok  marker.

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
      echo "::error::zsh-special-name-lint.sh: unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

# --- discovery -------------------------------------------------------------
# Scanning is relative to the CURRENT directory (run-doc-lints.sh cds to the
# repo root before invoking each lint). That is deliberate: a lint that
# hard-resolved its own repo root could never be exercised against a hermetic
# fixture tree, and an untestable guard is the one that quietly stops working.
# git ls-files is authoritative for a checkout; find covers a plain directory
# (the test fixtures build trees that are not git repos).
FILES_RAW="$(mktemp)"
trap 'rm -f "$FILES_RAW"' EXIT

# --others --exclude-standard includes not-yet-committed Markdown: a new doc
# with a hazardous snippet must be caught on the PR that introduces it, not
# after it lands. Gitignored files stay excluded.
if git -c core.quotePath=false ls-files --cached --others --exclude-standard -z -- '*.md' > "$FILES_RAW" 2>/dev/null \
   && [ -s "$FILES_RAW" ]; then
  :
else
  find . -type d -name .git -prune -o -type f -name '*.md' -print0 > "$FILES_RAW" 2>/dev/null || true
fi

file_count=0
while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  file_count=$((file_count + 1))
done < "$FILES_RAW"

if [ "$file_count" -eq 0 ]; then
  echo "::error::zsh-special-name-lint: discovery found no Markdown files — a glob is broken"
  exit 1
fi

# --- scan ------------------------------------------------------------------
# awk emits one FINDING line per hit and one FENCES line with the shell-fence
# count, so the canary can distinguish "clean" from "never looked".
SCAN_OUT="$(mktemp)"
trap 'rm -f "$FILES_RAW" "$SCAN_OUT"' EXIT

scan_awk='
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

function tier(n) {
  if (n == "path") return "severe"
  if (n ~ /^(cdpath|fpath|manpath|mailpath|module_path|fignore|psvar|watch|argv)$/) return "tied"
  if (n ~ /^(commands|functions|aliases|options|parameters|dirstack|pipestatus|signals|funcstack|histchars)$/) return "special"
  if (n ~ /^(status|LINENO|SECONDS|RANDOM|EUID|UID|GID)$/) return "fatal"
  return ""
}

function why(t) {
  if (t == "severe")  return "zsh ties lowercase `path` to `PATH`: the assignment REPLACES PATH and every later command in that function fails to resolve"
  if (t == "tied")    return "zsh ties this name to a shell parameter: the assignment silently overwrites it"
  if (t == "special") return "reserved zsh shell state: a scalar assignment silently rewrites it"
  return "zsh refuses this assignment (read-only / integer-typed) and the snippet aborts"
}

function report(file, lineno, name, raw,   t) {
  t = tier(name)
  if (t == "") return
  printf "FINDING\t%s\t%s\t%s\t%s\t%s\n", file, lineno, name, t, trim(raw)
  findings++
}

# Strip quoted spans and a trailing comment so only real code is inspected.
function decode(s) {
  gsub(/\\\\./, "", s)            # escaped chars cannot open a quote
  gsub(/'"'"'[^'"'"']*'"'"'/, " ", s)   # single-quoted spans
  gsub(/"[^"]*"/, " ", s)         # double-quoted spans
  sub(/(^|[[:space:]])#.*$/, "", s)
  return s
}

function is_keyword(tok) {
  return tok ~ /^(if|then|else|elif|fi|while|until|do|done|!|env|command|time|nohup|exec|builtin|nice|then;)$/
}

# Walk the command-position prefix of one segment.
function scan_segment(file, lineno, seg, raw,   n, i, toks, tok, name, started) {
  n = split(seg, toks, /[[:space:]]+/)
  i = 1
  # Skip empties, grouping braces/parens, and a function-definition header, so
  # `foo() { local name="$1" path candidate; }` reaches the declaration branch
  # exactly like a bare `local ...` line does.
  while (i <= n && (toks[i] == "" \
                    || toks[i] ~ /^[{}()]+$/ \
                    || toks[i] == "function" \
                    || toks[i] ~ /^[A-Za-z_][A-Za-z0-9_:.-]*\(\)[{}]*$/)) i++
  # declaration builtins
  if (i <= n && toks[i] ~ /^(local|declare|typeset|export|readonly)$/) {
    for (i++; i <= n; i++) {
      tok = toks[i]
      if (tok == "") continue
      if (tok ~ /^-/) continue                    # flags
      name = tok; sub(/=.*$/, "", name)
      report(file, lineno, name, raw)
    }
    return
  }
  # for NAME in ...
  if (i <= n && toks[i] == "for" && i + 1 <= n) {
    name = toks[i + 1]; sub(/=.*$/, "", name)
    report(file, lineno, name, raw)
    return
  }
  # read [-flags] NAME ...
  if (i <= n && toks[i] == "read") {
    for (i++; i <= n; i++) {
      tok = toks[i]
      if (tok == "") continue
      if (tok ~ /^-/) {
        # -p/-d/-n/-N/-t/-u/-i take a following word that is a prompt,
        # delimiter, count, timeout, fd, or initial text -- NOT a variable
        # name, so `read -p path value` binds only `value`. The word is
        # separate only when the letter ends the token (`-n1` carries its
        # own value). `-a NAME` really does bind NAME, so it is not skipped.
        if (tok ~ /^-[A-Za-z]*[pdnNtui]$/) i++
        continue
      }
      name = tok; sub(/=.*$/, "", name)
      report(file, lineno, name, raw)
    }
    return
  }
  # bare assignments in command position: skip leading keywords, inspect every
  # VAR=value prefix, stop at the command word.
  started = 0
  for (; i <= n; i++) {
    tok = toks[i]
    if (tok == "") continue
    if (is_keyword(tok)) { continue }
    if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
      name = tok; sub(/=.*$/, "", name)
      report(file, lineno, name, raw)
      started = 1
      continue
    }
    break                                          # command word reached
  }
  if (started) { }
}

BEGIN { FS = "\n"; findings = 0; fences = 0 }

FNR == 1 { in_fence = 0; fence_tok = ""; fence_len = 0; shellish = 0; pending = "" }

{
  line = $0

  # --- fence bookkeeping ---
  if (match(line, /^[ \t]*(```+|~~~+)/)) {
    marker = substr(line, RSTART, RLENGTH)
    sub(/^[[:space:]]+/, "", marker)
    tok = substr(marker, 1, 1)
    len = length(marker)
    rest = trim(substr(line, RSTART + RLENGTH))
    if (!in_fence) {
      in_fence = 1; fence_tok = tok; fence_len = len; pending = ""
      info = tolower(rest)
      sub(/[[:space:]].*$/, "", info)
      # Attribute-style info strings carry the language as a class: Quarto and
      # R Markdown write `{bash}`, Pandoc writes `{.bash}` (and `{.bash
      # .numberLines}`, already truncated to its first word above). Peel the
      # braces and the class dot so those fences are scanned, not skipped --
      # dropping a leading dot cannot widen the allow-list, since `.python`
      # only becomes `python`, which is still not shellish.
      sub(/^\{+/, "", info); sub(/\}+$/, "", info); sub(/^\.+/, "", info)
      shellish = (info == "" || info ~ /^(bash|sh|shell|zsh|console|shellsession)$/)
      if (shellish) fences++
      next
    } else if (tok == fence_tok && len >= fence_len && rest == "") {
      in_fence = 0; shellish = 0; pending = ""
      next
    }
  }

  if (!in_fence || !shellish) { pending = ""; next }

  code = decode(line)
  if (pending == "") { pending_lineno = FNR; pending_raw = line; pending_ok = 0 }
  if (line ~ /zsh-special-name-ok/) pending_ok = 1

  # A trailing backslash continues one command across physical lines, and
  # judging each line alone gets both halves wrong: `some_cmd \` + `path=value`
  # is an ARGUMENT (no assignment at all), while `local name="$1" \` +
  # `path candidate` IS a declaration. Join first, then scan the whole command
  # once -- reported against the line the command starts on.
  if (code ~ /\\[[:space:]]*$/) {
    sub(/\\[[:space:]]*$/, " ", code)
    pending = pending code
    next
  }
  code = pending code
  pending = ""
  if (pending_ok) next
  if (code ~ /^[[:space:]]*$/) next

  # split on command separators; each piece has its own command position
  gsub(/&&|\|\|/, "\001", code)
  gsub(/[;|&]/, "\001", code)
  m = split(code, segs, /\001/)
  for (s = 1; s <= m; s++) scan_segment(FILENAME, pending_lineno, segs[s], pending_raw)
}

END { printf "FENCES\t%d\n", fences }
'

# xargs -0 keeps arbitrary paths intact; awk handles many files in one process.
if ! xargs -0 awk "$scan_awk" < "$FILES_RAW" > "$SCAN_OUT" 2>/dev/null; then
  echo "::error::zsh-special-name-lint: the Markdown scan failed — treating as an error rather than a clean pass"
  exit 1
fi

fences="$(awk -F'\t' '$1 == "FENCES" { total += $2 } END { print total + 0 }' "$SCAN_OUT")"
errors=0

while IFS="$(printf '\t')" read -r kind file lineno name tier_name raw; do
  [ "$kind" = "FINDING" ] || continue
  case "$tier_name" in
    severe)  detail="zsh ties lowercase 'path' to 'PATH' — this assignment REPLACES PATH, so every later command in that function (including the one this helper execs) fails with 'env: bash: No such file or directory'" ;;
    tied)    detail="zsh ties '${name}' to a shell parameter — this assignment silently overwrites it" ;;
    special) detail="'${name}' is reserved zsh shell state — a scalar assignment silently rewrites it" ;;
    fatal)   detail="zsh refuses to assign '${name}' (read-only or integer-typed) — the pasted snippet aborts here" ;;
    *)       detail="'${name}' is a zsh-special parameter name" ;;
  esac
  echo "::error file=${file},line=${lineno}::${file}:${lineno}: shell block assigns zsh-special name '${name}' — ${detail}. Rename it (e.g. 'script_path'). Line: ${raw}"
  errors=$((errors + 1))
done < "$SCAN_OUT"

if [ "$fences" -eq 0 ]; then
  echo "::error::zsh-special-name-lint: scanned ${file_count} Markdown file(s) but entered 0 shell code fences — the fence regex is broken; refusing to report a vacuous pass"
  exit 1
fi

if [ "$errors" -gt 0 ]; then
  echo "zsh-special-name-lint: ${errors} error(s) found across ${file_count} Markdown files (${fences} shell fences scanned)"
  exit 1
fi

echo "zsh-special-name-lint: OK (${file_count} Markdown files, ${fences} shell fences scanned)"
