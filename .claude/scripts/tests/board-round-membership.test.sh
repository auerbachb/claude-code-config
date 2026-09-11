#!/usr/bin/env bash
# board-round-membership.test.sh — the durable round record (issue #1604).
# catalog: tests — Runs the real skill-embedded bash for `/subagent` Step 7.0's round-membership write and `/board` Step 3's queued-row derivation (issue #1604), plus the cross-file contracts they depend on: the schema block, the teardown clear, `/wave`'s deliberate non-write, and the reconciled "no durable field" rationale
#
# WHAT IS UNDER TEST
#   `/board` could not render exact Queued rows or exact Completed-this-round
#   rows from a thread that did not dispatch the round, because nothing on disk
#   said which issues belonged to it. `.repos["<key>"].round` is that record:
#   written once by `/subagent` Step 7.0 at dispatch, cleared by Step 8 item 6
#   at teardown, read by `/board` Step 3.
#
#   Writer, clear site, and reader must change together. A reader that stops
#   matching the written path does not fail — it renders an EMPTY round, which
#   looks exactly like a quiet repo. That is what these assertions catch.
#
# WHY A MIXED STATIC/EXECUTED TEST
#   SKILL.md is a procedure Claude executes, so the cross-file contracts (who
#   writes, who clears, who must NOT write) can only be asserted statically.
#   The two blocks that carry real logic — the write's read-before-write guard
#   and the queued-row derivation — are EXTRACTED FROM THE SKILL AND RUN, so a
#   copy in this file cannot drift from the shipped one.
#
#   Every static assertion is written to fail when the thing it looks for is
#   MISSING, not only when it is wrong: a guard that passes because it found
#   nothing to look at is worse than no guard.
#
# Offline: no network, no gh. jq and bash only.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=lib/skill-bash.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/skill-bash.sh"

SUBAGENT_MD="$REPO_ROOT/.claude/skills/subagent/SKILL.md"
BOARD_MD="$REPO_ROOT/.claude/skills/board/SKILL.md"
WAVE_MD="$REPO_ROOT/.claude/skills/wave/SKILL.md"
SCHEMA="$REPO_ROOT/.claude/reference/session-state-schema.json"
TIME_EST="$REPO_ROOT/.claude/reference/time-estimates.md"
CONTRACTS="$REPO_ROOT/.claude/reference/state-file-contracts.md"
FRESHNESS="$REPO_ROOT/.claude/scripts/table-freshness.sh"

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

echo "== premise: every file this suite reads exists =="
for f in "$SUBAGENT_MD" "$BOARD_MD" "$WAVE_MD" "$SCHEMA" "$TIME_EST" "$CONTRACTS" "$FRESHNESS"; do
  if [[ -r "$f" ]]; then
    check_eq "readable: ${f#"$REPO_ROOT"/}" "yes" "yes"
  else
    check_eq "readable: ${f#"$REPO_ROOT"/}" "yes" "no"
  fi
done
if [[ "$FAIL" -gt 0 ]]; then
  echo "== summary: $PASS passed, $FAIL failed =="
  exit 1
fi

echo
echo "== 1. schema: the round block is defined, commented, and deliberately untyped =="
check_eq "session-state-schema.json is valid JSON" "yes" \
  "$(jq -e . "$SCHEMA" >/dev/null 2>&1 && echo yes || echo no)"
ROUND_SHAPE="$(jq -r '
  (.repos | to_entries[0].value.round) as $r
  | if ($r | type) != "object" then "missing"
    elif ($r.members | type) != "array" then "members-not-array"
    elif ([$r.members[] | type] | unique) != ["string"] then "members-not-strings"
    elif ($r.dispatched_at | type) != "string" then "dispatched_at-not-string"
    else "ok" end' "$SCHEMA" 2>/dev/null)"
check_eq "repo-scoped .round has string members[] and a dispatched_at" "ok" "$ROUND_SHAPE"
check_eq "_round_comment documents the block" "1" \
  "$(jq -r '[.repos | to_entries[0].value | keys[] | select(. == "_round_comment")] | length' "$SCHEMA")"
# The comment is the only place the lifecycle is written down for a reader who
# arrives at the state file rather than at a skill, so pin the three roles.
COMMENT="$(jq -r '.repos | to_entries[0].value._round_comment' "$SCHEMA")"
for phrase in "Step 7.0" "/board" "teardown" "session-view"; do
  case "$COMMENT" in
    *"$phrase"*) check_eq "_round_comment names '$phrase'" "yes" "yes" ;;
    *)           check_eq "_round_comment names '$phrase'" "yes" "no" ;;
  esac
done
# A _field_types entry would be inert decoration that reads like a guard: the
# runtime contract loads top_level and pr_nested only (the `leave` precedent).
check_eq "no _field_types entry for round (repo-scoped blocks are unvalidatable)" "0" \
  "$(jq -r '[(._field_types // {}) | .. | strings | select(. == "round")] | length' "$SCHEMA")"

echo
echo "== 2. writer: /subagent Step 7.0 records the round, once, before the spawns =="
check_eq "Step 7.0 heading exists" "1" \
  "$(grep -c '^### 7\.0: Record the round.s membership' "$SUBAGENT_MD" || true)"
# Ordering is load-bearing: the record must be written before 7.1 spawns anything,
# so a /board run mid-dispatch never sees launched rows without their round.
L70="$(grep -n '^### 7\.0: Record the round' "$SUBAGENT_MD" | head -1 | cut -d: -f1)"
L71="$(grep -n '^### 7\.1: Record each pipeline' "$SUBAGENT_MD" | head -1 | cut -d: -f1)"
check_eq "7.0 precedes 7.1 in the file" "yes" \
  "$([[ -n "$L70" && -n "$L71" && "$L70" -lt "$L71" ]] && echo yes || echo no)"
check_eq "Step 7.0 writes the whole .round block in one compare-and-set" "1" \
  "$(grep -cF -- '--cas ".repos[\"$REPO_KEY\"].round={\"members\":${ROUND_MEMBERS},\"dispatched_at\":\"${ROUND_NOW}\",\"session\":\"${ROUND_SESSION}\"}"' "$SUBAGENT_MD" || true)"
# Scoped to 7.0's own range: the teardown reads the same path for its own CAS,
# so a file-wide count would pass on the wrong site alone.
check_eq "Step 7.0 reads the whole block before writing (the CAS compare value)" "1" \
  "$(sed -n "${L70},${L71}p" "$SUBAGENT_MD" | grep -cF -- '--get-json ".repos[\"$REPO_KEY\"].round"' || true)"
# A bare --set here would let this thread land on a sibling's round between the
# read and the write, and the loser would then tear down a record it never owned.
check_eq "no bare --set of .round anywhere in /subagent" "0" \
  "$(grep -cF -- '--set ".repos[\"$REPO_KEY\"].round=' "$SUBAGENT_MD" || true)"
# Never inline jq > tmp && mv: every session-state write goes through the helper.
check_eq "no inline jq write to session-state.json in Step 7.0" "0" \
  "$(sed -n "${L70},${L71}p" "$SUBAGENT_MD" | grep -c 'session-state\.json' || true)"

echo
echo "== 3. teardown: the round is cleared at round end, not at refill =="
check_eq "Step 8 clears .round to null under a compare-and-set" "1" \
  "$(grep -cF -- '--cas ".repos[\"$REPO_KEY\"].round=null"' "$SUBAGENT_MD" || true)"
# The clear must sit AFTER the --active 0 terminal board: same teardown site, so
# a reader cannot conclude the two are independent lifecycles.
L_TERMINAL="$(grep -n -- '--surface subagent-round-end' "$SUBAGENT_MD" | head -1 | cut -d: -f1)"
L_CLEAR="$(grep -nF '.round=null' "$SUBAGENT_MD" | head -1 | cut -d: -f1)"
check_eq "the clear sits with the round-end terminal board" "yes" \
  "$([[ -n "$L_TERMINAL" && -n "$L_CLEAR" && "$L_CLEAR" -gt "$L_TERMINAL" \
       && $((L_CLEAR - L_TERMINAL)) -lt 60 ]] && echo yes || echo no)"
check_eq "Step 8 states the refill path does not rewrite members" "yes" \
  "$(grep -qF 'Only the round'"'"'s END clears it' "$SUBAGENT_MD" && echo yes || echo no)"

echo
echo "== 4. reader: /board Step 3 derives both row classes from the record =="
check_eq "/board reads .round.members" "1" \
  "$(grep -cF -- '--get-json ".repos[\"$EFFECTIVE_REPO\"].round.members"' "$BOARD_MD" || true)"
check_eq "/board reads it per repo under --all-repos too" "1" \
  "$(grep -cF -- '--get-json ".repos[\"$RK\"].round.members"' "$BOARD_MD" || true)"
# The fallbacks must SURVIVE, conditionally: a round dispatched before the field
# existed still has to render, and deleting the bound would silently drop it.
check_eq "the timestamp bound survives as a no-record fallback" "yes" \
  "$(grep -qF 'With no record and no dispatch, fall back to a timestamp bound' "$BOARD_MD" \
     && echo yes || echo no)"
check_eq "the queued fallback is conditional on having no record" "yes" \
  "$(grep -qF 'Only when that repo has no round record' "$BOARD_MD" && echo yes || echo no)"
# A durable queue outlives the thread that wrote it, so it must not be able to
# hold a dead round open — the same evidence rule the pre-PR case already uses.
check_eq "a recorded queue alone does not open a round" "yes" \
  "$(grep -qF 'A recorded queue does not, by itself, open a round' "$BOARD_MD" && echo yes || echo no)"
# Matched on the unwrapped text: the sentence spans a line break in the source,
# so a whole-phrase grep would report a missing rule that is actually there.
check_eq "the no-round gate no longer counts queued rows as an opener" "1" \
  "$(tr '\n' ' ' < "$BOARD_MD" | grep -c -o 'Recorded queued members do not open a *round on their own' || true)"
# The qualifiers are the acceptance criterion nobody can grep for by accident:
# "approximate" and "unknown" must now be stated conditionally, not flatly.
check_eq "Queued is qualified conditionally" "yes" \
  "$(grep -qF '**Queued is exact**' "$BOARD_MD" && echo yes || echo no)"
check_eq "Delivered is qualified conditionally" "yes" \
  "$(grep -qF '**Delivered is exact**' "$BOARD_MD" && echo yes || echo no)"
check_eq "no unconditional 'Queued is unknown' bullet remains" "0" \
  "$(grep -cF -e '- **Queued is unknown**' "$BOARD_MD" || true)"
check_eq "no unconditional 'Delivered is approximate' bullet remains" "0" \
  "$(grep -cF -e '- **Delivered is approximate**' "$BOARD_MD" || true)"

echo
echo "== 5. /wave deliberately writes nothing, and says why =="
check_eq "/wave states it writes no round record" "yes" \
  "$(grep -qF '/wave` writes no round-membership record' "$WAVE_MD" && echo yes || echo no)"
check_eq "/wave never actually writes .round" "0" \
  "$(grep -c '\.round\.members=\|\.round=' "$WAVE_MD" || true)"

echo
echo "== 6. the cross-referenced 'no durable field' rationale is reconciled =="
# These three files justified a caller-declared count with a claim this issue
# retires. The count stays caller-declared — for a different, still-true reason.
for f in "$FRESHNESS" "$SUBAGENT_MD" "$BOARD_MD" "$TIME_EST"; do
  check_eq "no stale 'no durable field tracks queued issues' in ${f#"$REPO_ROOT"/}" "0" \
    "$(grep -c 'no durable field tracks queued issues' "$f" || true)"
done
check_eq "table-freshness.sh names the durable record" "yes" \
  "$(grep -qF 'round.members' "$FRESHNESS" && echo yes || echo no)"
check_eq "table-freshness.sh keeps --active caller-declared" "yes" \
  "$(grep -qF 'stays an argument' "$FRESHNESS" && echo yes || echo no)"
check_eq "time-estimates.md documents the field beside the pipelines contract" "1" \
  "$(grep -c '^### Round membership comes from state too' "$TIME_EST" || true)"
check_eq "state-file-contracts.md records the field-change rationale" "1" \
  "$(grep -c '^#### Second pass: `.repos\["<key>"\].round`' "$CONTRACTS" || true)"

echo
echo "== 7. EXECUTED: /subagent Step 7.0's real block against a stub state file =="
WRITE_BLOCK="$(extract_skill_bash "$SUBAGENT_MD" subagent-step7-round-membership-write)" || {
  echo "FAIL — could not extract the Step 7.0 block"; FAIL=$((FAIL + 1))
  echo "== summary: $PASS passed, $FAIL failed =="; exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub session-state.sh: the same three modes the block uses, backed by a real
# JSON file so a write made by one assertion is read back by the next.
cat > "$TMP/session-state.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
STATE="${STUB_STATE_FILE:?}"
case "${1:-}" in
  --repo-key)  printf '%s\n' "${STUB_REPO_KEY:-owner/repo}"; exit 0 ;;
  --get-json)
    OUT="$(jq -c "${2:?}" "$STATE" 2>/dev/null)" || exit 4
    printf '%s\n' "$OUT"
    # STUB_RACE_JSON simulates a SIBLING THREAD writing between this read and
    # the caller's CAS — the exact gap the compare exists to close. Each stub
    # call is its own process, so the once-only latch is a marker FILE, not an
    # unset: without it every later read would re-race and the scenario would
    # be testing something else.
    if [ -n "${STUB_RACE_JSON:-}" ] && [ ! -f "$STATE.raced" ]; then
      : > "$STATE.raced"
      jq ".repos[\"${STUB_REPO_KEY:-owner/repo}\"].round = (${STUB_RACE_JSON})" \
        "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    fi
    exit 0 ;;
  --set)
    ARG="${2:?}"; P="${ARG%%=*}"; V="${ARG#*=}"
    echo "SET $P" >> "${STUB_STATE_FILE}.calls"
    jq "${P} = (${V})" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    exit 0 ;;
  --cas)
    ARG="${2:?}"; P="${ARG%%=*}"; V="${ARG#*=}"
    [ "${3:-}" = "--expect" ] || { echo "stub: --cas requires --expect" >&2; exit 2; }
    EXPECT="${4-}"
    echo "CAS $P" >> "${STUB_STATE_FILE}.calls"
    # Exit 7 on mismatch, the real script's CAS-loss code — distinct from an
    # I/O error so the caller can tell "someone else won" from "write failed".
    jq -e --argjson want "$EXPECT" "(${P}) == \$want" "$STATE" >/dev/null 2>&1 || exit 7
    jq "${P} = (${V})" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    exit 0 ;;
  *) echo "stub: unsupported mode ${1:-}" >&2; exit 2 ;;
esac
STUB
chmod +x "$TMP/session-state.sh"

# The block declares ROUND_ISSUES with a placeholder for the caller to fill, the
# same shape ACTIVE_COUNT uses. Substitute a real round; assert the substitution
# happened, so a renamed variable cannot make every scenario below vacuous.
printf '%s\n' "$WRITE_BLOCK" \
  | sed 's/^\([[:space:]]*\)ROUND_ISSUES=(<.*$/\1ROUND_ISSUES=(${SCENARIO_ISSUES})/' \
  > "$TMP/write-block.sh"
check_eq "the ROUND_ISSUES placeholder was substituted" "1" \
  "$(grep -c 'ROUND_ISSUES=(\${SCENARIO_ISSUES})' "$TMP/write-block.sh" || true)"

run_write() {  # run_write <initial-state-json> <issues...>
  local initial="$1"; shift
  printf '%s' "$initial" > "$TMP/state.json"
  rm -f "$TMP/state.json.calls" "$TMP/state.json.raced"
  STUB_STATE_FILE="$TMP/state.json" \
  SCENARIO_ISSUES="$*" \
  SESSION_STATE_SH="$TMP/session-state.sh" \
  STUB_REPO_KEY="${STUB_REPO_KEY:-owner/repo}" \
  STUB_RACE_JSON="${STUB_RACE_JSON:-}" \
  CLAUDE_SESSION_ID="${CLAUDE_SESSION_ID:-sess-self}" \
    bash "$TMP/write-block.sh" 2>"$TMP/err" >"$TMP/out"
}

echo "-- 7a. no record yet -> the round is written"
run_write '{"repos":{"owner/repo":{}}}' 1604 1607 1612
check_eq "members recorded in execution order, as strings" '["1604","1607","1612"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"
check_eq "dispatched_at is an ISO-8601 UTC instant" "yes" \
  "$(grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
       <<<"$(jq -r '.repos["owner/repo"].round.dispatched_at' "$TMP/state.json")" \
     && echo yes || echo no)"

echo "-- 7b. re-entry (the SAME round re-running the step) -> the record STANDS"
run_write '{"repos":{"owner/repo":{"round":{"members":["1604","1607","1612"],"dispatched_at":"2026-09-02T18:38:00Z"}}}}' 1604 1607 1612
check_eq "dispatched_at still names the ORIGINAL dispatch" "2026-09-02T18:38:00Z" \
  "$(jq -r '.repos["owner/repo"].round.dispatched_at' "$TMP/state.json")"
check_eq "members untouched by a re-entered dispatch" '["1604","1607","1612"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"
# The calls log is only created BY a write, so its absence is the assertion —
# counted rather than existence-tested so a partial write cannot read as none.
CALL_COUNT=0
[[ -f "$TMP/state.json.calls" ]] && CALL_COUNT="$(wc -l < "$TMP/state.json.calls" | tr -d '[:space:]')"
check_eq "no write was issued at all" "0" "$CALL_COUNT"

echo "-- 7b2. the SAME round, RE-PLANNED order -> members refreshed, clock kept"
# `members` carries the queue ORDER that /board Step 3 reads back verbatim, so a
# re-entry whose execution order changed must refresh the order — while
# `dispatched_at` keeps naming the original dispatch, since the round did not
# restart. Neither "leave it" nor "replace the block" does both.
run_write '{"repos":{"owner/repo":{"round":{"members":["1604","1607","1612"],"dispatched_at":"2026-09-02T18:38:00Z","session":"sess-self"}}}}' 1612 1604 1607
check_eq "the recorded order is the new execution order" '["1612","1604","1607"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"
check_eq "the round's start did NOT move" "2026-09-02T18:38:00Z" \
  "$(jq -r '.repos["owner/repo"].round.dispatched_at' "$TMP/state.json")"
check_eq "attribution survives the refresh" "sess-self" \
  "$(jq -r '.repos["owner/repo"].round.session' "$TMP/state.json")"
check_eq "the refresh is a compare-and-set, never a plain set" "1" \
  "$(grep -c '^CAS ' "$TMP/state.json.calls" 2>/dev/null || echo 0)"
# Control: a set-equality identity check alone reports "same round" on this
# fixture, which is why the order comparison had to be added beside it.
check_eq "control: set equality alone calls the re-ordered round unchanged" "yes" \
  "$(printf '%s' '["1604","1607","1612"]' \
     | jq -e --argjson now '["1612","1604","1607"]' \
       '(((. - $now) | length) == 0) and ((($now - .) | length) == 0)' >/dev/null 2>&1 \
     && echo yes || echo no)"

echo "-- 7c. a DIFFERENT round left behind -> replaced wholesale, never merged"
run_write '{"repos":{"owner/repo":{"round":{"members":["1500","1501"],"dispatched_at":"2026-08-01T10:00:00Z"}}}}' 1604 1607
check_eq "the stale round's members are gone" '["1604","1607"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"
check_eq "dispatched_at is re-stamped for the new round" "no" \
  "$(jq -r '.repos["owner/repo"].round.dispatched_at == "2026-08-01T10:00:00Z"' "$TMP/state.json" \
     | sed 's/true/yes/;s/false/no/')"

echo "-- 7c2. a stale SUPERSET is not this round -> replaced, not reused"
# The regression: a subset test ("every issue dispatched now is already a
# member") reads a dead round's larger list as the same round, and /board then
# renders two retired issues as this round's queue. Set equality is the identity.
run_write '{"repos":{"owner/repo":{"round":{"members":["1500","1501","1604"],"dispatched_at":"2026-08-01T10:00:00Z"}}}}' 1604
check_eq "the superset's extra members do not survive into the new round" '["1604"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"
check_eq "dispatched_at is re-stamped rather than inherited from the dead round" "no" \
  "$(jq -r '.repos["owner/repo"].round.dispatched_at == "2026-08-01T10:00:00Z"' "$TMP/state.json" \
     | sed 's/true/yes/;s/false/no/')"

# Negative control: the pre-fix containment predicate, run on the SAME fixture,
# reports "same round" — proving 7c2 above is testing the fix rather than passing
# for some incidental reason, and that the shipped block no longer uses it.
check_eq "control: the containment predicate would have reused the stale superset" "yes" \
  "$(printf '%s' '["1500","1501","1604"]' \
     | jq -e --argjson now '["1604"]' '(($now - .) | length) == 0' >/dev/null 2>&1 \
     && echo yes || echo no)"
# Both directions of the difference must appear in 7.0's guard; either one alone
# is a containment test wearing an equality's clothes.
check_eq "the shipped guard subtracts in BOTH directions (set equality)" "yes" \
  "$(grep -qF '((.members - $now) | length) == 0' <<<"$(sed -n "${L70},${L71}p" "$SUBAGENT_MD")" \
     && grep -qF '(($now - .members) | length) == 0' <<<"$(sed -n "${L70},${L71}p" "$SUBAGENT_MD")" \
     && echo yes || echo no)"

echo "-- 7c3. a round that GREW is a different round -> replaced"
run_write '{"repos":{"owner/repo":{"round":{"members":["1604"],"dispatched_at":"2026-08-01T10:00:00Z"}}}}' 1604 1607
check_eq "the recorded round is the one being dispatched now" '["1604","1607"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"

echo "-- 7d. unresolvable repo key -> DEGRADED, and nothing is written"
STUB_REPO_KEY="_unknown" run_write '{"repos":{}}' 1604
# A prefix assignment on a FUNCTION call persists in bash's default mode, so every
# scenario variable is unset the moment its scenario ends. Left set, `_unknown`
# would silently make every later case take the unresolved-repo branch and pass
# for the wrong reason — the canary below is what proves the unset worked.
unset STUB_REPO_KEY
check_eq "a DEGRADED line names the lost record" "yes" \
  "$(grep -q '^DEGRADED: repo key unresolved' "$TMP/out" && echo yes || echo no)"
check_eq "no round written under the _unknown sentinel" "null" \
  "$(jq -c '.repos["_unknown"].round // "null"' "$TMP/state.json" | tr -d '"')"

echo "-- 7d2. the record carries the writing session, and replacing another's is visible"
CLAUDE_SESSION_ID="sess-B" run_write \
  '{"repos":{"owner/repo":{"round":{"members":["1500"],"dispatched_at":"2026-08-01T10:00:00Z","session":"sess-A"}}}}' 1604
check_eq "the new record is attributed to the writing session" "sess-B" \
  "$(jq -r '.repos["owner/repo"].round.session' "$TMP/state.json")"
check_eq "replacing another session's round is reported, not silent" "yes" \
  "$(grep -q 'replacing a round recorded by session sess-A' "$TMP/out" && echo yes || echo no)"
# Not a DEGRADED: replacing a corpse is the right default, and the common cause
# is a dead thread whose teardown never ran. Refusing would let that corpse
# describe every future round this repo dispatches.
check_eq "…and is a NOTE rather than a degradation" "0" \
  "$(grep -c 'DEGRADED' "$TMP/out" || true)"
# A prefix assignment on a FUNCTION call persists in bash's default mode, so
# clear it explicitly — otherwise every scenario below would silently run as
# sess-B and the ownership assertions would be testing one session, not two.
echo "-- 7d3. equal members, ANOTHER session -> not re-entry; recorded as ours"
CLAUDE_SESSION_ID="sess-B" run_write \
  '{"repos":{"owner/repo":{"round":{"members":["1604","1607"],"dispatched_at":"2026-08-01T10:00:00Z","session":"sess-A"}}}}' 1604 1607
check_eq "membership alone is not identity — the round is re-attributed" "sess-B" \
  "$(jq -r '.repos["owner/repo"].round.session' "$TMP/state.json")"
check_eq "and its dispatch time is this dispatch's, not the other session's" "no" \
  "$(jq -r '.repos["owner/repo"].round.dispatched_at == "2026-08-01T10:00:00Z"' "$TMP/state.json" \
     | sed 's/true/yes/;s/false/no/')"
unset CLAUDE_SESSION_ID

echo "-- 7d4. equal members, NO recorded session -> a pre-attribution record, left alone"
run_write \
  '{"repos":{"owner/repo":{"round":{"members":["1604","1607"],"dispatched_at":"2026-08-01T10:00:00Z"}}}}' 1604 1607
check_eq "a legacy record is treated as re-entry, not churned" "2026-08-01T10:00:00Z" \
  "$(jq -r '.repos["owner/repo"].round.dispatched_at' "$TMP/state.json")"

echo "-- 7e. a concurrent dispatch wins the slot -> CAS loss, no overwrite"
# Canary for the unset above: if `_unknown` had leaked out of 7d, this write
# would take the unresolved-repo branch and every assertion in 7e would pass
# against an empty state instead of a raced one.
run_write '{"repos":{"owner/repo":{}}}' 1604
check_eq "canary: scenario env did not leak out of 7d" '["1604"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"
# The sibling lands its round in the gap between this block's read and its write.
# The compare must refuse: two threads dispatching into one repo must not silently
# take each other's round record, and the loser must not tear one down later.
STUB_RACE_JSON='{"members":["2001","2002"],"dispatched_at":"2026-09-10T12:00:00Z"}' \
  run_write '{"repos":{"owner/repo":{}}}' 1604 1607
check_eq "the winner's round is untouched" '["2001","2002"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"
check_eq "the loser says so instead of silently proceeding" "yes" \
  "$(grep -q 'another dispatch recorded a round for this repo first' "$TMP/out" && echo yes || echo no)"
check_eq "the loser attempted exactly one compare-and-set and no plain set" "1" \
  "$(grep -c '^CAS ' "$TMP/state.json.calls" 2>/dev/null || echo 0)"
# The loser must still DISPATCH. This record is display state for /board; a
# non-zero exit here would make a losing race look like a failed launch step and
# invite gating real work on it — the same trade 7.3 refuses for the freshness
# clock. run_write returns the block's own status.
STUB_RACE_JSON='{"members":["2001","2002"],"dispatched_at":"2026-09-10T12:00:00Z"}' \
  run_write '{"repos":{"owner/repo":{}}}' 1604 1607
check_eq "a CAS loss does not fail the dispatch step" "0" "$?"
unset STUB_RACE_JSON

echo
echo "== 8. EXECUTED: /subagent Step 8's real teardown clear =="
CLEAR_BLOCK="$(extract_skill_bash "$SUBAGENT_MD" subagent-step8-round-teardown-clear)" || {
  echo "FAIL — could not extract the Step 8 teardown block"; FAIL=$((FAIL + 1))
  echo "== summary: $PASS passed, $FAIL failed =="; exit 1
}
# The block declares ENDED_ROUND_ISSUES with a caller placeholder, the same
# shape 7.0's ROUND_ISSUES uses. Substitute it, and assert the substitution
# landed — so a renamed variable cannot make every teardown scenario vacuous,
# and so this suite can no longer SUPPLY the variable the shipped block forgot
# to declare, which is what hid its no-op teardown.
printf '%s\n' "$CLEAR_BLOCK" \
  | sed 's/^\([[:space:]]*\)ENDED_ROUND_ISSUES=(<.*$/\1ENDED_ROUND_ISSUES=(${SCENARIO_ENDED})/' \
  > "$TMP/clear-block.sh"
check_eq "the ENDED_ROUND_ISSUES placeholder was substituted" "1" \
  "$(grep -c 'ENDED_ROUND_ISSUES=(\${SCENARIO_ENDED})' "$TMP/clear-block.sh" || true)"
# The shipped block must DECLARE the array itself. While it merely referenced
# one, this suite's own preamble supplied it and every teardown assertion passed
# against a variable a real caller never sets.
check_eq "the shipped block declares the array rather than assuming a caller variable" "1" \
  "$(grep -c '^[[:space:]]*ENDED_ROUND_ISSUES=(' "$TMP/clear-block.sh" || true)"

run_clear() {  # run_clear <initial-state-json> <ended-issues...>
  local initial="$1"; shift
  printf '%s' "$initial" > "$TMP/state.json"
  rm -f "$TMP/state.json.calls" "$TMP/state.json.raced"
  local issues="$*"
  {
    echo 'REPO_KEY="owner/repo"'
    cat "$TMP/clear-block.sh"
  } > "$TMP/clear-run.sh"
  STUB_STATE_FILE="$TMP/state.json" \
  SCENARIO_ENDED="$issues" \
  SESSION_STATE_SH="$TMP/session-state.sh" \
  STUB_REPO_KEY="owner/repo" \
  STUB_RACE_JSON="${STUB_RACE_JSON:-}" \
  CLAUDE_SESSION_ID="${CLAUDE_SESSION_ID:-sess-self}" \
    bash "$TMP/clear-run.sh" 2>"$TMP/err" >"$TMP/out"
}

echo "-- 8a. the round on disk is the one that just ended -> cleared"
run_clear '{"repos":{"owner/repo":{"round":{"members":["1604","1607"],"dispatched_at":"2026-09-02T18:38:00Z"}}}}' 1604 1607
check_eq "the finished round is cleared to null" "null" \
  "$(jq -c '.repos["owner/repo"].round' "$TMP/state.json")"

echo "-- 8b. a SIBLING's newer round is on disk -> left alone, silently"
run_clear '{"repos":{"owner/repo":{"round":{"members":["2001","2002"],"dispatched_at":"2026-09-10T12:00:00Z"}}}}' 1604 1607
check_eq "the sibling's live round survives this thread's teardown" '["2001","2002"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"
check_eq "no write was attempted against a round this thread does not own" "0" \
  "$([[ -f "$TMP/state.json.calls" ]] && wc -l < "$TMP/state.json.calls" | tr -d '[:space:]' || echo 0)"
check_eq "not reported as a degradation — leaving it is correct" "0" \
  "$(grep -c 'DEGRADED' "$TMP/out" || true)"

echo "-- 8b2. same members, ANOTHER session's record -> still not ours to clear"
# Membership alone is not identity when two threads can dispatch the same issues
# (a re-picked queue, a duplicated batch). Attribution decides.
run_clear '{"repos":{"owner/repo":{"round":{"members":["1604","1607"],"dispatched_at":"2026-09-10T12:00:00Z","session":"sess-other"}}}}' 1604 1607
check_eq "another session's identically-membered round survives" "sess-other" \
  "$(jq -r '.repos["owner/repo"].round.session' "$TMP/state.json")"

echo "-- 8c. the record changes between the read and the clear -> refused, named"
STUB_RACE_JSON='{"members":["2001"],"dispatched_at":"2026-09-10T12:00:00Z"}' \
  run_clear '{"repos":{"owner/repo":{"round":{"members":["1604"],"dispatched_at":"2026-09-02T18:38:00Z"}}}}' 1604
check_eq "the raced-in round is not cleared" '["2001"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"
check_eq "the refusal is reported" "yes" \
  "$(grep -q 'changed while this round was being torn down' "$TMP/out" && echo yes || echo no)"
unset STUB_RACE_JSON

echo "-- 8d. nothing recorded -> nothing to clear, and no error"
run_clear '{"repos":{"owner/repo":{}}}' 1604
check_eq "an absent round is a no-op" "0" \
  "$([[ -f "$TMP/state.json.calls" ]] && wc -l < "$TMP/state.json.calls" | tr -d '[:space:]' || echo 0)"

echo "-- 8e. the ended list was never supplied -> DEGRADED, and nothing is cleared"
# An unfilled placeholder is not an empty round: "${arr[@]}" on an empty array
# expands to ONE empty string, so the derived membership is [""], which matches
# no record — and an unguarded block then takes the SILENT not-ours branch and
# leaves the finished round on disk for the next /board to render as current.
run_clear '{"repos":{"owner/repo":{"round":{"members":["1604","1607"],"dispatched_at":"2026-09-02T18:38:00Z"}}}}'
check_eq "the unfilled list is reported rather than skipped silently" "yes" \
  "$(grep -q 'DEGRADED: the ended round issue list was not supplied' "$TMP/out" && echo yes || echo no)"
check_eq "no write is attempted against an unknown membership" "0" \
  "$([[ -f "$TMP/state.json.calls" ]] && wc -l < "$TMP/state.json.calls" | tr -d '[:space:]' || echo 0)"
check_eq "the round is left intact for a teardown that knows its members" '["1604","1607"]' \
  "$(jq -c '.repos["owner/repo"].round.members' "$TMP/state.json")"
# Control: the derivation itself, unguarded, yields [""] and not [] — so 8e is
# testing the guard rather than passing because an empty list is harmless.
check_eq "control: the unguarded derivation yields a one-empty-string array" '[""]' \
  "$(printf '%s\n' "${UNSET_ENDED_ARRAY[@]:-}" | jq -R . | jq -s -c .)"

echo
echo "== 9. EXECUTED: /board Step 3's real queued-row derivation =="
QUEUE_BLOCK="$(extract_skill_bash "$BOARD_MD" board-step3-queued-from-round)" || {
  echo "FAIL — could not extract the /board queued block"; FAIL=$((FAIL + 1))
  echo "== summary: $PASS passed, $FAIL failed =="; exit 1
}
printf '%s\n%s\n' "$QUEUE_BLOCK" 'printf "%s\n" "$QUEUED_ISSUES"' > "$TMP/queue-block.sh"

run_queue() {  # run_queue <members-json> <pipelines-json-or-empty>
  ROW_ROUND_MEMBERS="$1" ROW_PIPELINES="$2" bash "$TMP/queue-block.sh" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'
}
check_eq "members with no started_at are the queued rows, in recorded order" "1607 1612" \
  "$(run_queue '["1604","1607","1612"]' '{"1604":{"started_at":"2026-09-02T18:38:00Z","pr":1610}}')"
check_eq "a promoted member drops out of the queue without members changing" "1612" \
  "$(run_queue '["1604","1607","1612"]' '{"1604":{"started_at":"A"},"1607":{"started_at":"B"}}')"
check_eq "an all-launched round yields no queued rows" "" \
  "$(run_queue '["1604"]' '{"1604":{"started_at":"A"}}')"
check_eq "an empty pipelines block leaves every member queued" "1604 1607" \
  "$(run_queue '["1604","1607"]' '')"
# The negative control: a pipelines entry with NO started_at (a `.pr`-only
# record) must still read as queued, or the derivation would be testing
# key-presence rather than the launch record.
check_eq "a pipelines entry without started_at still counts as queued" "1604" \
  "$(run_queue '["1604"]' '{"1604":{"pr":1610}}')"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
