#!/usr/bin/env bash
# pr-body-review-note.sh — Append one line to a PR body's `## Review notes`, once per HEAD.
# catalog: review-escalation — Record a review-trigger decision (such as a BugBot daily-cap skip) as one line under the PR body's `## Review notes`, idempotent per key and HEAD
#
# PURPOSE
#   A skipped reviewer trigger should be visible on the PR itself, not only in
#   a session log (issue #1812: `/fixpr` Step 3b notes a BugBot daily-cap skip).
#   Step 3b can run several times on one HEAD, so the note must land once per
#   HEAD: each line carries a hidden marker `<!-- review-note:<key>:<head> -->`,
#   and a body that already holds the marker is left alone. A new HEAD adds a
#   new line, so the notes read as a per-push history.
#
# USAGE
#   pr-body-review-note.sh <pr_number> --head <sha> --key <slug> --line <text>
#                          [--repo owner/name] [--body-file <path>]
#   pr-body-review-note.sh --help | -h
#
#   --head <sha>        The HEAD the note is about (7–40 hex characters).
#   --key <slug>        What kind of note, e.g. bugbot-daily-cap ([a-z0-9-]).
#   --line <text>       The note, one line.
#   --repo owner/name   Passed to gh; default: the current checkout's repo.
#   --body-file <path>  Read and rewrite this file instead of the PR body
#                       (tests; no gh call is made).
#
# PLACEMENT
#   The line is appended as a bullet at the end of the `## Review notes`
#   section, before the next `#` or `##` heading outside a code fence. Headings
#   are read as CommonMark ATX headings: up to three leading spaces, an
#   optional closing run of `#`, any letter case (`  ## Review Notes ##`). With
#   no such section, one is created at the end of the body, and any blank lines
#   that ended the body collapse into the one blank line before its heading.
#   Every other line is left byte-for-byte as it was. A body with CRLF line
#   endings (the GitHub web editor saves them) is matched with the CR stripped,
#   every existing line keeps its own ending, and the added lines use CRLF.
#
# OUTPUT
#   stdout: `added` or `present` (the marker was already there; nothing written).
#   stderr: diagnostics.
#
# EXIT STATUS
#   0   added, or already present
#   1   the body could not be read or written
#   2   usage error
#   70  --help header extraction produced no output (internal defect)
#
# EXAMPLES
#   pr-body-review-note.sh 1840 --head "$PUSHED_SHA" --key bugbot-daily-cap \
#     --line 'BugBot skipped: daily cap ($10.12 of $10.00 today)'
#   pr-body-review-note.sh 1 --head abc1234 --key test --line hi --body-file body.md

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^# catalog:/ { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

usage_error() {
  echo "pr-body-review-note.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

die() {
  echo "pr-body-review-note.sh: $1" >&2
  exit 1
}

PR=""
HEAD=""
KEY=""
LINE=""
LINE_SET=0
REPO=""
BODY_FILE=""
need_value() { [[ $# -ge 2 && -n "$2" ]] || usage_error "$1 requires a value"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --head) need_value "$@"; HEAD="$2"; shift 2 ;;
    --key) need_value "$@"; KEY="$2"; shift 2 ;;
    --line) need_value "$@"; LINE="$2"; LINE_SET=1; shift 2 ;;
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --body-file) need_value "$@"; BODY_FILE="$2"; shift 2 ;;
    -*) usage_error "unknown flag: $1" ;;
    *)
      [[ -z "$PR" ]] || usage_error "unexpected argument: $1"
      PR="$1"; shift ;;
  esac
done

[[ "$PR" =~ ^[1-9][0-9]*$ ]] || usage_error "a PR number is required"
[[ "$HEAD" =~ ^[0-9a-fA-F]{7,40}$ ]] || usage_error "--head must be a 7-40 character hex SHA"
[[ "$KEY" =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage_error "--key must match [a-z0-9][a-z0-9-]*"
[[ "$LINE_SET" -eq 1 ]] || usage_error "--line is required"
case "$LINE" in
  *$'\n'*|*$'\r'*) usage_error "--line must be a single line" ;;
  *"-->"*) usage_error "--line cannot contain '-->' (it would close the marker)" ;;
esac
[[ -z "$REPO" || "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9_.-]+$ ]] || usage_error "--repo must be owner/name"

MARKER="<!-- review-note:${KEY}:$(printf '%s' "$HEAD" | tr '[:upper:]' '[:lower:]') -->"

TMP="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$TMP" "$TMP.new"' EXIT

if [[ -n "$BODY_FILE" ]]; then
  [[ -f "$BODY_FILE" && -r "$BODY_FILE" ]] || die "body file not readable: $BODY_FILE"
  cp "$BODY_FILE" "$TMP" || die "could not read $BODY_FILE"
else
  command -v gh >/dev/null 2>&1 || die "gh not found — cannot read PR #$PR"
  gh pr view "$PR" ${REPO:+--repo "$REPO"} --json body -q .body > "$TMP" \
    || die "could not read the body of PR #$PR"
fi

if grep -qF -- "$MARKER" "$TMP"; then
  echo "present"
  exit 0
fi

# Insert at the end of `## Review notes` (before trailing blank lines), or
# create the section at the end. Headings inside ``` / ~~~ fences are content.
# A fence closes only on a run of its own character at least as long as the
# opener with nothing after it (CommonMark), so a ``` line inside a ````
# block, or a ~~~ line inside a ``` block, is content too. A trailing CR is
# stripped before matching and written back on output (see PLACEMENT).
NOTE="- $LINE $MARKER" awk '
  # The fence run that opens line s ("```", "~~~~", ...), or "" when none.
  # No {m,n} interval: older mawk builds do not support it.
  function fence_run(s,   t) {
    t = s
    sub(/^ ? ? ?/, "", t)
    if (t ~ /^```/) { match(t, /^`+/); return substr(t, 1, RLENGTH) }
    if (t ~ /^~~~/) { match(t, /^~+/); return substr(t, 1, RLENGTH) }
    return ""
  }
  function closes(s, open,   run, t) {
    run = fence_run(s)
    if (run == "" || substr(run, 1, 1) != substr(open, 1, 1) || length(run) < length(open)) return 0
    t = s
    sub(/^ ? ? ?/, "", t)
    return substr(t, length(run) + 1) ~ /^[ \t]*$/
  }
  # ATX headings (CommonMark): up to three leading spaces, then the opening
  # run, then a space, a tab, or the end of the line.
  function is_notes(s,   t) {
    t = tolower(s)
    sub(/^ ? ? ?/, "", t)
    return t ~ /^##[ \t]+review[ \t]+notes([ \t]+#+)?[ \t]*$/
  }
  function ends_section(s,   t) {
    t = s
    sub(/^ ? ? ?/, "", t)
    return t ~ /^##?([ \t]|$)/
  }
  # Each existing line is written back with the ending it was read with; an
  # added line uses CRLF when any line of the body did.
  function emit(i) { printf "%s%s\n", lines[i], (cr[i] ? "\r" : "") }
  function add(s) { printf "%s%s\n", s, (crlf ? "\r" : "") }
  { cr[NR] = sub(/\r$/, ""); if (cr[NR]) crlf = 1; lines[NR] = $0 }
  END {
    note = ENVIRON["NOTE"]
    start = 0; stop = NR + 1; open = ""
    for (i = 1; i <= NR; i++) {
      if (open != "") { if (closes(lines[i], open)) open = ""; continue }
      run = fence_run(lines[i])
      if (run != "") { open = run; continue }
      if (!start && is_notes(lines[i])) { start = i; continue }
      if (start && ends_section(lines[i])) { stop = i; break }
    }
    if (!start) {
      last = NR
      while (last > 0 && lines[last] ~ /^[ \t]*$/) last--
      for (i = 1; i <= last; i++) emit(i)
      if (last > 0) add("")
      add("## Review notes")
      add("")
      add(note)
      exit
    }
    at = stop - 1
    while (at > start && lines[at] ~ /^[ \t]*$/) at--
    for (i = 1; i <= at; i++) emit(i)
    if (at == start) add("")
    add(note)
    for (i = at + 1; i < stop; i++) emit(i)
    if (stop <= NR && (at + 1 >= stop)) add("")
    for (i = stop; i <= NR; i++) emit(i)
  }
' "$TMP" > "$TMP.new" || die "could not build the new body"

if [[ -n "$BODY_FILE" ]]; then
  cat "$TMP.new" > "$BODY_FILE" || die "could not write $BODY_FILE"
else
  gh pr edit "$PR" ${REPO:+--repo "$REPO"} --body-file "$TMP.new" >/dev/null \
    || die "could not update the body of PR #$PR"
fi
echo "added"
