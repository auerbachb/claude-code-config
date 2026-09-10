#!/usr/bin/env bash
# Unit + concurrency tests for handoff-state.sh (issue #682 —
# handoff files had the same unlocked RMW profile session-state.json had before #639;
# concurrent orchestrators (/babysit-pr, /pr-monitor-and-manage, Phase B) silently lost
# each other's array appends when they all read-modify-wrote at once).
# catalog: tests — Tests for `handoff-state.sh`
#
# Uses a temporary HOME so it never touches the real ~/.claude/. Requires jq.
# Run from repo root:
#   bash .claude/scripts/tests/handoff-state.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/handoff-state.sh"
LOCK_LIB="$REPO_ROOT/.claude/scripts/state-lock.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not found" >&2; exit 1
fi
if [[ ! -f "$LOCK_LIB" ]]; then
  echo "FAIL: $LOCK_LIB not found" >&2; exit 1
fi

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude/handoffs"

PR="99"
HANDOFF_FILE="$HOME/.claude/handoffs/pr-${PR}-handoff.json"
LOCK_DIR="$HANDOFF_FILE.lock"

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

# --legacy-flat on every call (issue #1366): this suite asserts against the flat
# HANDOFF_FILE above, and an omitted scope no longer means "flat" — it derives
# owner/repo from the cwd (this checkout) or exits 2. Path scoping is
# handoff-scoping.test.sh's subject; locking, RMW, and dedup semantics are this
# one's, and they are identical on either path. Declaring the flat path also
# keeps a standing assertion that --legacy-flat reaches it for the modes this
# suite exercises — --create, --init, --get, --set, --append, --delete, and the
# unknown-mode rejection. It does NOT cover --path: that mode returns before any
# lock or write, and its --legacy-flat assertion lives in handoff-scoping.test.sh
# (test 1), so claiming "every mode" here would let a --legacy-flat --path
# regression pass this suite unnoticed (CodeAnt, PR #1423).
run() { bash "$SCRIPT" --legacy-flat "$@"; }
reset_handoff() { rm -rf "$HANDOFF_FILE" "$LOCK_DIR"; }

SEED_JSON='{"schema_version":"1.0","pr_number":99,"head_sha":"aaa","reviewer":"cr",
  "phase_completed":"A","created_at":"2026-01-01T00:00:00Z",
  "findings_fixed":[],"findings_dismissed":[],
  "threads_replied":[],"threads_resolved":[],
  "files_changed":[],"push_timestamp":"2026-01-01T00:00:00Z","notes":""}'

echo "== --create: writes valid JSON =="
reset_handoff
run --create "$PR" "$SEED_JSON"
check_eq "--create exits 0" "0" "$?"
check_eq "file exists after --create" "1" "$([[ -f "$HANDOFF_FILE" ]] && echo 1 || echo 0)"
check_eq "file is valid JSON" "0" "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"
check_eq "pr_number round-trips" "99" "$(jq -r '.pr_number' "$HANDOFF_FILE")"

echo
echo "== --get: lock-free read returns the file =="
reset_handoff
run --create "$PR" "$SEED_JSON"
GOT="$(run --get "$PR")"
check_eq "--get exits 0 when file exists" "0" "$?"
check_eq "--get returns valid JSON" "0" "$(printf '%s' "$GOT" | jq -e . >/dev/null 2>&1; echo $?)"
check_eq "--get on missing file exits 3" "3" "$(run --get "999" 2>/dev/null; echo $?)"

echo
echo "== --set: locked scalar update =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --set "$PR" ".head_sha=bbb"
check_eq "--set exits 0" "0" "$?"
check_eq ".head_sha updated" "bbb" "$(jq -r '.head_sha' "$HANDOFF_FILE")"
check_eq "other fields preserved after --set" "99" "$(jq -r '.pr_number' "$HANDOFF_FILE")"

echo
echo "== --append: string arrays dedup by exact value =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --append "$PR" "findings_fixed" '"fix-1"'
run --append "$PR" "findings_fixed" '"fix-2"'
run --append "$PR" "findings_fixed" '"fix-1"'   # duplicate — should be deduplicated
check_eq "--append exits 0" "0" "$?"
check_eq "string array deduped to 2 elements" "2" \
  "$(jq '.findings_fixed | length' "$HANDOFF_FILE")"
check_eq "fix-1 present" "fix-1" \
  "$(jq -r '.findings_fixed[0]' "$HANDOFF_FILE")"
check_eq "fix-2 present" "fix-2" \
  "$(jq -r '.findings_fixed[1]' "$HANDOFF_FILE")"

echo
echo "== --append findings_dismissed: dedup by .id =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --append "$PR" "findings_dismissed" '{"id":"fd-1","reason":"false positive"}'
run --append "$PR" "findings_dismissed" '{"id":"fd-2","reason":"out of scope"}'
run --append "$PR" "findings_dismissed" '{"id":"fd-1","reason":"updated reason"}'  # same id, dedup
check_eq "findings_dismissed deduped to 2 elements (by .id)" "2" \
  "$(jq '.findings_dismissed | length' "$HANDOFF_FILE")"
IDS="$(jq -r '[.findings_dismissed[].id] | sort | join(",")' "$HANDOFF_FILE")"
check_eq "both .id values present" "fd-1,fd-2" "$IDS"

echo
echo "== --delete: removes the file, idempotent =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --delete "$PR"
check_eq "--delete exits 0" "0" "$?"
check_eq "file absent after --delete" "0" "$([[ -f "$HANDOFF_FILE" ]] && echo 1 || echo 0)"
run --delete "$PR"   # second delete: idempotent
check_eq "--delete again exits 0 (idempotent)" "0" "$?"

echo
echo "== Two concurrent --append writers: both appends survive =="
reset_handoff
run --create "$PR" "$SEED_JSON"
# Two writers race to append different values to the same string array.
# Without the lock, one append would be lost; with it, both must survive.
( run --append "$PR" "threads_replied" '"thread-alpha"' ) &
( run --append "$PR" "threads_replied" '"thread-beta"' ) &
wait
COUNT="$(jq '.threads_replied | length' "$HANDOFF_FILE")"
check_eq "both concurrent appends survived (length=2)" "2" "$COUNT"
VALS="$(jq -r '.threads_replied | sort | join(",")' "$HANDOFF_FILE")"
check_eq "thread-alpha present" "1" "$(grep -c 'thread-alpha' <<<"$VALS")"
check_eq "thread-beta present" "1" "$(grep -c 'thread-beta' <<<"$VALS")"
check_eq "file is still valid JSON after concurrent writes" "0" \
  "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"

echo
echo "== 20 concurrent --append writers: all appends present =="
reset_handoff
run --create "$PR" "$SEED_JSON"
RC_LOG="$TMP_HOME/rc.log"
: > "$RC_LOG"
for i in $(seq 1 20); do
  ( CLAUDE_STATE_LOCK_TIMEOUT=120 run --append "$PR" "files_changed" "\"file-${i}.sh\""; \
    echo "$?" >> "$RC_LOG" ) &
done
wait
check_eq "every concurrent --append exited 0" "" \
  "$(grep -v '^0$' "$RC_LOG" | tr '\n' ' ' | sed 's/ $//')"
check_eq "file is valid JSON after 20 concurrent appends" "0" \
  "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"
check_eq "all 20 unique filenames present" "20" \
  "$(jq '.files_changed | length' "$HANDOFF_FILE")"

echo
echo "== Holder killed mid-write: lock is recoverable, handoff intact =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --set "$PR" ".notes=before_kill"
bash -c 'source "$1"; state_lock_acquire "$2" || exit 6; printf "held\n" > "$3"; sleep 60' \
  _ "$LOCK_LIB" "$HANDOFF_FILE" "$TMP_HOME/held" &
HOLDER=$!
for _ in $(seq 1 100); do [[ -f "$TMP_HOME/held" ]] && break; sleep 0.05; done
check_eq "lock directory exists while held" "1" \
  "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
kill -9 "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
OUT="$(CLAUDE_STATE_LOCK_TIMEOUT=5 run --set "$PR" ".notes=after_kill" 2>&1)"; RC=$?
check_eq "next writer recovers the stale lock (exit 0)" "0" "$RC"
check_eq "stale-break reported on stderr" "1" "$(grep -c 'broke stale lock' <<<"$OUT")"
check_eq "new write landed" "after_kill" "$(jq -r '.notes' "$HANDOFF_FILE")"
check_eq "handoff file still valid JSON" "0" \
  "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"

echo
echo "== Lock timeout: exit 6, handoff file unmodified =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --set "$PR" ".notes=untouched"
# cmp(1) against a real file, NOT $(cat ...): command substitution strips
# trailing newlines, so a write that changed only those bytes would pass an
# assertion whose whole point is byte identity (issue #1531 — the same pattern
# PR #1500 introduced for its own assertions below).
LOCK_TIMEOUT_BEFORE="$TMP_HOME/before-lock-timeout.json"
cp "$HANDOFF_FILE" "$LOCK_TIMEOUT_BEFORE"
mkdir -p "$LOCK_DIR"
{
  printf 'pid=%s\n' "$$"
  printf 'host=%s\n' "$(hostname)"
  printf 'epoch=%s\n' "$(date +%s)"
} > "$LOCK_DIR/owner"
OUT="$(CLAUDE_STATE_LOCK_TIMEOUT=1 run --set "$PR" ".notes=should_not_land" 2>&1)"; RC=$?
check_eq "timed-out writer exits 6" "6" "$RC"
check_eq "handoff file byte-identical after timeout" "0" \
  "$(cmp -s "$LOCK_TIMEOUT_BEFORE" "$HANDOFF_FILE"; echo $?)"
check_eq "live holder's lock NOT broken" "1" "$([[ -d "$LOCK_DIR" ]] && echo 1 || echo 0)"
rm -rf "$LOCK_DIR"

# Negative control for the assertion above: the comparator must SEE a
# trailing-newline-only difference, and the retired cat-substitution idiom must
# not. Without this pair, "byte-identical after timeout" could pass vacuously
# against a write that touched only those bytes (issue #1531).
NL_CONTROL_A="$TMP_HOME/nl-control-a.json"
NL_CONTROL_B="$TMP_HOME/nl-control-b.json"
cp "$HANDOFF_FILE" "$NL_CONTROL_A"
cp "$NL_CONTROL_A" "$NL_CONTROL_B"
printf '\n' >> "$NL_CONTROL_B"
check_eq "cmp -s catches a trailing-newline-only difference" "1" \
  "$(cmp -s "$NL_CONTROL_A" "$NL_CONTROL_B"; echo $?)"
check_eq "the retired cat-substitution idiom is blind to it" "blind" \
  "$([[ "$(cat "$NL_CONTROL_A")" == "$(cat "$NL_CONTROL_B")" ]] && echo blind || echo sees)"

echo
echo "== --init: create-if-absent (no-op when file exists) =="
reset_handoff
run --init "$PR" "$SEED_JSON"
check_eq "--init exits 0 (file absent)" "0" "$?"
check_eq "file created by --init" "1" "$([[ -f "$HANDOFF_FILE" ]] && echo 1 || echo 0)"
check_eq "--init creates valid JSON" "0" "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"
check_eq "--init pr_number correct" "99" "$(jq -r '.pr_number' "$HANDOFF_FILE")"
# Now overwrite with different content and confirm --init is a no-op
run --set "$PR" ".notes=already_exists"
run --init "$PR" "$SEED_JSON"
check_eq "--init exits 0 when file exists (no-op)" "0" "$?"
check_eq "--init preserves existing content" "already_exists" "$(jq -r '.notes' "$HANDOFF_FILE")"

echo
echo "== --init: concurrent race — Phase A beats checkpoint =="
reset_handoff
# Simulate: two concurrent --init calls; first one wins, second is a no-op.
( run --init "$PR" "$SEED_JSON" ) &
( run --init "$PR" "$(jq -n --argjson s "$SEED_JSON" '$s | .notes = "phase_a_data"')" ) &
wait
check_eq "file valid JSON after concurrent --init" "0" \
  "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"
check_eq "exactly one --init won, file has pr_number 99" "99" "$(jq -r '.pr_number' "$HANDOFF_FILE")"

echo
echo "== --append: numeric IDs stored as strings (not JSON numbers) =="
reset_handoff
run --create "$PR" "$SEED_JSON"
run --append "$PR" "findings_fixed" "1734629876"
check_eq "--append numeric ID exits 0" "0" "$?"
check_eq "numeric ID stored as string type" "string" \
  "$(jq -r '.findings_fixed[0] | type' "$HANDOFF_FILE")"
check_eq "numeric ID value correct as string" "1734629876" \
  "$(jq -r '.findings_fixed[0]' "$HANDOFF_FILE")"
# Ensure dedup still works for string-coerced numerics
run --append "$PR" "findings_fixed" "1734629876"
check_eq "duplicate numeric ID deduped" "1" \
  "$(jq '.findings_fixed | length' "$HANDOFF_FILE")"
# Quoted JSON string IDs still work
run --append "$PR" "findings_fixed" '"abc-id-1"'
check_eq "quoted JSON string ID stored correctly" "abc-id-1" \
  "$(jq -r '.findings_fixed[1]' "$HANDOFF_FILE")"
check_eq "quoted JSON string ID is string type" "string" \
  "$(jq -r '.findings_fixed[1] | type' "$HANDOFF_FILE")"

echo
echo "== --set: type coercion (JSON literal vs bare string) =="
# Issue #853: the --set literal-vs-string detection used `jq -e .`, whose exit
# status keys off the OUTPUT's truthiness, not parse success. `false` and `null`
# parse fine but exit 1, so they fell to the --arg branch and landed as the
# STRINGS "false"/"null". "false" is truthy in jq, so a later
# `if .merge_gate_met then …` read a failed gate as passed. `jq empty` exits 0 on
# any valid JSON; the -n guard keeps an empty value on the string path, since
# `jq empty` also accepts empty stdin but `--argjson v ""` would then fail.
reset_handoff
run --create "$PR" "$SEED_JSON"

run --set "$PR" ".merge_gate_met=false"
check_eq "--set false exits 0" "0" "$?"
check_eq "false stored as boolean type" "boolean" \
  "$(jq -r '.merge_gate_met | type' "$HANDOFF_FILE")"
check_eq "false value round-trips" "false" \
  "$(jq -r '.merge_gate_met' "$HANDOFF_FILE")"
check_eq "false is falsy in jq (not the truthy string \"false\")" "not-taken" \
  "$(jq -r 'if .merge_gate_met then "taken" else "not-taken" end' "$HANDOFF_FILE")"

run --set "$PR" ".blocked_on=null"
check_eq "--set null exits 0" "0" "$?"
check_eq "null stored as null type" "null" \
  "$(jq -r '.blocked_on | type' "$HANDOFF_FILE")"

run --set "$PR" ".ci_green=true"
check_eq "--set true exits 0" "0" "$?"
check_eq "true stored as boolean type" "boolean" \
  "$(jq -r '.ci_green | type' "$HANDOFF_FILE")"
check_eq "true value round-trips" "true" "$(jq -r '.ci_green' "$HANDOFF_FILE")"

run --set "$PR" ".review_rounds=42"
check_eq "--set number exits 0" "0" "$?"
check_eq "42 stored as number type" "number" \
  "$(jq -r '.review_rounds | type' "$HANDOFF_FILE")"
check_eq "42 value round-trips" "42" "$(jq -r '.review_rounds' "$HANDOFF_FILE")"

run --set "$PR" '.meta={"a":1}'
check_eq "--set object exits 0" "0" "$?"
check_eq "object stored as object type" "object" \
  "$(jq -r '.meta | type' "$HANDOFF_FILE")"
check_eq "object field round-trips" "1" "$(jq -r '.meta.a' "$HANDOFF_FILE")"

run --set "$PR" ".notes=abc"
check_eq "--set bare word exits 0" "0" "$?"
check_eq "bare word (invalid JSON) stored as string type" "string" \
  "$(jq -r '.notes | type' "$HANDOFF_FILE")"
check_eq "bare word value round-trips" "abc" "$(jq -r '.notes' "$HANDOFF_FILE")"

run --set "$PR" '.reviewer="quoted"'
check_eq "--set quoted JSON string exits 0" "0" "$?"
check_eq "quoted JSON string stored as string type" "string" \
  "$(jq -r '.reviewer | type' "$HANDOFF_FILE")"
check_eq "quoted JSON string decoded exactly once (no double-decode)" "quoted" \
  "$(jq -r '.reviewer' "$HANDOFF_FILE")"

run --set "$PR" ".push_timestamp="
check_eq "--set empty value exits 0 (no parse failure)" "0" "$?"
check_eq "empty value stored as string type" "string" \
  "$(jq -r '.push_timestamp | type' "$HANDOFF_FILE")"
check_eq "empty value is the empty string" "" \
  "$(jq -r '.push_timestamp' "$HANDOFF_FILE")"

# Whitespace-only values are the empty case's near miss: `jq empty` ACCEPTS
# " " and "\t" (zero JSON values, same as "") but `--argjson` REJECTS all
# three, so probing with `jq empty` would send whitespace down the JSON branch
# and hard-fail the write. Probing with `--argjson` itself keeps them strings.
run --set "$PR" ".notes= "
check_eq "--set single-space value exits 0 (not a write failure)" "0" "$?"
check_eq "single space stored as string type" "string" \
  "$(jq -r '.notes | type' "$HANDOFF_FILE")"
check_eq "single space preserved verbatim" " " \
  "$(jq -r '.notes' "$HANDOFF_FILE")"

run --set "$PR" ".notes=$(printf '\t')"
check_eq "--set tab-only value exits 0" "0" "$?"
check_eq "tab stored as string type" "string" \
  "$(jq -r '.notes | type' "$HANDOFF_FILE")"
check_eq "tab preserved verbatim" "$(printf '\t')" \
  "$(jq -r '.notes' "$HANDOFF_FILE")"

check_eq "file still valid JSON after all coercion writes" "0" \
  "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"
check_eq "unrelated fields preserved across coercion writes" "99" \
  "$(jq -r '.pr_number' "$HANDOFF_FILE")"

echo
echo "== --set: raw jq expression is refused, not stored (issue #1357) =="
# A --set value that is an unevaluated jq PROGRAM used to fall through to the
# --arg string branch, exit 0, and store the expression SOURCE — clobbering the
# previous value with no error (observed on PR #1350's A->B handoff, where it
# destroyed Phase A's notes). The guard runs AFTER the --argjson probe, so
# issue #853's false/null JSON-literal handling is untouched (re-asserted below).
reset_handoff
run --create "$PR" "$SEED_JSON"
run --set "$PR" ".notes=phase_a_findings"
BEFORE_JQ_GUARD="$(cat "$HANDOFF_FILE")"

OUT="$(run --set "$PR" '.notes=.notes + " clobbered"' 2>&1)"; RC=$?
check_eq "incident shape exits 4" "4" "$RC"
check_eq "incident shape leaves file byte-identical" "$BEFORE_JQ_GUARD" "$(cat "$HANDOFF_FILE")"
check_eq "prior notes value survives the refusal" "phase_a_findings" \
  "$(jq -r '.notes' "$HANDOFF_FILE")"
check_eq "refusal names the refusing-to-write contract" "1" \
  "$(grep -c 'refusing to write' <<<"$OUT")"
check_eq "refusal names the unevaluated jq expression" "1" \
  "$(grep -c 'unevaluated jq expression' <<<"$OUT")"

# The issue's literal text spaced the assignment (`.notes = .notes + "..."`),
# which leaves whitespace on BOTH sides of the split — the guard must tolerate a
# leading space in the value.
OUT="$(run --set "$PR" '.notes = .notes + " clobbered"' 2>&1)"; RC=$?
check_eq "spaced assignment shape exits 4" "4" "$RC"
check_eq "spaced assignment leaves file byte-identical" "$BEFORE_JQ_GUARD" "$(cat "$HANDOFF_FILE")"

for EXPR in '(.a // [])' '.foo | length' '(.threads_replied // []) + ["t1"]' \
            '.files_changed | map(select(. != "a"))'; do
  RC="$(run --set "$PR" ".notes=${EXPR}" >/dev/null 2>&1; echo $?)"
  check_eq "jq expression refused: ${EXPR}" "4" "$RC"
  check_eq "file byte-identical after refusing ${EXPR}" "$BEFORE_JQ_GUARD" "$(cat "$HANDOFF_FILE")"
done

echo
echo "== --set: genuine string values still write (no false rejects) =="
# The string branch is the normal home of prose, SHAs, paths and URLs. Each of
# these trips at least one of the guard's three signals but not all three, so a
# regression that loosens the heuristic fails here rather than in production.
check_string_set() {
  local desc="$1" value="$2"
  local rc
  rc="$(run --set "$PR" ".notes=${value}" >/dev/null 2>&1; echo $?)"
  check_eq "stored: $desc (exit 0)" "0" "$rc"
  check_eq "stored: $desc (round-trips as string)" "$value" "$(jq -r '.notes' "$HANDOFF_FILE")"
  check_eq "stored: $desc (string type)" "string" "$(jq -r '.notes | type' "$HANDOFF_FILE")"
}
check_string_set "plain word" "abc"
check_string_set "head sha" "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
check_string_set "timestamp" "2026-01-02T03:04:05Z"
check_string_set "dotfile path (leading dot, no operator)" ".claude/scripts/handoff-state.sh"
check_string_set "workflow path (leading dot, no operator)" ".github/workflows/ci.yml"
check_string_set "relative path" "./scripts/foo.sh"
check_string_set "url (operator chars, no leading path)" "https://github.com/auerbachb/claude-code-config/pull/1350"
check_string_set "prose naming a field and a plus" "Fixed .notes + head_sha handling"
check_string_set "prose with pipe and slashes" "CR clean | CodeAnt approved // threads resolved"
# Leading dot AND an operator, but not valid jq — the compile probe is the only
# signal keeping this prose out of the refusal path.
check_string_set "prose that starts with a dotted token" ".env + .env.local are ignored"

# Issue #853 re-assertion: JSON literals are decided by the --argjson probe
# BEFORE the guard, so the guard cannot push false/null onto the string path.
run --set "$PR" ".merge_gate_met=false"
check_eq "#853: false still exits 0 with the guard in place" "0" "$?"
check_eq "#853: false still stored as boolean" "boolean" \
  "$(jq -r '.merge_gate_met | type' "$HANDOFF_FILE")"
run --set "$PR" ".blocked_on=null"
check_eq "#853: null still exits 0 with the guard in place" "0" "$?"
check_eq "#853: null still stored as null type" "null" \
  "$(jq -r '.blocked_on | type' "$HANDOFF_FILE")"

echo
echo "== --set: the compile probe never EXECUTES the value (PR #1378) =="
# jq comments run to end of line, and the probe used to be one line
# (`def p: VALUE; empty`). A value ending in `#` swallowed the terminator and
# promoted its OWN tail to top-level expression, which jq then ran during what
# is meant to be a compile-only check: `.a + 1; def g: 1; last(repeat(1)) #`
# looped forever while this script held the state lock, blocking every sibling
# pipeline. Two defences are pinned here — the value now occupies its own line,
# and a value containing `#` skips the probe entirely, because past a comment
# jq would be judging only the PREFIX and calling prose an expression.
reset_handoff
run --create "$PR" "$SEED_JSON"
run --set "$PR" ".notes=phase_a_findings"

# Bounded, so a regression FAILS the suite instead of hanging it forever.
#
# `set -m` puts the child in its OWN process group so the timeout can kill the
# whole tree. Killing only the top-level bash leaves a regressed probe's `jq`
# running as an orphan — verified directly: with the parent killed, the spinning
# jq survives — and freeing LOCK_DIR below would then hand the lock to the next
# test while that orphan was still writing, turning one clean failure into
# cascading noise (CodeAnt, PR #1378). So: kill the group, wait for it to
# actually drain, and only then release the lock.
set_bounded() {                    # set_bounded <value> -> echoes rc (124 = hung)
  local value="$1" pid rc waited=0 drain=0
  set -m
  # --legacy-flat for the same reason run() carries it (issue #1366): this suite
  # asserts against the flat $HANDOFF_FILE, and an omitted scope now derives from
  # the cwd — which, with an un-migrated flat record already present and no scoped
  # one, is refused (exit 2) rather than written. Without the flag every shape
  # below would report the refusal instead of exercising the probe.
  bash "$SCRIPT" --legacy-flat --set "$PR" ".notes=${value}" >/dev/null 2>&1 &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $waited -ge 10 ]]; then
      kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      while [[ $drain -lt 10 ]] && kill -0 -"$pid" 2>/dev/null; do
        sleep 1; drain=$((drain + 1))
      done
      rm -rf "$LOCK_DIR"   # safe now: the whole group is gone
      echo 124; return
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"; rc=$?
  echo "$rc"
}

HANG_SHAPE='.a + 1; def g: 1; last(repeat(1)) #'
check_eq "infinite-loop shape does not hang the probe" "0" "$(set_bounded "$HANG_SHAPE")"
check_eq "infinite-loop shape round-trips verbatim as a string" "$HANG_SHAPE" \
  "$(jq -r '.notes' "$HANDOFF_FILE")"

# Same escape attempt WITHOUT a comment: a `;` closes the generated def and a
# second def follows, but the terminator still sits on its own line, so the
# trailing `; empty` cannot be absorbed and jq refuses the program outright.
# This is the shape CodeAnt raised against the four-line probe (PR #1378 round
# 2); it neither compiles nor executes, so the value stores as a string.
SEMI_SHAPE='.a + 1; def g: 1; last(repeat(1))'
check_eq "semicolon+def escape does not execute" "0" "$(set_bounded "$SEMI_SHAPE")"
check_eq "semicolon+def escape round-trips verbatim as a string" "$SEMI_SHAPE" \
  "$(jq -r '.notes' "$HANDOFF_FILE")"
check_eq "semicolon+def escape leaves no lock behind" "0" \
  "$([[ -e "$LOCK_DIR" ]] && echo 1 || echo 0)"

ERROR_SHAPE='.a + 1; def g: 1; error("BOOM") #'
check_eq "error() shape does not run during the probe" "0" "$(set_bounded "$ERROR_SHAPE")"
check_eq "error() shape round-trips verbatim as a string" "$ERROR_SHAPE" \
  "$(jq -r '.notes' "$HANDOFF_FILE")"
check_eq "file still valid JSON after both probe shapes" "0" \
  "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"

# Parity: line discipline ALONE would start refusing prose whose pre-`#` prefix
# happens to parse. The `#` bail-out keeps these on the string path, exactly
# where the single-line probe left them — zero verdict changes, hole closed.
check_string_set "prose carrying an issue number" ".notes + issue #1357 details"
check_string_set "two dotted paths and a PR reference" ".claude/rules + .claude/reference # see PR #1378"
check_string_set "expression-shaped text ending in a comment" '.notes + " x" #'

# Negative control: the `#` bail-out must not blunt the guard for values without
# one, or this whole section would pass by disabling the feature under test.
RC="$(run --set "$PR" '.notes=.notes + " clobbered"' >/dev/null 2>&1; echo $?)"
check_eq "incident shape still exits 4 with the # bail-out in place" "4" "$RC"

echo
echo "== the four-line probe assembly is independently load-bearing (PR #1378) =="
# The assertions above go through the real script, where the `#` bail-out
# short-circuits BEFORE jq is ever invoked — so they prove the guard end to end
# but do NOT isolate the line discipline, and a revert of the multiline assembly
# alone would still pass them (CodeAnt, round 4). These exercise the two
# assemblies directly on one value, no bail-out in the way.
#
# A `#` value is NOT the only probe of this defence, and line discipline is not
# sufficient on its own: a comment-free value CAN execute. jq admits
# `Exp := FuncDef Exp`, so a value ending in an unterminated `def` absorbs the
# probe's `;` terminator and promotes its own tail to top level even across four
# lines (CodeRabbit, PR #1378). That shape is covered by the `;` bail-out and
# pinned below.
bounded_jq() {                     # bounded_jq <program> [secs] -> rc (124 = hung)
  local prog="$1" limit="${2:-10}" pid rc waited=0 drain=0
  set -m
  jq -n "$prog" </dev/null >/dev/null 2>&1 &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $waited -ge $limit ]]; then
      kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      while [[ $drain -lt 10 ]] && kill -0 -"$pid" 2>/dev/null; do
        sleep 1; drain=$((drain + 1))
      done
      echo 124; return
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"; rc=$?
  echo "$rc"
}

ERR_V='.a + 1; def g: 1; error("BOOM") #'
check_eq "one-line assembly EXECUTES the value (jq runtime error)" "5" \
  "$(bounded_jq "def _p: ${ERR_V}; empty")"
check_eq "four-line assembly refuses to compile it (jq syntax error)" "3" \
  "$(bounded_jq "def _p:
${ERR_V}
;
empty")"

LOOP_V='.a + 1; def g: 1; last(repeat(1)) #'
check_eq "one-line assembly HANGS on the loop shape" "124" \
  "$(bounded_jq "def _p: ${LOOP_V}; empty" 4)"
check_eq "four-line assembly refuses the loop shape outright" "3" \
  "$(bounded_jq "def _p:
${LOOP_V}
;
empty" 4)"

echo
echo "== the \`;\` bail-out closes the def-absorbing route (PR #1378) =="
# jq's `Exp := FuncDef Exp` lets a value ending in an unterminated `def` take
# the probe's terminator as its OWN, leaving the value's tail as the top-level
# expression. Four-line assembly does not stop it — only refusing to probe a
# value containing `;` does. No `#` anywhere in this shape.
ABSORB_V='.a ; last(repeat(1)) | def h: 1'

check_eq "def-absorbing shape defeats the four-line assembly (hangs jq)" "124" \
  "$(bounded_jq "def _p:
${ABSORB_V}
;
empty" 4)"

# End to end the script must never reach that jq call: the `;` bail-out fires
# first, so the write completes and the value is stored verbatim.
check_eq "def-absorbing shape does not hang the real script" "0" \
  "$(set_bounded "$ABSORB_V")"
check_eq "def-absorbing shape round-trips verbatim as a string" "$ABSORB_V" \
  "$(jq -r '.notes' "$HANDOFF_FILE")"
check_eq "file still valid JSON after the def-absorbing shape" "0" \
  "$(jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; echo $?)"

# Why bailing on `;` closes the CLASS and not just this shape: escaping the
# wrapper needs the probe's own `def` terminated early, which needs a `;`.
# Without one, a trailing `def` still absorbs the terminator but then leaves no
# top-level expression at all, so jq refuses at compile time — it cannot run.
check_eq "no-semicolon trailing def is refused at compile, never executed" "3" \
  "$(bounded_jq "def _p:
.a | def h: 1
;
empty" 4)"

# No structural grep for the bail-out is needed here, unlike the line-discipline
# check below: the `set_bounded` assertion above runs the REAL script on a value
# that reaches jq only if the bail-out is gone, so deleting it turns that 0 into
# a 124 and fails outright.

# Structural: the shipped probe must actually keep the value on its own line.
# If someone re-inlines it, the two assertions above still describe jq
# correctly but would no longer describe THIS script — this catches that.
# Bracket expressions, not a bare `${`, so shellcheck does not read the literal
# pattern as an unexpanded expression (SC2016) — the match must stay literal.
check_eq "handoff-state.sh keeps \$JQ_VAL on its own probe line" "1" \
  "$(grep -cE '^[$][{]JQ_VAL[}]$' "$SCRIPT")"

echo
echo "== --append: jq-expression guard is --set-only (scope boundary) =="
# --append does not share --set's value branch and cannot clobber a prior value,
# so issue #1357 deliberately left it alone. This pins that decision: a future
# widening should change this assertion consciously, not discover it by surprise.
reset_handoff
run --create "$PR" "$SEED_JSON"
run --append "$PR" "findings_fixed" '.notes + " x"'
check_eq "--append with a jq-expression value still exits 0" "0" "$?"
check_eq "--append stored the expression verbatim as a string" '.notes + " x"' \
  "$(jq -r '.findings_fixed[0]' "$HANDOFF_FILE")"
check_eq "--append left the seeded notes untouched" "" "$(jq -r '.notes' "$HANDOFF_FILE")"

echo
echo "== Usage errors: exit 2 on bad args =="
run --create 2>/dev/null; check_eq "--create missing args exits 2" "2" "$?"
run --init 2>/dev/null;   check_eq "--init missing args exits 2" "2" "$?"
run --set 2>/dev/null;    check_eq "--set missing args exits 2" "2" "$?"
run --append 2>/dev/null; check_eq "--append missing args exits 2" "2" "$?"
run --delete 2>/dev/null; check_eq "--delete missing args exits 2" "2" "$?"
run --bogus 2>/dev/null;  check_eq "unknown flag exits 2" "2" "$?"

echo
echo "== --append <field> validation (issue #1514) =="
# Non-emptiness was the only check on <field>, so ANY string became a schema
# field. `--append 452 --owner-repo auerbachb/inventory` stored the literal key
# "--owner-repo", exited 0 and printed success: the write the caller meant was
# lost, and what landed was a record that parses as valid JSON while holding no
# real field at all. An artifact of exactly that shape sat in
# ~/.claude/handoffs/_unknown/pr-452-handoff.json, unattributable at migration
# time precisely because the owner_repo it should have carried was eaten as a
# field NAME. A typo (`threads_replyed`) was equally silent.
#
# The negative control at the end of this block rebuilds the pre-fix script and
# proves these assertions fail against it, so none of them can pass vacuously.
SCHEMA_FILE="$REPO_ROOT/.claude/reference/handoff-file-schema.json"
check_eq "the handoff schema reference exists" "1" \
  "$([[ -f "$SCHEMA_FILE" ]] && echo 1 || echo 0)"

# The issue's own reproduction: a misordered scope flag consumed as <field>.
reset_handoff
APPEND_FLAG_RC=0
APPEND_FLAG_ERR="$(run --append "$PR" --owner-repo auerbachb/inventory 2>&1 >/dev/null)" \
  || APPEND_FLAG_RC=$?
check_eq "--append with a misordered flag as <field> exits 2" "2" "$APPEND_FLAG_RC"
# Classify in a STANDALONE case, never inside $( ... ): bash 3.2 reads the `)`
# closing a case PATTERN as the one closing the substitution, so the inline form
# ends the substitution early and the assertion fails to parse (issue #1541).
# Hoisting also dodges the `[[ ... ]] && echo ... || echo ...` precedence trap,
# where a non-zero "named" branch would silently fall through to the else arm.
case "$APPEND_FLAG_ERR" in
  *"misordered flag"*) APPEND_FLAG_CAUSE="named" ;;
  *) APPEND_FLAG_CAUSE="unnamed: $APPEND_FLAG_ERR" ;;
esac
check_eq "the refusal names the misordered-flag cause" "named" "$APPEND_FLAG_CAUSE"
check_eq "a refused --append creates no handoff file" "0" \
  "$([[ -f "$HANDOFF_FILE" ]] && echo 1 || echo 0)"

# Same refusal against an EXISTING record: it must be left untouched, not
# merely un-appended. cmp(1) rather than $(cat ...) — command substitution
# strips trailing newlines, so a write that changed only those bytes would pass
# an assertion whose whole point is byte identity (CodeRabbit, PR #1500).
reset_handoff
run --create "$PR" "$SEED_JSON" >/dev/null 2>&1
APPEND_BASELINE="$TMP_HOME/append-field-baseline.json"
cp "$HANDOFF_FILE" "$APPEND_BASELINE"
run --append "$PR" --owner-repo auerbachb/inventory >/dev/null 2>&1
check_eq "a refused --append exits 2 against an existing record" "2" "$?"
check_eq "a refused --append leaves the record byte-identical" "0" \
  "$(cmp -s "$HANDOFF_FILE" "$APPEND_BASELINE"; echo $?)"
check_eq "no flag-shaped key reached the record" "false" \
  "$(jq 'has("--owner-repo")' "$HANDOFF_FILE")"

# Every non-schema shape is refused, and each is checked separately so one
# passing guard cannot answer for the rest. `-x` covers a SHORT misordered flag;
# the others are typos and non-identifiers.
APPEND_BAD_CHECKED=0
APPEND_BAD_VIOLATIONS=""
for _bad in "--legacy-flat" "-x" "threads_replyed" "not a field" "a/b" ".notes" "*"; do
  reset_handoff
  run --append "$PR" "$_bad" "v" >/dev/null 2>&1
  _rc=$?
  APPEND_BAD_CHECKED=$((APPEND_BAD_CHECKED + 1))
  [[ "$_rc" == "2" ]] || APPEND_BAD_VIOLATIONS="$APPEND_BAD_VIOLATIONS rc($_bad)=$_rc"
  [[ -f "$HANDOFF_FILE" ]] && APPEND_BAD_VIOLATIONS="$APPEND_BAD_VIOLATIONS wrote($_bad)"
done
check_eq "every rejected <field> shape was exercised (fail-closed)" "7" "$APPEND_BAD_CHECKED"
check_eq "every rejected <field> exits 2 and writes nothing" "" "$APPEND_BAD_VIOLATIONS"

# The restriction is on what --append may CREATE, so every field the schema
# does define must still append. The list is READ FROM THE SCHEMA rather than
# restated here: a field added to the schema but not to the script's allowlist
# must turn this red.
SCHEMA_ARRAY_FIELDS="$(jq -r 'to_entries[] | select(.value | type == "array") | .key' \
  "$SCHEMA_FILE" 2>/dev/null | sort)"
check_eq "schema array-field discovery found the fields (fail-closed)" "6" \
  "$(printf '%s\n' "$SCHEMA_ARRAY_FIELDS" | grep -c .)"
reset_handoff
run --create "$PR" "$SEED_JSON" >/dev/null 2>&1
APPEND_OK_CHECKED=0
APPEND_OK_VIOLATIONS=""
while IFS= read -r _field; do
  [[ -z "$_field" ]] && continue
  # findings_dismissed is the one array of objects; the rest take strings.
  if [[ "$_field" == "findings_dismissed" ]]; then
    _elem='{"id":"fd-1514","reason":"schema coverage"}'
  else
    _elem="v-$_field"
  fi
  run --append "$PR" "$_field" "$_elem" >/dev/null 2>&1 \
    || APPEND_OK_VIOLATIONS="$APPEND_OK_VIOLATIONS rejected($_field)"
  [[ "$(jq --arg f "$_field" '.[$f] | length' "$HANDOFF_FILE")" == "1" ]] \
    || APPEND_OK_VIOLATIONS="$APPEND_OK_VIOLATIONS unstored($_field)"
  APPEND_OK_CHECKED=$((APPEND_OK_CHECKED + 1))
done <<< "$SCHEMA_ARRAY_FIELDS"
check_eq "every schema array field got an --append attempt (fail-closed)" "6" \
  "$APPEND_OK_CHECKED"
check_eq "every schema array field still appends and stores" "" "$APPEND_OK_VIOLATIONS"

# Forward compatibility (handoff-files.md): the guard restricts creation, never
# preservation. An unknown field already in a record survives a valid --append
# to a DIFFERENT field, verbatim and structurally intact.
reset_handoff
run --create "$PR" \
  '{"schema_version":"1.0","future_field":{"nested":["keep","me"]},"threads_replied":["t-0"]}' \
  >/dev/null 2>&1
run --append "$PR" "files_changed" "src/new.ts" >/dev/null 2>&1
check_eq "a valid --append preserves an unknown field verbatim" \
  '{"nested":["keep","me"]}' "$(jq -c '.future_field' "$HANDOFF_FILE")"
check_eq "the valid --append still landed alongside it" "src/new.ts" \
  "$(jq -r '.files_changed[0]' "$HANDOFF_FILE")"

# The allowlist and the schema are two files that must move together; the script
# cannot read the schema at run time (it is a reference document, not a shipped
# dependency), so the sync is asserted here instead.
SCRIPT_ARRAY_FIELDS="$(grep -oE '^HANDOFF_ARRAY_FIELDS="[^"]*"' "$SCRIPT" \
  | sed -e 's#^HANDOFF_ARRAY_FIELDS="##' -e 's#"$##' | tr ' ' '\n' | sort)"
check_eq "the script's allowlist was discovered (fail-closed)" "6" \
  "$(printf '%s\n' "$SCRIPT_ARRAY_FIELDS" | grep -c .)"
check_eq "HANDOFF_ARRAY_FIELDS matches the schema's array fields" \
  "$SCHEMA_ARRAY_FIELDS" "$SCRIPT_ARRAY_FIELDS"

echo
echo "== --set field paths: audited for the same gap (issue #1514) =="
# --set needs no allowlist: two independent mechanisms already stop a misordered
# flag from becoming a key, and neither writes. Pinned so the audit's conclusion
# cannot quietly stop being true.
reset_handoff
run --create "$PR" "$SEED_JSON" >/dev/null 2>&1
SET_BASELINE="$TMP_HOME/set-audit-baseline.json"
cp "$HANDOFF_FILE" "$SET_BASELINE"
run --set "$PR" --owner-repo auerbachb/inventory >/dev/null 2>&1
check_eq "--set with a misordered flag exits 2 (the argument has no '=')" "2" "$?"
run --set "$PR" --owner-repo=auerbachb/inventory >/dev/null 2>&1
check_eq "--set with a flag-shaped jq path exits 4 (jq refuses it)" "4" "$?"
check_eq "neither --set misorder modified the record" "0" \
  "$(cmp -s "$HANDOFF_FILE" "$SET_BASELINE"; echo $?)"
check_eq "no flag-shaped key reached the record via --set" "false" \
  "$(jq 'has("--owner-repo")' "$HANDOFF_FILE")"

echo
echo "== Negative control: the assertions above fail against the pre-fix script =="
# Rebuild the pre-fix script by stripping the guard out of the CURRENT source,
# rather than reading it back from git history: CI checks out shallow, so a
# `git show <sha>:` control would be unrunnable there — and once this lands on
# main, a control that reads main would be testing the fixed copy and pass
# vacuously forever.
PREFIX_DIR="$TMP_HOME/prefix-append"; mkdir -p "$PREFIX_DIR/lib"
awk '
  $0 ~ /ARRAY_FIELD" == -\*/ { skip = 1 }
  skip && /^    esac$/       { skip = 0; next }
  !skip                      { print }
' "$SCRIPT" > "$PREFIX_DIR/handoff-state.sh"
cp "$REPO_ROOT/.claude/scripts/state-lock.sh" "$PREFIX_DIR/"
cp "$REPO_ROOT"/.claude/scripts/lib/*.sh "$PREFIX_DIR/lib/"
# Fail closed on the rebuild itself: a strip that removed nothing, removed too
# much, or produced an unrunnable script would make every "pre-fix accepts it"
# assertion below meaningless.
check_eq "the guard is present in the shipped script" "1" \
  "$(grep -c 'is not one of the handoff schema' "$SCRIPT")"
check_eq "the negative control stripped the guard out" "0" \
  "$(grep -c 'is not one of the handoff schema' "$PREFIX_DIR/handoff-state.sh")"
check_eq "the pre-fix rebuild is syntactically valid" "0" \
  "$(bash -n "$PREFIX_DIR/handoff-state.sh" 2>/dev/null; echo $?)"
prefix_run() { bash "$PREFIX_DIR/handoff-state.sh" --legacy-flat "$@"; }
# The rebuild still works for a LEGITIMATE append — proof the strip removed the
# guard and not the mode.
reset_handoff
prefix_run --append "$PR" "files_changed" "src/control.ts" >/dev/null 2>&1
check_eq "the pre-fix rebuild still performs a valid --append" "src/control.ts" \
  "$(jq -r '.files_changed[0]' "$HANDOFF_FILE" 2>/dev/null)"
# And it exhibits the defect: both refused shapes are accepted, exit 0, and
# store their bogus key.
reset_handoff
prefix_run --append "$PR" --owner-repo auerbachb/inventory >/dev/null 2>&1
check_eq "pre-fix: the misordered flag exits 0" "0" "$?"
check_eq "pre-fix: the flag name was stored as a field" '{"--owner-repo":["auerbachb/inventory"]}' \
  "$(jq -c . "$HANDOFF_FILE" 2>/dev/null)"
reset_handoff
prefix_run --append "$PR" "threads_replyed" "t-1" >/dev/null 2>&1
check_eq "pre-fix: a typo'd field exits 0" "0" "$?"
check_eq "pre-fix: the typo was stored as a field" "true" \
  "$(jq 'has("threads_replyed")' "$HANDOFF_FILE" 2>/dev/null)"
reset_handoff

echo
echo "== --help contract: the header IS the contract surface (issue #1461) =="
# handoff-files.md names `handoff-state.sh --help` as the canonical contract, and
# print_usage() emits the leading comment block verbatim — so a header that
# under-reports the script's real requirements is contract drift, not a typo.
# These guards are FAIL-CLOSED: each asserts it actually discovered something
# before asserting the discovered set is documented, so a grep that silently
# stops matching fails the suite instead of passing vacuously.
USAGE_TEXT="$(bash "$SCRIPT" --help 2>/dev/null)"
check_eq "--help prints the header" "nonempty" \
  "$([[ -n "$USAGE_TEXT" ]] && echo nonempty || echo empty)"

# Sibling libraries the script HARD-REQUIRES (each exits 5 when absent), read
# out of the script body rather than restated here.
# The sed expressions use `#` as the delimiter and carry no backslash escapes,
# so BSD and GNU sed read them identically (a `\}` here errors on GNU sed).
SIBLING_LIBS="$(grep -oE '^[A-Za-z_]+="\$\{SCRIPT_DIR\}/[^"]+"' "$SCRIPT" \
  | sed -e 's#.*SCRIPT_DIR}/##' -e 's#"$##' | sort -u)"
check_eq "sibling-library discovery found the hard requirements (fail-closed)" "3" \
  "$(printf '%s\n' "$SIBLING_LIBS" | grep -c .)"

DEPS_BLOCK="$(printf '%s\n' "$USAGE_TEXT" | awk '/^DEPENDENCIES$/ { f = 1; next } f && /^[A-Z]/ { exit } f { print }')"
UNDOCUMENTED_LIBS=""
while IFS= read -r _lib; do
  [[ -z "$_lib" ]] && continue
  case "$DEPS_BLOCK" in *"$_lib"*) ;; *) UNDOCUMENTED_LIBS="$UNDOCUMENTED_LIBS $_lib" ;; esac
done <<< "$SIBLING_LIBS"
check_eq "--help DEPENDENCIES names every hard-required sibling library" "" "$UNDOCUMENTED_LIBS"

# The list is only useful if it is SUFFICIENT: build a stub holding exactly the
# files DEPENDENCIES names and prove the script runs there. Before #1461 the
# block named state-lock.sh alone, so this stub exited 5 on the missing
# normalizer — the documented contract could not actually be followed.
DOC_DEPS="$(printf '%s\n' "$DEPS_BLOCK" | grep -oE '[A-Za-z0-9._/-]+\.sh' \
  | sed 's#^\.claude/scripts/##' | sort -u)"
check_eq "documented-dependency stub derived a file list (fail-closed)" "3" \
  "$(printf '%s\n' "$DOC_DEPS" | grep -c .)"
# Both stubs live under the suite's TMP_HOME so the existing EXIT trap removes
# them even if an assertion below aborts the run.
DEP_STUB="$TMP_HOME/dep-stub"; mkdir -p "$DEP_STUB"
cp "$SCRIPT" "$DEP_STUB/"
MISSING_DOC_DEPS=""
while IFS= read -r _dep; do
  [[ -z "$_dep" ]] && continue
  if [[ ! -f "$REPO_ROOT/.claude/scripts/$_dep" ]]; then
    MISSING_DOC_DEPS="$MISSING_DOC_DEPS $_dep"; continue
  fi
  mkdir -p "$DEP_STUB/$(dirname "$_dep")"
  cp "$REPO_ROOT/.claude/scripts/$_dep" "$DEP_STUB/$_dep"
done <<< "$DOC_DEPS"
check_eq "every file DEPENDENCIES names exists on disk" "" "$MISSING_DOC_DEPS"
bash "$DEP_STUB/handoff-state.sh" --owner-repo stub/repo --path 4242 >/dev/null 2>&1
check_eq "a stub holding only the documented dependencies runs" "0" "$?"

# The widened exit-5 row claims a missing sibling library exits 5. Pin that
# behaviour for EACH library separately. Omitting several at once would let
# whichever guard comes first in source order answer for all of them, so a later
# guard could be deleted or broken without turning this red — the vacuous pass
# these drift guards exist to prevent. Dropping exactly one library keeps every
# other guard satisfied, so the assertion can only hold if that library's own
# guard fired.
LIBLESS_ROOT="$TMP_HOME/libless"; mkdir -p "$LIBLESS_ROOT"
LIBLESS_CHECKED=0
while IFS= read -r _omit; do
  [[ -z "$_omit" ]] && continue
  _stub="$LIBLESS_ROOT/$(printf '%s' "$_omit" | tr '/.' '__')"
  mkdir -p "$_stub"
  cp "$SCRIPT" "$_stub/"
  while IFS= read -r _keep; do
    [[ -z "$_keep" || "$_keep" == "$_omit" ]] && continue
    mkdir -p "$_stub/$(dirname "$_keep")"
    cp "$REPO_ROOT/.claude/scripts/$_keep" "$_stub/$_keep"
  done <<< "$SIBLING_LIBS"
  # </dev/null so the script cannot swallow this loop's herestring stdin.
  bash "$_stub/handoff-state.sh" --owner-repo stub/repo --path 4242 \
    </dev/null >/dev/null 2>&1
  check_eq "a missing $_omit exits 5, as EXIT CODES documents" "5" "$?"
  LIBLESS_CHECKED=$((LIBLESS_CHECKED + 1))
done <<< "$SIBLING_LIBS"
# Fail closed: a loop that silently ran zero times would leave the exit-5 row
# unpinned while still reporting no failures.
check_eq "every hard-required sibling library got its own exit-5 check" "3" \
  "$LIBLESS_CHECKED"

# Every literal exit code the script can return must have an EXIT CODES row.
# Comment lines are stripped first so the header describing a code cannot be
# what makes that code look documented.
EXIT_BLOCK="$(printf '%s\n' "$USAGE_TEXT" | awk '/^EXIT CODES$/ { f = 1; next } f && /^[A-Z]/ { exit } f { print }')"
EXIT_CODES="$(grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -oE 'exit [0-9]+' | awk '{ print $2 }' | sort -u)"
# 6 literals: 0, 2, 3, 4, 5 and 70 (EX_SOFTWARE — the --help extraction guard
# added in issue #1528). 6 is documented but reached through
# STATE_LOCK_EXIT_TIMEOUT rather than a literal, so it is not in this set.
check_eq "exit-code discovery found the literal codes (fail-closed)" "6" \
  "$(printf '%s\n' "$EXIT_CODES" | grep -c .)"
UNDOCUMENTED_CODES=""
while IFS= read -r _code; do
  [[ -z "$_code" ]] && continue
  grep -qE "^ +${_code}  " <<<"$EXIT_BLOCK" \
    || UNDOCUMENTED_CODES="$UNDOCUMENTED_CODES $_code"
done <<< "$EXIT_CODES"
check_eq "--help EXIT CODES documents every literal exit code" "" "$UNDOCUMENTED_CODES"

# A row EXISTING is not the same as a row still SAYING what it said. The check
# above matches "^ +5  " and nothing more, so deleting any cause from the exit-5
# row -- or the unchanged-file promise it makes -- left every assertion above
# green (CodeRabbit, PR #1500). Pin the row's own text, fail-closed.
CODE5_ROW="$(printf '%s\n' "$EXIT_BLOCK" \
  | awk '/^ +5  / { f = 1; print; next } f && /^ +[0-9]+  / { exit } f { print }')"
check_eq "exit-5 row extracted from EXIT CODES (fail-closed)" "nonempty" \
  "$([[ -n "${CODE5_ROW//[[:space:]]/}" ]] && echo nonempty || echo empty)"
# The row wraps across lines, so collapse whitespace before matching: a phrase
# broken by the wrap ("missing at\n     startup") is still the same claim.
CODE5_TEXT="$(printf '%s\n' "$CODE5_ROW" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
MISSING_CAUSES=""
CAUSES_CHECKED=0
while IFS= read -r _cause; do
  [[ -z "$_cause" ]] && continue
  CAUSES_CHECKED=$((CAUSES_CHECKED + 1))
  case "$CODE5_TEXT" in
    *"$_cause"*) ;;
    *) MISSING_CAUSES="$MISSING_CAUSES [$_cause]" ;;
  esac
done <<'CAUSES'
mktemp / temp-write / mv failure
rm failure under --delete
REQUIRED sibling library missing at startup
all leaving the handoff file exactly as it was
CAUSES
check_eq "exit-5 cause list is fail-closed (4 phrases checked)" "4" "$CAUSES_CHECKED"
check_eq "exit-5 row still names every documented cause" "" "$MISSING_CAUSES"

# The row promises all three causes leave the handoff file EXACTLY as it was.
# Prove it for the cause this suite can induce -- a missing REQUIRED library,
# which the row says fails "before anything is read" -- by attempting a real
# --set that would otherwise rewrite the file. Reuses the stubs built above.
reset_handoff
run --create "$PR" "$SEED_JSON" >/dev/null 2>&1
# cmp(1), not $(cat ...): command substitution strips trailing newlines, so a
# failed write that changed ONLY those bytes would pass an assertion whose
# whole point is byte identity (CodeRabbit, PR #1500).
BEFORE_EXIT5="$TMP_HOME/exit5-baseline.json"
cp "$HANDOFF_FILE" "$BEFORE_EXIT5"
LIBLESS_WRITE_CHECKED=0
EXIT5_WRITE_VIOLATIONS=""
while IFS= read -r _omit; do
  [[ -z "$_omit" ]] && continue
  _stub="$LIBLESS_ROOT/$(printf '%s' "$_omit" | tr '/.' '__')"
  [[ -f "$_stub/handoff-state.sh" ]] || continue
  bash "$_stub/handoff-state.sh" --legacy-flat --set "$PR" '.notes=exit5_must_not_land' \
    </dev/null >/dev/null 2>&1
  _rc=$?
  LIBLESS_WRITE_CHECKED=$((LIBLESS_WRITE_CHECKED + 1))
  [[ "$_rc" == "5" ]] || EXIT5_WRITE_VIOLATIONS="$EXIT5_WRITE_VIOLATIONS rc($_omit)=$_rc"
  cmp -s "$HANDOFF_FILE" "$BEFORE_EXIT5" \
    || EXIT5_WRITE_VIOLATIONS="$EXIT5_WRITE_VIOLATIONS modified($_omit)"
done <<< "$SIBLING_LIBS"
check_eq "every library got an exit-5 write attempt (fail-closed)" "3" \
  "$LIBLESS_WRITE_CHECKED"
check_eq "a --set that exits 5 leaves the handoff file byte-identical" "" \
  "$EXIT5_WRITE_VIOLATIONS"

echo
echo "== --repair: replace-if-unusable, under the lock (CodeAnt Major, PR #1598) =="
# FAILS-WITHOUT-FIX (partial — replayed against 8f38791, this PR's pre-fix HEAD,
# in a detached worktree so the sibling libraries still resolve). --repair does
# not exist there, so it exits 2 and writes nothing. Observed 5 fail / 3 pass:
#
#   --repair seeds an absent handoff          FAIL  (got '', nothing written)
#   --repair on a valid handoff exits 0       FAIL  (got 2, unknown option)
#   --repair rewrites an unparseable handoff  FAIL  (got '')
#   --repair rewrites one it cannot read      FAIL  (got 'A', file untouched)
#   --repair rejects an invalid body -> 4     FAIL  (got 2)
#   leaves a valid handoff byte-identical     pass  — VACUOUSLY
#   concurrent Phase A write not clobbered    pass  — VACUOUSLY
#   invalid body does not touch the target    pass  — VACUOUSLY
#
# The three vacuous passes are recorded, not hidden: a script that refuses the
# flag writes nothing, and "wrote nothing" satisfies every preservation
# assertion for the wrong reason. They earn their place as forward guards — they
# fail the day --repair starts overwriting — but only the five above demonstrate
# the fix, and the preservation contract is what the five make meaningful.
#
# The load-bearing case is "valid record is left untouched". polling-state-gate
# used to decide a handoff was corrupt and then call --create, which overwrites
# whatever is there by the time the lock is granted; a Phase A writer that
# repaired the record in that window lost it. The predicate has to be re-tested
# on the same side of the lock as the write, and these assert exactly that.
RPR_RICH='{"schema_version":"1.0","pr_number":424242,"phase_completed":"A","findings_fixed":["real work"]}'
RPR_THIN='{"schema_version":"1.0","pr_number":424242,"phase_completed":"B","findings_fixed":[]}'

# absent -> writes
rm -f "$HANDOFF_FILE"
bash "$SCRIPT" --legacy-flat --repair "$PR" "$RPR_THIN" >/dev/null 2>&1
check_eq "--repair seeds an absent handoff" "B" \
  "$(jq -r '.phase_completed' "$HANDOFF_FILE" 2>/dev/null)"

# valid -> NO-OP. This is the race the fix closes: the richer record survives.
printf '%s' "$RPR_RICH" > "$HANDOFF_FILE"
rpr_before="$(cat "$HANDOFF_FILE")"
rpr_rc=0
bash "$SCRIPT" --legacy-flat --repair "$PR" "$RPR_THIN" >/dev/null 2>&1 || rpr_rc=$?
check_eq "--repair on a valid handoff exits 0" "0" "$rpr_rc"
check_eq "…and leaves it byte-identical, preserving the richer record" \
  "$rpr_before" "$(cat "$HANDOFF_FILE")"
check_eq "…so a concurrent Phase A write is not clobbered" "real work" \
  "$(jq -r '.findings_fixed[0]' "$HANDOFF_FILE")"

# corrupt -> rewrites
printf 'not json{' > "$HANDOFF_FILE"
bash "$SCRIPT" --legacy-flat --repair "$PR" "$RPR_THIN" >/dev/null 2>&1
check_eq "--repair rewrites an unparseable handoff" "B" \
  "$(jq -r '.phase_completed' "$HANDOFF_FILE" 2>/dev/null)"

# unreadable -> rewrites. Mode 000 denies nothing to uid 0; announced, never
# silently skipped, so a case that stops running cannot look like one that passed.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "skip — --repair unreadable case: mode 000 does not deny reads to root"
else
  printf '%s' "$RPR_RICH" > "$HANDOFF_FILE"
  chmod 000 "$HANDOFF_FILE"
  bash "$SCRIPT" --legacy-flat --repair "$PR" "$RPR_THIN" >/dev/null 2>&1
  chmod 644 "$HANDOFF_FILE" 2>/dev/null || true
  check_eq "--repair rewrites a handoff it cannot read" "B" \
    "$(jq -r '.phase_completed' "$HANDOFF_FILE" 2>/dev/null)"
fi

# invalid body -> exit 4, target untouched (same contract as --create/--init)
printf '%s' "$RPR_RICH" > "$HANDOFF_FILE"
rpr_before="$(cat "$HANDOFF_FILE")"
rpr_rc=0
bash "$SCRIPT" --legacy-flat --repair "$PR" 'not json{' >/dev/null 2>&1 || rpr_rc=$?
check_eq "--repair rejects an invalid body with exit 4" "4" "$rpr_rc"
check_eq "…without touching the target" "$rpr_before" "$(cat "$HANDOFF_FILE")"

echo
echo "==================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==================================="

[[ $FAIL -eq 0 ]]
