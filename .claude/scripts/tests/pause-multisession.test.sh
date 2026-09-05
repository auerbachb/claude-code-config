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
# Range: the first `def base:` line through the last `slot_degraded(...)` line,
# which closes the program. The trailing `')` shell text is stripped — the
# program is single-quoted in the skill, so it contains no apostrophe of its own.
SELECT_JQ="$(awk '
  /def base:/ { grab = 1 }
  grab && /slot_degraded\("the legacy suspend slot"/ { sub(/\047.*$/, ""); print; exit }
  grab        { print }
' "$PAUSE_RESUME_SKILL")"

if [[ -z "$SELECT_JQ" || "$SELECT_JQ" != *"def unresumed"* || "$SELECT_JQ" != *"slot_class("* ]]; then
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

# select_full <pauses-json> <legacy-pause-json> <legacy-suspend-json>
# The program returns {total, records, degraded} (issue #1611): per-slot
# degradation has to travel with the selection, or the caller cannot name the
# damaged slot without re-deriving it from a second program that could drift.
select_full() {
  jq -nc --arg repo_key "$REPO_KEY" \
    --argjson pauses "$1" --argjson legacy_pause "$2" --argjson legacy_suspend "$3" \
    "$SELECT_JQ"
}
select_records() { select_full "$@" | jq -c '.records'; }
select_degraded() { select_full "$@" | jq -r '.degraded | join(",")'; }

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
echo "== One slot, one verdict — the shared classifier (issue #1611) =="
# ---------------------------------------------------------------------------
# The shared predicate above settles what an un-resumed RECORD is. It says
# nothing about a SLOT holding a value that is not a record at all, and the three
# readers disagreed there twice over. First /pause-resume and the sweep dropped a
# non-object `.pause` / `.suspend` as though the slot were empty while /go-on
# raised (#1607 made all three raise). Then the raise itself proved too coarse:
# it aborts the whole combine, so ONE damaged legacy singleton discarded every
# healthy keyed record read beside it — and a corrupt `.pauses` value took a
# quiet `else []` branch in two readers while a corrupt legacy slot raised, so
# the two damaged shapes were not even treated alike.
#
# Both are now one rule: `slot_class` classifies a single slot as
# absent | present | unreadable, identically for the keyed map and the legacy
# singletons, and the caller degrades only the slot it names. Extract that rule
# from all three readers, prove the texts agree, and run all three against one
# fixture matrix.
SWEEP="$REPO_ROOT/.claude/scripts/candidate-ownership.sh"
GO_ON_SKILL="$REPO_ROOT/.claude/skills/go-on/SKILL.md"

# Leading indentation differs by host program (a shell heredoc-free jq argument
# at 2 spaces, a skill code block at 6); the RULE must not.
extract_slot_class() {
  awk '
    /def slot_class\(\$kind\):/ { grab = 1 }
    grab { sub(/^[ \t]+/, ""); print }
    grab && /if slot_class\(\$kind\) == "unreadable" then \[\$name\] else \[\] end;/ { exit }
  ' "$1"
}
CLASS_SKILL="$(extract_slot_class "$PAUSE_RESUME_SKILL")"
CLASS_GOON="$(extract_slot_class "$GO_ON_SKILL")"
CLASS_SWEEP="$(extract_slot_class "$SWEEP")"
for _c in "$CLASS_SKILL" "$CLASS_GOON" "$CLASS_SWEEP"; do
  if [[ "$_c" != *"def slot_degraded"* ]]; then
    echo "FAIL — could not extract the slot classifier from all three readers" >&2
    exit 1
  fi
done
PASS=$((PASS + 1)); echo "ok   — the slot classifier extracted from all three readers"
check_eq "/go-on probe B carries the identical classifier" "$CLASS_SKILL" "$CLASS_GOON"
check_eq "the ownership sweep carries the identical classifier" "$CLASS_SKILL" "$CLASS_SWEEP"

# value | kind | expected class. Nine cases: every source state each reader can
# meet, for BOTH slot shapes — which is the point, since the asymmetry being
# removed is precisely that the map and the singletons classified differently.
CLASS_MATRIX='[
  {"case":"map: absent",              "v":null,                          "kind":"map",  "want":"absent"},
  {"case":"map: empty",               "v":{},                            "kind":"map",  "want":"present"},
  {"case":"map: records",             "v":{"s1":{"active":true}},        "kind":"map",  "want":"present"},
  {"case":"map: malformed value",     "v":{"s1":"not-a-record"},         "kind":"map",  "want":"unreadable"},
  {"case":"map: scalar",              "v":123,                           "kind":"map",  "want":"unreadable"},
  {"case":"map: array",               "v":[],                            "kind":"map",  "want":"unreadable"},
  {"case":"map: empty string",        "v":"",                            "kind":"map",  "want":"unreadable"},
  {"case":"slot: empty string",       "v":"",                            "kind":"slot", "want":"unreadable"},
  {"case":"slot: absent",             "v":null,                          "kind":"slot", "want":"absent"},
  {"case":"slot: record",             "v":{"active":true},               "kind":"slot", "want":"present"},
  {"case":"slot: scalar",             "v":123,                           "kind":"slot", "want":"unreadable"}
]'

eval_class() { # eval_class <classifier-text> <value-json> <kind>
  jq -nr --argjson v "$2" --arg k "$3" "$1"' $v | slot_class($k)'
}
CCOUNT=$(printf '%s' "$CLASS_MATRIX" | jq -r 'length')
i=0
while [[ "$i" -lt "$CCOUNT" ]]; do
  CASE=$(printf '%s' "$CLASS_MATRIX" | jq -r ".[$i].case")
  VAL=$(printf '%s' "$CLASS_MATRIX" | jq -c ".[$i].v")
  KIND=$(printf '%s' "$CLASS_MATRIX" | jq -r ".[$i].kind")
  WANT=$(printf '%s' "$CLASS_MATRIX" | jq -r ".[$i].want")
  check_eq "pause-resume classifies — $CASE" "$WANT" "$(eval_class "$CLASS_SKILL" "$VAL" "$KIND")"
  check_eq "go-on probe B agrees — $CASE"    "$WANT" "$(eval_class "$CLASS_GOON" "$VAL" "$KIND")"
  check_eq "ownership sweep agrees — $CASE"  "$WANT" "$(eval_class "$CLASS_SWEEP" "$VAL" "$KIND")"
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
echo "== An empty read is a DAMAGED slot, not an absent one =="
# ---------------------------------------------------------------------------
# The classifier above already calls the empty JSON string `unreadable` for both
# shapes. It never saw one: `session-state.sh --get` prints NOTHING for a slot
# holding `""` (rc=0, empty stdout), and all three readers coerced that empty
# read to `null` before the classifier ran — `${VAR:-null}`, `[[ -z "$v" ]]`,
# and `if . == "" then null`. A slot holding `""` is not a map and not a record,
# so reporting it absent is the same "corrupt board read as nothing parked"
# masking this contract exists to stop. Assert the SHELL halves, per reader,
# because that is the layer the coercion lived in.
check_eq "session-state.sh --get really does print nothing for a slot holding \"\"" \
  "" "$(reset_state; jq -n --arg key "$REPO_KEY" '{repos: {($key): {pauses: ""}}}' > "$STATE_FILE"
        "$SCRIPT" --get ".repos[\"$REPO_KEY\"].pauses" 2>/dev/null)"
reset_state

# The sweep's coercion, extracted and run as-is.
eval "$(awk '/^pause_slot_arg\(\) \{/,/^\}/' "$SWEEP")"
check_eq "the sweep hands an empty read through as a JSON string, not null" \
  '""' "$(pause_slot_arg "")"
check_eq "and still calls the literal null absent" "null" "$(pause_slot_arg "null")"
check_eq "and still passes a healthy record through untouched" \
  '{"active":true}' "$(pause_slot_arg '{"active":true}')"

# /pause-resume's coercion, extracted and run as-is.
eval "$(awk '/^_json_or_null\(\) \{/,/^\}/' "$PAUSE_RESUME_SKILL")"
check_eq "/pause-resume hands an empty read through as a JSON string, not null" \
  '""' "$(_json_or_null "")"
check_eq "and still calls the literal null absent" "null" "$(_json_or_null "null")"

# /go-on parses inside jq instead, so assert its `parse` def and its init value.
PARSE_GOON="$(awk '/^ *def parse: /{sub(/^[ \t]+/,""); print; exit}' "$GO_ON_SKILL")"
check_eq "/go-on parses an empty read as damaged, not as null" '"unparseable"' \
  "$(jq -nc --arg v "" "$PARSE_GOON"' $v | parse')"
check_eq "/go-on still parses the literal null as absent" "null" \
  "$(jq -nc --arg v "null" "$PARSE_GOON"' $v | parse')"
check_eq "/go-on seeds its slot vars with null, so an unread slot stays absent" "3" \
  "$(grep -cE '^(PAUSES|LEGACY_PAUSE|LEGACY_SUSPEND)_RAW="null"$' "$GO_ON_SKILL")"
check_eq "and no reader re-coerces an empty slot read back to null" "0" \
  "$(grep -cE '\$\{(PAUSES|LEGACY_PAUSE|LEGACY_SUSPEND)_RAW:-null\}' "$GO_ON_SKILL")"

# A corrupt map and a corrupt legacy slot reach the SAME verdict — the asymmetry
# BugBot named (`else []` for one, `error()` for the other) is gone.
check_eq "a corrupt map and a corrupt legacy slot classify alike" \
  "$(eval_class "$CLASS_SKILL" '"junk"' map)" \
  "$(eval_class "$CLASS_SKILL" '"junk"' slot)"

# ---------------------------------------------------------------------------
echo "== A damaged slot degrades ALONE, in all three readers =="
# ---------------------------------------------------------------------------
# Extract each reader's whole combine and run it. These are the three programs
# the issue names; each must return the surviving records AND name the damaged
# slot, rather than raising and returning nothing.
SWEEP_JQ="$(awk '
  index($0, "--argjson legacy_suspend") { flag = 1; next }
  flag { print }
  flag && index($0, "slot_degraded(\"suspend (legacy)\"") { exit }
' "$SWEEP")"
SWEEP_JQ="${SWEEP_JQ%\'*}"
PROBE_B_JQ="$(awk '
  index($0, "--arg lsusp") { flag = 1; next }
  flag { print }
  flag && index($0, "slot_degraded(\"suspend\"") { exit }
' "$GO_ON_SKILL")"
PROBE_B_JQ="${PROBE_B_JQ%\'*}"
for _prog in "$SWEEP_JQ" "$PROBE_B_JQ"; do
  if [[ "$_prog" != *"def slot_class"* || "$_prog" != *"degraded:"* ]]; then
    echo "FAIL — could not extract the combine program from the sweep and go-on" >&2
    exit 1
  fi
done
# Compile both, so a clipped extraction fails here rather than making every
# assertion below read as "no records".
jq -n --argjson pauses null --argjson legacy_pause null --argjson legacy_suspend null \
  "$SWEEP_JQ" >/dev/null 2>&1 \
  || { echo "FAIL — the extracted ownership-sweep combine does not compile" >&2; exit 1; }
jq -n --arg keyed null --arg lpause null --arg lsusp null "$PROBE_B_JQ" >/dev/null 2>&1 \
  || { echo "FAIL — the extracted go-on probe B combine does not compile" >&2; exit 1; }
PASS=$((PASS + 1)); echo "ok   — sweep and probe B combines extracted and compile"

sweep_combine() { # sweep_combine <pauses> <legacy-pause> <legacy-suspend>
  jq -nc --argjson pauses "$1" --argjson legacy_pause "$2" --argjson legacy_suspend "$3" "$SWEEP_JQ"
}
probe_b_combine() { # same three sources, as RAW STRINGS (what --get returns)
  jq -nc --arg keyed "$1" --arg lpause "$2" --arg lsusp "$3" "$PROBE_B_JQ"
}

KEYED_TWO="$(jq -nc --arg a "$SESS_A" --arg b "$SESS_B" --arg ata "$AT_A" --arg atb "$AT_B" \
  '{($a): {active:true, paused_at:$ata}, ($b): {active:true, paused_at:$atb}}')"
GOOD_SUSPEND='{"active":true,"suspended_at":"2026-08-29T10:00:00Z"}'
CORRUPT='"a string where a record belongs"'

echo "-- a corrupt legacy .pause keeps the keyed map and .suspend --"
# FAILS WITHOUT FIX: the raise aborted the whole combine, so /pause-resume got
# `[]` + STATE_UNREADABLE, and the sweep tripped batch_degrade and drew NO
# parked-unit evidence — a candidate owned by a readable keyed record could then
# be dispatched underneath a live parked board.
check_eq "pause-resume keeps 3 records" "3" \
  "$(select_records "$KEYED_TWO" "$CORRUPT" "$GOOD_SUSPEND" | jq -r 'length')"
check_eq "pause-resume names only the damaged slot" "the legacy pause slot" \
  "$(select_degraded "$KEYED_TWO" "$CORRUPT" "$GOOD_SUSPEND")"
check_eq "the ownership sweep keeps 3 records" "3" \
  "$(sweep_combine "$KEYED_TWO" "$CORRUPT" "$GOOD_SUSPEND" | jq -r '.records | length')"
check_eq "the sweep names only the damaged slot" "pause (legacy)" \
  "$(sweep_combine "$KEYED_TWO" "$CORRUPT" "$GOOD_SUSPEND" | jq -r '.degraded | join(",")')"
check_eq "probe B keeps 3 records" "3" \
  "$(probe_b_combine "$KEYED_TWO" "$CORRUPT" "$GOOD_SUSPEND" | jq -r '.records | length')"
check_eq "probe B names only the damaged slot" "pause" \
  "$(probe_b_combine "$KEYED_TWO" "$CORRUPT" "$GOOD_SUSPEND" | jq -r '.degraded | join(",")')"

echo "-- a corrupt legacy .suspend keeps the keyed map and .pause --"
GOOD_PAUSE='{"active":true,"paused_at":"2026-08-30T10:00:00Z"}'
check_eq "pause-resume keeps 3 records" "3" \
  "$(select_records "$KEYED_TWO" "$GOOD_PAUSE" "$CORRUPT" | jq -r 'length')"
check_eq "pause-resume names only .suspend" "the legacy suspend slot" \
  "$(select_degraded "$KEYED_TWO" "$GOOD_PAUSE" "$CORRUPT")"
check_eq "the ownership sweep keeps 3 records" "3" \
  "$(sweep_combine "$KEYED_TWO" "$GOOD_PAUSE" "$CORRUPT" | jq -r '.records | length')"
check_eq "probe B keeps 3 records" "3" \
  "$(probe_b_combine "$KEYED_TWO" "$GOOD_PAUSE" "$CORRUPT" | jq -r '.records | length')"

echo "-- a corrupt .pauses map is NAMED, not silently empty, and the legacy slots survive --"
# FAILS WITHOUT FIX (the sweep and /pause-resume): a corrupt map took an
# `else []` branch inside the combine — dropped without a word in the program
# itself — while a corrupt legacy slot raised. Same damage, two behaviours.
check_eq "pause-resume keeps both legacy records" "2" \
  "$(select_records "$CORRUPT" "$GOOD_PAUSE" "$GOOD_SUSPEND" | jq -r 'length')"
check_eq "pause-resume names the map" "the pauses map" \
  "$(select_degraded "$CORRUPT" "$GOOD_PAUSE" "$GOOD_SUSPEND")"
check_eq "the ownership sweep keeps both legacy records" "2" \
  "$(sweep_combine "$CORRUPT" "$GOOD_PAUSE" "$GOOD_SUSPEND" | jq -r '.records | length')"
check_eq "the sweep names the map" "pauses" \
  "$(sweep_combine "$CORRUPT" "$GOOD_PAUSE" "$GOOD_SUSPEND" | jq -r '.degraded | join(",")')"
check_eq "probe B keeps both legacy records" "2" \
  "$(probe_b_combine "$CORRUPT" "$GOOD_PAUSE" "$GOOD_SUSPEND" | jq -r '.records | length')"
check_eq "probe B names the map" "pauses" \
  "$(probe_b_combine "$CORRUPT" "$GOOD_PAUSE" "$GOOD_SUSPEND" | jq -r '.degraded | join(",")')"

echo "-- a malformed VALUE inside an otherwise-valid map degrades the map alone --"
MALFORMED_MAP="$(jq -nc --arg a "$SESS_A" '{($a): "not-a-record"}')"
check_eq "pause-resume names the map, keeps the legacy record" "the pauses map" \
  "$(select_degraded "$MALFORMED_MAP" "$GOOD_PAUSE" null)"
check_eq "and that legacy record is still selected" "1" \
  "$(select_records "$MALFORMED_MAP" "$GOOD_PAUSE" null | jq -r 'length')"

echo "-- two damaged slots are both named, and the survivor still counts --"
check_eq "pause-resume names both" "the pauses map,the legacy suspend slot" \
  "$(select_degraded "$CORRUPT" "$GOOD_PAUSE" "$CORRUPT")"
check_eq "the surviving .pause record is still selected" "1" \
  "$(select_records "$CORRUPT" "$GOOD_PAUSE" "$CORRUPT" | jq -r 'length')"

echo "-- nothing damaged means nothing named --"
check_eq "pause-resume degrades no slot on healthy state" "" \
  "$(select_degraded "$KEYED_TWO" "$GOOD_PAUSE" "$GOOD_SUSPEND")"
check_eq "the sweep degrades no slot on healthy state" "" \
  "$(sweep_combine "$KEYED_TWO" "$GOOD_PAUSE" "$GOOD_SUSPEND" | jq -r '.degraded | join(",")')"
check_eq "probe B degrades no slot on healthy state" "" \
  "$(probe_b_combine "$KEYED_TWO" "$GOOD_PAUSE" "$GOOD_SUSPEND" | jq -r '.degraded | join(",")')"

echo "-- probe B: an unparseable slot value is that slot's problem, not the union's --"
# probe B receives RAW strings, so a slot holding non-JSON must be caught inside
# the slot. Raising out of `fromjson` took the other two slots with it.
check_eq "probe B survives non-JSON in .pause" "2" \
  "$(probe_b_combine "$KEYED_TWO" 'this is not json' 'null' | jq -r '.records | length')"
check_eq "probe B names the unparseable slot" "pause" \
  "$(probe_b_combine "$KEYED_TWO" 'this is not json' 'null' | jq -r '.degraded | join(",")')"

echo "-- negative control: the pre-#1611 shapes lose everything --"
# The assertions above prove the new behaviour. They prove it is NEW only against
# the shapes it replaced: `one()`'s raise, which aborts the combine, and the
# map's silent `else []`, which names nothing. Both are exercised here on the
# same fixtures, and both must fail the checks above.
cat > "$TMP_HOME/prechange.jq" <<'PRECHANGE'
def one($b): if ($b | type) == "object" then [$b]
             elif ($b | type) == "null" then []
             else error("legacy pause slot is not a record") end;
( if ($pauses | type) == "object"
  then ($pauses | to_entries | map(select((.value | type) == "object") | .value))
  else [] end )
+ one($legacy_pause) + one($legacy_suspend)
PRECHANGE
PRECHANGE_JQ="$(cat "$TMP_HOME/prechange.jq")"
prechange_combine() {
  jq -nc --argjson pauses "$1" --argjson legacy_pause "$2" --argjson legacy_suspend "$3" \
    "$PRECHANGE_JQ" 2>/dev/null
}
# A corrupt legacy slot aborts the program: no output at all, so the healthy
# keyed records and the healthy `.suspend` record are lost with it.
check_eq "pre-change: a corrupt legacy slot returns nothing" "" \
  "$(prechange_combine "$KEYED_TWO" "$CORRUPT" "$GOOD_SUSPEND")"
# ...while a corrupt map is silently dropped and names nothing — the asymmetry.
check_eq "pre-change: a corrupt map is silently empty, not named" "2" \
  "$(prechange_combine "$CORRUPT" "$GOOD_PAUSE" "$GOOD_SUSPEND" | jq -r 'length')"

# ---------------------------------------------------------------------------
echo "== End to end: the sweep still reports ownership past a damaged slot =="
# ---------------------------------------------------------------------------
# The jq-level checks above prove the combine. This runs the REAL sweep, because
# two shell-level coercions sat between the state file and that combine and both
# turned a damaged slot back into an absent one:
#   * `json_or_null` mapped a slot holding non-JSON text to `null`, which the
#     classifier then calls `absent` — a corrupt board read as "nothing parked";
#   * a slot holding valid JSON of the wrong type reached the old `one()`, whose
#     raise aborted the whole combine and left the sweep with NO parked evidence.
# The second is the reported failure: with a perfectly readable keyed record
# naming issue 4242 as parked, the sweep answered `unowned` and `/pm` was free to
# dispatch it underneath a live parked board.
STUB_BIN="$TMP_HOME/stub-bin"
mkdir -p "$STUB_BIN"
# Offline and deterministic: the sweep's gh reads are evidence, not the subject.
printf '#!/bin/sh\nexit 1\n' > "$STUB_BIN/gh"
chmod +x "$STUB_BIN/gh"

sweep_verdict() { # sweep_verdict <raw .pause slot value, written verbatim>
  reset_state
  jq -n --arg slot "$1" --arg key "$REPO_KEY" '
    {repos: {($key): {
      pauses: {"dead-session-1": {
        active: true, session_id: "dead-session-1",
        paused_at: "2026-09-03T10:00:00Z",
        parked: [{kind:"pr", ref:4242, branch:"issue-4242-thing",
                  stopped_at:"awaiting review", next_move:"poll"}],
        monitors_stopped: [], background_tasks_stopped: []}},
      pause: ($slot | try fromjson catch .)}}}' > "$STATE_FILE"
  ( cd "$REPO_ROOT" && PATH="$STUB_BIN:$PATH" \
      ./.claude/scripts/candidate-ownership.sh 4242 --repo "$REPO_KEY" --json 2>/dev/null )
}

for _shape in '"not JSON at all, just text"' '[1,2,3]' '""'; do
  OUT="$(sweep_verdict "$(jq -rn --argjson v "$_shape" '$v | if type == "string" then . else tojson end')")"
  check_eq "a corrupt .pause ($_shape) still reports the keyed record as owned" \
    "owned_live" "$(jq -r '.verdict' <<<"$OUT")"
  check_eq "and the sweep names that slot, and only that slot" "1" \
    "$(jq -r '[.degraded[] | select(startswith("pause (legacy):"))] | length' <<<"$OUT")"
  check_eq "the combine itself is never reported as failed" "0" \
    "$(jq -r '[.degraded[] | select(startswith("pause records: could not be combined"))] | length' <<<"$OUT")"
done

echo "-- control: a healthy .pause names no pause slot at all --"
OUT="$(sweep_verdict '{"active":false}')"
check_eq "healthy state reports the keyed record owned" "owned_live" \
  "$(jq -r '.verdict' <<<"$OUT")"
check_eq "and degrades no pause slot" "0" \
  "$(jq -r '[.degraded[] | select(startswith("pause"))] | length' <<<"$OUT")"
reset_state

# ---------------------------------------------------------------------------
echo "== A marker restore is never counted as restored =="
# ---------------------------------------------------------------------------
# The marker path exists for when session-state.json is UNREADABLE, so it is the
# one path that must never claim success. Its selection entry carries the stub
# record {marker_path} — the marker is prose and is never parsed into
# monitors_stopped / background_tasks_stopped — and the Step 2 loop binds
# $PAUSE_STATE from that stub. Counting its absent arrays as zero pending made
# Step 7 report a completed restore over a board whose Monitors and parked units
# were never touched, violating the Safety note's "may never report success over
# a board it did not restore". Pin that the marker path is excluded from the
# success branch and that pending stays UNKNOWN there.
STEP7=$(awk '
  index($0, "ALL_REARMED=true") { grab = 1 }
  grab                          { print }
  grab && /^fi$/                { exit }
' "$PAUSE_RESUME_SKILL")
if [[ -z "$STEP7" ]]; then
  FAIL=$((FAIL + 1)); echo "FAIL — could not extract Step 7 from the skill" >&2
else
  PASS=$((PASS + 1)); echo "ok   — Step 7 extracted"
fi
# The success branch requires a real write-back address, so an empty
# $STATE_PATH can never reach RESTORED.
check_eq "the restored branch requires a state path" "1" \
  "$(grep -c 'ALL_REARMED" == true && -n "\$STATE_PATH"' <<<"$STEP7")"
# ...and the marker path must not compute a pending count from the stub record.
check_eq "the marker path leaves pending unknown" "1" \
  "$(grep -c 'cannot be confirmed: the marker carries no re-arm inventory' <<<"$STEP7")"
# No RESTORED increment may sit in a branch reachable with an empty state path.
check_eq "RESTORED is incremented on exactly one path" "1" \
  "$(grep -c 'RESTORED=\$((RESTORED + 1))' <<<"$STEP7")"

# ---------------------------------------------------------------------------
echo "== A failed gate clear ends one record, not the command =="
# ---------------------------------------------------------------------------
# Steps 3-7 run inside the Step 2 per-record loop, so an `exit` anywhere in the
# restore sequence abandons every later record and hides it from Step 8 as well.
# Step 4b used to `exit 1` when the execution gate could not be cleared, which
# contradicted both the Step 2 prose and the Safety note ("Every `exit` inside
# the restore sequence is a `continue`"). Pin the gate-failure branch itself.
STEP4B=$(awk '
  index($0, "Could not clear the pause execution gate") { grab = 1 }
  grab                                                  { print }
  grab && /^fi$/                                        { exit }
' "$PAUSE_RESUME_SKILL")
if [[ -z "$STEP4B" ]]; then
  FAIL=$((FAIL + 1)); echo "FAIL — could not extract the Step 4b gate-failure branch" >&2
else
  PASS=$((PASS + 1)); echo "ok   — Step 4b gate-failure branch extracted"
fi
check_eq "a failed gate clear continues to the next record" "1" \
  "$(grep -c '^  continue$' <<<"$STEP4B")"
check_eq "a failed gate clear never exits the whole command" "0" \
  "$(grep -c 'exit 1' <<<"$STEP4B")"

# The gate is session-scoped, so restoring ANOTHER session's board must clear
# that session's gate too. Clearing only the current session left the parked
# session launch-blocked after its board was restored, with /go-on probe A still
# reading the live gate as a pause.
check_eq "the gate clear targets the record's own session" "1" \
  "$(grep -c 'GATE_TARGETS="\$RECORD_SESSION \$SESSION_ID"' "$PAUSE_RESUME_SKILL")"
check_eq "placeholder session ids are not cleared as sessions" "1" \
  "$(grep -c '""|marker|legacy|"\$SESSION_ID") : ;;' "$PAUSE_RESUME_SKILL")"

# ---------------------------------------------------------------------------
echo "== The repo-wide refill clear happens once, after the loop =="
# ---------------------------------------------------------------------------
# `refill` is repo-wide but Step 6 runs inside the per-record loop, so writing it
# there cleared the pause after the FIRST record — new pipeline work could start
# while sibling boards were still being restored, and Step 5 may already have
# re-armed PMM. Step 6 now only marks intent; Step 8 performs the single write.
check_eq "Step 6 only marks the refill intent" "1" \
  "$(grep -c 'REFILL_CLEAR_PENDING=true' "$PAUSE_RESUME_SKILL")"
check_eq "the refill flag is initialized before the loop" "1" \
  "$(grep -c 'REFILL_CLEAR_PENDING=false' "$PAUSE_RESUME_SKILL")"
# Exactly one refill write, and it must sit after the loop (Step 8), guarded by
# the pending flag rather than by RESUME_REFILL directly.
check_eq "exactly one refill write remains" "1" \
  "$(grep -c 'refill={\\"paused\\":false' "$PAUSE_RESUME_SKILL")"
REFILL_WRITE_LINE=$(grep -n 'refill={\\"paused\\":false' "$PAUSE_RESUME_SKILL" | cut -d: -f1)
STEP8_LINE=$(grep -n '^## Step 8:' "$PAUSE_RESUME_SKILL" | cut -d: -f1)
if [[ -n "$REFILL_WRITE_LINE" && -n "$STEP8_LINE" && "$REFILL_WRITE_LINE" -gt "$STEP8_LINE" ]]; then
  PASS=$((PASS + 1)); echo "ok   — the refill write sits after the per-record loop"
else
  FAIL=$((FAIL + 1))
  echo "FAIL — the refill write is still inside the per-record loop (line ${REFILL_WRITE_LINE:-none}, Step 8 at ${STEP8_LINE:-none})" >&2
fi

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
echo "== A slot holding the STRING \"null\" is damaged, not absent (issue #1629) =="
# ---------------------------------------------------------------------------
# #1611 closed the `""` half of this. The `"null"` half was unreachable from the
# readers: raw `--get` prints the same four characters for an absent path, a
# stored JSON null, AND a slot corrupted into the JSON STRING "null", and
# reserving that text for "absent" is the only signal raw output offers. So a
# corrupt board read as "nothing parked" with no reader bug to point at. The fix
# is the interface: the three readers now read pause slots with `--get-json`.
#
# These assertions drive the REAL shell read path — a seeded state file, read by
# the real script, coerced by each reader's own extracted function — not a
# hand-written value handed straight to the classifier.
reset_state
ss --set ".repos[\"$REPO_KEY\"].pauses=\"null\"" >/dev/null 2>&1
check_eq "the seeded slot really does hold the STRING \"null\"" "string" \
  "$(jq -r --arg k "$REPO_KEY" '.repos[$k].pauses | type' "$STATE_FILE")"

# NEGATIVE CONTROL: the conflation the readers could not see past.
GET_RAW="$(ss --get ".repos[\"$REPO_KEY\"].pauses" 2>/dev/null)"
GET_JSON="$(ss --get-json ".repos[\"$REPO_KEY\"].pauses" 2>/dev/null)"
check_eq "--get prints the corrupt slot as bare null (the defect)" "null" "$GET_RAW"
check_eq "--get-json prints it quoted, so it is distinguishable" '"null"' "$GET_JSON"

# Each reader's own coercion, extracted and run as-is, on BOTH wire formats.
# `--get` output classifies absent (the bug); `--get-json` output classifies
# unreadable (the fix). Same function, same fixture — only the read mode moved.
eval "$(awk '/^pause_slot_arg\(\) \{/,/^\}/' "$SWEEP")"
eval "$(awk '/^_json_or_null\(\) \{/,/^\}/' "$PAUSE_RESUME_SKILL")"

# Every `--get-json` classification row below is paired with the value row above
# (`--get-json prints it quoted`), which is what keeps them from passing
# vacuously: on a tree with no --get-json the read returns EMPTY, and empty is
# `unreadable` to all three coercions for an entirely different reason. Assert
# the input reached them, not just the verdict.
check_eq "the --get-json read produced input, not an empty failure" "1" \
  "$([[ -n "$GET_JSON" ]] && echo 1 || echo 0)"
check_eq "sweep + --get would call the corrupt slot ABSENT (pre-fix behaviour)" \
  "absent"     "$(eval_class "$CLASS_SWEEP" "$(pause_slot_arg "$GET_RAW")" map)"
check_eq "sweep + --get-json calls it unreadable" \
  "unreadable" "$(eval_class "$CLASS_SWEEP" "$(pause_slot_arg "$GET_JSON")" map)"
check_eq "pause-resume + --get would call it ABSENT (pre-fix behaviour)" \
  "absent"     "$(eval_class "$CLASS_SKILL" "$(_json_or_null "$GET_RAW")" map)"
check_eq "pause-resume + --get-json calls it unreadable" \
  "unreadable" "$(eval_class "$CLASS_SKILL" "$(_json_or_null "$GET_JSON")" map)"
check_eq "go-on + --get would call it ABSENT (pre-fix behaviour)" \
  "absent"     "$(eval_class "$CLASS_GOON" "$(jq -nc --arg v "$GET_RAW"  "$PARSE_GOON"' $v | parse')" map)"
check_eq "go-on + --get-json calls it unreadable" \
  "unreadable" "$(eval_class "$CLASS_GOON" "$(jq -nc --arg v "$GET_JSON" "$PARSE_GOON"' $v | parse')" map)"

echo "-- the legacy singletons take the same rule --"
reset_state
ss --set ".repos[\"$REPO_KEY\"].pause=\"null\"" >/dev/null 2>&1
ss --set ".repos[\"$REPO_KEY\"].suspend=\"null\"" >/dev/null 2>&1
for _slot in pause suspend; do
  _j="$(ss --get-json ".repos[\"$REPO_KEY\"].$_slot" 2>/dev/null)"
  # Paired with the classification rows below so they cannot pass vacuously: a
  # tree without --get-json returns EMPTY here, which every coercion also calls
  # `unreadable`. This row is what distinguishes "read it and judged it damaged"
  # from "could not read it at all".
  check_eq ".$_slot reads back as a quoted JSON string under --get-json" '"null"' "$_j"
  check_eq "sweep calls a .$_slot holding \"null\" unreadable" \
    "unreadable" "$(eval_class "$CLASS_SWEEP" "$(pause_slot_arg "$_j")" slot)"
  check_eq "pause-resume calls a .$_slot holding \"null\" unreadable" \
    "unreadable" "$(eval_class "$CLASS_SKILL" "$(_json_or_null "$_j")" slot)"
  check_eq "go-on calls a .$_slot holding \"null\" unreadable" \
    "unreadable" "$(eval_class "$CLASS_GOON" "$(jq -nc --arg v "$_j" "$PARSE_GOON"' $v | parse')" slot)"
done

echo "-- a genuinely absent slot is still absent, and a healthy board still present --"
# Without these the fix could pass by calling everything unreadable.
reset_state
ABSENT_JSON="$(ss --set '.schema_version=2' >/dev/null 2>&1; ss --get-json ".repos[\"$REPO_KEY\"].pauses" 2>/dev/null)"
check_eq "an absent pauses slot reads as bare null under --get-json" "null" "$ABSENT_JSON"
check_eq "sweep still calls it absent"        "absent" "$(eval_class "$CLASS_SWEEP" "$(pause_slot_arg "$ABSENT_JSON")" map)"
check_eq "pause-resume still calls it absent" "absent" "$(eval_class "$CLASS_SKILL" "$(_json_or_null "$ABSENT_JSON")" map)"
check_eq "go-on still calls it absent"        "absent" \
  "$(eval_class "$CLASS_GOON" "$(jq -nc --arg v "$ABSENT_JSON" "$PARSE_GOON"' $v | parse')" map)"

reset_state
ss --set ".repos[\"$REPO_KEY\"].pauses={\"$SESS_A\":$(board "$SESS_A" "$AT_A" 1573 true)}" >/dev/null 2>&1
HEALTHY_JSON="$(ss --get-json ".repos[\"$REPO_KEY\"].pauses" 2>/dev/null)"
check_eq "sweep still calls a healthy keyed board present"        "present" "$(eval_class "$CLASS_SWEEP" "$(pause_slot_arg "$HEALTHY_JSON")" map)"
check_eq "pause-resume still calls a healthy keyed board present" "present" "$(eval_class "$CLASS_SKILL" "$(_json_or_null "$HEALTHY_JSON")" map)"
check_eq "go-on still calls a healthy keyed board present"        "present" \
  "$(eval_class "$CLASS_GOON" "$(jq -nc --arg v "$HEALTHY_JSON" "$PARSE_GOON"' $v | parse')" map)"
check_eq "and the records survive the round trip" "1" \
  "$(select_records "$HEALTHY_JSON" null null | jq -r 'length')"

echo "-- all three readers actually read the pause slots with --get-json --"
# The pin. A future edit that quietly reverts a pause slot to raw `--get` puts
# the invisible-corruption hole straight back, and nothing above would catch it
# because every assertion here feeds the coercions by hand.
check_eq "candidate-ownership.sh reads its three pause slots with --get-json" "3" \
  "$(grep -cE 'ss_get_json "\.repos\[\\"\$REPO_KEY\\"\]\.(pauses|pause|suspend)"' "$SWEEP")"
check_eq "candidate-ownership.sh reads no pause slot with plain --get" "0" \
  "$(grep -cE '^[^#]*ss_get "\.repos\[\\"\$REPO_KEY\\"\]\.(pauses|pause|suspend)"' "$SWEEP")"
check_eq "/pause-resume _read_slot uses --get-json" "1" \
  "$(grep -c -- 'SLOT_VALUE=$("$SESSION_STATE_SH" --get-json "$1"' "$PAUSE_RESUME_SKILL")"
check_eq "/go-on probe B uses --get-json for its slot loop" "1" \
  "$(grep -c -- 'SLOT_RAW=$("$SESSION_STATE_SH" --get-json ' "$GO_ON_SKILL")"
check_eq "and session-state.sh actually provides --get-json" "1" \
  "$(grep -c -- '--get|--get-json)' "$SCRIPT")"

# ---------------------------------------------------------------------------
echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAIL: pause-multisession tests failed" >&2
  exit 1
fi
echo "OK: pause-multisession tests passed"
