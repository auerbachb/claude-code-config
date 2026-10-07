#!/usr/bin/env bash
# pm-priority.test.sh — Offline tests for pm-priority.sh and /pm's use of it (issue #1767).
# catalog: tests — Tests for `pm-priority.sh` — the issue's tests 5.1 (`top: #c #a` leads, marked override) and 5.2 (`park #b until tomorrow`: absent today, back tomorrow), AC 4.3 (drop restores the ranked place; an absent file passes through), the date grammar, a corrupt file (exit 4, never overwritten), a linked worktree writing the main-root file, `--repo` resolution, concurrent writers, and `/pm`'s anchored read/overlay blocks plus its refill and template contract
#
# Everything runs in a throwaway HOME and git repo: the developer's
# ~/.claude/session-state.json and checkouts are never read or written.
# The /pm blocks are extracted from pm/SKILL.md by their test anchors and run
# against the real helper, so the skill's bash and the helper cannot drift.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../pm-priority.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PM_SKILL="$REPO_ROOT/.claude/skills/pm/SKILL.md"
TEMPLATES="$REPO_ROOT/.claude/reference/pm-output-templates.md"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
check_contains() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
die() { echo "FATAL — $1" >&2; exit 1; }

[[ -x "$HELPER" ]] || die "pm-priority.sh not found at $HELPER"
command -v jq >/dev/null 2>&1 || { echo "SKIP: pm-priority.test.sh — jq is not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: pm-priority.test.sh — git is not installed"; exit 0; }

# shellcheck source=lib/skill-bash.sh
source "$SCRIPT_DIR/lib/skill-bash.sh"

TMP="$(mktemp -d)" || die "mktemp -d failed"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd -P "$TMP" && pwd)"   # macOS: /var → /private/var, so paths compare equal

export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$TMP/notrepo"
unset CLAUDE_SESSION_REPO

REPO="$TMP/repo"
WT="$TMP/wt"
FILE="$REPO/.claude/pm-priority.json"
mkdir -p "$REPO"
git -C "$REPO" init -q || die "git init failed"
git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init || die "git commit failed"
git -C "$REPO" remote add origin git@github.com:Acme/Widgets.git || die "git remote add failed"
git -C "$REPO" worktree add -q "$WT" -b feature >/dev/null 2>&1 || die "git worktree add failed"

D1="2026-10-07"   # a Wednesday
D2="2026-10-08"

# p ARGS… — run the helper from the main checkout with today pinned to D1.
p() { (cd "$REPO" && "$HELPER" --today "$D1" "$@"); }
# apply_on DAY — the six-issue fixture backlog (#101…#106 = a…f), overlaid.
FIXTURE=$'101\n102\n103\n104\n105\n106'
apply_on() { (cd "$REPO" && printf '%s\n' "$FIXTURE" | "$HELPER" --today "$1" apply); }
order_of() { printf '%s\n' "$1" | awk -F'\t' '{print $1}' | paste -sd' ' -; }

# --------------------------------------------------------------- absent file
echo "== absent file: no override"
out=$(p show --json); rc=$?
check "show on an absent file exits 0" "$rc" "0"
check "show --json reports present:false" "$(jq -r '.present' <<<"$out")" "false"
check "show --json names the main-root file" "$(jq -r '.file' <<<"$out")" "$FILE"
check "show --json derives the repo from origin" "$(jq -r '.repo' <<<"$out")" "acme/widgets"
out=$(apply_on "$D1"); rc=$?
check "apply on an absent file exits 0" "$rc" "0"
check "apply on an absent file passes the ranking through" "$(order_of "$out")" "101 102 103 104 105 106"
check "every passed-through row is tagged ranked" "$(awk -F'\t' '$2!="ranked"' <<<"$out" | wc -l | tr -d ' ')" "0"
p drop 104 >/dev/null; rc=$?
check "drop on an absent file exits 0" "$rc" "0"
if [[ ! -e "$FILE" ]]; then ok "drop on an absent file creates no file"; else fail "drop on an absent file created $FILE"; fi

# ------------------------------------------------------------- test 5.1
echo "== test 5.1: top: #c #a"
out=$(p top '#103' 101); rc=$?
check "top exits 0" "$rc" "0"
check_contains "top names the new order" "$out" "Order set: #103, #101"
out=$(apply_on "$D1")
check "#c and #a lead, then the rest in ranked order" "$(order_of "$out")" "103 101 102 104 105 106"
check "row 1 is #103, override, place 1" "$(sed -n 1p <<<"$out")" $'103\toverride\t1'
check "row 2 is #101, override, place 2" "$(sed -n 2p <<<"$out")" $'101\toverride\t2'
check "rows 3-6 are tagged ranked" "$(sed -n '3,$p' <<<"$out" | awk -F'\t' '$2=="ranked"' | wc -l | tr -d ' ')" "4"
json=$(cd "$REPO" && printf '%s\n' "$FIXTURE" | "$HELPER" --today "$D1" apply --json)
check "apply --json: the same order" "$(jq -r '[.order[].issue] | join(" ")' <<<"$json")" "103 101 102 104 105 106"
check "apply --json: nothing not eligible" "$(jq -c '.not_eligible' <<<"$json")" "[]"

echo "== an ordered issue missing from the eligible list is reported, never added"
json=$(cd "$REPO" && printf '%s\n' 101 102 104 | "$HELPER" --today "$D1" apply --json)
check "excluded #103 is not added" "$(jq -r '[.order[].issue] | join(" ")' <<<"$json")" "101 102 104"
check "#101 is override place 1 once #103 is out" "$(jq -c '.order[0]' <<<"$json")" '{"issue":101,"source":"override","position":1}'
check "excluded #103 is listed not eligible at its operator place" "$(jq -c '.not_eligible' <<<"$json")" '[{"issue":103,"position":1}]'

# ------------------------------------------------------------- AC 4.3
echo "== AC 4.3: drop restores the ranked position"
p drop 103 >/dev/null
check "after drop #103: #101 leads, #103 is back in third place" "$(order_of "$(apply_on "$D1")")" "101 102 103 104 105 106"
check "after drop #103: #103 is ranked again" "$(apply_on "$D1" | awk -F'\t' '$1==103 {print $2}')" "ranked"
p drop 101 >/dev/null
out=$(apply_on "$D1")
check "after dropping both: the ranking is untouched" "$(order_of "$out")" "101 102 103 104 105 106"
check "after dropping both: no override row is left" "$(awk -F'\t' '$2=="override"' <<<"$out" | wc -l | tr -d ' ')" "0"

# ------------------------------------------------------------- test 5.2
echo "== test 5.2: park #b until tomorrow"
out=$(p park '#102' --until tomorrow); rc=$?
check "park exits 0" "$rc" "0"
check_contains "park names the return date" "$out" "#102 parked until $D2"
check "the file records until=$D2" "$(jq -r '.parked["102"].until' "$FILE")" "$D2"
check "today: #102 is absent" "$(order_of "$(apply_on "$D1")")" "101 103 104 105 106"
check "tomorrow: #102 is back in its ranked place" "$(order_of "$(apply_on "$D2")")" "101 102 103 104 105 106"
json=$(cd "$REPO" && printf '%s\n' "$FIXTURE" | "$HELPER" --today "$D1" apply --json)
check "apply --json lists the park, in the input" "$(jq -c '.parked' <<<"$json")" "[{\"issue\":102,\"until\":\"$D2\",\"in_input\":true}]"
check "show on the return day no longer lists the park" "$(cd "$REPO" && "$HELPER" --today "$D2" show --json | jq -c '.parked')" "[]"
(cd "$REPO" && "$HELPER" --today "$D2" bump 105 >/dev/null)
check "a write on the return day prunes the expired park" "$(jq -c '.parked' "$FILE")" "{}"

echo "== park dates"
until_of() { jq -r --arg n "$1" '.parked[$n].until' "$FILE"; }
p park 110 --until friday >/dev/null;    check "friday from Wednesday $D1 is 2026-10-09" "$(until_of 110)" "2026-10-09"
p park 111 --until Wednesday >/dev/null; check "a weekday equal to today means next week" "$(until_of 111)" "2026-10-14"
p park 112 --until +3d >/dev/null;       check "+3d is 2026-10-10" "$(until_of 112)" "2026-10-10"
p park 113 --until +1 >/dev/null;        check "+1 is tomorrow" "$(until_of 113)" "$D2"
p park 114 --until 2026-12-31 >/dev/null; check "an explicit date is kept" "$(until_of 114)" "2026-12-31"
# A year end, in a second repo: a write on 2026-12-31 would prune this one's
# October parks, which the checks below still need.
REPO2="$TMP/repo2"; mkdir -p "$REPO2"
git -C "$REPO2" init -q || die "second repo: git init failed"
git -C "$REPO2" remote add origin https://github.com/acme/gadgets.git || die "second repo: git remote add failed"
out=$(cd "$REPO2" && "$HELPER" --today 2026-12-31 park 115 --until tomorrow)
check_contains "tomorrow crosses a year end" "$out" "#115 parked until 2027-01-01"
check "a park on the last day of a year is stored for the next" \
  "$(jq -r '.parked["115"].until' "$REPO2/.claude/pm-priority.json")" "2027-01-01"
before=$(cat "$FILE")
p park 116 --until "$D1" >/dev/null 2>&1; check "a park until today is refused (exit 2)" "$?" "2"
p park 116 --until 2026-01-01 >/dev/null 2>&1; check "a park in the past is refused (exit 2)" "$?" "2"
p park 116 --until 2026-02-30 >/dev/null 2>&1; check "an impossible date is refused (exit 2)" "$?" "2"
p park 116 --until someday >/dev/null 2>&1; check "a word that is not a date is refused (exit 2)" "$?" "2"
p park 116 >/dev/null 2>&1; check "park without --until is refused (exit 2)" "$?" "2"
check "refused parks leave the file unchanged" "$(cat "$FILE")" "$before"

echo "== bump and top"
p drop 105 >/dev/null
p bump 120 >/dev/null; p bump 121 >/dev/null
check "bump inserts at the head" "$(jq -c '.order' "$FILE")" "[121,120]"
out=$(p bump 120)
check_contains "bump of an ordered issue says it moved" "$out" "#120 moved to the head of the order"
check "bump moves an ordered issue to the head" "$(jq -c '.order' "$FILE")" "[120,121]"
check "#110 is parked before the bump" "$(jq -r '.parked["110"].until' "$FILE")" "2026-10-09"
p bump 110 >/dev/null
check "bump unparks the issue" "$(jq -r '.parked["110"] // "gone"' "$FILE")" "gone"
check "#111 and #112 are parked before the top" "$(jq -c '[.parked | keys[]] | sort' "$FILE")" '["111","112","113","114"]'
p top 111 112 111 >/dev/null
check "top replaces the order, without duplicates" "$(jq -c '.order' "$FILE")" "[111,112]"
check "top unparks the issues it lists, and only those" "$(jq -c '[.parked | keys[]] | sort' "$FILE")" '["113","114"]'
out=$(p drop 999)
check_contains "drop of an issue in neither list says so" "$out" "#999 was not in the override; nothing changed"

echo "== unknown fields survive a write"
jq '. + {note: "kept"}' "$FILE" > "$FILE.edit" && mv "$FILE.edit" "$FILE"
p bump 130 >/dev/null
check "a top-level field the helper does not know is preserved" "$(jq -r '.note' "$FILE")" "kept"
check "version is 1" "$(jq -r '.version' "$FILE")" "1"

# ------------------------------------------------------------- unreadable
echo "== an unreadable file: exit 4, never overwritten"
GOOD=$(cat "$FILE")
corrupt_case() { # LABEL CONTENT
  printf '%s' "$2" > "$FILE"
  local snap; snap=$(cat "$FILE")
  p show >/dev/null 2>&1;  check "$1: show exits 4" "$?" "4"
  p bump 140 >/dev/null 2>&1; check "$1: bump exits 4" "$?" "4"
  local out rc=0
  out=$(cd "$REPO" && printf '101\n' | "$HELPER" --today "$D1" apply 2>/dev/null) || rc=$?
  check "$1: apply exits 4" "$rc" "4"
  check "$1: apply prints nothing to rank by" "$out" ""
  check "$1: the file is byte-for-byte unchanged" "$(cat "$FILE")" "$snap"
}
corrupt_case "not JSON" 'not json {'
corrupt_case "a JSON array" '[1,2]'
corrupt_case "a duplicated issue" '{"order":[1,1]}'
corrupt_case "a string in order" '{"order":["7"]}'
corrupt_case "a bad parked date" '{"parked":{"7":{"until":"soon"}}}'
corrupt_case "ordered and parked" '{"order":[7],"parked":{"7":{"until":"2099-01-01"}}}'
corrupt_case "an unknown version" '{"version":2,"order":[]}'
err=$(p show 2>&1 >/dev/null)
check_contains "the error names the problem" "$err" "unsupported version"
printf '%s\n' "$GOOD" > "$FILE"
p show >/dev/null; check "a repaired file reads again" "$?" "0"

# ------------------------------------------------------------- worktrees
echo "== a linked worktree writes the main checkout's file"
out=$(cd "$WT" && "$HELPER" --today "$D1" show --json)
check "show from the worktree names the main-root file" "$(jq -r '.file' <<<"$out")" "$FILE"
(cd "$WT" && "$HELPER" --today "$D1" bump 150 >/dev/null)
check "bump from the worktree lands in the main-root file" "$(jq -r '.order[0]' "$FILE")" "150"
if [[ ! -e "$WT/.claude/pm-priority.json" ]]; then ok "no file is written inside the worktree"; else fail "a file was written inside the worktree"; fi

# ------------------------------------------------------------- --repo
echo "== --repo resolution"
out=$(cd "$REPO" && "$HELPER" --repo Acme/Widgets show --json); rc=$?
check "--repo matching the working directory exits 0" "$rc" "0"
check "--repo is matched case-insensitively" "$(jq -r '.file' <<<"$out")" "$FILE"
(cd "$TMP/notrepo" && "$HELPER" --repo acme/widgets show >/dev/null 2>&1); rc=$?
check "--repo with no checkout anywhere exits 3" "$rc" "3"
printf '{"schema_version":2,"repos":{"acme/widgets":{"root_repo":"%s"}}}\n' "$WT" > "$HOME/.claude/session-state.json"
out=$(cd "$TMP/notrepo" && "$HELPER" --repo acme/widgets show --json 2>&1); rc=$?
check "--repo through session state's root_repo exits 0" "$rc" "0"
check "--repo through a recorded worktree resolves to the main-root file" "$(jq -r '.file' <<<"$out" 2>/dev/null)" "$FILE"
(cd "$TMP/notrepo" && "$HELPER" --repo acme/other show >/dev/null 2>&1); rc=$?
check "--repo for an unknown repo exits 3" "$rc" "3"
"$HELPER" --repo acme/other --dir "$REPO" show >/dev/null 2>&1; rc=$?
check "--dir whose origin is another repo exits 3" "$rc" "3"
"$HELPER" --dir "$TMP/notrepo" show >/dev/null 2>&1; rc=$?
check "--dir outside any git checkout exits 3" "$rc" "3"
"$HELPER" --repo 'not a repo' show >/dev/null 2>&1; rc=$?
check "a malformed --repo is a usage error" "$rc" "2"
rm -f "$HOME/.claude/session-state.json"

# ------------------------------------------------------------- concurrency
echo "== concurrent writers lose no update"
pids=()
for n in 201 202 203 204 205 206 207 208; do
  (cd "$REPO" && "$HELPER" --today "$D1" bump "$n" >/dev/null 2>&1) &
  pids+=("$!")
done
crc=0
for pid in "${pids[@]}"; do wait "$pid" || crc=1; done
check "every concurrent bump exits 0" "$crc" "0"
check "all eight concurrent bumps are in the order" \
  "$(jq -c '[.order[] | select(. >= 201 and . <= 208)] | sort' "$FILE")" "[201,202,203,204,205,206,207,208]"
check "the order holds no duplicate" "$(jq '(.order | length) == (.order | unique | length)' "$FILE")" "true"
leftovers=""
for entry in "$REPO/.claude"/* "$REPO/.claude"/.[!.]*; do
  [[ -e "$entry" ]] || continue
  [[ "${entry##*/}" == "pm-priority.json" ]] || leftovers="$leftovers ${entry##*/}"
done
check "no lock dir or temp file is left behind" "$leftovers" ""

# ------------------------------------------------------------- usage
echo "== usage errors exit 2"
usage_case() { local label="$1"; shift; p "$@" >/dev/null 2>&1; check "$label" "$?" "2"; }
usage_case "an unknown verb" frob
usage_case "top with no issue" top
usage_case "bump with no issue" bump
usage_case "bump with two issues" bump 1 2
usage_case "a non-number issue" bump x12
usage_case "issue zero" bump 0
usage_case "an unknown flag" show --yaml
"$HELPER" --today 2026-13-01 show >/dev/null 2>&1; check "a bad --today" "$?" "2"
(cd "$REPO" && printf '101\nnope\n' | "$HELPER" apply >/dev/null 2>&1); check "a malformed apply line" "$?" "2"
out=$(cd "$REPO" && printf '#101\n\n  102 \n101\n' | "$HELPER" --today "$D1" apply --json | jq -r '[.order[].issue | tostring] | join(" ")')
check "apply accepts #N, blank lines, and spaces, and drops repeats" "$(tr ' ' '\n' <<<"$out" | grep -E '^(101|102)$' | paste -sd' ' -)" "101 102"
help=$("$HELPER" --help 2>&1); rc=$?
check "--help exits 0" "$rc" "0"
for needle in "EXIT STATUS" "apply" "park N" "America/New_York" "--repo OWNER/NAME"; do
  check_contains "--help documents $needle" "$help" "$needle"
done

# ------------------------------------------------------------- bash 3.2
if [[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" == "3" ]]; then
  echo "== /bin/bash 3.2"
  rm -f "$FILE"
  out=$(cd "$REPO" && /bin/bash "$HELPER" --today "$D1" top 103 101 2>&1); rc=$?
  check "bash 3.2: top exits 0" "$rc" "0"
  out=$(cd "$REPO" && printf '%s\n' "$FIXTURE" | /bin/bash "$HELPER" --today "$D1" apply)
  check "bash 3.2: test 5.1 order" "$(order_of "$out")" "103 101 102 104 105 106"
  (cd "$REPO" && /bin/bash "$HELPER" --today "$D1" park 102 --until friday >/dev/null 2>&1)
  check "bash 3.2: park friday" "$(jq -r '.parked["102"].until' "$FILE")" "2026-10-09"
  out=$(cd "$TMP/notrepo" && printf '1\n' | /bin/bash "$HELPER" apply 2>/dev/null); rc=$?
  check "bash 3.2: no checkout exits 3" "$rc" "3"
fi

# ------------------------------------------------------------- /pm blocks
echo "== /pm: the anchored read (1B.1a) and overlay (1B.4 item 7)"
READ_BLOCK="$(extract_skill_bash "$PM_SKILL" pm-1b1a-priority-read)" || die "anchor pm-1b1a-priority-read missing"
APPLY_BLOCK="$(extract_skill_bash "$PM_SKILL" pm-1b4-priority-apply)" || die "anchor pm-1b4-priority-apply missing"

# run_read DIR HELPER_PATH — runs 1B.1a's block; prints "<unreadable> <present> <order>".
run_read() {
  (cd "$1" && PM_PRIORITY_SH="$2" bash -c "$READ_BLOCK"'
printf "%s %s %s\n" "$PRIORITY_UNREADABLE" "$(jq -r .present <<<"$PRIO_JSON")" "$(jq -c .order <<<"$PRIO_JSON")"')
}
rm -f "$FILE"
check "1B.1a, no file: readable, no override" "$(run_read "$REPO" "$HELPER")" "false false []"
(cd "$REPO" && "$HELPER" top 103 101 >/dev/null)
check "1B.1a, an order: readable, present, the order" "$(run_read "$REPO" "$HELPER")" "false true [103,101]"
check "1B.1a, from a worktree: the same order" "$(run_read "$WT" "$HELPER")" "false true [103,101]"
check "1B.1a, outside a checkout: no override, not unreadable" "$(run_read "$TMP/notrepo" "$HELPER")" "false false []"
check "1B.1a, no helper: the safe default" "$(run_read "$REPO" "")" "false false []"
GOOD=$(cat "$FILE")
printf 'garbage' > "$FILE"
check "1B.1a, a corrupt file: unreadable (fails closed)" "$(run_read "$REPO" "$HELPER")" "true false []"
printf '%s\n' "$GOOD" > "$FILE"

# run_apply DIR — runs 1B.4 item 7's block over the six-issue fixture.
run_apply() {
  (cd "$1" && PM_PRIORITY_SH="$HELPER" bash -c 'PRIORITY_UNREADABLE=false
RANKED_ISSUES=(101 102 103 104 105 106)
'"$APPLY_BLOCK"'
printf "%s %s\n" "$PRIORITY_UNREADABLE" "$(jq -r "[.order[] | \"\(.issue):\(.source)\"] | join(\",\")" <<<"${PRIO_APPLY:-null}" 2>/dev/null)"')
}
check "1B.4 item 7: test 5.1 through /pm's own block" "$(run_apply "$REPO")" \
  "false 103:override,101:override,102:ranked,104:ranked,105:ranked,106:ranked"
printf '[' > "$FILE"
check "1B.4 item 7: a file broken since 1B.1a sets unreadable" "$(run_apply "$REPO" | cut -d' ' -f1)" "true"
rm -f "$FILE"

echo "== /pm: wiring and contract"
SKILL_TEXT=$(cat "$PM_SKILL")
TPL_TEXT=$(cat "$TEMPLATES")
check_contains "Step 0 resolves the helper portably" "$SKILL_TEXT" 'PM_PRIORITY_SH=$(resolve_script pm-priority.sh || true)'
check_contains "Step 0 names the degraded case" "$SKILL_TEXT" "DEGRADED: pm-priority.sh not found (checked all three paths)"
line_of() { grep -nF -- "$1" "$PM_SKILL" | head -1 | cut -d: -f1; }
excl=$(line_of 'Skip issues labeled `blocked`, `on-hold`, `wontfix`, `duplicate`')
applyl=$(line_of '<!-- test-anchor: pm-1b4-priority-apply -->')
judg=$(line_of '### 1B.4b: Judgment check')
if [[ -n "$excl" && -n "$applyl" && -n "$judg" && "$excl" -lt "$applyl" && "$applyl" -lt "$judg" ]]; then
  ok "the overlay runs after 1B.4's exclusions and before the judgment check"
else
  fail "the overlay is not between the exclusions ($excl) and 1B.4b ($judg): line $applyl"
fi
cand=$(line_of 'every open issue in `PRIO_JSON.order` is a candidate')
pass2=$(line_of '**Pass 2 — Deep read:**')
if [[ -n "$cand" && -n "$pass2" && "$cand" -lt "$pass2" ]]; then
  ok "parked issues are dropped in Pass 1, before any deep read"
else
  fail "the 1B.3 candidate rule is missing or after Pass 2 ($cand vs $pass2)"
fi
check_contains "1B.5 blocks dispatch on an unreadable file" "$SKILL_TEXT" '**An unreadable operator priority is a stop of the same kind** (`PRIORITY_UNREADABLE=true`'
check_contains "3.4 re-reads the file on every refill" "$SKILL_TEXT" "**Re-read the operator priority on every refill**"
check_contains "3.4 takes the operator order before the queue" "$SKILL_TEXT" "**(o) Operator order — first.**"
check_contains "3.4 defers parked issues in every source" "$SKILL_TEXT" "**Parked issues are deferred in every source:**"
check_contains "3.4 names the idle reason" "$SKILL_TEXT" '| `paused (priority unreadable)` |'
check_contains "day mode's digest knows the idle reason" "$SKILL_TEXT" '`paused (budget unknown)`, `paused (priority unreadable)` (3.4)'
check_contains "1B.4b leaves override rows alone" "$SKILL_TEXT" "**Operator-ordered rows are already decided**"
check_contains "the templates mark override rows" "$TPL_TEXT" "Operator order (desk) #1"
check_contains "the templates carry the Parked (desk) line" "$TPL_TEXT" "Parked (desk): #57 until 2026-10-09"
check_contains "the templates carry the Not eligible (desk) line" "$TPL_TEXT" "Not eligible (desk):"
check_contains "the full ranking opens with the operator section" "$TPL_TEXT" "## Operator order (desk)"
check_contains "the context line carries the status" "$TPL_TEXT" "operator priority {2 ordered, 1 parked}"

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "OK: pm-priority.sh tests passed ($PASS passed)"
  exit 0
fi
echo "FAIL: $FAIL test(s) failed ($PASS passed)"
exit 1
