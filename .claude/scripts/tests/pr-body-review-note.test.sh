#!/usr/bin/env bash
# Offline tests for pr-body-review-note.sh (issue #1812).
# catalog: tests — Tests `pr-body-review-note.sh` offline — one line per key and HEAD under `## Review notes`, section creation, placement before the next heading, fenced headings ignored, the rest of the body untouched, and usage errors
#
# WHAT IS UNDER TEST
#   /fixpr Step 3b records a BugBot daily-cap skip in the PR body, and Step 3b
#   can run more than once on one HEAD, so the note must land exactly once per
#   HEAD. Every case runs the real script in --body-file mode, which reads and
#   rewrites a local file through the same insertion code as the gh path; the
#   last case runs the gh path against a stub.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/pr-body-review-note.sh"
TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL — %s\n--- expected\n%s\n--- got\n%s\n---\n' "$desc" "$expected" "$actual"
  fi
}

SHA1="abc1234def5678abc1234def5678abc1234def56"
SHA2="0123456789abcdef0123456789abcdef01234567"
LINE='BugBot skipped: daily cap ($10.12 of $10.00 today)'
OUT=""; RC=0
note() {   # <body file> <sha> [line] -> OUT, RC
  RC=0
  OUT="$("$SCRIPT" 1840 --head "$2" --key bugbot-daily-cap --line "${3:-$LINE}" --body-file "$1" 2>"$TMP/err")" || RC=$?
}
m() { printf '<!-- review-note:bugbot-daily-cap:%s -->' "$1"; }

############################################################################
echo "== no section: created at the end; two runs on one HEAD add one line =="
printf '## Summary\n\nDoes a thing.\n\n## Test plan\n\n- [ ] works\n\n' > "$TMP/a.md"
note "$TMP/a.md" "$SHA1"
check_eq "first run: added, exit 0" "added|0" "$OUT|$RC"
note "$TMP/a.md" "$SHA1"
check_eq "second run on the same HEAD: present, exit 0" "present|0" "$OUT|$RC"
check_eq "the line appears exactly once" "1" "$(grep -cF 'BugBot skipped: daily cap' "$TMP/a.md" | tr -d ' ')"
check_eq "body after both runs" "$(printf '## Summary\n\nDoes a thing.\n\n## Test plan\n\n- [ ] works\n\n## Review notes\n\n- %s %s' "$LINE" "$(m "$SHA1")")" "$(cat "$TMP/a.md")"

echo "== a new HEAD adds a second line under the same heading =="
note "$TMP/a.md" "$SHA2" 'BugBot skipped: daily cap ($11.70 of $10.00 today)'
check_eq "added" "added" "$OUT"
check_eq "one heading" "1" "$(grep -c '^## Review notes' "$TMP/a.md" | tr -d ' ')"
check_eq "two lines, oldest first" \
  "- $LINE $(m "$SHA1");- BugBot skipped: daily cap (\$11.70 of \$10.00 today) $(m "$SHA2");" \
  "$(grep '^- BugBot' "$TMP/a.md" | tr '\n' ';')"

echo "== an existing section in the middle: the line goes at its end, before the next heading =="
printf '## Summary\n\nx\n\n## Review notes\n\n- earlier note\n\n## Test plan\n\n- [ ] a\n' > "$TMP/b.md"
note "$TMP/b.md" "$SHA1"
check_eq "placed after the last note, blank line kept before Test plan" \
  "$(printf '## Summary\n\nx\n\n## Review notes\n\n- earlier note\n- %s %s\n\n## Test plan\n\n- [ ] a' "$LINE" "$(m "$SHA1")")" \
  "$(cat "$TMP/b.md")"

echo "== an empty section directly followed by a heading =="
printf '## Review notes\n## Test plan\n- [ ] a\n' > "$TMP/c.md"
note "$TMP/c.md" "$SHA1"
check_eq "a blank line on each side" \
  "$(printf '## Review notes\n\n- %s %s\n\n## Test plan\n- [ ] a' "$LINE" "$(m "$SHA1")")" "$(cat "$TMP/c.md")"

echo "== a ### subsection stays inside; a fenced ## line is content =="
printf '## Review notes\n\n### Older\n\n- old\n\n```md\n## Not a heading\n```\n\n## Test plan\n' > "$TMP/d.md"
note "$TMP/d.md" "$SHA1"
check_eq "inserted after the fence, before ## Test plan" \
  "$(printf '## Review notes\n\n### Older\n\n- old\n\n```md\n## Not a heading\n```\n- %s %s\n\n## Test plan' "$LINE" "$(m "$SHA1")")" \
  "$(cat "$TMP/d.md")"

echo "== a fence closes only on its own character, at least as long (CommonMark) =="
# Under a plain toggle the inner ``` would close the ```` block and the next
# line would read as a heading, cutting the section short.
printf '## Review notes\n\n````md\n```\n## Not a heading\n```\n````\n\n~~~\n```\n## Also not\n~~~\n\n## Test plan\n' > "$TMP/n.md"
note "$TMP/n.md" "$SHA1"
check_eq "nested and mixed fences are content; the note lands before ## Test plan" \
  "$(printf '## Review notes\n\n````md\n```\n## Not a heading\n```\n````\n\n~~~\n```\n## Also not\n~~~\n- %s %s\n\n## Test plan' "$LINE" "$(m "$SHA1")")" \
  "$(cat "$TMP/n.md")"
printf '```\n## Review notes\n``` not a closer\n```\n\n## Review notes\n' > "$TMP/o.md"
note "$TMP/o.md" "$SHA1"
check_eq "a closing run with trailing text is content; the real section is found" \
  "$(printf '```\n## Review notes\n``` not a closer\n```\n\n## Review notes\n\n- %s %s' "$LINE" "$(m "$SHA1")")" \
  "$(cat "$TMP/o.md")"

echo "== a heading inside a fence never counts as the section =="
printf 'Example:\n\n```\n## Review notes\n```\n' > "$TMP/e.md"
note "$TMP/e.md" "$SHA1"
check_eq "a real section is created after the fence" \
  "$(printf 'Example:\n\n```\n## Review notes\n```\n\n## Review notes\n\n- %s %s' "$LINE" "$(m "$SHA1")")" "$(cat "$TMP/e.md")"

echo "== an empty body =="
: > "$TMP/f.md"
note "$TMP/f.md" "$SHA1"
check_eq "just the section" "$(printf '## Review notes\n\n- %s %s' "$LINE" "$(m "$SHA1")")" "$(cat "$TMP/f.md")"

echo "== the marker is case-folded, so an upper-case SHA is the same HEAD =="
note "$TMP/f.md" "$(printf '%s' "$SHA1" | tr '[:lower:]' '[:upper:]')"
check_eq "present" "present" "$OUT"

############################################################################
echo "== usage errors exit 2 and touch nothing =="
printf 'body\n' > "$TMP/g.md"
usage() { RC=0; "$SCRIPT" "$@" --body-file "$TMP/g.md" >/dev/null 2>&1 || RC=$?; }
usage 1840 --key k --line x;                       check_eq "no --head" "2" "$RC"
usage 1840 --head zzz --key k --line x;            check_eq "non-hex --head" "2" "$RC"
usage 1840 --head "$SHA1" --line x;                check_eq "no --key" "2" "$RC"
usage 1840 --head "$SHA1" --key "Bad Key" --line x; check_eq "malformed --key" "2" "$RC"
usage 1840 --head "$SHA1" --key k;                 check_eq "no --line" "2" "$RC"
usage 1840 --head "$SHA1" --key k --line "$(printf 'a\nb')"; check_eq "multi-line --line" "2" "$RC"
usage 1840 --head "$SHA1" --key k --line 'x --> y'; check_eq "--line closing the marker" "2" "$RC"
usage --head "$SHA1" --key k --line x;             check_eq "no PR number" "2" "$RC"
usage 1840 --head "$SHA1" --key k --line x --repo nope; check_eq "malformed --repo" "2" "$RC"
check_eq "the body file is untouched" "body" "$(cat "$TMP/g.md")"
RC=0; "$SCRIPT" 1840 --head "$SHA1" --key k --line x --body-file "$TMP/missing.md" >/dev/null 2>&1 || RC=$?
check_eq "a missing body file exits 1" "1" "$RC"

############################################################################
echo "== the gh path: read with gh pr view, write with gh pr edit =="
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view") cat "$GH_BODY" ;;
  "pr edit")
    prev=""
    for a in "$@"; do [[ "$prev" == "--body-file" ]] && cp "$a" "$GH_BODY"; prev="$a"; done ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export GH_LOG="$TMP/gh.log" GH_BODY="$TMP/live.md"
printf '## Summary\n\nx\n' > "$GH_BODY"
: > "$GH_LOG"
RC=0; OUT="$(PATH="$TMP/bin:$PATH" "$SCRIPT" 1840 --repo acme/one --head "$SHA1" --key bugbot-daily-cap --line "$LINE")" || RC=$?
check_eq "added via gh" "added|0" "$OUT|$RC"
check_eq "gh view then edit, on the named repo" \
  "pr view 1840 --repo acme/one --json body -q .body;pr edit 1840 --repo acme/one --body-file" \
  "$(sed 's/--body-file .*/--body-file/' "$GH_LOG" | tr '\n' ';' | sed 's/;$//')"
RC=0; OUT="$(PATH="$TMP/bin:$PATH" "$SCRIPT" 1840 --repo acme/one --head "$SHA1" --key bugbot-daily-cap --line "$LINE")" || RC=$?
check_eq "second run: present, no second edit" "present|1" "$OUT|$(grep -c '^pr edit' "$GH_LOG" | tr -d ' ')"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: pr-body-review-note.sh tests passed"
