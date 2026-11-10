#!/usr/bin/env bash
# doc-lint: enforce the canonical script-usage.log telemetry write (issue #1406).
#
# Background: ~65 scripts append one usage-telemetry line to
# $HOME/.claude/script-usage.log. The historical form put the stderr guard
# AFTER the append target:
#
#     printf ... >> "$HOME/.claude/script-usage.log" 2>/dev/null || true
#
# Redirections apply left to right, so on a machine without ~/.claude/ the
# failed `>>` open writes bash's diagnostic to the still-original stderr —
# spurious CI-log noise on any runner without that directory (live evidence
# in issue #1406). `|| true` fixes only the exit status, never the leaked
# text.
#
# Canonical form — the ONLY accepted append (site keeps its own HOME
# spelling: $HOME, ${HOME}, ${HOME:-/tmp}; single-line or continuation-line
# layout both qualify because the check is per-line):
#
#     printf ... 2>/dev/null >> "<home>/.claude/script-usage.log" || true
#
# Rejected shapes (each emits a ::error:: annotation):
#   - bad order:    >> "...script-usage.log" 2>/dev/null || true
#   - unsuppressed: >> "...script-usage.log" with no preceding 2>/dev/null
#   - grouped:      { ... >> "...script-usage.log"; } 2>/dev/null || true
#     (safe at runtime, but a second accepted form defeats a single
#     greppable canonical shape)
#   - missing `|| true` after the append (aborts `set -e` scripts when the
#     open fails)
#   - unquoted or partially-quoted append target (e.g. "$HOME"/.claude/...)
#   - more than one script-usage.log mention on an appending line — a
#     trailing comment quoting the canonical form must not be able to
#     launder a bad append into a pass
#
# === Opt-out marker ===
#
#   # script-usage-redirect-ok
#
# Place on the same line as a deliberate non-canonical append. No current
# file needs it; it exists for documented exceptions (e.g. a fixture
# generator that intentionally emits a rejected shape).
#
# === Scan scope ===
#
# Shell files under .claude/scripts/ and .claude/skills/ — the two trees
# that carry the telemetry line. tests/ subdirectories are excluded: test
# suites legitimately embed non-canonical fixture strings. Comment lines
# are skipped. The corpus comes from NUL-delimited git ls-files (with
# core.quotePath=false, so non-ASCII paths arrive raw instead of C-quoted)
# and a find -print0 fallback (test fixtures use git init). A listed file
# that is missing or unreadable, or that awk fails to process, is an ERROR,
# not a silent skip — a partially scanned corpus must never report as a
# clean pass.
#
# === Vacuity canary ===
#
# If the scan finds ZERO script-usage.log append lines in the whole corpus,
# the lint fails rather than passing vacuously — a rename of the log file
# or a relocation of the telemetry line would otherwise turn this lint into
# a silent no-op (the guards-that-pass-by-not-running failure mode).
#
# === CI wiring ===
#
# Named to match .github/scripts/*-lint.sh — auto-discovered by
# run-doc-lints.sh; runs under the `rule-lint` required CI check without
# any workflow edit.
#
# Companion tests: .github/scripts/tests/script-usage-redirect-lint.test.sh
# (lint semantics, fixture trees) and
# .claude/scripts/tests/script-usage-log-redirect.test.sh (runtime behavior
# of the converted scripts).
#
# Usage: bash .github/scripts/script-usage-redirect-lint.sh
# Exits 0 on clean pass, 1 on any findings, 2 on usage error.

set -euo pipefail

errors=0

usage() {
  cat <<'EOF'
Usage: .github/scripts/script-usage-redirect-lint.sh

  Enforces the canonical script-usage.log telemetry write — the stderr
  guard BEFORE the append, trailing || true:

    printf ... 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

  in shell files under .claude/scripts/ and .claude/skills/ (tests/
  excluded). Opt-out for a deliberate exception, on the same line:

    # script-usage-redirect-ok

  Run from the repo root. Exits 1 on any finding, 2 on usage error.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "::error::script-usage-redirect-lint.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

MARKER="# script-usage-redirect-ok"
MSG="Non-canonical script-usage.log append. Use exactly: printf ... 2>/dev/null >> \"<home>/.claude/script-usage.log\" || true (guard BEFORE the append, fully quoted target, one mention per line; see issue #1406). For a deliberate exception add on the same line: ${MARKER}"

# ---------------------------------------------------------------------------
# Build the scan corpus: git-tracked shell files under the two telemetry
# trees, minus tests/ dirs. NUL-delimited so special-character paths survive
# verbatim; core.quotePath=false so git never C-quotes them into strings a
# later -f test would silently drop. Falls back to find -print0 when not in
# a git repo (test fixtures use git init).
# ---------------------------------------------------------------------------
sh_files=()
while IFS= read -r -d '' f; do
  [[ -n "$f" ]] || continue
  [[ "$f" == */tests/* ]] && continue
  sh_files+=("$f")
done < <(
  git -c core.quotePath=false ls-files -z '.claude/scripts/*.sh' '.claude/skills/*.sh' 2>/dev/null \
    || find .claude/scripts .claude/skills -name '*.sh' ! -path './.git/*' -print0 2>/dev/null
)

if (( ${#sh_files[@]} == 0 )); then
  echo "::error::script-usage-redirect-lint.sh: no shell files found under .claude/scripts/ or .claude/skills/ — run from the repo root"
  exit 1
fi

appends_seen=0
scanned=0
AWK_OUT="$(mktemp -t script-usage-redirect-lint.XXXXXX)"
trap 'rm -f "$AWK_OUT"' EXIT

for file in "${sh_files[@]}"; do
  # A listed-but-unopenable file is a coverage hole, never a silent skip.
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    printf '::error file=%s::script-usage-redirect-lint.sh: listed file is missing or unreadable — NOT scanned\n' "$file"
    errors=$((errors + 1))
    continue
  fi

  # Per-line analysis. A line is a candidate append when `>>` directly
  # targets a path ending in script-usage.log (any quoting). Candidates
  # must match the full canonical shape AND mention the log exactly once
  # (a trailing comment quoting the canonical form cannot launder a bad
  # append). Output protocol: "A<tab>line" canonical, "E<tab>line" finding.
  rc=0
  awk -v MARKER="$MARKER" '
    {
      line = $0
      tmp = line
      sub(/^[ \t]+/, "", tmp)
      if (tmp ~ /^#/) next                       # comment line
      if (index(line, MARKER) > 0) next          # explicit opt-out
      if (line !~ />>[ \t]*[^ \t;|&]*script-usage\.log/) next   # not an append
      cnt = line
      occ = gsub(/script-usage\.log/, "&", cnt)
      canonical = (occ == 1 && line ~ /2>\/dev\/null[ \t]+>>[ \t]*"[^"]*script-usage\.log"[ \t]+[|][|][ \t]+true[ \t]*$/)
      if (canonical) { printf "A\t%d\tok\n", NR }
      else           { printf "E\t%d\tbad\n", NR }
    }
  ' "$file" > "$AWK_OUT" || rc=$?

  if (( rc != 0 )); then
    printf '::error file=%s::script-usage-redirect-lint.sh: awk failed (rc=%s) — file NOT scanned\n' "$file" "$rc"
    errors=$((errors + 1))
    continue
  fi
  scanned=$((scanned + 1))

  while IFS=$'\t' read -r kind lineno _; do
    case "$kind" in
      A) appends_seen=$((appends_seen + 1)) ;;
      E)
        appends_seen=$((appends_seen + 1))
        printf '::error file=%s,line=%s::%s\n' "$file" "$lineno" "$MSG"
        errors=$((errors + 1))
        ;;
    esac
  done < "$AWK_OUT"
done

# ---------------------------------------------------------------------------
# Vacuity canary: zero append lines in the whole corpus means the pattern
# moved out from under this lint — fail loudly instead of passing.
# ---------------------------------------------------------------------------
if (( appends_seen == 0 )); then
  echo "::error::script-usage-redirect-lint.sh: found ZERO script-usage.log append lines in ${scanned} scanned files — the telemetry pattern moved or was renamed, so this lint is scanning nothing. Update its scope."
  errors=$((errors + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( errors > 0 )); then
  echo "script-usage-redirect-lint: ${errors} error(s) found"
  exit 1
fi

echo "script-usage-redirect-lint: OK (${scanned} files scanned, ${appends_seen} canonical append(s))"
