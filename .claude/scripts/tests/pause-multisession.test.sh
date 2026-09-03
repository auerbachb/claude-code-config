#!/usr/bin/env bash
# Tests for per-session pause records and resume receipts, issue #1576.
#
# THE BUG
#   `.repos[<key>].pause` and `.repos[<key>].resume` were repo SINGLETONS. Two
#   sessions running /pause on one repo 80 seconds apart silently clobbered each
#   other: the later write replaced the earlier session's board outright, and
#   that board survived only as its marker file. /pause-resume then read the
#   surviving slot SUCCESSFULLY, so the marker-glob fallback never fired, and a
#   sibling's `active: false` produced an "already resumed" no-op — stopped
#   Monitors left unarmed, parked units left unlaunched, no error anywhere.
#
# WHAT IS VERIFIED
#   - Two interleaved concurrent pause writes both survive and stay independent
#   - The /pause-resume Step 1 selection program returns BOTH un-resumed records,
#     newest first, each with its own write-back path
#   - Marking one record resumed leaves the other selected (no masking)
#   - A partially-restored record (active:false, re-arms pending) stays selected
#   - The legacy singletons `.pause` / `.suspend` are UNION members, selected even
#     when `.pauses` is non-empty — not an else-branch that fires only on an
#     empty map, which would hide a pre-upgrade board
#   - Resume receipts are keyed per session and do not clobber each other
#
# SELF-CERTIFICATION
#   The selection program is EXTRACTED from .claude/skills/pause-resume/SKILL.md
#   rather than copied here, so these assertions certify the documented program.
#   If that block drifts, extraction or the assertions fail loudly instead of
#   passing against a stale duplicate.
#
# Each regression test carries a FAILS-WITHOUT-FIX note naming the pre-#1576
# behaviour, and the singleton clobber is additionally pinned as a live negative
# control so the fixtures cannot pass vacuously.
#
# Run from any directory; uses a throwaway HOME so the real ~/.claude/
# session-state.json is never touched.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/session-state.sh"
PAUSE_RESUME_SKILL="$REPO_ROOT/.claude/skills/pause-resume/SKILL.md"

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"

REPO_KEY="testowner/testrepo"
export CLAUDE_SESSION_REPO="$REPO_KEY"

PASS=0
FAIL=0

check_eq() {
  if [[ "$3" == "$2" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $1 (expected '$2', got '$3')"
  fi
}

ss() { bash "$SCRIPT" "$@"; }
reset_state() { rm -f "$STATE_FILE"; }

# --- the selection program, lifted from the skill -----------------------------
# Range: the first `def base:` line through the `| reverse` that closes the
# program. The trailing `') || ...` shell text is stripped.
SELECT_JQ="$(awk '
  /def base:/          { grab = 1 }
  grab && /\| reverse/ { sub(/.\).*$/, ""); print; exit }
  grab                 { print }
' "$PAUSE_RESUME_SKILL")"

if [[ -z "$SELECT_JQ" || "$SELECT_JQ" != *"def unresumed"* || "$SELECT_JQ" != *"legacy("* ]]; then
  echo "FAIL — could not extract the Step 1 selection program from $PAUSE_RESUME_SKILL" >&2
  echo "       (the skill's enumeration block changed shape; update this extractor)" >&2
  exit 1
fi
# Substring checks alone would accept a truncated program. Compile it: an
# extractor that silently clips a line must fail here, not produce empty output
# that every assertion below then reads as "no records selected".
if ! jq -n --arg repo_key x --argjson pauses null \
     --argjson legacy_pause null --argjson legacy_suspend null \
     "$SELECT_JQ" >/dev/null 2>&1; then
  echo "FAIL — the extracted Step 1 selection program does not compile" >&2
  printf '%s\n' "$SELECT_JQ" >&2
  exit 1
fi
PASS=$((PASS + 1)); echo "ok   — Step 1 selection program extracted from the skill and compiles"

# select <pauses-json> <legacy-pause-json> <legacy-suspend-json>
select_records() {
  jq -nc --arg repo_key "$REPO_KEY" \
    --argjson pauses "$1" --argjson legacy_pause "$2" --argjson legacy_suspend "$3" \
    "$SELECT_JQ"
}

# A pause board. board <session> <paused_at> <pr> <active> [resumed_at]
board() {
  jq -nc --arg s "$1" --arg at "$2" --argjson pr "$3" --argjson active "$4" \
    --arg resumed "${5:-}" '
    {active: $active, session_id: $s, paused_at: $at,
     window_minutes: 15, window_expired: false,
     landed: [], parked: [{kind:"pr", ref:$pr, branch:("issue-" + ($pr|tostring) + "-x"),
                           stopped_at:"awaiting review", next_move:"poll"}],
     monitors_stopped: [{owner:"babysit", ref:$pr, task_id:("t" + $s),
                         generation:"g1", stopped:true, rearmed:true}],
     background_tasks_stopped: [],
     refill_paused: true,
     marker_path: ("~/.claude/handoffs/pause-" + $s + ".md"),
     resumed_at: (if $resumed == "" then null else $resumed end)}'
}

SESS_A="60aba151-c372-47f9-813b-7af00c2034db"
SESS_B="5febbb95-99d7-4503-a5ea-620ea61f813c"
AT_A="2026-09-02T21:56:40Z"
AT_B="2026-09-02T21:58:01Z"

# ---------------------------------------------------------------------------
echo "== Two interleaved pause writes (the reported incident) =="
# ---------------------------------------------------------------------------
reset_state
BOARD_A="$(board "$SESS_A" "$AT_A" 1573 true)"
BOARD_B="$(board "$SESS_B" "$AT_B" 1553 true)"

# Interleaved, not sequential: both writers race for the same state file, the
# way two sessions closing their laptops minutes apart actually do.
ss --set ".repos[\"$REPO_KEY\"].pauses[\"$SESS_A\"]=$BOARD_A" >/dev/null 2>&1 &
W1=$!
ss --set ".repos[\"$REPO_KEY\"].pauses[\"$SESS_B\"]=$BOARD_B" >/dev/null 2>&1 &
W2=$!
wait $W1; RC_A=$?
wait $W2; RC_B=$?
check_eq "concurrent write A succeeds" "0" "$RC_A"
check_eq "concurrent write B succeeds" "0" "$RC_B"

# FAILS WITHOUT FIX: with /pause writing the singleton `.repos[<key>].pause`,
# the second of these two writes replaced the first and this count was 1.
STORED="$(ss --get ".repos[\"$REPO_KEY\"].pauses" 2>/dev/null)"
check_eq "both records survive the race" "2" "$(printf '%s' "$STORED" | jq -r 'keys | length')"
check_eq "record A keeps its own timestamp" "$AT_A" \
  "$(printf '%s' "$STORED" | jq -r --arg k "$SESS_A" '.[$k].paused_at')"
check_eq "record B keeps its own timestamp" "$AT_B" \
  "$(printf '%s' "$STORED" | jq -r --arg k "$SESS_B" '.[$k].paused_at')"
check_eq "record A keeps its own parked PR" "1573" \
  "$(printf '%s' "$STORED" | jq -r --arg k "$SESS_A" '.[$k].parked[0].ref')"
check_eq "record B keeps its own parked PR" "1553" \
  "$(printf '%s' "$STORED" | jq -r --arg k "$SESS_B" '.[$k].parked[0].ref')"
check_eq "record A keeps its own marker" "~/.claude/handoffs/pause-$SESS_A.md" \
  "$(printf '%s' "$STORED" | jq -r --arg k "$SESS_A" '.[$k].marker_path')"
check_eq "each record is self-describing" "$SESS_B" \
  "$(printf '%s' "$STORED" | jq -r --arg k "$SESS_B" '.[$k].session_id')"

echo "-- negative control: the pre-#1576 singleton write shape still clobbers --"
# Proves the assertions above are not passing vacuously: the same two boards
# written to the old singleton slot leave exactly one survivor.
reset_state
ss --set ".repos[\"$REPO_KEY\"].pause=$BOARD_A" >/dev/null 2>&1
ss --set ".repos[\"$REPO_KEY\"].pause=$BOARD_B" >/dev/null 2>&1
SINGLETON="$(ss --get ".repos[\"$REPO_KEY\"].pause" 2>/dev/null)"
check_eq "singleton keeps only the later board" "$AT_B" \
  "$(printf '%s' "$SINGLETON" | jq -r '.paused_at')"
check_eq "singleton lost the earlier session entirely" "$SESS_B" \
  "$(printf '%s' "$SINGLETON" | jq -r '.session_id')"

# ---------------------------------------------------------------------------
echo "== Step 1 enumeration: every un-resumed record, newest first =="
# ---------------------------------------------------------------------------
PAUSES="$(jq -nc --arg a "$SESS_A" --arg b "$SESS_B" \
  --argjson ba "$BOARD_A" --argjson bb "$BOARD_B" '{($a): $ba, ($b): $bb}')"

SEL="$(select_records "$PAUSES" null null)"
check_eq "both un-resumed records selected" "2" "$(printf '%s' "$SEL" | jq -r 'length')"
check_eq "newest first" "$SESS_B" "$(printf '%s' "$SEL" | jq -r '.[0].session_id')"
check_eq "older second" "$SESS_A" "$(printf '%s' "$SEL" | jq -r '.[1].session_id')"
check_eq "each carries its own write-back path" \
  ".repos[\"$REPO_KEY\"].pauses[\"$SESS_A\"]" \
  "$(printf '%s' "$SEL" | jq -r '.[1].state_path')"
check_eq "keyed records are tagged as such" "pauses" \
  "$(printf '%s' "$SEL" | jq -r '.[0].state_key')"

# FAILS WITHOUT FIX: this is the exact masking the issue reported — the sibling
# resumed first, and its `active: false` ended the whole command as a no-op.
echo "-- a resumed sibling masks nothing --"
PAUSES_ONE_RESUMED="$(printf '%s' "$PAUSES" | jq -c --arg b "$SESS_B" \
  '.[$b].active = false | .[$b].resumed_at = "2026-09-02T23:48:12Z"')"
SEL="$(select_records "$PAUSES_ONE_RESUMED" null null)"
check_eq "the un-resumed sibling is still selected" "1" "$(printf '%s' "$SEL" | jq -r 'length')"
check_eq "and it is the earlier session, not the resumed one" "$SESS_A" \
  "$(printf '%s' "$SEL" | jq -r '.[0].session_id')"

echo "-- restoring one record does not disturb the other on disk --"
reset_state
ss --set ".repos[\"$REPO_KEY\"].pauses[\"$SESS_A\"]=$BOARD_A" >/dev/null 2>&1
ss --set ".repos[\"$REPO_KEY\"].pauses[\"$SESS_B\"]=$BOARD_B" >/dev/null 2>&1
ss --set ".repos[\"$REPO_KEY\"].pauses[\"$SESS_B\"].active=false" \
   --set ".repos[\"$REPO_KEY\"].pauses[\"$SESS_B\"].resumed_at=\"2026-09-02T23:48:12Z\"" \
   >/dev/null 2>&1
AFTER="$(ss --get ".repos[\"$REPO_KEY\"].pauses" 2>/dev/null)"
check_eq "the restored record is closed" "false" \
  "$(printf '%s' "$AFTER" | jq -r --arg k "$SESS_B" '.[$k].active')"
check_eq "the other record is untouched and still active" "true" \
  "$(printf '%s' "$AFTER" | jq -r --arg k "$SESS_A" '.[$k].active')"
check_eq "the other record kept its parked work" "1573" \
  "$(printf '%s' "$AFTER" | jq -r --arg k "$SESS_A" '.[$k].parked[0].ref')"
SEL="$(select_records "$AFTER" null null)"
check_eq "a later enumeration still finds the un-resumed board" "$SESS_A" \
  "$(printf '%s' "$SEL" | jq -r '.[0].session_id')"

echo "-- every record resumed is a genuinely empty selection --"
BOTH_RESUMED="$(printf '%s' "$PAUSES" | jq -c 'map_values(.active = false)')"
SEL="$(select_records "$BOTH_RESUMED" null null)"
check_eq "no records selected" "0" "$(printf '%s' "$SEL" | jq -r 'length')"

echo "-- a partially restored record is still selected (Step 2 retry path) --"
PARTIAL="$(printf '%s' "$PAUSES" | jq -c --arg a "$SESS_A" --arg b "$SESS_B" \
  '.[$b].active = false
   | .[$a].active = false
   | .[$a].monitors_stopped[0].rearmed = false')"
SEL="$(select_records "$PARTIAL" null null)"
check_eq "the record with a pending re-arm survives the filter" "1" \
  "$(printf '%s' "$SEL" | jq -r 'length')"
check_eq "and it is the partially restored one" "$SESS_A" \
  "$(printf '%s' "$SEL" | jq -r '.[0].session_id')"

echo "-- the jq // trap the un-resumed predicate must not reuse --"
# `//` is jq's alternative operator and treats FALSE as empty, so `.active // true`
# answers "true" for exactly the resumed records it is meant to exclude. Written
# that way, the selection filter silently passes everything — which is how the
# four assertions above go green while masking nothing at all. Pin both halves:
# the language behaviour, and the fact that no reader spells it that way.
check_eq "jq's // yields true for active:false" "true" \
  "$(jq -nr '{active:false} | (.active // true)')"
check_eq "the correct predicate excludes it" "false" \
  "$(jq -nr '{active:false} | (.active != false)')"
# Match the CODE shape — `(.active // true)` or `jq -r '.active // true'` — not a
# prose mention: every reader deliberately names the trap in a comment.
bad_predicate_count() { grep -cE -- "[(\"']\.active // true" "$1"; }
check_eq "the skill never codes .active // true" "0" \
  "$(bad_predicate_count "$PAUSE_RESUME_SKILL")"
check_eq "nor does go-on's probe B" "0" \
  "$(bad_predicate_count "$REPO_ROOT/.claude/skills/go-on/SKILL.md")"
check_eq "nor does the ownership sweep" "0" \
  "$(bad_predicate_count "$REPO_ROOT/.claude/scripts/candidate-ownership.sh")"
printf '(.active // true)\n' > "$TMP_HOME/predicate-probe.txt"
check_eq "and that pin would catch a regression" "1" \
  "$(bad_predicate_count "$TMP_HOME/predicate-probe.txt")"

echo "-- a malformed record does not throw away the whole selection --"
MALFORMED="$(printf '%s' "$PAUSES" | jq -c --arg a "$SESS_A" \
  '.[$a].monitors_stopped = "not-an-array" | .[$a].active = false')"
SEL="$(select_records "$MALFORMED" null null)"
check_eq "the healthy sibling is still selected" "$SESS_B" \
  "$(printf '%s' "$SEL" | jq -r '.[0].session_id')"

echo "-- a record with no active field counts as active --"
NO_ACTIVE="$(printf '%s' "$PAUSES" | jq -c --arg a "$SESS_A" --arg b "$SESS_B" \
  'del(.[$a].active) | .[$b].active = false')"
SEL="$(select_records "$NO_ACTIVE" null null)"
check_eq "missing active is treated as un-resumed" "$SESS_A" \
  "$(printf '%s' "$SEL" | jq -r '.[0].session_id')"

# ---------------------------------------------------------------------------
echo "== Legacy singletons are union members, not an else-branch =="
# ---------------------------------------------------------------------------
# FAILS WITHOUT FIX: reading the legacy slots only when `.pauses` is empty — the
# obvious "fallback" shape — makes a board parked before the upgrade unreachable
# the moment any session writes a keyed record. That is this same bug one level up.
LEGACY_PAUSE="$(board "legacy-sess" "2026-08-30T10:00:00Z" 1400 true)"
SEL="$(select_records "$PAUSES" "$LEGACY_PAUSE" null)"
check_eq "legacy .pause selected ALONGSIDE a non-empty keyed map" "3" \
  "$(printf '%s' "$SEL" | jq -r 'length')"
check_eq "the legacy record is tagged with its own state key" "pause" \
  "$(printf '%s' "$SEL" | jq -r '[.[] | select(.state_key == "pause")][0].state_key')"
check_eq "the legacy record writes back to the singleton path" \
  ".repos[\"$REPO_KEY\"].pause" \
  "$(printf '%s' "$SEL" | jq -r '[.[] | select(.state_key == "pause")][0].state_path')"
check_eq "and it sorts by its own timestamp, oldest here" "pause" \
  "$(printf '%s' "$SEL" | jq -r '.[2].state_key')"

LEGACY_SUSPEND="$(jq -nc '{active: true, suspended_at: "2026-08-29T10:00:00Z",
  parked: [{kind:"pr", ref:1300, branch:"issue-1300-x"}], monitors_stopped: [],
  background_tasks_stopped: [], marker_path: "~/.claude/handoffs/suspend-old.md"}')"
SEL="$(select_records "$PAUSES" null "$LEGACY_SUSPEND")"
check_eq "legacy .suspend is a union member too" "3" "$(printf '%s' "$SEL" | jq -r 'length')"
check_eq "pre-#1310 suspended_at orders it" "suspend" \
  "$(printf '%s' "$SEL" | jq -r '.[2].state_key')"

echo "-- a resumed legacy singleton is filtered like any other record --"
SEL="$(select_records "null" "$(printf '%s' "$LEGACY_PAUSE" | jq -c '.active = false')" null)"
check_eq "resumed legacy record not selected" "0" "$(printf '%s' "$SEL" | jq -r 'length')"

echo "-- an absent map with an un-resumed legacy record still resumes --"
SEL="$(select_records "null" "$LEGACY_PAUSE" null)"
check_eq "legacy-only state is recoverable" "1" "$(printf '%s' "$SEL" | jq -r 'length')"

# ---------------------------------------------------------------------------
echo "== One un-resumed predicate, shared by every reader =="
# ---------------------------------------------------------------------------
# /pause-resume decides what to restore; candidate-ownership.sh decides what is
# still parked. If those two predicates drift, the sweep calls a board free while
# the resume command is still going to restore it — a duplicate-work hazard of
# exactly the kind that shipped issue #652 twice. Extract BOTH and compare
# verdicts on one matrix rather than trusting them to be kept in step by hand.
SWEEP="$REPO_ROOT/.claude/scripts/candidate-ownership.sh"
GO_ON_SKILL="$REPO_ROOT/.claude/skills/go-on/SKILL.md"
extract_pred() {
  awk '
    /def pend\(\$a\):/ { grab = 1 }
    grab               { print }
    grab && /> 0\);/   { exit }
  ' "$1"
}
PRED_SKILL="$(extract_pred "$PAUSE_RESUME_SKILL")"
PRED_SWEEP="$(extract_pred "$SWEEP")"
PRED_GOON="$(extract_pred "$GO_ON_SKILL")"
for _p in "$PRED_SKILL" "$PRED_SWEEP" "$PRED_GOON"; do
  if [[ "$_p" != *"def unresumed"* ]]; then
    echo "FAIL — could not extract an un-resumed predicate from all three readers" >&2
    exit 1
  fi
done
PASS=$((PASS + 1)); echo "ok   — all three predicates extracted for comparison"

# record | expected verdict
MATRIX='[
  {"case":"active",                 "rec":{"active":true},                                          "want":true},
  {"case":"resumed, all rearmed",   "rec":{"active":false,"monitors_stopped":[{"rearmed":true}]},    "want":false},
  {"case":"resumed, rearm pending", "rec":{"active":false,"monitors_stopped":[{"rearmed":false}]},   "want":true},
  {"case":"resumed, bare",          "rec":{"active":false},                                         "want":false},
  {"case":"no active field",        "rec":{},                                                       "want":true},
  {"case":"resumed, task pending",  "rec":{"active":false,"background_tasks_stopped":[{}]},          "want":true},
  {"case":"resumed, malformed arr", "rec":{"active":false,"monitors_stopped":"bad"},                 "want":false},
  {"case":"resumed, scalar entry",  "rec":{"active":false,"monitors_stopped":["oops"]},              "want":true},
  {"case":"unparseable active",     "rec":{"active":"false"},                                       "want":true}
]'

eval_pred() { # eval_pred <predicate-text> <record-json>
  jq -nr --argjson r "$2" "$1"' $r | unresumed'
}

COUNT=$(printf '%s' "$MATRIX" | jq -r 'length')
i=0
while [[ "$i" -lt "$COUNT" ]]; do
  CASE=$(printf '%s' "$MATRIX" | jq -r ".[$i].case")
  REC=$(printf '%s' "$MATRIX" | jq -c ".[$i].rec")
  WANT=$(printf '%s' "$MATRIX" | jq -r ".[$i].want")
  check_eq "pause-resume predicate — $CASE" "$WANT" "$(eval_pred "$PRED_SKILL" "$REC")"
  check_eq "ownership sweep agrees — $CASE" "$WANT" "$(eval_pred "$PRED_SWEEP" "$REC")"
  check_eq "go-on probe B agrees — $CASE" "$WANT" "$(eval_pred "$PRED_GOON" "$REC")"
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
echo "== Resume receipts are keyed per session =="
# ---------------------------------------------------------------------------
reset_state
RECEIPT_A="$(jq -nc --arg s "$SESS_A" '{class:"pause",
  evidence_digest:"pause|2026-09-02T21:56:40Z|1573|abc1234|issue-1573-x",
  at:"2026-09-02T23:00:00Z", session_id:$s, dispatched_to:"/pause-resume"}')"
RECEIPT_B="$(jq -nc --arg s "$SESS_B" '{class:"pause",
  evidence_digest:"pause|2026-09-02T21:58:01Z|1553|def5678|issue-1553-x",
  at:"2026-09-02T23:48:12Z", session_id:$s, dispatched_to:"/pause-resume"}')"

ss --set ".repos[\"$REPO_KEY\"].resumes[\"$SESS_A\"]=$RECEIPT_A" >/dev/null 2>&1 &
W1=$!
ss --set ".repos[\"$REPO_KEY\"].resumes[\"$SESS_B\"]=$RECEIPT_B" >/dev/null 2>&1 &
W2=$!
wait $W1; wait $W2

# FAILS WITHOUT FIX: as a singleton `.resume`, only the later dispatch was
# recorded, so a sibling's receipt could answer "already resumed" for a session
# whose own board was still parked.
RECEIPTS="$(ss --get ".repos[\"$REPO_KEY\"].resumes" 2>/dev/null)"
check_eq "both receipts survive" "2" "$(printf '%s' "$RECEIPTS" | jq -r 'keys | length')"
check_eq "session A reads its own digest" \
  "pause|2026-09-02T21:56:40Z|1573|abc1234|issue-1573-x" \
  "$(printf '%s' "$RECEIPTS" | jq -r --arg k "$SESS_A" '.[$k].evidence_digest')"
check_eq "session B reads its own digest" \
  "pause|2026-09-02T21:58:01Z|1553|def5678|issue-1553-x" \
  "$(printf '%s' "$RECEIPTS" | jq -r --arg k "$SESS_B" '.[$k].evidence_digest')"
check_eq "a session with no receipt reads absent, not a sibling's" "null" \
  "$(ss --get ".repos[\"$REPO_KEY\"].resumes[\"never-dispatched\"]" 2>/dev/null)"

echo "-- negative control: the pre-#1576 singleton receipt still clobbers --"
reset_state
ss --set ".repos[\"$REPO_KEY\"].resume=$RECEIPT_A" >/dev/null 2>&1
ss --set ".repos[\"$REPO_KEY\"].resume=$RECEIPT_B" >/dev/null 2>&1
check_eq "singleton receipt keeps only the later session" "$SESS_B" \
  "$(ss --get ".repos[\"$REPO_KEY\"].resume" 2>/dev/null | jq -r '.session_id')"

# ---------------------------------------------------------------------------
echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAIL: pause-multisession tests failed" >&2
  exit 1
fi
echo "OK: pause-multisession tests passed"
