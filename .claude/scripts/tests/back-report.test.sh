#!/usr/bin/env bash
# catalog: tests — Proves /back's report: pinned-clock digest length, menus-first sources in thread and all scope, and unreadable sources named rather than shown as empty
# Tests for issue #2541: .claude/scripts/back-report.sh. Every run uses a throwaway HOME and stubbed
# gh, owner-task.sh and human-queue.sh; the live ~/.claude and GitHub are never touched.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/back-report-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/.claude" "$tmp/bin"
export PATH="$tmp/bin:$PATH"
unset CLAUDE_SESSION_REPO UNATTENDED_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID BACK_REPORT_OWNER_TASK BACK_REPORT_HQ

if ! command -v jq >/dev/null 2>&1; then echo "SKIP: back-report.test.sh — jq is not installed"; exit 0; fi

REPORT="$root/.claude/scripts/back-report.sh"
UNATT="$root/.claude/scripts/unattended.sh"
STATE="$root/.claude/scripts/session-state.sh"
REPO="$tmp/repo"
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/acme/widgets.git
OTHER="$tmp/other"
git init -q "$OTHER"
git -C "$OTHER" remote add origin https://github.com/acme/gadgets.git

# gh: canned answers; GH_FAIL=1 makes every call fail.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[ "${GH_FAIL:-0}" = 1 ] && exit 1
case "$1 $2" in
  "pr list") case "$*" in *"--state merged"*) printf '[{"number":7,"title":"Merged one","url":"u7","mergedAt":"2026-11-19T03:00:00Z"}]\n' ;;
             *) printf '[{"number":8,"title":"Opened one","url":"u8","createdAt":"2026-11-19T04:00:00Z","state":"OPEN"}]\n' ;; esac ;;
  "search prs") case "$*" in *--merged-at*) printf '[{"number":7,"title":"Merged one","url":"u7","repository":{"nameWithOwner":"acme/widgets"},"closedAt":"x"}]\n' ;;
               *) printf '[{"number":9,"title":"Gadget PR","url":"u9","repository":{"nameWithOwner":"acme/gadgets"},"createdAt":"x","state":"OPEN"}]\n' ;; esac ;;
  "run list") printf '[{"databaseId":1,"name":"ci","displayTitle":"broke","url":"r1","headBranch":"b","createdAt":"2026-11-18T22:50:00Z","updatedAt":"2026-11-19T02:00:00Z"},{"databaseId":2,"name":"ci","displayTitle":"failed before he left","url":"r2","headBranch":"b","createdAt":"2026-11-18T20:00:00Z","updatedAt":"2026-11-18T20:10:00Z"}]\n' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export GH_LOG="$tmp/gh.log"

# owner-task.sh: OT_MODE=ok|empty|fail (exit 4, empty stdout, per the Issue #2538 contract)
cat >"$tmp/owner-task.sh" <<'OT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OT_LOG"
if [ "$1" = add ]; then   # OT_ADD_RC=N fails every add with exit N
  [ "${OT_ADD_RC:-0}" = 0 ] || exit "$OT_ADD_RC"
  n=$(grep -c '^add ' "$OT_LOG")
  while [ $# -gt 0 ]; do [ "$1" = --source ] && printf '%s\n' "$2" >>"$OT_LOG.source"; shift; done
  printf 'ht-0000000%s\n' "$n"; exit 0
fi
case "${OT_MODE:-ok}" in
  fail) exit 4 ;;
  empty) printf '[]\n' ;;
  *) printf '[{"id":"T-1","repo":"acme/widgets","what":"Fill in .env.local","why":"only you hold the key","source":"PR #8","created_at":"2026-11-19T02:00:00Z","state":"open","done_at":null,"proof":null},{"id":"T-2","repo":"acme/widgets","what":"old","why":"x","source":"y","created_at":"2026-11-18T02:00:00Z","state":"done","done_at":"2026-11-18T03:00:00Z","proof":"checked"}]\n' ;;
esac
OT
chmod +x "$tmp/owner-task.sh"
export OT_LOG="$tmp/ot.log"

# human-queue.sh: HQ_MODE=ok|down (exit 7, the desk database unreachable)
cat >"$tmp/hq.sh" <<'HQ'
#!/usr/bin/env bash
[ "${HQ_MODE:-ok}" = down ] && { echo "human-queue.sh: database unreachable" >&2; exit 7; }
case "$1" in
  list) printf '[{"id":"D-4","kind":"decision","repo":"acme/widgets","session_id":"sess-a","question":"Ship the beta?","options":["Yes","No"],"default_option":"Yes","created_at":"2026-11-19T01:00:00Z","context":["did: held the release"]},{"id":"D-5","kind":"decision","repo":"acme/gadgets","session_id":"sess-b","question":"Gadget colour?","options":["Red","Blue"],"default_option":"Red","created_at":"2026-11-19T01:30:00Z","context":[]}]\n' ;;
  stoppage) printf '[{"id":1,"stopped_at":"2026-11-19T05:00:00Z","thread":"sess-a","repo":"acme/widgets","ref":"pr#8","cause":"usage_limit","corrected_cause":null,"idle_seconds":600},{"id":2,"stopped_at":"2026-11-10T05:00:00Z","thread":"sess-a","repo":"acme/widgets","ref":null,"cause":"crash","corrected_cause":null,"idle_seconds":60}]\n' ;;
  *) exit 4 ;;
esac
HQ
chmod +x "$tmp/hq.sh"

pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok   — %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL — %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
R() { rc=0; out=$(cd "$REPO" && "$REPORT" "$@" 2>"$tmp/err") || rc=$?; }
f() { printf '%s' "$out" | jq -r "$1"; }

NOW=1795089600   # pinned clock: 2026-11-19T12:00:00Z
export BACK_REPORT_OWNER_TASK="$tmp/owner-task.sh" BACK_REPORT_HQ="$tmp/hq.sh"

printf '== nothing waiting\n'
OT_MODE=empty R --session sess-a --now "$NOW" --since $(( NOW - 1800 ))
check "exit 0" "$rc" 0
check "thread scope" "$(f .scope)" thread
check "repo key" "$(f .repo)" acme/widgets
check "no questions: an empty list, not null" "$(f '.questions == []')" true
check "no tasks: an empty list, not null" "$(f '.tasks == []')" true
check "since from the flag" "$(f .since_source)" flag

printf '== short absence (30 minutes)\n'
check "30 minutes away" "$(f .away_seconds)" 1800
check "short digest" "$(f .digest_level)" short

printf '== overnight absence, declared away, questions and decisions waiting\n'
"$STATE" --set ".unattended.active=true" --set ".unattended.since_epoch=$(( NOW - 36000 ))" \
  --set ".unattended.until_epoch=$(( NOW + 3600 ))" >/dev/null
"$STATE" --set ".unattended.since_epoch=$(( NOW - 36000 ))" >/dev/null
(cd "$REPO" && "$UNATT" record --question "Which region?" --recommended us-east --did "used us-east" --session sess-a >/dev/null)
(cd "$REPO" && "$UNATT" record --question "Unattributed?" >/dev/null)
(cd "$REPO" && "$UNATT" record --question "Another thread's?" --session sess-b >/dev/null)
(cd "$OTHER" && "$UNATT" record --question "Gadget question?" --session sess-b >/dev/null)
THIRD="$tmp/third"; git init -q "$THIRD"; git -C "$THIRD" remote add origin https://github.com/acme/sprockets.git
(cd "$THIRD" && "$UNATT" record --question "Sprocket question?" --session sess-c >/dev/null)
(cd "$REPO" && "$UNATT" record --question "Answered already?" --session sess-a >/dev/null)
(cd "$REPO" && "$UNATT" answer U-4 --answer yes >/dev/null)
"$STATE" --set ".unattended.since_epoch=$(( NOW - 13 * 3600 ))" >/dev/null
R --session sess-a --now "$NOW"
check "since from the stored away declaration" "$(f .since_source)" declared
check "13 hours away" "$(f .away_seconds)" $(( 13 * 3600 ))
check "long digest" "$(f .digest_level)" long
check "thread: this session's and unattributed open questions only" "$(f '[.questions[].question] | join("|")')" "Which region?|Unattributed?"
check "a question carries what was done meanwhile" "$(f '.questions[0].did')" "used us-east"
check "thread: this repo's Decision" "$(f '[.decisions[].id] | join(",")')" D-4
check "thread: other threads' open items are counted" "$(f .other_threads_open)" 4
check "open tasks only, with the why-human reason and source" "$(f '[.tasks[] | .id, .why, .source] | join("|")')" "T-1|only you hold the key|PR #8"
check "owner-task.sh asked for this repo's list" "$(tail -1 "$OT_LOG")" "list --json"
check "merged PRs" "$(f '.activity.merged[0].number')" 7
check "opened PRs" "$(f '.activity.opened[0].number')" 8
check "failed while away, though started before he left; an earlier failure is cut" "$(f '[.activity.failed[].displayTitle] | join(",")')" broke
check "stoppages since the declaration only" "$(f '[.stoppages[].id] | join(",")')" 1
check "nothing unreadable" "$(f '.unreadable | length')" 0
check "local-only sources are named" "$(f '.local_sources | index("handoffs") != null')" true

printf '== /back all: every thread and repo\n'
R --all --session sess-a --now "$NOW"
check "all scope" "$(f .scope)" all
check "all: another thread's open question is listed" "$(f '[.questions[].question] | index("Gadget question?") != null')" true
check "all: every open question" "$(f '.questions | length')" 5
check "all: every Decision" "$(f '.decisions | length')" 2
check "all: nothing counted as elsewhere" "$(f .other_threads_open)" 0
check "all: owner-task.sh asked for every repo" "$(tail -1 "$OT_LOG")" "list --json --all-repos"
check "all: failed runs per active repo" "$(f '[.activity.failed[].repo] | unique | join(",")')" "acme/gadgets,acme/sprockets,acme/widgets"
check "all: a repo known only from an open question is checked for failed runs" "$(grep -c 'run list --repo acme/sprockets' "$GH_LOG" | tr -d ' ')" 1

printf '== unreadable sources are named, never empty\n'
OT_MODE=fail HQ_MODE=down GH_FAIL=1 R --session sess-a --now "$NOW"
check "still exit 0" "$rc" 0
check "tasks unavailable: null" "$(f .tasks)" null
check "decisions unavailable: null" "$(f .decisions)" null
check "merged unavailable: null" "$(f .activity.merged)" null
check "questions still read" "$(f '.questions | length')" 2
check "each unreadable source is named" "$(f '[.unreadable[].source] | sort | join("|")')" "Desk Decisions|GitHub failed runs|GitHub merged PRs|GitHub opened PRs|human tasks|stoppages"
check "the task failure gives its exit code" "$(f '.unreadable[] | select(.source == "human tasks") | .reason')" "owner-task.sh list exited 4"
check "the desk reason is plain" "$(f '.unreadable[] | select(.source == "Desk Decisions") | .reason')" "the desk database is unset or unreachable"
BACK_REPORT_OWNER_TASK="$tmp/missing.sh" R --session sess-a --now "$NOW"
check "owner-task.sh missing: tasks null" "$(f .tasks)" null
check "owner-task.sh missing: said so" "$(f '.unreadable[] | select(.source == "human tasks") | .reason')" "owner-task.sh not found (checked all three paths)"

printf '== handoffs\n'
mkdir -p "$HOME/.claude/handoffs/acme/widgets"
printf '{"pr_number":8,"phase_completed":"A","head_sha":"abc"}\n' >"$HOME/.claude/handoffs/acme/widgets/pr-8-handoff.json"
: >"$HOME/.claude/handoffs/acme/widgets/pr-9-handoff.json"
R --session sess-a --now "$NOW"
check "a handoff is listed" "$(f '[.handoffs[] | "\(.repo)#\(.pr):\(.phase_completed)"] | join(",")')" "acme/widgets#8:A"
check "an empty handoff file is named" "$(f '[.unreadable[].source | select(endswith("pr-9-handoff.json"))] | length')" 1

printf '== --save-recovered: tasks handed over in the thread but never saved\n'
cat >"$tmp/found.json" <<'J'
[{"what":"Sign in to Railway","why":"only you hold the login"},
 {"what":"  fill in .ENV.local ","why":"already listed, other case and spacing"},
 {"what":"OLD","why":"already listed and done"},
 {"what":"sign in to railway","why":"repeated in the same scan"},
 {"what":"Run the live test on your profile","why":"it uses your account"}]
J
: >"$OT_LOG"; rm -f "$OT_LOG.source"
R --save-recovered "$tmp/found.json" --session sess-a --now "$NOW"
check "exit 0" "$rc" 0
check "the list, done tasks included, is read for duplicates" "$(head -1 "$OT_LOG")" "list --all --json --repo acme/widgets"
check "two new tasks saved, with their ids" "$(f '[.saved[] | .id + "=" + .what] | join("|")')" "ht-00000001=Sign in to Railway|ht-00000002=Run the live test on your profile"
check "the source carries the recovered marker" "$(sort -u "$OT_LOG.source")" "recovered by /back from this thread (session sess-a, 2026-11-19)"
check "the saved record shows the same source" "$(f '.saved[0].source')" "recovered by /back from this thread (session sess-a, 2026-11-19)"
check "already on the list (open or done) or repeated: not saved twice" "$(f '[.duplicates[].existing_id] | join(",")')" "T-1,T-2,earlier in this list"
check "only the two new tasks were added" "$(grep -c '^add ' "$OT_LOG" | tr -d ' ')" 2
check "nothing not saved" "$(f '.not_saved | length')" 0

printf '== --save-recovered: a public repo with no bucket, an unreadable list, no helper\n'
OT_ADD_RC=3 R --save-recovered "$tmp/found.json" --now "$NOW"
check "no location: both new tasks listed as not saved" "$(f '[.not_saved[].what] | join("|")')" "Sign in to Railway|Run the live test on your profile"
check "no location: the reason names exit 3" "$(f '.not_saved[0].reason')" "no location for this repo's tasks: a public repo with no private bucket in the pointer file (owner-task.sh add exited 3)"
check "no location: the task's why is kept" "$(f '.not_saved[0].why')" "only you hold the login"
check "no location: nothing reported saved" "$(f '.saved | length')" 0
R --save-recovered "$tmp/found.json" --now "$NOW"
check "no session id: the marker still says recovered" "$(f '.saved[0].source')" "recovered by /back from this thread (2026-11-19)"
OT_ADD_RC=5 R --save-recovered "$tmp/found.json" --now "$NOW"
check "secret refused: named" "$(f '.not_saved[0].reason')" "refused as a possible secret (owner-task.sh add exited 5)"
OT_ADD_RC=7 R --save-recovered "$tmp/found.json" --now "$NOW"
check "checker missing: named" "$(f '.not_saved[0].reason')" "the secret checker is missing, so the write was refused (owner-task.sh add exited 7)"
: >"$OT_LOG"
OT_MODE=fail R --save-recovered "$tmp/found.json" --now "$NOW"
check "unreadable list: every task not saved, none added" "$(f '.not_saved | length'):$(grep -c '^add ' "$OT_LOG" | tr -d ' ')" "5:0"
check "unreadable list: the reason says why" "$(f '.not_saved[0].reason')" "the task list could not be read to check for duplicates (owner-task.sh list exited 4)"
BACK_REPORT_OWNER_TASK="$tmp/missing.sh" R --save-recovered "$tmp/found.json" --now "$NOW"
check "helper missing: not saved, said so" "$(f '"\(.saved | length):\(.not_saved[0].reason)"')" "0:owner-task.sh not found (checked all three paths)"
printf '{"what":"x"}\n' >"$tmp/bad.json"
R --save-recovered "$tmp/bad.json"; check "not an array: usage error" "$rc" 2
printf '[]\n[]\n' >"$tmp/two.json"
R --save-recovered "$tmp/two.json"; check "two top-level values: usage error" "$rc" 2
printf '[]\n' >"$tmp/empty.json"
R --save-recovered "$tmp/empty.json"; check "an empty array: nothing saved, exit 0" "$rc:$(f '.saved | length')" "0:0"
R --save-recovered "$tmp/nope.json"; check "missing file: usage error" "$rc" 2

printf '== usage\n'
R --since 08 --now "$NOW"; check "a leading-zero epoch is read as decimal" "$rc:$(f .since)" "0:8"
R --since soon; check "bad --since: usage error" "$rc" 2
R --bogus; check "unknown flag: usage error" "$rc" 2
R --help; check "--help exits 0" "$rc" 0

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
