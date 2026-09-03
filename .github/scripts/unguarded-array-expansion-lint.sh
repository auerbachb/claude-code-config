#!/usr/bin/env bash
# lint: reject bare "${ARR[@]}" expansion of an empty-capable array in a
# `set -u` shell script, which aborts on bash 3.2 (issue #1389).
#
# === The defect this exists to prevent ===
#
# Bash before 4.4 treats an EMPTY array as UNSET when it is expanded with the
# `[@]` or `[*]` subscript. Under `set -u` that is a fatal error, not a warning:
#
#     $ /bin/bash -uc 'a=(); printf "[%s]" "${a[@]}"; echo done'
#     /bin/bash: a[@]: unbound variable        # rc 127, `done` never prints
#
# macOS ships bash 3.2.57 as /bin/bash, so this fires on the developer machine.
# The sanctioned fix is the guarded expansion idiom already used in 21 files
# here, which expands to nothing at all when the array is empty:
#
#     ${ARR[@]+"${ARR[@]}"}
#
# === Why CI structurally cannot catch this (the reason a lint exists) ===
#
# `hook-scripts.yml` runs on ubuntu-latest / bash 5.x, where expanding an empty
# array under `set -u` is tolerated. A reintroduction is therefore GREEN ON CI
# AND BROKEN LOCALLY — the inverse of the usual failure mode. `shellcheck` has
# no code for the pattern (it is correct on modern bash). The symptom is silent:
# the bug behind issue #1371 made `estimate-resolve.sh` return `exit 4` with an
# EMPTY error string, so callers lost estimates with no visible cause.
#
# PR #1379 fixed three named scripts and pinned the idiom with structural greps
# in their two test suites — but only in those three files. This lint is the
# repo-wide guard that stops the next one.
#
# === Measured bash 3.2 semantics (probed on 3.2.57, not assumed) ===
#
#   ABORTS   "${a[@]}"   ${a[*]}   "${a[*]}"   for x in "${a[@]}"
#            ...every [@]/[*] expansion of an empty array, in every position.
#            `${a[*]}` aborts exactly like `${a[@]}`, so the "guard it with
#            [[ -n "${a[*]}" ]]" reflex is ITSELF the bug — the guard aborts
#            before it can protect anything.
#   SAFE     ${a[@]+"${a[@]}"}     the sanctioned idiom — expands to nothing
#            "${a[@]:-}"           but yields ONE EMPTY-STRING element, which
#                                  is a different argument list; not a drop-in
#            ${#a[@]}              a count is always safe, even when unset
#
# === The two-part rule (why this is not a grep) ===
#
# A bare `grep` for the token drowns in false positives — 286 expansion sites
# live under `.claude/` and `.github/`, and most are provably safe. This lint
# reports a site only when BOTH halves hold:
#
#   Part 1 — the array is EMPTY-CAPABLE in this file. It is flagged only if the
#            file assigns it `NAME=()`, declares it with `local/declare/typeset
#            -a NAME` and no initialiser, or `unset`s it. An array built once as
#            a non-empty literal (`GIT=(git -C "$root")`) can never be empty, so
#            its bare expansion is never reported. This is the filter that does
#            the heavy lifting: 44 of 301 shell files declare an empty array.
#
#   Part 2 — the expansion is UNGUARDED. Any earlier `${#NAME[@]}` in the file
#            (a count test the author wrote — `(( ${#a[@]} ))`, `[ ${#a[@]} -gt
#            0 ]`, an early return, anything) marks that array guarded from
#            there on, as does a later non-empty literal assignment. Only a
#            site with no emptiness reasoning anywhere before it is reported.
#
# Both halves are deliberately biased toward SILENCE.
#
# === Known limitation, accepted on purpose ===
#
# A guard marks its array safe for the REST OF THE FILE, not just for the block
# it syntactically encloses. So this second use is missed:
#
#     args=()
#     if (( ${#args[@]} )); then cmd "${args[@]}"; fi   # guarded
#     other "${args[@]}"                                # NOT reported — a bug
#
# Closing that gap means tracking bash block structure (if/fi, while/done, case
# patterns, one-line function bodies, `&&` chains, heredocs) accurately enough
# to know where a guard stops applying. Getting that wrong produces FALSE
# POSITIVES — reporting a use the author did guard — and the issue names exactly
# that outcome as the failure mode to avoid: a lint that "drowns in false
# positives and gets disabled" protects nothing.
#
# Under-reporting is the safe direction. Every finding this lint does emit is
# real, so it stays credible and stays enabled, and it still catches the shape
# this repo actually reintroduces: a conditionally-built array expanded bare
# with no emptiness reasoning anywhere. Block-scoped guard tracking is a
# worthwhile refinement ONCE it can be shown not to add false positives; it is
# not a prerequisite for the guard to be worth having.
#
# === Scan scope ===
#
# Tracked `*.sh` files that enable `set -u` (`set -u`, `set -eu`, `set -euo
# pipefail`, `set -o nounset`). A file without `set -u` cannot exhibit the
# abort. Comments are stripped before scanning, and `<<'EOF'` / `<<"EOF"`
# heredoc bodies are skipped because a quoted delimiter makes the body literal
# text that never expands.
#
# === Opt-out marker ===
#
#   # empty-array-ok: <reason>
#
# On the same line as a deliberate bare expansion the analysis cannot see is
# safe. The reason is REQUIRED and enforced — a bare marker with no explanation
# is itself reported, so the escape hatch cannot become a silent allowlist.
#
# === Deferral list (self-expiring) ===
#
# One pre-existing violation could not be remediated on the PR that introduced
# this lint because its file was open in another in-flight PR, and editing it
# would have manufactured a cross-PR conflict. `DEFERRED` below carries it with
# a reason.
#
# The list cannot rot: a deferral that no longer matches a live finding is
# itself reported as an error, so the entry must be deleted in the same change
# that fixes the site. An allowlist that silently outlives its justification is
# the failure mode this design exists to avoid.
#
# === Vacuity canary ===
#
# The lint FAILS rather than passing green if discovery finds no shell files, if
# no scanned file enabled `set -u`, or if zero array expansions were examined.
# A renamed directory or a broken regex would otherwise turn this into a silent
# no-op — the guards-that-pass-by-not-running failure mode.
#
# CI wiring: named .github/scripts/*-lint.sh, so run-doc-lints.sh discovers it
# with no workflow edit. Companion test:
# .github/scripts/tests/unguarded-array-expansion-lint.test.sh
#
# Usage: bash .github/scripts/unguarded-array-expansion-lint.sh [--help]
# Exits 0 on a clean pass, 1 on any finding, 2 on a usage error.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: bash .github/scripts/unguarded-array-expansion-lint.sh

  Scans tracked shell scripts that enable `set -u` for a bare "${ARR[@]}" or
  ${ARR[*]} expansion of an array that can be empty. Bash 3.2 (the /bin/bash
  macOS ships) treats an empty array as unset, so such an expansion aborts the
  script with `ARR[@]: unbound variable` — while passing on CI's bash 5.

  Fix a finding with the guarded expansion idiom:

      cmd ${ARR[@]+"${ARR[@]}"}          # expands to nothing when empty

  or gate the bare expansion behind a count check:

      if (( ${#ARR[@]} )); then cmd "${ARR[@]}"; fi

  Note that "${ARR[@]:-}" is NOT equivalent — it yields one empty-string
  argument rather than no arguments at all.

  No options besides --help. Run from the repo root: discovery is relative to
  the current directory, which is what makes the lint testable against a
  hermetic fixture tree.

  Suppress one deliberate line with a trailing marker AND a reason:

      cmd "${ARR[@]}"   # empty-array-ok: caller guarantees at least one entry

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
      echo "::error::unguarded-array-expansion-lint.sh: unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

# --- deferral list ---------------------------------------------------------
# Pre-existing violations this lint could not fix on the PR that introduced it.
# Format: <path>|<array name>|<reason>. A deferral that matches no live finding
# is reported as a STALE entry and fails the lint, so the list expires itself
# rather than quietly outliving its justification.
DEFERRED=(
  '.claude/scripts/candidate-ownership.sh|UNIQ|file open in PR #1607 (issue #1330) when the lint landed; editing it would have manufactured a cross-PR conflict. Guarded on line 182 already, so the author knew the idiom — line 186 was simply missed. Fix with the guarded idiom once #1607 merges.'
)

is_deferred() {  # <file> <name>; also records the hit in DEFERRED_HIT
  local f="$1" n="$2" i=0 entry
  for entry in ${DEFERRED[@]+"${DEFERRED[@]}"}; do
    i=$((i + 1))
    if [ "${entry%%|*}" = "$f" ]; then
      local rest="${entry#*|}"
      if [ "${rest%%|*}" = "$n" ]; then
        DEFERRED_HIT="${DEFERRED_HIT}${i} "
        return 0
      fi
    fi
  done
  return 1
}
DEFERRED_HIT=""

# --- discovery -------------------------------------------------------------
# Scanning is relative to the CURRENT directory (run-doc-lints.sh cds to the
# repo root before invoking each lint). That is deliberate: a lint that
# hard-resolved its own repo root could never be exercised against a hermetic
# fixture tree, and an untestable guard is the one that quietly stops working.
# git ls-files is authoritative for a checkout; find covers a plain directory
# (the test fixtures build trees that are not git repos).
FILES_RAW="$(mktemp)"
SCAN_OUT="$(mktemp)"
trap 'rm -f "$FILES_RAW" "$SCAN_OUT"' EXIT

# --others --exclude-standard includes not-yet-committed scripts: a new script
# with an unguarded expansion must be caught on the PR that introduces it, not
# after it lands. Gitignored files stay excluded.
if git -c core.quotePath=false ls-files --cached --others --exclude-standard -z -- '*.sh' > "$FILES_RAW" 2>/dev/null \
   && [ -s "$FILES_RAW" ]; then
  :
else
  find . -type d -name .git -prune -o -type f -name '*.sh' -print0 > "$FILES_RAW" 2>/dev/null || true
fi

file_count=0
while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  file_count=$((file_count + 1))
done < "$FILES_RAW"

if [ "$file_count" -eq 0 ]; then
  echo "::error::unguarded-array-expansion-lint: discovery found no shell files — a glob is broken"
  exit 1
fi

# --- scan ------------------------------------------------------------------
# awk emits one FINDING line per hit, plus two counter lines so the canary can
# tell "clean" apart from "never looked".
scan_awk='
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

# Strip a trailing comment. A `#` only opens a comment at the start of a word,
# so ${#a[@]} (where # follows `{`) and a literal a#b survive untouched.
function decomment(s) {
  sub(/(^|[[:space:]])#.*$/, "", s)
  return s
}

# --- per-file reset -------------------------------------------------------
FNR == 1 {
  delete state          # per-array: "empty" (empty-capable) | "safe"
  in_literal_heredoc = 0
  heredoc_tag = ""
  scanning = 0          # set once a REAL `set -u` line is reached
}

{
  raw = $0

  # --- heredoc bookkeeping ---------------------------------------------
  # A quoted delimiter (<<'"'"'EOF'"'"' or <<"EOF") makes the body LITERAL text: no
  # expansion happens, so nothing in it can abort. Skip those bodies. An
  # unquoted delimiter does expand, so its body is scanned normally.
  if (in_literal_heredoc) {
    if (trim(raw) == heredoc_tag) { in_literal_heredoc = 0; heredoc_tag = "" }
    next
  }
  if (match(raw, /<<-?[[:space:]]*("[^"]+"|'"'"'[^'"'"']+'"'"')/)) {
    tag = substr(raw, RSTART, RLENGTH)
    gsub(/^<<-?[[:space:]]*/, "", tag)
    gsub(/["'"'"']/, "", tag)
    in_literal_heredoc = 1
    heredoc_tag = tag
    next
  }

  line = decomment(raw)
  if (line ~ /^[[:space:]]*$/) next

  # --- `set -u` gate ----------------------------------------------------
  # A file only matters if it enables `set -u`; without it the abort cannot
  # happen. The check runs HERE, inside the main loop, rather than as a
  # pre-pass over the raw file: heredoc bookkeeping above has already run, so
  # a `set -euo pipefail` line that is merely LITERAL TEXT inside a quoted
  # heredoc (a script that writes another script, a usage block) cannot switch
  # scanning on. `set -u` always precedes the code it governs, so reaching it
  # in line order loses nothing.
  if (!scanning) {
    if (line ~ /(^|[[:space:]])set[[:space:]]+-[a-zA-Z]*u[a-zA-Z]*([[:space:]]|$)/ ||
        line ~ /(^|[[:space:]])set[[:space:]]+-o[[:space:]]+nounset([[:space:]]|$)/) {
      scanning = 1
      files_scanned++
    } else {
      next
    }
  }

  # --- Part 1: track which arrays can be empty --------------------------
  # NAME=()            explicit empty init            -> empty-capable
  # local/declare/typeset -a NAME (no initialiser)    -> empty-capable
  # unset NAME                                        -> empty-capable
  # NAME=(content)     non-empty literal              -> safe
  #
  # NAME+=(...) deliberately does NOT clear empty-capable: an append is nearly
  # always conditional (that is why the array is built incrementally), and when
  # it is not, the guarded idiom costs nothing to apply anyway.
  work = line
  while (match(work, /(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*=\(/)) {
    seg = substr(work, RSTART, RLENGTH)
    nm = seg
    sub(/^[^A-Za-z_]*/, "", nm)
    sub(/=\($/, "", nm)
    rest = substr(work, RSTART + RLENGTH)
    if (rest ~ /^[[:space:]]*\)/)
      state[nm] = "empty"
    else
      state[nm] = "safe"
    work = rest
  }

  # declaration with -a/-A and no `=` on the token: empty-capable.
  # Command separators are turned into whitespace first, so a one-line function
  # body (`f() { local -a acc; ... }`) yields the token `acc`, not `acc;` — the
  # trailing separator would otherwise fail the identifier test and silently
  # drop the declaration.
  declline = line
  gsub(/[;&|(){}]/, " ", declline)
  if (declline ~ /(^|[[:space:]])(local|declare|typeset)[[:space:]]/) {
    n = split(declline, dtok, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (dtok[i] ~ /^(local|declare|typeset)$/) {
        arrayish = 0
        for (j = i + 1; j <= n; j++) {
          if (dtok[j] ~ /^-/) { if (dtok[j] ~ /[aA]/) arrayish = 1; continue }
          if (dtok[j] == "") continue
          if (dtok[j] ~ /=/) break        # has an initialiser: handled above
          if (dtok[j] !~ /^[A-Za-z_][A-Za-z0-9_]*$/) break
          if (arrayish && !(dtok[j] in state)) state[dtok[j]] = "empty"
        }
      }
    }
  }

  if (match(declline, /(^|[[:space:]])unset[[:space:]]+/)) {
    rest = substr(declline, RSTART + RLENGTH)
    n = split(rest, utok, /[[:space:]]+/)
    for (i = 1; i <= n; i++)
      if (utok[i] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) state[utok[i]] = "empty"
  }

  # --- Part 2: a ${#NAME[@]} count test marks NAME guarded from here on --
  # Scanned BEFORE the expansion hunt so a same-line guard counts:
  #   (( ${#a[@]} )) && cmd "${a[@]}"
  probe_line = line
  while (match(probe_line, /\$\{#[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}/)) {
    nm = substr(probe_line, RSTART, RLENGTH)
    gsub(/^\$\{#|\[[@*]\]\}$/, "", nm)
    state[nm] = "safe"
    probe_line = substr(probe_line, RSTART + RLENGTH)
  }

  # --- neutralise GUARDED expansions before hunting bare ones ------------
  # ${NAME[@]+ ... } / ${NAME[@]:- ... } / ${NAME[@]:+ ... } are safe. Remove
  # the opener and remember the name, so the INNER "${NAME[@]}" of the
  # ${NAME[@]+"${NAME[@]}"} idiom is not mistaken for a bare expansion.
  delete guarded_here
  hunt = line
  out = ""
  while (match(hunt, /\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\](\+|:-|:\+|:=|-)/)) {
    nm = substr(hunt, RSTART, RLENGTH)
    sub(/^\$\{/, "", nm)
    sub(/\[[@*]\].*$/, "", nm)
    guarded_here[nm] = 1
    out = out substr(hunt, 1, RSTART - 1)
    hunt = substr(hunt, RSTART + RLENGTH)
  }
  hunt = out hunt

  # --- report remaining BARE expansions of empty-capable arrays ----------
  while (match(hunt, /\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}/)) {
    tokentext = substr(hunt, RSTART, RLENGTH)
    nm = tokentext
    sub(/^\$\{/, "", nm)
    sub(/\[[@*]\]\}$/, "", nm)
    hunt = substr(hunt, RSTART + RLENGTH)

    expansions++
    if (nm in guarded_here) continue         # inner half of the guarded idiom
    if (!(nm in state)) continue             # never assigned here: not our call
    if (state[nm] != "empty") continue       # provably non-empty, or guarded

    if (raw ~ /empty-array-ok/) {
      if (raw ~ /empty-array-ok:[[:space:]]*[^[:space:]]/) { waived++; continue }
      printf "FINDING\t%s\t%s\t%s\t%s\t%s\n", FILENAME, FNR, nm, "bare-marker", trim(raw)
      next
    }
    printf "FINDING\t%s\t%s\t%s\t%s\t%s\n", FILENAME, FNR, nm, tokentext, trim(raw)
  }
}

END { printf "COUNTS\t%d\t%d\t%d\n", files_scanned, expansions, waived }
'

# xargs -0 keeps arbitrary paths intact; awk handles many files in one process.
if ! xargs -0 awk "$scan_awk" < "$FILES_RAW" > "$SCAN_OUT" 2>/dev/null; then
  echo "::error::unguarded-array-expansion-lint: the shell scan failed — treating as an error rather than a clean pass"
  exit 1
fi

scanned="$(awk -F'\t' '$1 == "COUNTS" { t += $2 } END { print t + 0 }' "$SCAN_OUT")"
expansions="$(awk -F'\t' '$1 == "COUNTS" { t += $3 } END { print t + 0 }' "$SCAN_OUT")"
waived="$(awk -F'\t' '$1 == "COUNTS" { t += $4 } END { print t + 0 }' "$SCAN_OUT")"
errors=0

deferred_used=0
while IFS="$(printf '\t')" read -r kind file lineno name token raw; do
  [ "$kind" = "FINDING" ] || continue
  if [ "$token" != "bare-marker" ] && is_deferred "${file#./}" "$name"; then
    deferred_used=$((deferred_used + 1))
    echo "unguarded-array-expansion-lint: DEFERRED ${file}:${lineno} (${name}) — tracked, not fixed here"
    continue
  fi
  if [ "$token" = "bare-marker" ]; then
    echo "::error file=${file},line=${lineno}::${file}:${lineno}: '# empty-array-ok' with no reason after the colon. The waiver must record WHY '${name}' cannot be empty here, e.g. '# empty-array-ok: callers validate argv before this point'. Line: ${raw}"
  else
    echo "::error file=${file},line=${lineno}::${file}:${lineno}: bare ${token} expands an empty-capable array under 'set -u' — bash 3.2 (macOS /bin/bash) aborts with '${name}[@]: unbound variable', while CI's bash 5 passes. Use \${${name}[@]+\"\${${name}[@]}\"} or gate it behind (( \${#${name}[@]} )). Line: ${raw}"
  fi
  errors=$((errors + 1))
done < "$SCAN_OUT"

if [ "$scanned" -eq 0 ]; then
  echo "::error::unguarded-array-expansion-lint: found ${file_count} shell file(s) but none enabled 'set -u' — the set-u regex is broken; refusing to report a vacuous pass"
  exit 1
fi

if [ "$expansions" -eq 0 ]; then
  echo "::error::unguarded-array-expansion-lint: scanned ${scanned} 'set -u' file(s) but examined 0 array expansions — the expansion regex is broken; refusing to report a vacuous pass"
  exit 1
fi

# A deferral whose file is still present but produced no finding has outlived
# its justification: the site was fixed and the entry was left behind. Fail on
# it, so the list can never become a silent hole.
#
# The `-f` test scopes staleness to trees that actually CONTAIN the deferred
# file. Without it every hermetic fixture tree would trip this check, and a lint
# that cannot be exercised against a fixture is one that quietly stops working.
idx=0
for entry in ${DEFERRED[@]+"${DEFERRED[@]}"}; do
  idx=$((idx + 1))
  dfile="${entry%%|*}"
  case " $DEFERRED_HIT " in
    *" $idx "*) continue ;;
  esac
  [ -f "$dfile" ] || continue        # not this tree's file; nothing to assert
  rest="${entry#*|}"
  echo "::error::unguarded-array-expansion-lint: STALE deferral #${idx} (${dfile}, array '${rest%%|*}') — the file is present but no longer produces this finding, so the entry has outlived its justification. Delete it from DEFERRED in $0."
  errors=$((errors + 1))
done

if [ "$errors" -gt 0 ]; then
  echo "unguarded-array-expansion-lint: ${errors} error(s) found across ${scanned} 'set -u' shell files (${expansions} array expansions examined, ${waived} waived, ${deferred_used} deferred)"
  exit 1
fi

echo "unguarded-array-expansion-lint: OK (${scanned} 'set -u' shell files, ${expansions} array expansions examined, ${waived} waived, ${deferred_used} deferred)"
