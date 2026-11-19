#!/usr/bin/env bash
# Offline tests for pm-epic.sh and the /pm epic wiring (issues #2545, #2546).
# catalog: tests — Tests for `pm-epic.sh` and `/pm epic #N`: argument parsing (missing, malformed, `#N`/`N`), children from the `## Increment chain` checklist, task lists and sub-issues (same repo only, never the parent, PRs or other-repo refs), an unreadable sub-issue API falling back to the body, missing/closed/childless parents, close-if-done closing only when every child is closed and no scope remains, the `## Epic scope` coverage record (init, waves of at most five, resume after a part-filed wave, the in-review trigger, no-clean-seam stop, malformed records and lost writes failing closed), and the skill's parse-before-goal and no-inference contract
# covers: .claude/scripts/pm-epic.sh .claude/skills/subagent/SKILL.md .claude/skills/pm/SKILL.md .claude/skills/pm/modules/shared/epic.md .claude/skills/pm/modules/rank/load.md .claude/skills/pm/modules/flow/refill.md .claude/skills/pm/scripts/dispatch-module.sh
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
if [ "\$1 \$2" = "api graphql" ]; then
  m=""; for a in "\$@"; do case "\$a" in n=*) m="\${a#n=}" ;; esac; done
  if [ -n "\$m" ] && [ -f "\$fx/prs-\$m.json" ]; then cat "\$fx/prs-\$m.json"; exit 0; fi
  echo "HTTP 502" >&2; exit 1
fi
if [ "\$1" = api ]; then
  n=\$(printf '%s' "\$2" | sed -n 's#^repos/acme/w/issues/\([0-9]*\)\$#\1#p')
  if [ -n "\$n" ] && [ -f "\$fx/next-issue-\$n.json" ] && [ -f "\$fx/served-\$n" ]; then
    mv "\$fx/next-issue-\$n.json" "\$fx/issue-\$n.json"
  fi
  [ -n "\$n" ] && touch "\$fx/served-\$n"
  if [ -n "\$n" ] && [ -f "\$fx/issue-\$n.json" ]; then cat "\$fx/issue-\$n.json"; exit 0; fi
  if [ -f "\$fx/fail-all" ]; then echo "HTTP 502" >&2; exit 1; fi
  echo "gh: Not Found (HTTP 404)" >&2; exit 1
fi
if [ "\$1 \$2" = "issue edit" ]; then
  [ -f "\$fx/edit-fail" ] && { echo "HTTP 502" >&2; exit 1; }
  bf=""; prev=""; for a in "\$@"; do [ "\$prev" = --body-file ] && bf="\$a"; prev="\$a"; done
  jq --rawfile b "\$bf" '.body = \$b' "\$fx/issue-\$3.json" > "\$fx/tmp" && mv "\$fx/tmp" "\$fx/issue-\$3.json"
  [ -f "\$fx/edit-clobber" ] && jq '.body = "clobbered by another writer"' "\$fx/issue-\$3.json" > "\$fx/tmp" && mv "\$fx/tmp" "\$fx/issue-\$3.json"
  exit 0
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
check_eq "children: a listed child GitHub cannot find exits 6 (JSON still printed)" "6" "$rc"
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

# Conservative rule: only top-level items (0-3 spaces, no tab) are children, so a
# fence nested in a list item and indented code never leak an example.
BODY520=$'- Examples:\n    ~~~\n    - [ ] #200\n    ~~~\n- [ ] #101\n'
issue 520 open "List-container fence parent" "$BODY520"
out=$("$SCRIPT" children acme/w 520); rc=$?
check_eq "list-item fence: exits 0" "0" "$rc"
check_eq "list-item fence: only the top-level #101" "101" "$(jq -r '[.children[].number] | join(",")' <<< "$out")"
BODY530=$'Text.\n\n    - [ ] #200 indented code\n\t- [ ] #201 tab-indented\n   - [ ] #104 three spaces still counts\n'
issue 530 open "Indented code parent" "$BODY530"
out=$("$SCRIPT" children acme/w 530); rc=$?
check_eq "indented code: 4+ spaces and tabs are never children" "104" "$(jq -r '[.children[].number] | join(",")' <<< "$out")"

# ---- sub-issue API unavailable: body still stands ------------------------------
rm "$TMP/fx/sub-100.json"
out=$("$SCRIPT" children acme/w 100); rc=$?
check_eq "no sub-issue API: still reads (exit 6 only for the missing #106)" "6" "$rc"
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

issue 700 closed "Closed parent, open child" $'- [x] #501\n- [ ] #502\n'
issue 502 open "c2 reopened" ""
echo '[]' > "$TMP/fx/sub-700.json"
: > "$TMP/calls.log"
out=$("$SCRIPT" close-if-done acme/w 700 2>/dev/null); rc=$?
check_eq "close-if-done: closed parent with an open child is a discrepancy (exit 1)" "1" "$rc"
check_eq "close-if-done: discrepancy line" "discrepancy #700 closed with 1 of 2 children open" "$out"
issue 720 closed "Closed parent, only a missing child" $'- [x] #799\n'
echo '[]' > "$TMP/fx/sub-720.json"
"$SCRIPT" close-if-done acme/w 720 >/dev/null 2>&1; rc=$?
check_eq "close-if-done: a closed parent listing only a missing child is not done (exit 1)" "1" "$rc"
issue 730 closed "Closed parent, sub-issues unreadable" "No list."
"$SCRIPT" close-if-done acme/w 730 >/dev/null 2>&1; rc=$?
check_eq "close-if-done: a closed parent with unreadable sub-issues is not done (exit 1)" "1" "$rc"
issue 710 open "Race parent" $'- [x] #501\n- [x] #711\n'
issue 711 closed "c711" ""
echo '[]' > "$TMP/fx/sub-710.json"
rm -f "$TMP/fx/served-711"
jq '.state = "open"' "$TMP/fx/issue-711.json" > "$TMP/fx/next-issue-711.json"
: > "$TMP/calls.log"
out=$("$SCRIPT" close-if-done acme/w 710); rc=$?
check_eq "close-if-done: a child reopened before the close re-read keeps the parent open" "open #710 (1 of 2 children open)" "$out"
check_eq "close-if-done: no close call after the re-read finds an open child" "0" "$(grep -c '^issue close' "$TMP/calls.log")"

# ---- epic scope record and waves (issue #2546) -------------------------------------
body_of() { jq -r '.body' "$TMP/fx/issue-$1.json"; }
rows() { printf '%s\n' "$@" > "$TMP/rows"; }
prs() {  # prs N JSON-NODES
  jq -n --argjson nodes "$2" '{data: {repository: {issue: {closedByPullRequestsReferences: {pageInfo: {hasNextPage: false}, nodes: $nodes}}}}}' > "$TMP/fx/prs-$1.json"
}

# A childless epic describing eight deliverables, captured by /issue-maker.
issue 800 open "Big theme" $'Build the big theme.\n\n## Not yet cut\n\n- six\n- seven\n\n_Captured via /issue-maker._'
"$SCRIPT" children acme/w 800 >/dev/null 2>&1; rc=$?
check_eq "waves: a childless epic is still exit 5 from children" "5" "$rc"
out=$("$SCRIPT" scope acme/w 800); rc=$?
check_eq "scope: no record is exit 5" "5" "$rc"
check_eq "scope: no record prints present:false" "false" "$(jq -r .present <<< "$out")"
rows "- S1 · remaining · One" "- S2 · remaining · Two" "- S3 · remaining · Three" "- S4 · remaining · Four" \
  "- S5 · remaining · Five" "- S6 · remaining · Six" "- S7 · remaining · Seven" "- S8 · remaining · Eight"
check_eq "scope-init: writes eight remaining items" "scope #800: 8 items, 8 remaining" "$("$SCRIPT" scope-init acme/w 800 "$TMP/rows")"
check_eq "scope-init: the footer stays the last line" "_Captured via /issue-maker._" "$(body_of 800 | sed '/^$/d' | tail -1)"
check_contains "scope-init: the original text is kept" "## Not yet cut" "$(body_of 800)"
"$SCRIPT" children acme/w 800 >/dev/null 2>&1; rc=$?
check_eq "scope rows are never children (plain bullets)" "5" "$rc"
"$SCRIPT" scope-init acme/w 800 "$TMP/rows" >/dev/null 2>&1; rc=$?
check_eq "scope-init: refuses a second record (exit 8)" "8" "$rc"
check_eq "wave-due: the first wave is due at once, five items" "due 1 S1,S2,S3,S4,S5" "$("$SCRIPT" wave-due acme/w 800)"
"$SCRIPT" wave-open acme/w 800 2 5 >/dev/null 2>&1; rc=$?
check_eq "wave-open: a wave that is not next is refused" "8" "$rc"
"$SCRIPT" wave-open acme/w 800 1 6 >/dev/null 2>&1; rc=$?
check_eq "wave-open: more than five children is refused" "8" "$rc"
"$SCRIPT" record acme/w 800 S1 801 >/dev/null 2>&1; rc=$?
check_eq "record: refused before a wave is open" "8" "$rc"
check_eq "wave-open: opens wave 1" "opened wave 1 on #800 (5 planned)" "$("$SCRIPT" wave-open acme/w 800 1 5)"
check_eq "wave-open: the same call again is a no-op" "wave 1 already open (5 planned)" "$("$SCRIPT" wave-open acme/w 800 1 5)"
for n in 801 802 803 804 805 806 807 808 809; do issue "$n" open "Child $n" "- Parent: #800"; done
"$SCRIPT" record acme/w 800 S1 801 >/dev/null
"$SCRIPT" record acme/w 800 S2 802 >/dev/null
check_eq "record: names the item and the wave" "recorded #803 for S3 (wave 1)" "$("$SCRIPT" record acme/w 800 S3 803)"
# A fresh thread after a crash mid-wave resumes the wave; it never re-opens it.
check_eq "wave-due: a part-filed wave resumes with only its unfiled items" "resume 1 S4,S5 3/5" "$("$SCRIPT" wave-due acme/w 800)"
"$SCRIPT" wave-open acme/w 800 2 3 >/dev/null 2>&1; rc=$?
check_eq "wave-open: the next wave waits for the current one to be filed" "8" "$rc"
"$SCRIPT" record acme/w 800 S4 804 >/dev/null
"$SCRIPT" record acme/w 800 S5 805 >/dev/null
"$SCRIPT" record acme/w 800 S6 806 >/dev/null 2>&1; rc=$?
check_eq "record: a sixth child in a five-child wave is refused" "8" "$rc"
"$SCRIPT" record acme/w 800 S1 806 >/dev/null 2>&1; rc=$?
check_eq "record: a covered item never takes a second child" "8" "$rc"
"$SCRIPT" record acme/w 800 S9 806 >/dev/null 2>&1; rc=$?
check_eq "record: an unknown item is refused" "8" "$rc"
check_eq "record: the same pair again is a no-op" "already recorded #801 for S1" "$("$SCRIPT" record acme/w 800 S1 801)"
out=$("$SCRIPT" scope acme/w 800)
check_eq "scope: three items remain after wave 1" "S6,S7,S8" "$(jq -r '.remaining | join(",")' <<< "$out")"
check_eq "scope: wave 1 covers five" "801,802,803,804,805" "$(jq -r '.children | join(",")' <<< "$out")"
out=$("$SCRIPT" children acme/w 800); rc=$?
check_eq "children: the wave's children are read from the increment chain" "801,802,803,804,805" "$(jq -r '[.children[] | select(.sources | index("increment-chain")) | .number] | join(",")' <<< "$out")"
check_eq "record: one box per child, no duplicates" "5" "$(body_of 800 | grep -c '^- \[ \] #80')"
check_eq "record: the footer is still the last line" "_Captured via /issue-maker._" "$(body_of 800 | sed '/^$/d' | tail -1)"
scope_line=$(body_of 800 | grep -n '^## Epic scope' | cut -d: -f1)
chain_line=$(body_of 800 | grep -n '^## Increment chain' | cut -d: -f1)
if [[ -n "$scope_line" && -n "$chain_line" && "$scope_line" -lt "$chain_line" ]]; then
  pass "the scope record sits above the increment chain"
else
  fail "the scope record sits above the increment chain ($scope_line vs $chain_line)"
fi
# Step 5.1's ordinary strip-to-end of the chain section can never take the record.
check_contains "Step 5.1's checklist strip keeps the scope record" "## Epic scope" \
  "$(body_of 800 | awk '/^## Increment chain$/{f=1} !f')"

# The next wave waits for the last child of wave 1 (#805, the highest number).
prs 805 '[]'
check_eq "wave-due: waits while the last child has no PR" "wait 1 - #805" "$("$SCRIPT" wave-due acme/w 800)"
prs 805 '[{"number":9,"state":"OPEN","isDraft":true}]'
check_eq "wave-due: a draft PR is not in review" "wait 1 - #805" "$("$SCRIPT" wave-due acme/w 800)"
prs 805 '[{"number":9,"state":"CLOSED","isDraft":false}]'
check_eq "wave-due: a closed unmerged PR is not in review" "wait 1 - #805" "$("$SCRIPT" wave-due acme/w 800)"
prs 805 '[{"number":9,"state":"OPEN","isDraft":false}]'
check_eq "wave-due: an open PR for the last child makes the next wave due" "due 2 S6,S7,S8" "$("$SCRIPT" wave-due acme/w 800)"
rm "$TMP/fx/prs-805.json"
"$SCRIPT" wave-due acme/w 800 >/dev/null 2>&1; rc=$?
check_eq "wave-due: an unreadable PR list is exit 1, never due" "1" "$rc"
printf '{"data":{"repository":null}}' > "$TMP/fx/prs-805.json"
"$SCRIPT" wave-due acme/w 800 >/dev/null 2>&1; rc=$?
check_eq "wave-due: a partial GraphQL answer is exit 1, never due" "1" "$rc"
rm "$TMP/fx/prs-805.json"
issue 805 closed "Child 805" "- Parent: #800"
check_eq "wave-due: a closed last child makes the next wave due" "due 2 S6,S7,S8" "$("$SCRIPT" wave-due acme/w 800)"
check_eq "wave-open: opens wave 2 with the three left" "opened wave 2 on #800 (3 planned)" "$("$SCRIPT" wave-open acme/w 800 2 3)"
"$SCRIPT" record acme/w 800 S6 801 >/dev/null 2>&1; rc=$?
check_eq "record: a child already covering another item is refused" "8" "$rc"
for p in "S6 806" "S7 807" "S8 808"; do "$SCRIPT" record acme/w 800 $p >/dev/null; done
check_eq "wave-due: nothing remains, no more waves" "covered 2 -" "$("$SCRIPT" wave-due acme/w 800)"
check_eq "record: wave 2 boxes added after wave 1's" "801,802,803,804,805,806,807,808" \
  "$(body_of 800 | sed -n 's/^- \[ \] #\([0-9]*\)$/\1/p' | paste -sd, -)"

# close-if-done keeps a parent open while its scope record lists remaining items.
issue 820 open "Half-done epic" $'Scope.\n\n## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 1 · planned 1\n\n- S1 · covered by #821 · wave 1 · First\n- S2 · remaining · Second\n\n## Increment chain\n\n- [x] #821\n'
issue 821 closed "First" "- Parent: #820"
echo '[]' > "$TMP/fx/sub-820.json"
: > "$TMP/calls.log"
check_eq "close-if-done: remaining scope keeps the parent open" "open #820 (every child closed; 1 scope items remain)" "$("$SCRIPT" close-if-done acme/w 820)"
check_eq "close-if-done: no close call while scope remains" "0" "$(grep -c '^issue close' "$TMP/calls.log")"
check_eq "wave-due: an epic with a closed wave and remaining scope gets the next wave" "due 2 S2" "$("$SCRIPT" wave-due acme/w 820)"
issue 822 open "Malformed epic" $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 1\n\n- S1 · covred by #821 · wave 1 · typo\n\n- [x] #821\n'
echo '[]' > "$TMP/fx/sub-822.json"
err=$("$SCRIPT" close-if-done acme/w 822 2>&1 >/dev/null); rc=$?
check_eq "close-if-done: a malformed record never closes (exit 1)" "1" "$rc"
check_contains "close-if-done: malformed reason" "malformed" "$err"
check_eq "close-if-done: no close call on a malformed record" "0" "$(grep -c '^issue close' "$TMP/calls.log")"

# An epic with two existing children and uncovered scope: only the remainder is split.
issue 830 open "Partly split epic" $'Theme.\n\n- [ ] #831\n- [ ] #832\n'
issue 831 open "Existing one" ""
issue 832 open "Existing two" ""
rows "- S1 · covered by #831 · wave 0 · One" "- S2 · covered by #832 · wave 0 · Two" "- S3 · remaining · Three"
"$SCRIPT" scope-init acme/w 830 "$TMP/rows" >/dev/null 2>&1; rc=$?
check_eq "scope-init: wave-0 coverage on a partial child list (sub-issues unreadable) is refused" "1" "$rc"
check_eq "scope-init: nothing written on a partial child list" "0" "$(body_of 830 | grep -c '## Epic scope')"
echo '[]' > "$TMP/fx/sub-830.json"
"$SCRIPT" scope-init acme/w 830 "$TMP/rows" >/dev/null
check_eq "existing children: only the uncovered item is due (wave 0 never waits)" "due 1 S3" "$("$SCRIPT" wave-due acme/w 830)"
check_eq "existing children: the original task list is kept" "2" "$(body_of 830 | grep -c '^- \[ \] #83[12]$')"
issue 840 open "Fully covered epic" $'- [ ] #831\n'
echo '[]' > "$TMP/fx/sub-840.json"
rows "- S1 · covered by #831 · wave 0 · All of it"
"$SCRIPT" scope-init acme/w 840 "$TMP/rows" >/dev/null
check_eq "a fully covered epic gets no wave" "covered 0 -" "$("$SCRIPT" wave-due acme/w 840)"
issue 841 open "Bad init" ""
echo '[]' > "$TMP/fx/sub-841.json"
rows "- S1 · covered by #899 · wave 0 · Ghost"
"$SCRIPT" scope-init acme/w 841 "$TMP/rows" >/dev/null 2>&1; rc=$?
check_eq "scope-init: a wave-0 row naming an issue that is not a child is refused" "2" "$rc"
rows "- S1 · covered by #832 · wave 0 · Not ours"
"$SCRIPT" scope-init acme/w 841 "$TMP/rows" >/dev/null 2>&1; rc=$?
check_eq "scope-init: a real issue that is not this parent's child cannot cover an item" "2" "$rc"
rows "- S1 · covered by #831 · wave 2 · Future"
"$SCRIPT" scope-init acme/w 841 "$TMP/rows" >/dev/null 2>&1; rc=$?
check_eq "scope-init: a new record covers only at wave 0" "2" "$rc"
rows "S1 remaining"
"$SCRIPT" scope-init acme/w 841 "$TMP/rows" >/dev/null 2>&1; rc=$?
check_eq "scope-init: a row off the shape is a usage error" "2" "$rc"
check_eq "scope-init: nothing written on a refused init" "" "$(body_of 841)"

# No clean seam: filing stops, the reason is recorded, nothing more is filed.
check_eq "stop: records the reason" "stopped filing on #830: no clean seam: the rest is one migration" \
  "$("$SCRIPT" stop acme/w 830 'no clean seam: the rest is one migration')"
check_eq "wave-due: a stopped epic files nothing and says why" "stopped 0 - no clean seam: the rest is one migration" "$("$SCRIPT" wave-due acme/w 830)"
"$SCRIPT" wave-open acme/w 830 1 1 >/dev/null 2>&1; rc=$?
check_eq "wave-open: refused while stopped" "8" "$rc"
check_eq "stop: the same reason again is a no-op" "already stopped #830" "$("$SCRIPT" stop acme/w 830 'no clean seam: the rest is one migration')"
check_eq "stop: one Stopped: line" "1" "$(body_of 830 | grep -c '^Stopped:')"

# Malformed records fail closed.
mal() {  # mal N BODY LABEL
  issue "$1" open "Malformed" "$2"
  "$SCRIPT" scope acme/w "$1" >/dev/null 2>&1; local r=$?
  check_eq "malformed: $3 is exit 7" "7" "$r"
  "$SCRIPT" wave-due acme/w "$1" >/dev/null 2>&1; r=$?
  check_eq "malformed: wave-due on $3 is exit 7" "7" "$r"
}
mal 850 $'## Epic scope\n\nWave: 0\n\n- S1 · remaining · x\n' "no marker"
mal 851 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\n\n- S1 · remaining · x\n' "no Wave line"
mal 852 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n- S1 · remaining · x\n- S1 · remaining · y\n' "a duplicate item"
mal 853 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n- S1 · covered by #831 · wave 3 · x\n' "a wave past the current wave"
mal 854 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n- S1 · remaining · x\n\n## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n- S2 · remaining · y\n' "two sections"
mal 855 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 1 · planned 9\n\n- S1 · remaining · x\n' "a planned count past five"
mal 856 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: one\n\n- S1 · remaining · x\n' "an unreadable Wave line"
issue 857 open "Fenced example" $'```\n## Epic scope\n- S1 · remaining · x\n```\n'
"$SCRIPT" scope acme/w 857 >/dev/null 2>&1; rc=$?
check_eq "a fenced '## Epic scope' example is not a record" "5" "$rc"

# A record section ends at the next heading; later sections survive a write.
issue 860 open "Sections" $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n- S1 · remaining · x\n- S2 · remaining · y\n\n## Increment chain\n\n- [x] #831\n\n## Notes\n\nKeep me.\n'
issue 861 open "c861" ""
"$SCRIPT" wave-open acme/w 860 1 1 >/dev/null
"$SCRIPT" record acme/w 860 S1 861 >/dev/null
check_eq "record: the new box follows the earlier box" "831,861" "$(body_of 860 | sed -n 's/^- \[[ x]\] #\([0-9]*\)$/\1/p' | paste -sd, -)"
check_contains "record: a later section survives" $'## Notes\n\nKeep me.' "$(body_of 860)"
check_eq "record: the S2 row is untouched" "- S2 · remaining · y" "$(body_of 860 | grep '^- S2')"

mal 858 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 1\n\n- S1 · remaining · x\n' "a positive wave with no planned count"
mal 859 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\nStopped:\n\n- S1 · remaining · x\n' "an empty Stopped: line"

# Fenced examples inside the record are never items; a last row with no newline is.
issue 862 open "Fenced row" $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n```\n- S9 · remaining · example only\n```\n- S1 · remaining · real'
check_eq "scope: a fenced row is not an item; an unterminated last row is" "S1" "$("$SCRIPT" scope acme/w 862 | jq -r '.remaining | join(",")')"
issue 863 open "Open fence" $'Text.\n\n```\nunclosed'
rows "- S1 · remaining · x"
"$SCRIPT" scope-init acme/w 863 "$TMP/rows" >/dev/null 2>&1; rc=$?
check_eq "scope-init: refuses a body that ends inside an unclosed fence" "8" "$rc"
check_eq "scope-init: nothing written into a fence" $'Text.\n\n```\nunclosed' "$(body_of 863)"
# A fenced box for the child is not a link: record adds a real one outside the fence.
issue 864 open "Fenced box" $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n- S1 · remaining · x\n\n## Increment chain\n\n```\n- [ ] #865\n```\n'
issue 865 open "c865" ""
"$SCRIPT" wave-open acme/w 864 1 1 >/dev/null
"$SCRIPT" record acme/w 864 S1 865 >/dev/null
check_eq "record: a fenced box is not a link; the real box is added" "865" \
  "$("$SCRIPT" children acme/w 864 2>/dev/null | jq -r '[.children[].number] | join(",")')"
# close-if-done never closes past a child the record names but the child list did not show.
issue 880 open "Race epic" $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 1 · planned 2\n\n- S1 · covered by #881 · wave 1 · a\n- S2 · covered by #882 · wave 1 · b\n\n## Increment chain\n\n- [x] #881\n'
issue 881 closed "c881" ""
issue 882 open "c882" ""
echo '[]' > "$TMP/fx/sub-880.json"
: > "$TMP/calls.log"
check_contains "close-if-done: a recorded child missing from the child list keeps the parent open" "open #880" \
  "$("$SCRIPT" close-if-done acme/w 880)"
check_eq "close-if-done: no close call past an unlisted recorded child" "0" "$(grep -c '^issue close' "$TMP/calls.log")"

mal 866 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n- S1 · remaining · x\n- S2· remaining · typo\n' "an off-shape item row"
mal 867 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 1 · planned 1\n\n- S1 · covered by #881 · wave 1 · a\n- S2 · covered by #882 · wave 1 · b\n- S3 · remaining · c\n' "a wave with more children than planned"
# scope-init can write a record already stopped, in one write.
issue 868 open "Stopped at birth" $'- [ ] #831\n'
echo '[]' > "$TMP/fx/sub-868.json"
rows "- S1 · covered by #831 · wave 0 · Done part" "- S2 · remaining · The rest"
"$SCRIPT" scope-init acme/w 868 "$TMP/rows" "no clean seam: one migration" >/dev/null
check_eq "scope-init: a stop reason is written in the same record" "stopped 0 - no clean seam: one migration" "$("$SCRIPT" wave-due acme/w 868)"
# More than 100 linked PRs with none qualifying is unread, never "wait".
issue 869 open "Paged epic" $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 1 · planned 1\n\n- S1 · covered by #882 · wave 1 · a\n- S2 · remaining · b\n'
jq -n '{data: {repository: {issue: {closedByPullRequestsReferences: {pageInfo: {hasNextPage: true}, nodes: [{number: 1, state: "CLOSED", isDraft: false}]}}}}}' > "$TMP/fx/prs-882.json"
"$SCRIPT" wave-due acme/w 869 >/dev/null 2>&1; rc=$?
check_eq "wave-due: an unread next page of PRs is exit 1" "1" "$rc"
rm "$TMP/fx/prs-882.json"
# A child listed on the parent after the child read keeps the parent open.
issue 885 open "Late child epic" $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 1 · planned 1\n\n- S1 · covered by #881 · wave 1 · a\n\n## Increment chain\n\n- [x] #881\n'
echo '[]' > "$TMP/fx/sub-885.json"
rm -f "$TMP/fx/served-885"
jq '.body += "- [ ] #882\n"' "$TMP/fx/issue-885.json" > "$TMP/fx/next-issue-885.json"
issue 881 closed "c881" ""
: > "$TMP/calls.log"
out=$("$SCRIPT" close-if-done acme/w 885 2>/dev/null); rc=$?
check_eq "close-if-done: the late-child check exits 0" "0" "$rc"
check_contains "close-if-done: the late-child check reports the parent open" "open #885" "$out"
check_eq "close-if-done: a child added before the scope read keeps the parent open" "0" "$(grep -c '^issue close' "$TMP/calls.log")"

mal 886 $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 1 · planned 2\n\n- S1 · covered by #881 · wave 1 · a\n- S2 · covered by #881 · wave 1 · b\n' "one wave child covering two items"
# An indented heading (1-3 spaces) is still the record.
issue 887 open "Indented heading" $' ## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n- S1 · remaining · x\n'
check_eq "scope: a heading indented 1-3 spaces is still the record" "S1" "$("$SCRIPT" scope acme/w 887 | jq -r '.remaining | join(",")')"
# A PR listed on the parent never blocks the close.
issue 888 open "PR on the list" $'## Increment chain\n\n- [x] #881\n- [x] #105\n'
echo '[]' > "$TMP/fx/sub-888.json"
check_eq "close-if-done: a listed PR is not a late child" "closed #888 (1 children)" "$("$SCRIPT" close-if-done acme/w 888 2>/dev/null)"

# Write failures and a lost race are reported, never assumed.
issue 870 open "Write fails" $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n- S1 · remaining · x\n'
touch "$TMP/fx/edit-fail"
"$SCRIPT" wave-open acme/w 870 1 1 >/dev/null 2>&1; rc=$?
check_eq "wave-open: a failed write is exit 1" "1" "$rc"
rm "$TMP/fx/edit-fail"
touch "$TMP/fx/edit-clobber"
"$SCRIPT" wave-open acme/w 870 1 1 >/dev/null 2>&1; rc=$?
check_eq "wave-open: a write another writer overwrote fails verification (exit 1)" "1" "$rc"
rm "$TMP/fx/edit-clobber"
issue 871 closed "Closed epic" $'## Epic scope\n\n<!-- pm-epic-scope v1 -->\nWave: 0\n\n- S1 · remaining · x\n'
"$SCRIPT" wave-due acme/w 871 >/dev/null 2>&1; rc=$?
check_eq "wave-due: a closed parent is exit 4" "4" "$rc"
"$SCRIPT" record acme/w 820 S2 820 >/dev/null 2>&1; rc=$?
check_eq "record: the parent is never its own child" "2" "$rc"

# ---- epic.md blocks: Restore and Completion ----------------------------------------
block() {  # block ANCHOR -> the bash fence following that test anchor in epic.md
  awk -v a="<!-- test-anchor: $1 -->" '$0 == a {f = 1; next} f && /^```bash/ {b = 1; next} b && /^```/ {exit} b {print}' \
    "$SKILL/modules/shared/epic.md"
}
RESTORE=$(block pm-epic-restore)
cat > "$TMP/bin/ss-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SS_LOG"
if [ "$1" = --get-json ]; then cat "$SS_VALUE"; exit "${SS_RC:-0}"; fi
exit 0
STUB
chmod +x "$TMP/bin/ss-stub"
restore() {  # restore JSON [RC] -> "UNREADABLE NUMBER COMPLETE"
  printf '%s' "$1" > "$TMP/ss-value"
  SS_VALUE="$TMP/ss-value" SS_LOG="$TMP/ss.log" SS_RC="${2:-0}" SESSION_STATE_SH="$TMP/bin/ss-stub" REPO_KEY=acme/w \
    bash -c 'EPIC_SCOPE_UNREADABLE=true; EPIC_NUMBER=""; '"$RESTORE"'; echo "$EPIC_SCOPE_UNREADABLE ${EPIC_NUMBER:-none} $EPIC_COMPLETE"'
}
check_eq "restore: a valid epic clears an earlier unreadable flag" "false 12 false" "$(restore '{"number":12,"set_at":"x"}')"
check_eq "restore: a completed epic reads as complete, not as no epic" "false 12 true" "$(restore '{"number":12,"set_at":"x","completed_at":"y"}')"
check_eq "restore: null is no epic" "false none false" "$(restore 'null')"
check_eq "restore: a string number is unreadable" "true none false" "$(restore '{"number":"12"}')"
check_eq "restore: a failed read is unreadable" "true none false" "$(restore 'null' 4)"
COMPLETE=$(block pm-epic-complete)
cat > "$TMP/bin/epic-stub" <<'STUB'
#!/usr/bin/env bash
echo "closed #12 (2 children)"
STUB
chmod +x "$TMP/bin/epic-stub"
: > "$TMP/ss.log"
SS_VALUE=/dev/null SS_LOG="$TMP/ss.log" SESSION_STATE_SH="$TMP/bin/ss-stub" PM_EPIC_SH="$TMP/bin/epic-stub" \
  REPO_KEY=acme/w EPIC_NUMBER=12 bash -c "$COMPLETE" >/dev/null
check_contains "completion: marks the stored epic complete" '.epic.completed_at=' "$(cat "$TMP/ss.log")"
check_eq "completion: never nulls the epic (no whole-backlog fall-through)" "0" "$(grep -c 'epic=null' "$TMP/ss.log")"
WAVE=$(block pm-epic-wave)
wave() {  # wave "LINE" RC -> "FILE NEEDS_SCOPE UNREADABLE VERDICT K ITEMS"
  printf '#!/usr/bin/env bash\necho "%s"\nexit %s\n' "$1" "$2" > "$TMP/bin/wave-stub"
  chmod +x "$TMP/bin/wave-stub"
  PM_EPIC_SH="$TMP/bin/wave-stub" REPO_KEY=acme/w EPIC_NUMBER=12 \
    bash -c 'EPIC_SCOPE_UNREADABLE=false; '"$WAVE"'; echo "$EPIC_FILE_WAVE $EPIC_NEEDS_SCOPE $EPIC_SCOPE_UNREADABLE $EPIC_WAVE_VERDICT $EPIC_WAVE_K $EPIC_WAVE_ITEMS"'
}
check_eq "wave block: due files the listed items" "true false false due 2 S6,S7,S8" "$(wave 'due 2 S6,S7,S8' 0)"
check_eq "wave block: resume files the rest of a part-filed wave" "true false false resume 1 S4,S5" "$(wave 'resume 1 S4,S5 3/5' 0)"
check_eq "wave block: wait files nothing" "false false false wait 1 -" "$(wave 'wait 1 - #805' 0)"
check_eq "wave block: stopped files nothing" "false false false stopped 0 -" "$(wave 'stopped 0 - no clean seam' 0)"
check_eq "wave block: no record runs the scope check" "false true false none 0 -" "$(wave 'none 0 -' 5)"
check_eq "wave block: a malformed record pauses" "false false true   " "$(wave '' 7)"
check_eq "wave block: an unreadable read pauses, never files" "false false true   " "$(wave '' 1)"

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
check_contains "rank:load restores a stored epic, not only a typed one" 'Restore block' "$(cat "$SKILL/modules/rank/load.md")"
check_contains "refill applies the epic scope" 'shared:epic' "$(cat "$SKILL/modules/flow/refill.md")"
check_contains "resume restores the epic scope" 'shared:epic' "$(cat "$SKILL/modules/resume/load.md")"
# Outside the routing notes that point at shared:epic (and the two idle-reason
# rows naming it), no ranking or refill text mentions epics at all: nothing
# there can key on an "epic" title, label or keyword.
stray=$(for f in "$SKILL"/modules/rank/*.md "$SKILL/modules/flow/refill.md"; do
  awk -v f="$f" '/<!-- pm-routing:begin -->/ {r = 1} /<!-- pm-routing:end -->/ {r = 0; next}
    !r && tolower($0) ~ /epic/ && index($0, "(epic #N complete)") == 0 &&
      index($0, "(epic #N stopped: <reason>)") == 0 &&
      index($0, "(epic scope unreadable)") == 0 {print f ": " $0}' "$f"
done)
check_eq "ranking and refill never key on an 'epic' title, label or keyword" "" "$stray"

echo
echo "pm-epic.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
