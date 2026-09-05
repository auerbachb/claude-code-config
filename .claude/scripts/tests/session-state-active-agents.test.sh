#!/usr/bin/env bash
# Tests for the `.active_agents` keyed-map contract in session-state.sh,
# issue #1631.
# catalog: tests — Tests the `.active_agents` keyed-map contract in `session-state.sh` — a negative control proving the old whole-value replace loses a sibling thread's entries, concurrent per-key writes that lose none, the array→map migration, and `--remove-agent` (issue #1631)
#
# The bug: `.active_agents` was a top-level ARRAY, so no writer could address
# one entry. Every writer did `--get '.active_agents'`, filtered or appended
# locally, then `--set '.active_agents=<whole array>'`. The read and the write
# sit in two different lock windows, so a sibling thread's append landing
# between them is silently discarded. Observed three times on 2026-09-04, each
# time dropping live Phase B/C agents with no error anywhere.
#
# Verifies:
#   - NEGATIVE CONTROL: the old read-filter-write idiom really does lose a
#     sibling's entry under the same interleaving the fix survives. Without it,
#     the concurrency test below could pass vacuously — a green result would
#     prove only that the harness never produced the race.
#   - Two concurrent writers (targeted append from A, --remove-agent from B)
#     lose neither thread's entries, under a DETERMINISTIC interleaving
#     (both threads read before either writes) and under a hot loop.
#   - array -> map migration on first read: keyed by `.id`, `.agent` honored as
#     a secondary key source, `null`/non-object elements dropped, an id-less
#     entry keyed `_unkeyed_<index>`, idempotent, persisted by --migrate.
#   - --remove-agent contract: deletes one key, preserves siblings, no-op on a
#     missing key (exit 0), works on a fresh state file, repeatable, composes
#     with --set and --cas in one atomic write, rejects bad usage.
#   - --session-view projects a MAP (not an array) and keeps its attribution
#     rule, dropping non-object values.
#
# Each regression test includes a FAILS-WITHOUT-FIX comment so a reviewer can
# revert the change in session-state.sh and confirm the test fails.
#
# Run from any directory; uses a throwaway HOME so the real ~/.claude/
# session-state.json is never touched.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/session-state.sh"

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"

# Pin the repo scope so nothing here depends on the cwd's git origin.
export CLAUDE_SESSION_REPO="auerbachb/claude-code-config"

PASS=0
FAIL=0

check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}

run() { bash "$SCRIPT" "$@"; }

seed() { printf '%s\n' "$1" > "$STATE_FILE"; }

# Sorted key list of the on-disk map, as a compact JSON array.
disk_keys() { jq -c '(.active_agents // {}) | keys' "$STATE_FILE" 2>/dev/null; }

agent_json() {
  jq -n -c --arg id "$1" --arg phase "$2" \
    '{id:$id, task:("PR work " + $id), phase:$phase, launched:"2026-09-04T12:00:00Z"}'
}

# ===========================================================================
echo "== Negative control: the OLD read-filter-write idiom loses entries =="
# ===========================================================================
# This replays exactly what every writer did before this change, with the two
# threads interleaved the way two orchestration threads on one machine
# interleave: both read, then both write. The lock inside session-state.sh does
# not help — each --set is individually atomic, and each one carries a whole
# FIELD VALUE computed from a snapshot taken before the other writer's --set
# landed. That is true of the array this seeds and equally true of the map it
# migrates to, which is why the fix is per-key writes rather than the shape
# change on its own.
#
# If this test ever goes green, the harness has stopped reproducing the race
# and the fix test below proves nothing.
seed '{"schema_version":2,"active_agents":[{"id":"sibling","phase":"B"}],"repos":{}}'

# Thread A reads the map and plans an append of "thread-a".
SNAP_A="$(run --raw-path --get '.active_agents')"
# Thread B reads the SAME snapshot — this is the window, and it is the window
# whether the field is an array or a map. What differs is the WRITE: the old
# idiom had no way to spell "just my key", so both threads wrote the whole
# value computed from their own stale snapshot.
SNAP_B="$SNAP_A"
NEW_A="$(jq -c --argjson e "$(agent_json thread-a A)" '. + {"thread-a": $e}' <<<"$SNAP_A")"
NEW_B="$(jq -c --argjson e "$(agent_json thread-b A)" '. + {"thread-b": $e}' <<<"$SNAP_B")"
# Thread A writes its whole value, then thread B writes its whole value.
run --raw-path --set ".active_agents=$NEW_A" >/dev/null 2>&1
run --raw-path --set ".active_agents=$NEW_B" >/dev/null 2>&1
check_eq "negative control: whole-value replace drops thread-a" \
  '["sibling","thread-b"]' "$(disk_keys)"

# ===========================================================================
echo "== Concurrency: targeted per-key writes lose nothing =="
# ===========================================================================
# FAILS WITHOUT FIX: with `.active_agents` still an array there is no way to
# spell a per-key write, so the only available idiom is the one the negative
# control above proves lossy.
#
# Deterministic interleaving: both threads capture their view of the world
# BEFORE either writes — the exact window the old idiom lost data in — and only
# then issue their targeted write and their --remove-agent.
seed '{"schema_version":2,"active_agents":{"sibling":{"id":"sibling","phase":"B"},"doomed":{"id":"doomed","phase":"C"}},"repos":{}}'
VIEW_A="$(run --raw-path --get '.active_agents')"
VIEW_B="$(run --raw-path --get '.active_agents')"
check_eq "both threads read the same pre-write snapshot" \
  "$(jq -cS . <<<"$VIEW_A")" "$(jq -cS . <<<"$VIEW_B")"
run --raw-path --set ".active_agents[\"thread-a\"]=$(agent_json thread-a A)" >/dev/null 2>&1
run --remove-agent doomed >/dev/null 2>&1
check_eq "sequential interleave: append kept, removal applied, sibling survives" \
  '["sibling","thread-a"]' "$(disk_keys)"

# Same again, but genuinely concurrent — the `( ... ) & ... wait` idiom from
# state-lock.test.sh — repeated so a single lucky ordering cannot carry it.
CONC_LOSSES=0
for _round in 1 2 3 4 5; do
  seed '{"schema_version":2,"active_agents":{"sibling":{"id":"sibling","phase":"B"},"doomed":{"id":"doomed","phase":"C"}},"repos":{}}'
  ( run --raw-path --set ".active_agents[\"thread-a\"]=$(agent_json thread-a A)" >/dev/null 2>&1 ) &
  PID_A=$!
  ( run --raw-path --set ".active_agents[\"thread-b\"]=$(agent_json thread-b A)" >/dev/null 2>&1 ) &
  PID_B=$!
  ( run --remove-agent doomed >/dev/null 2>&1 ) &
  PID_C=$!
  wait "$PID_A" "$PID_B" "$PID_C"
  # Valid JSON, single document, and every expected key present.
  if ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    CONC_LOSSES=$((CONC_LOSSES + 1)); continue
  fi
  if [[ "$(disk_keys)" != '["sibling","thread-a","thread-b"]' ]]; then
    CONC_LOSSES=$((CONC_LOSSES + 1))
  fi
done
check_eq "5 concurrent rounds: no round lost an entry or corrupted the file" \
  "0" "$CONC_LOSSES"

# ===========================================================================
echo "== array -> map migration =="
# ===========================================================================
# FAILS WITHOUT FIX: without _agents_map the read returns the array verbatim.
seed '{"schema_version":2,"active_agents":[null,{"id":"a1","pr":10},{"task":"no id"},{"agent":"b2"},"junk"],"repos":{}}'
check_eq "legacy array migrates to a map keyed by id/agent, null + non-object dropped" \
  '["_unkeyed_2","a1","b2"]' "$(run --raw-path --get '.active_agents' | jq -c 'keys')"
check_eq "migration preserves the entry payload" \
  '10' "$(run --raw-path --get '.active_agents' | jq -r '.a1.pr')"
check_eq "a read does NOT rewrite the file" \
  'array' "$(jq -r '.active_agents | type' "$STATE_FILE")"

# FAILS WITHOUT FIX: with a bare `_unkeyed_<index>` key, the id-less entry at
# index 1 lands on `_unkeyed_1` and CLOBBERS the real agent that carries that
# literal id — the migration would lose an identified agent to an anonymous
# one, which is exactly the loss issue #1631 exists to stop (CodeAnt, PR #1637).
seed '{"schema_version":2,"active_agents":[{"id":"_unkeyed_1","phase":"A"},{"phase":"B"}],"repos":{}}'
UNKEYED_MAP="$(run --raw-path --get '.active_agents')"
check_eq "an id-less entry never clobbers a real agent named _unkeyed_<index>" \
  '["_unkeyed_1","_unkeyed_1_"]' "$(jq -c 'keys' <<<"$UNKEYED_MAP")"
check_eq "the real agent keeps its own key and payload" \
  'A' "$(jq -r '.["_unkeyed_1"].phase' <<<"$UNKEYED_MAP")"
check_eq "the id-less entry survives under the disambiguated key" \
  'B' "$(jq -r '.["_unkeyed_1_"].phase' <<<"$UNKEYED_MAP")"

# FAILS WITHOUT FIX: `.id // .agent` falls through only on null/false, so an
# entry carrying an EMPTY or wrong-typed `.id` shadowed a perfectly good
# `.agent` and landed under `_unkeyed_` (CodeAnt, PR #1637). The two sources are
# now tried for the first USABLE key — non-empty string or number.
seed '{"schema_version":2,"active_agents":[{"id":"","agent":"real-a"},{"id":{},"agent":"real-b"},{"id":[],"agent":"real-c"},{"id":false,"agent":"real-d"},{"id":0,"agent":"ignored"}],"repos":{}}'
check_eq "an unusable .id falls through to .agent instead of _unkeyed_" \
  '["0","real-a","real-b","real-c","real-d"]' \
  "$(run --raw-path --get '.active_agents' | jq -c 'keys')"

# Disambiguation keeps walking past an occupied suffix rather than stopping at one.
seed '{"schema_version":2,"active_agents":[{"id":"_unkeyed_2"},{"id":"_unkeyed_2_"},{"phase":"Z"}],"repos":{}}'
check_eq "disambiguation walks past every occupied key" \
  '["_unkeyed_2","_unkeyed_2_","_unkeyed_2__"]' \
  "$(run --raw-path --get '.active_agents' | jq -c 'keys')"

# Duplicate REAL ids must still collapse last-writer-wins — the disambiguation
# above applies only to the anonymous fallback, never to an identified agent.
seed '{"schema_version":2,"active_agents":[{"id":"dup","v":1},{"id":"dup","v":2}],"repos":{}}'
check_eq "duplicate real ids still collapse to the last entry" \
  '{"dup":{"id":"dup","v":2}}' "$(run --raw-path --get '.active_agents' | jq -cS '.')"

seed '{"schema_version":2,"active_agents":[null,{"id":"a1","pr":10},{"task":"no id"},{"agent":"b2"},"junk"],"repos":{}}'
run --migrate >/dev/null 2>&1
check_eq "--migrate persists the map" 'object' "$(jq -r '.active_agents | type' "$STATE_FILE")"
BEFORE="$(jq -cS '.active_agents' "$STATE_FILE")"
run --migrate >/dev/null 2>&1
check_eq "--migrate is idempotent on an already-migrated map" \
  "$BEFORE" "$(jq -cS '.active_agents' "$STATE_FILE")"

seed '{"schema_version":2,"active_agents":[],"repos":{}}'
check_eq "an empty legacy array migrates to an empty map" \
  '{}' "$(run --raw-path --get '.active_agents' | jq -c .)"

# A duplicate id collapses to the last entry — the same last-writer-wins the
# array already had, made explicit so a future reader does not read it as loss.
seed '{"schema_version":2,"active_agents":[{"id":"dup","phase":"A"},{"id":"dup","phase":"C"}],"repos":{}}'
check_eq "duplicate ids collapse to the last entry" \
  'C' "$(run --raw-path --get '.active_agents' | jq -r '.dup.phase')"

# An unexpected type is left alone by the migration rather than discarded.
# `--get` still answers with the documented safe default for a corrupt
# known-typed field ({} now that the contract says object), so the proof that
# nothing was discarded is the file itself: a read never rewrites it.
seed '{"schema_version":2,"active_agents":"corrupted","repos":{}}'
check_eq "--get on a corrupt field returns the safe default" \
  '{}' "$(run --raw-path --get '.active_agents' 2>/dev/null)"
check_eq "...and the migration discarded nothing on disk" \
  'corrupted' "$(jq -r '.active_agents' "$STATE_FILE")"

# ===========================================================================
echo "== --remove-agent contract =="
# ===========================================================================
seed '{"schema_version":2,"active_agents":{"a1":{"id":"a1"},"b2":{"id":"b2"},"c3":{"id":"c3"}},"repos":{}}'
run --remove-agent b2 >/dev/null 2>&1; RC=$?
check_eq "--remove-agent exits 0" "0" "$RC"
check_eq "--remove-agent deletes only its own key" '["a1","c3"]' "$(disk_keys)"

run --remove-agent b2 >/dev/null 2>&1; RC=$?
check_eq "removing an already-absent id is a no-op that exits 0" "0" "$RC"
check_eq "the no-op left the siblings alone" '["a1","c3"]' "$(disk_keys)"

run --remove-agent a1 --remove-agent c3 >/dev/null 2>&1
check_eq "repeated --remove-agent removes each id in one write" '[]' "$(disk_keys)"

rm -f "$STATE_FILE"
run --remove-agent ghost >/dev/null 2>&1; RC=$?
check_eq "--remove-agent against a missing state file exits 0" "0" "$RC"
check_eq "...and seeds an empty map rather than a type violation" \
  '{}' "$(jq -c '.active_agents' "$STATE_FILE")"

# Composition with --set: one invocation, one atomic write.
seed '{"schema_version":2,"active_agents":{"old":{"id":"old"}},"repos":{}}'
run --raw-path --remove-agent old --set ".active_agents[\"new\"]=$(agent_json new A)" \
  --set '.monitoring_active=true' >/dev/null 2>&1
check_eq "--remove-agent composes with --set in one write" '["new"]' "$(disk_keys)"
check_eq "...and the unrelated --set in the same batch landed" \
  'true' "$(jq -r '.monitoring_active' "$STATE_FILE")"

# FAILS WITHOUT FIX: same-key remove + assign in one invocation. Deletions used
# to be staged after every assignment, so a respawn that drained an id and
# reassigned it in the same call ended with NO record at all — the drain path
# reintroducing the loss issue #1631 fixed in the writers. Deletions now stage
# first, so the assignment always survives, in EITHER flag order (CodeAnt, #1637).
seed '{"schema_version":2,"active_agents":{"respawn":{"id":"respawn","phase":"A"}},"repos":{}}'
run --raw-path --remove-agent respawn --set ".active_agents[\"respawn\"]=$(agent_json respawn B)" \
  >/dev/null 2>&1
check_eq "same-key remove+assign keeps the assignment (remove first)" '["respawn"]' "$(disk_keys)"
check_eq "...and it is the NEW record, not the drained one" \
  'B' "$(jq -r '.active_agents.respawn.phase' "$STATE_FILE")"

seed '{"schema_version":2,"active_agents":{"respawn":{"id":"respawn","phase":"A"}},"repos":{}}'
run --raw-path --set ".active_agents[\"respawn\"]=$(agent_json respawn B)" --remove-agent respawn \
  >/dev/null 2>&1
check_eq "same-key assign+remove is order-insensitive: assignment still wins" \
  'B' "$(jq -r '.active_agents.respawn.phase' "$STATE_FILE")"

# FAILS WITHOUT FIX: the CAS TARGET assignment was staged before the removes even
# after the composed --set writes were moved, so a --cas whose own target is the
# agent key deleted the record it had just written (CodeAnt, PR #1637).
seed "$(jq -n -c --argjson a "$(agent_json cx A)" \
  '{schema_version:2, active_agents:{cx:$a}, repos:{}}')"
run --raw-path --cas ".active_agents[\"cx\"]=$(agent_json cx B)" \
  --expect "$(agent_json cx A)" --remove-agent cx >/dev/null 2>&1
check_eq "a --cas target on the agent key survives a same-key --remove-agent" \
  'B' "$(jq -r '.active_agents.cx.phase' "$STATE_FILE")"

# Different keys are unaffected by the staging order — the common case.
seed '{"schema_version":2,"active_agents":{"gone":{"id":"gone"},"stays":{"id":"stays"}},"repos":{}}'
run --raw-path --remove-agent gone --set ".active_agents[\"fresh\"]=$(agent_json fresh A)" \
  >/dev/null 2>&1
check_eq "distinct keys: the drain and the append both land" '["fresh","stays"]' "$(disk_keys)"

# Composition with --cas: the compare gates the deletion too.
seed '{"schema_version":2,"active_agents":{"old":{"id":"old"}},"pmm_active":false,"repos":{}}'
run --raw-path --cas '.pmm_active=true' --expect 'false' --remove-agent old >/dev/null 2>&1; RC=$?
check_eq "--cas win applies the composed --remove-agent" "0" "$RC"
check_eq "...and the agent is gone" '[]' "$(disk_keys)"

seed '{"schema_version":2,"active_agents":{"old":{"id":"old"}},"pmm_active":true,"repos":{}}'
run --raw-path --cas '.pmm_active=true' --expect 'false' --remove-agent old >/dev/null 2>&1; RC=$?
check_eq "--cas mismatch exits 7 and applies nothing" "7" "$RC"
check_eq "...so the agent survives a lost CAS" '["old"]' "$(disk_keys)"

# Usage errors.
run --remove-agent >/dev/null 2>&1; RC=$?
check_eq "--remove-agent with no id exits 2" "2" "$RC"
run --get '.active_agents' --remove-agent x >/dev/null 2>&1; RC=$?
check_eq "--remove-agent combined with --get exits 2" "2" "$RC"

# A literal `false` must be REJECTED, not silently healed. jq's `//` treats
# false as empty, so seeding the map with `.active_agents // {}` would convert
# a corrupt boolean into a valid empty map — a write that exits 0 while
# discarding the evidence. The seed tests `== null` instead.
seed '{"schema_version":2,"active_agents":false,"repos":{}}'
run --remove-agent whatever >/dev/null 2>&1; RC=$?
check_eq "--remove-agent on a literal false exits 4, not 0" "4" "$RC"
check_eq "...and false is not healed into an empty map" \
  'false' "$(jq -c '.active_agents' "$STATE_FILE")"

# A corrupt non-object value is rejected by the field-type contract (exit 4),
# not silently mangled or aborted with an opaque jq error.
seed '{"schema_version":2,"active_agents":"corrupted","repos":{}}'
OUT="$(run --remove-agent whatever 2>&1)"; RC=$?
check_eq "--remove-agent on a corrupt field exits 4" "4" "$RC"
check_eq "...with the field-type message" "1" \
  "$(grep -c "field '.active_agents' would become type 'string'" <<<"$OUT")"
check_eq "...and the file is unmodified" \
  'corrupted' "$(jq -r '.active_agents' "$STATE_FILE")"

# ===========================================================================
echo "== --session-view projects a map =="
# ===========================================================================
# FAILS WITHOUT FIX: the old `map(select(...))` returns an ARRAY, so a caller
# reading `.active_agents["<id>"]` off the view gets null.
seed '{
  "schema_version": 2,
  "active_agents": {
    "mine-noPR":   {"id":"mine-noPR"},
    "mine-byPR":   {"id":"mine-byPR", "pr": 1631},
    "theirs-byPR": {"id":"theirs-byPR", "pr": 4242},
    "theirs-owner":{"id":"theirs-owner", "owner_repo": "someone/else"},
    "junk":        null
  },
  "repos": {
    "auerbachb/claude-code-config": {"prs": {"1631": {"reviewer": "cr"}}},
    "someone/else": {"prs": {"4242": {"reviewer": "cr"}}}
  }
}'
VIEW="$(run --session-view)"
check_eq "--session-view emits an object, not an array" \
  'object' "$(jq -r '.active_agents | type' <<<"$VIEW")"
check_eq "--session-view keeps this repo's entries and drops the others" \
  '["mine-byPR","mine-noPR"]' "$(jq -c '.active_agents | keys' <<<"$VIEW")"
check_eq "--session-view drops a null value" \
  'false' "$(jq -r '.active_agents | has("junk")' <<<"$VIEW")"
check_eq "--session-view entries are addressable by key" \
  '1631' "$(jq -r '.active_agents["mine-byPR"].pr' <<<"$VIEW")"
check_eq "--all-repos still emits every entry" \
  '["junk","mine-byPR","mine-noPR","theirs-byPR","theirs-owner"]' \
  "$(run --session-view --all-repos | jq -c '.active_agents | keys')"

# A legacy array reaches the view already migrated.
seed '{"schema_version":2,"active_agents":[{"id":"legacy"}],"repos":{}}'
check_eq "--session-view migrates a legacy array before projecting" \
  'object' "$(run --session-view | jq -r '.active_agents | type')"

# ===========================================================================
echo ""
echo "== Summary =="
echo "PASS: $PASS   FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
