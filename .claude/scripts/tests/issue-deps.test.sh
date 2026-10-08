#!/usr/bin/env bash
# Offline tests for issue-deps.sh (issue #1760).
# catalog: tests — Tests for `issue-deps.sh`: the `/pm` 1B.3 marker set in bodies and comments (any case), edge direction, chains, diamonds, cycles, cross-repo and self references, closed issues, and a failing read that never reads as zero
# Stubs `gh` on PATH with fixture JSON. Run from anywhere:
#   bash .claude/scripts/tests/issue-deps.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/issue-deps.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }
check_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_contains() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing '$2' in: $3)"; fi
}

# ---- stub gh: `issue list --repo O/R ...` serves $TMP/issues-O-R.json -------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls.log"
if [ "\${1:-} \${2:-} \${3:-}" = "issue list --repo" ]; then
  f="$TMP/issues-\$(printf '%s' "\$4" | tr '/' '-').json"
  if [ -f "\$f" ]; then cat "\$f"; exit 0; fi
  echo "HTTP 404" >&2
  exit 1
fi
echo "unexpected gh call: \$*" >&2
exit 64
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# Chain #10 <- #15 <- #20; a diamond #30 <- {#31, #32} <- #33; a cycle
# #40 <-> #41; markers in every case and in comments; `unblocks`; noise.
cat > "$TMP/issues-acme-widgets.json" <<'EOF'
[{"number": 10, "body": "Head.", "comments": []},
 {"number": 15, "body": "## Related Issues\n\n- Depends on #10", "comments": []},
 {"number": 20, "body": "Tail.", "comments": [{"body": "blocked BY #15, see above"}]},
 {"number": 30, "body": "Diamond top.", "comments": []},
 {"number": 31, "body": "**Depends on:** #30", "comments": []},
 {"number": 32, "body": "Prerequisite for #30", "comments": []},
 {"number": 33, "body": "after #31 and before nothing", "comments": [{"body": "AFTER #32"}]},
 {"number": 40, "body": "Depends on #41", "comments": []},
 {"number": 41, "body": "Depends on #40", "comments": []},
 {"number": 50, "body": "This unblocks #51 and enables #52.", "comments": [{"body": "Required by #53"}]},
 {"number": 51, "body": "x", "comments": []},
 {"number": 52, "body": "x", "comments": []},
 {"number": 53, "body": "x", "comments": []},
 {"number": 60, "body": "Depends on other/repo#10. Depends on #60. thereafter #10. dependson #10. Unblocks #9.", "comments": []},
 {"number": 70, "body": "Closed one. Depends on #10.", "state": "CLOSED", "comments": []},
 {"number": 71, "body": "Depends on #70 and depends on #72", "comments": []}]
EOF

dep() {  # dep ISSUE — the dependents entry for ISSUE as "count|direct|transitive|cycle"
  "$SCRIPT" dependents acme/widgets "$1" \
    | jq -r '.issues[0] | "\(.count)|\(.direct | join(","))|\(.transitive | join(","))|\(.cycle)"'
}

check_eq "chain: the head has 2 transitive dependents (closed #70's marker never read)" "2|15|15,20|false" "$(dep 10)"
check_eq "chain: the middle has 1" "1|20|20|false" "$(dep 15)"
check_eq "chain: the tail has 0" "0|||false" "$(dep 20)"
check_eq "a marker in a comment, in capitals, counts (#15 <- #20)" "1" "$(dep 15 | cut -d'|' -f1)"
check_eq "diamond: #33 counted once; bold-colon form and every case read" "3|31,32|31,32,33|false" "$(dep 30)"
check_eq "cycle: terminates and says so" "1|41|41|true" "$(dep 40)"
check_eq "unblocking direction: unblocks / enables / required by" "3|51,52,53|51,52,53|false" "$(dep 50)"
check_eq "cross-repo, self, no-boundary (thereafter, dependson) markers never count" "0|||false" "$(dep 60)"
check_eq "an open issue that depends on a closed one is that issue's dependent (#71 on #70)" \
  "1|71|71|false" "$(dep 70)"

: > "$TMP/calls.log"
OUT=$("$SCRIPT" dependents acme/widgets '#10' 15)
check_eq "one gh call for several issues" "1" "$(grep -c 'issue list' "$TMP/calls.log")"
check_eq "several issues in one read, in the order given, a leading # accepted" "10,15" \
  "$(printf '%s' "$OUT" | jq -r '[.issues[].issue] | join(",")')"
check_eq "the repo and the open count (the closed entry dropped)" "acme/widgets 15" \
  "$(printf '%s' "$OUT" | jq -r '"\(.repo) \(.open_issues)"')"
check_contains "the read is the open issues, bodies and comments, 500 at most" \
  "issue list --repo acme/widgets --state open --limit 500 --json number,body,comments" "$(tail -1 "$TMP/calls.log")"

EDGES=$("$SCRIPT" edges acme/widgets)
check_eq "edges: blocker -> blocked, deduplicated and sorted" \
  "10>15 15>20 30>31 30>32 31>33 32>33 40>41 41>40 50>51 50>52 50>53 60>9 70>71 72>71" \
  "$(printf '%s' "$EDGES" | jq -r '[.edges[] | "\(.blocker)>\(.blocked)"] | join(" ")')"

cp "$TMP/issues-acme-widgets.json" "$TMP/input.json"
check_eq "--input FILE reads the same JSON, repo null" "null 2" \
  "$("$SCRIPT" dependents --input "$TMP/input.json" 10 | jq -r '"\(.repo) \(.issues[0].count)"')"
check_eq "--input - reads stdin" "2" \
  "$("$SCRIPT" dependents --input - 10 < "$TMP/input.json" | jq -r '.issues[0].count')"
check_eq "parse prints the edges array alone" "14" \
  "$("$SCRIPT" parse < "$TMP/input.json" | jq 'length')"

# ---- failures: never a count of zero ----------------------------------------
RC=0; OUT=$("$SCRIPT" dependents acme/missing 10 2>"$TMP/err") || RC=$?
check_eq "a failing gh read exits 1" "1" "$RC"
check_eq "... with nothing on stdout" "" "$OUT"
check_contains "... saying dependents are unknown" "dependents unknown (not zero)" "$(cat "$TMP/err")"
printf '{"not": "an array"}' > "$TMP/obj.json"
RC=0; "$SCRIPT" dependents --input "$TMP/obj.json" 10 >/dev/null 2>&1 || RC=$?
check_eq "JSON that is not an array exits 1" "1" "$RC"
RC=0; "$SCRIPT" dependents --input "$TMP/nope.json" 10 >/dev/null 2>&1 || RC=$?
check_eq "an unreadable --input exits 1" "1" "$RC"
RC=0; ISSUE_DEPS_GH="$TMP/no-gh" "$SCRIPT" dependents acme/widgets 10 >/dev/null 2>&1 || RC=$?
check_eq "no gh exits 1" "1" "$RC"

# ---- usage ------------------------------------------------------------------
for args in "" "bogus" "dependents acme/widgets" "dependents 10" "edges" "edges acme/widgets 10" \
  "dependents acme/widgets ten" "dependents acme/widgets 0" "dependents acme/widgets --input x 10" \
  "parse 10" "dependents --bogus"; do
  RC=0
  # shellcheck disable=SC2086 # deliberate splitting of each case's arguments
  "$SCRIPT" $args >/dev/null 2>&1 || RC=$?
  check_eq "usage: '$args' exits 2" "2" "$RC"
done
HELP=$("$SCRIPT" --help 2>&1)
check_contains "--help names the marker set" "blocked by #N, depends on #N, prerequisite for #N, after #N" "$HELP"
check_contains "--help ends with its dependencies" "jq 1.6+" "$HELP"
# jq 1.6 has scan/1 only (scan/2 arrived in 1.7): the 1.6+ promise means every
# scan takes one argument, case folded by an inline (?i) in the regex itself.
SCAN2=$(grep -n -E 'scan\([^()]*;' "$SCRIPT" | grep -v -E '^[0-9]+:#' || true)
check_eq "jq 1.6: no two-argument scan in the program" "" "$SCAN2"

echo
echo "issue-deps.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
