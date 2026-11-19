#!/usr/bin/env bash
# Offline tests for pm-epic.sh and the /pm epic wiring (issue #2545).
# catalog: tests — Tests for `pm-epic.sh` and `/pm epic #N`: argument parsing (missing, malformed, `#N`/`N`), children from the `## Increment chain` checklist, task lists and sub-issues (same repo only, never the parent, PRs or other-repo refs), an unreadable sub-issue API falling back to the body, missing/closed/childless parents, close-if-done closing only when every child is closed, and the skill's parse-before-goal and no-inference contract
# covers: .claude/scripts/pm-epic.sh .claude/skills/pm/SKILL.md .claude/skills/pm/modules/shared/epic.md .claude/skills/pm/modules/rank/load.md .claude/skills/pm/modules/flow/refill.md .claude/skills/pm/scripts/dispatch-module.sh
# Stubs `gh` on PATH with fixture JSON. Run from anywhere:
#   bash .claude/scripts/tests/pm-epic.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/pm-epic.sh"
SKILL="$REPO_ROOT/.claude/skills/pm"

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

# ---- stub gh ------------------------------------------------------------------
# gh api repos/acme/w/issues/N             -> $TMP/fx/issue-N.json, else 404
# gh api --paginate repos/acme/w/issues/N/sub_issues?per_page=100
#                                          -> $TMP/fx/sub-N.json, else 403
# gh issue close N --repo acme/w ...       -> logged, closes the fixture
mkdir -p "$TMP/bin" "$TMP/fx"
cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls.log"
fx="$TMP/fx"
if [ "\$1" = api ] && [ "\$2" = --paginate ]; then
  n=\$(printf '%s' "\$3" | sed -n 's#^repos/acme/w/issues/\([0-9]*\)/sub_issues.*#\1#p')
  if [ -n "\$n" ] && [ -f "\$fx/sub-\$n.json" ]; then cat "\$fx/sub-\$n.json"; exit 0; fi
  echo "HTTP 403: Resource not accessible by integration" >&2; exit 1
fi
if [ "\$1" = api ]; then
  n=\$(printf '%s' "\$2" | sed -n 's#^repos/acme/w/issues/\([0-9]*\)\$#\1#p')
  if [ -n "\$n" ] && [ -f "\$fx/issue-\$n.json" ]; then cat "\$fx/issue-\$n.json"; exit 0; fi
  if [ -f "\$fx/fail-all" ]; then echo "HTTP 502" >&2; exit 1; fi
  echo "gh: Not Found (HTTP 404)" >&2; exit 1
fi
if [ "\$1 \$2" = "issue close" ]; then
  jq '.state = "closed"' "\$fx/issue-\$3.json" > "\$fx/tmp" && mv "\$fx/tmp" "\$fx/issue-\$3.json"
  exit 0
fi
echo "unexpected gh call: \$*" >&2
exit 64
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

issue() {  # issue N STATE TITLE [BODY] [pr]
  local pr=null
  [[ "${5:-}" == pr ]] && pr='{"url":"x"}'
  jq -n --argjson n "$1" --arg s "$2" --arg t "$3" --arg b "${4:-}" --argjson pr "$pr" \
    '{number:$n, state:$s, title:$t, body:$b} + (if $pr then {pull_request:$pr} else {} end)' \
    > "$TMP/fx/issue-$1.json"
}

# ---- parse-arg ------------------------------------------------------------------
check_eq "parse-arg: #N" "123" "$("$SCRIPT" parse-arg '#123')"
check_eq "parse-arg: bare N" "7" "$("$SCRIPT" parse-arg 7)"
for bad in '' 'foo' '#' '#0' '12a' 'new' '#-3'; do
  out=$("$SCRIPT" parse-arg "$bad" 2>&1); rc=$?
  check_eq "parse-arg rejects '$bad' with exit 2" "2" "$rc"
  check_eq "parse-arg error for '$bad' is one line" "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
done
check_contains "parse-arg names the expected form" "/pm epic #123" "$("$SCRIPT" parse-arg '' 2>&1)"

# ---- a parent with three open children + noise ---------------------------------
BODY100=$'Theme text that says epic epic epic.\n\n- [ ] not an issue line\n- [ ] other/repo#900 cross-repo child\n- [x] #100 self\n- [ ] #105 a PR, not an issue\n- [ ] #106 missing issue\n- [ ] #104 task-list child\nSee #999 in prose (not a task list).\n\n```\n- [ ] #200 fenced example\n```\n\n## Increment chain\n\nDecomposed.\n\n- [ ] #101\n- [x] #102\n'
issue 100 open "Parent theme" "$BODY100"
issue 101 open "Child one" "- Parent: #100"
issue 102 closed "Child two" "- Depends on #101"
issue 103 open "Child three (sub-issue only)" ""
issue 104 open "Child four (body task list and sub-issue)" ""
issue 105 open "A pull request" "" pr
issue 200 open "Unrelated backlog issue" ""
cat > "$TMP/fx/sub-100.json" <<'EOF'
[{"number":103,"repository_url":"https://api.github.com/repos/acme/w"},
 {"number":104,"repository_url":"https://api.github.com/repos/acme/w"},
 {"number":900,"repository_url":"https://api.github.com/repos/other/repo"},
 {"number":100,"repository_url":"https://api.github.com/repos/acme/w"}]
EOF

out=$("$SCRIPT" children acme/w '#100'); rc=$?
check_eq "children: open parent with children exits 0" "0" "$rc"
check_eq "children: same-repo children in first-seen order" "104,101,102,103" "$(jq -r '[.children[].number] | join(",")' <<< "$out")"
check_eq "children: open set excludes the closed child" "104,101,103" "$(jq -r '.open | join(",")' <<< "$out")"
check_eq "children: closed set" "102" "$(jq -r '.closed | join(",")' <<< "$out")"
check_eq "children: a missing number is reported, not a child" "106" "$(jq -r '.missing | join(",")' <<< "$out")"
check_eq "children: never the parent, a PR, prose #N, a fenced example or another repo" "false" \
  "$(jq -r '[.children[].number] | any(. == 100 or . == 105 or . == 999 or . == 900 or . == 200)' <<< "$out")"
check_eq "children: checklist source recorded" '["increment-chain"]' "$(jq -c '.children[] | select(.number == 101) | .sources' <<< "$out")"
check_eq "children: body + sub-issue sources merged" '["task-list","sub-issue"]' "$(jq -c '.children[] | select(.number == 104) | .sources' <<< "$out")"
check_eq "children: sub-issues read" "read" "$(jq -r '.sub_issues' <<< "$out")"

# ---- fences close only on a same-character marker at least as long (CommonMark) --
BODY500=$'````\n~~~\n- [ ] #201 inside a 4-backtick fence after a tilde line\n```\n- [ ] #202 inside after a shorter backtick marker\n````\n- [ ] #101 after the fence closes\n~~~~\n```\n- [ ] #203 inside a tilde fence after a backtick line\n~~~\n- [ ] #204 inside after a shorter tilde marker\n~~~~ info\n- [ ] #205 a closer cannot carry an info string\n~~~~~\n- [ ] #104 after the longer tilde closer\n'
issue 500 open "Fence parent" "$BODY500"
for n in 201 202 203 204 205; do issue "$n" open "Fenced $n" ""; done
out=$("$SCRIPT" children acme/w 500); rc=$?
check_eq "fences: exits 0" "0" "$rc"
check_eq "fences: nested/shorter markers keep the fence open" "101,104" "$(jq -r '[.children[] | select(.sources | index("task-list")) | .number] | join(",")' <<< "$out")"

# Indent: 0-3 spaces open/close a fence; 4+ never does. A backtick opener whose
# info string holds a backtick opens nothing.
BODY510=$'   ```\n- [ ] #201 inside a 3-space-indented fence\n    ```\n- [ ] #202 still inside: a 4-space closer is not a closer\n   ```\n- [ ] #101 after the 3-space closer\n    ```\n- [ ] #104 a 4-space opener opens nothing\n``` a`b\n- [ ] #102 a backtick in a backtick info string opens nothing\n~~~ a`b\n- [ ] #203 a tilde opener may carry a backtick\n~~~\n'
issue 510 open "Fence indent parent" "$BODY510"
out=$("$SCRIPT" children acme/w 510); rc=$?
check_eq "fence indent: exits 0" "0" "$rc"
check_eq "fence indent: 0-3 spaces only; backtick info strings open nothing" "101,104,102" "$(jq -r '[.children[] | select(.sources | index("task-list")) | .number] | join(",")' <<< "$out")"

# ---- sub-issue API unavailable: body still stands ------------------------------
rm "$TMP/fx/sub-100.json"
out=$("$SCRIPT" children acme/w 100); rc=$?
check_eq "no sub-issue API: still exits 0" "0" "$rc"
check_eq "no sub-issue API: reported unavailable" "unavailable" "$(jq -r '.sub_issues' <<< "$out")"
check_eq "no sub-issue API: checklist + task list children only" "104,101,102" "$(jq -r '[.children[].number] | join(",")' <<< "$out")"

# ---- an issue titled "epic new button" with no children -------------------------
issue 300 open "epic new button" $'Epic: make a new button.\n\n- [ ] design it\n- [ ] ship it\n'
out=$("$SCRIPT" children acme/w 300); rc=$?
check_eq "childless 'epic ...' title: exit 5" "5" "$rc"
check_eq "childless: JSON still printed with no children" "0" "$(jq -r '.children | length' <<< "$out")"

# ---- closed and missing parents ------------------------------------------------
issue 400 closed "Done parent" $'- [ ] #101\n'
"$SCRIPT" children acme/w 400 >/dev/null; rc=$?
check_eq "closed parent: exit 4" "4" "$rc"
err=$("$SCRIPT" children acme/w 401 2>&1 >/dev/null); rc=$?
check_eq "missing parent: exit 3" "3" "$rc"
check_contains "missing parent: one-line reason" "does not exist" "$err"
"$SCRIPT" children acme/w 105 >/dev/null 2>&1; rc=$?
check_eq "a PR number is not an epic: exit 3" "3" "$rc"
touch "$TMP/fx/fail-all"
"$SCRIPT" children acme/w 402 >/dev/null 2>&1; rc=$?
check_eq "a failing read is exit 1, never 'missing'" "1" "$rc"
rm "$TMP/fx/fail-all"
"$SCRIPT" children 'not a repo' 100 >/dev/null 2>&1; rc=$?
check_eq "bad repo: usage exit 2" "2" "$rc"

# ---- close-if-done ---------------------------------------------------------------
issue 500 open "Parent to finish" $'## Increment chain\n\n- [x] #501\n- [ ] #502\n'
issue 501 closed "c1" ""
issue 502 open "c2" ""
: > "$TMP/calls.log"
check_eq "close-if-done: an open child keeps the parent open" "open #500 (1 of 2 children open)" "$("$SCRIPT" close-if-done acme/w 500)"
check_eq "close-if-done: no close call while a child is open" "0" "$(grep -c '^issue close' "$TMP/calls.log")"
issue 502 closed "c2" ""
err=$("$SCRIPT" close-if-done acme/w 500 2>&1 >/dev/null); rc=$?
check_eq "close-if-done: unreadable sub-issues never close (exit 1)" "1" "$rc"
check_contains "close-if-done: unreadable sub-issues reason" "not closing on a partial child list" "$err"
check_eq "close-if-done: no close call on a partial child list" "0" "$(grep -c '^issue close' "$TMP/calls.log")"
echo '[]' > "$TMP/fx/sub-500.json"
check_eq "close-if-done: closes once every child is closed" "closed #500 (2 children)" "$("$SCRIPT" close-if-done acme/w 500)"
check_contains "close-if-done: the close comment names the children" "#501, #502" "$(grep '^issue close 500' "$TMP/calls.log")"
issue 600 open "Parent with a dead reference" $'- [x] #501\n- [x] #699\n'
echo '[]' > "$TMP/fx/sub-600.json"
: > "$TMP/calls.log"
err=$("$SCRIPT" close-if-done acme/w 600 2>&1 >/dev/null); rc=$?
check_eq "close-if-done: a missing listed child never closes (exit 1)" "1" "$rc"
check_contains "close-if-done: missing child named" "#699" "$err"
check_eq "close-if-done: no close call with a missing child" "0" "$(grep -c '^issue close' "$TMP/calls.log")"
check_eq "close-if-done: idempotent on a closed parent" "already-closed #500" "$("$SCRIPT" close-if-done acme/w 500)"
"$SCRIPT" close-if-done acme/w 300 >/dev/null; rc=$?
check_eq "close-if-done: a childless parent is never closed" "5" "$rc"

# ---- skill wiring ------------------------------------------------------------------
entry="$SKILL/SKILL.md"
epic_parse=$(grep -n '^- \*\*Epic' "$entry" | head -1 | cut -d: -f1)
mode_parse=$(grep -n '^- \*\*Mode:\*\*' "$entry" | head -1 | cut -d: -f1)
if [[ -n "$epic_parse" && -n "$mode_parse" && "$epic_parse" -lt "$mode_parse" ]]; then
  pass "SKILL.md parses epic before the mode and business goal"
else
  fail "SKILL.md parses epic before the mode and business goal ($epic_parse vs $mode_parse)"
fi
check_eq "dispatcher resolves shared:epic" "$SKILL/modules/shared/epic.md" "$(bash "$SKILL/scripts/dispatch-module.sh" shared epic)"
epic_mod="$SKILL/modules/shared/epic.md"
check_contains "epic module forbids inferring epic-ness" "never infer" "$(tr '[:upper:]' '[:lower:]' < "$epic_mod")"
check_contains "epic module persists the scope" '.repos[\"$REPO_KEY\"].epic' "$(cat "$epic_mod")"
check_contains "rank:load applies the epic scope" 'shared:epic' "$(cat "$SKILL/modules/rank/load.md")"
check_contains "refill applies the epic scope" 'shared:epic' "$(cat "$SKILL/modules/flow/refill.md")"
check_contains "resume restores the epic scope" 'shared:epic' "$(cat "$SKILL/modules/resume/load.md")"
# Outside the routing notes that point at shared:epic (and the two idle-reason
# rows naming it), no ranking or refill text mentions epics at all: nothing
# there can key on an "epic" title, label or keyword.
stray=$(for f in "$SKILL"/modules/rank/*.md "$SKILL/modules/flow/refill.md"; do
  awk -v f="$f" '/<!-- pm-routing:begin -->/ {r = 1} /<!-- pm-routing:end -->/ {r = 0; next}
    !r && tolower($0) ~ /epic/ && index($0, "(epic #N complete)") == 0 &&
      index($0, "(epic scope unreadable)") == 0 {print f ": " $0}' "$f"
done)
check_eq "ranking and refill never key on an 'epic' title, label or keyword" "" "$stray"

echo
echo "pm-epic.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
