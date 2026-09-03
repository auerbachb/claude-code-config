#!/usr/bin/env bash
# chip-offer-registry.test.sh — Offline tests for chip-offer-registry.sh.
#
# Tests cover:
#   --reserve: normal, cap-exhausted (exit 7), lock timeout
#   --transition: happy path, unknown task_id
#   --count / --list: with and without --state filter
#   Concurrent reservation: two simultaneous emitters against FREE=1
#   TTL expiry
#   Emitter allowlist drift: header VALID EMITTERS (printed verbatim by --help)
#     must match the --emitter case allowlist (Issue #1464)
#   Emitter call-site coverage: all six canonical emitter SKILL.md files carry an
#     explicit --reserve call site, not an inherited-by-reference one (#1388)
#   Runnable-invocation pin: /harness-audit ships its reservation as an executable
#     snippet, so that snippet must survive deletion detection on its own
#
# All tests use a temp HOME dir so ~/.claude/session-state.json is not touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${SCRIPT_DIR}/../chip-offer-registry.sh"
LOCK_LIB="${SCRIPT_DIR}/../state-lock.sh"

if [[ ! -x "$REGISTRY" ]]; then
  echo "FAIL: chip-offer-registry.sh not found at $REGISTRY" >&2; exit 1
fi
if [[ ! -f "$LOCK_LIB" ]]; then
  echo "FAIL: state-lock.sh not found at $LOCK_LIB" >&2; exit 1
fi

PASS=0; FAIL=0
ok()   { PASS=$(( PASS+1 )); echo "ok   — $1"; }
fail() { FAIL=$(( FAIL+1 )); echo "FAIL — $1"; }

# Per-test temp HOME dir.  State file lives at "$H/.claude/session-state.json".
# The .claude/ dir is created so the script-usage.log write doesn't error.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

make_home() {
  local d="$TMP_DIR/$RANDOM"
  mkdir -p "$d/.claude"
  echo "$d"
}

sf() { echo "$1/.claude/session-state.json"; }   # state-file path helper

# run_registry <HOME_DIR> [registry args]
run_registry() {
  local h="$1"; shift
  HOME="$h" bash "$REGISTRY" --repo test/repo "$@"
}

# ---------------------------------------------------------------------------
# 1. --reserve: basic happy path
# ---------------------------------------------------------------------------
H="$(make_home)"
tid="$(run_registry "$H" --reserve --emitter pm --issue 1 --cap-free 3)"
rc=$?
if [[ $rc -eq 0 && -n "$tid" && "$tid" =~ ^offer- ]]; then
  ok "--reserve creates an entry and returns a task_id"
else
  fail "--reserve basic happy path (rc=$rc tid='$tid')"
fi

# 2. --count reflects the reserved entry
n="$(run_registry "$H" --count)"
if [[ "$n" == "1" ]]; then
  ok "--count returns 1 after one reserve"
else
  fail "--count after one reserve: expected 1, got $n"
fi

# 3. --list returns a JSON array with the entry
arr="$(run_registry "$H" --list)"
len="$(printf '%s' "$arr" | jq 'length')"
state="$(printf '%s' "$arr" | jq -r '.[0].state')"
if [[ "$len" == "1" && "$state" == "offered" ]]; then
  ok "--list returns the entry in 'offered' state"
else
  fail "--list after reserve: len=$len state=$state"
fi

# 4. --reserve with explicit --task-id is echoed back
H="$(make_home)"
custom_id="my-custom-task-99"
tid2="$(run_registry "$H" --reserve --emitter prompt --issue 42 --cap-free 5 --task-id "$custom_id")"
rc2=$?
if [[ $rc2 -eq 0 && "$tid2" == "$custom_id" ]]; then
  ok "--reserve --task-id echo back custom id"
else
  fail "--reserve --task-id: rc=$rc2 tid='$tid2' (expected '$custom_id')"
fi

# ---------------------------------------------------------------------------
# 5. --reserve: cap exhausted (exit 7)
# ---------------------------------------------------------------------------
H="$(make_home)"
# Fill 2 slots (cap-free=2)
run_registry "$H" --reserve --emitter pm --issue 10 --cap-free 2 > /dev/null
run_registry "$H" --reserve --emitter prompt --issue 11 --cap-free 2 > /dev/null
# Third one should be refused
run_registry "$H" --reserve --emitter wave --issue 12 --cap-free 2 >/dev/null 2>&1
rc_cap=$?
if [[ $rc_cap -eq 7 ]]; then
  ok "--reserve exits 7 when cap exhausted"
else
  fail "--reserve cap exhausted: expected exit 7, got $rc_cap"
fi

# 6. count is still 2 (the refused one did not sneak in)
n2="$(run_registry "$H" --count)"
if [[ "$n2" == "2" ]]; then
  ok "registry count is 2 after cap-exhausted refusal"
else
  fail "registry count after refusal: expected 2, got $n2"
fi

# ---------------------------------------------------------------------------
# 7. --transition: offered → running
# ---------------------------------------------------------------------------
H="$(make_home)"
tid3="$(run_registry "$H" --reserve --emitter wave --issue 20 --cap-free 5)"
run_registry "$H" --transition --task-id "$tid3" --state running
rc_tr=$?
st="$(run_registry "$H" --list | jq -r '.[0].state')"
if [[ $rc_tr -eq 0 && "$st" == "running" ]]; then
  ok "--transition offered→running succeeds"
else
  fail "--transition offered→running: rc=$rc_tr state=$st"
fi

# 8. --transition: running → pr-backed removes from capacity count
run_registry "$H" --transition --task-id "$tid3" --state pr-backed >/dev/null
n_pr="$(run_registry "$H" --count)"
if [[ "$n_pr" == "0" ]]; then
  ok "--transition to pr-backed removes entry from capacity count"
else
  fail "--transition→pr-backed: count=$n_pr (expected 0)"
fi

# 9. --transition: unknown task_id exits 2
run_registry "$H" --transition --task-id "no-such-id" --state running >/dev/null 2>&1
rc_unk=$?
if [[ $rc_unk -eq 2 ]]; then
  ok "--transition with unknown task_id exits 2"
else
  fail "--transition unknown id: expected exit 2, got $rc_unk"
fi

# ---------------------------------------------------------------------------
# 10. --count --state filter
# ---------------------------------------------------------------------------
H="$(make_home)"
t_a="$(run_registry "$H" --reserve --emitter pm --issue 30 --cap-free 5)"
t_b="$(run_registry "$H" --reserve --emitter prompt --issue 31 --cap-free 5)"
run_registry "$H" --transition --task-id "$t_b" --state running >/dev/null
n_off="$(run_registry "$H" --count --state offered)"
n_run="$(run_registry "$H" --count --state running)"
if [[ "$n_off" == "1" && "$n_run" == "1" ]]; then
  ok "--count --state filter returns per-state counts"
else
  fail "--count --state: offered=$n_off running=$n_run (expected 1,1)"
fi

# 11. --list --state filter
arr_off="$(run_registry "$H" --list --state offered)"
len_off="$(printf '%s' "$arr_off" | jq 'length')"
issue_off="$(printf '%s' "$arr_off" | jq -r '.[0].issue')"
if [[ "$len_off" == "1" && "$issue_off" == "30" ]]; then
  ok "--list --state offered returns only offered entries"
else
  fail "--list --state offered: len=$len_off issue=$issue_off"
fi

# ---------------------------------------------------------------------------
# 12. TTL expiry: entries older than TTL are not counted
# ---------------------------------------------------------------------------
H="$(make_home)"
past="1970-01-01T00:00:00Z"
printf '{"repos":{"test/repo":{"chip_offers":[{"task_id":"old-1","emitter":"pm","issue":50,"state":"offered","offered_at":"%s","expires_at":"%s","pr":null,"last_updated":"%s"}]}}}\n' \
  "$past" "$past" "$past" > "$(sf "$H")"
n_ttl="$(CLAUDE_CHIP_OFFER_TTL_S=1 run_registry "$H" --count)"
if [[ "$n_ttl" == "0" ]]; then
  ok "expired entries (offered_at in 1970) excluded from count with TTL=1s"
else
  fail "TTL expiry: count=$n_ttl (expected 0)"
fi

# 13. Entries with no offered_at are never treated as expired (fail-closed)
H="$(make_home)"
printf '{"repos":{"test/repo":{"chip_offers":[{"task_id":"no-ts","emitter":"pm","issue":51,"state":"offered","pr":null,"last_updated":"2026-01-01T00:00:00Z"}]}}}\n' \
  > "$(sf "$H")"
n_no_ts="$(CLAUDE_CHIP_OFFER_TTL_S=1 run_registry "$H" --count)"
if [[ "$n_no_ts" == "1" ]]; then
  ok "entry with no offered_at is never expired (fail-closed)"
else
  fail "no-offered_at fail-closed: count=$n_no_ts (expected 1)"
fi

# ---------------------------------------------------------------------------
# 14. terminal states (done, retracted) not counted
# ---------------------------------------------------------------------------
H="$(make_home)"
t_c="$(run_registry "$H" --reserve --emitter pm --issue 60 --cap-free 5)"
t_d="$(run_registry "$H" --reserve --emitter prompt --issue 61 --cap-free 5)"
run_registry "$H" --transition --task-id "$t_c" --state done >/dev/null
run_registry "$H" --transition --task-id "$t_d" --state retracted >/dev/null
n_term="$(run_registry "$H" --count)"
if [[ "$n_term" == "0" ]]; then
  ok "done and retracted entries excluded from count"
else
  fail "terminal states: count=$n_term (expected 0)"
fi

# ---------------------------------------------------------------------------
# 15. missing session-state.json is not an error (--count → 0)
# ---------------------------------------------------------------------------
H_absent="$TMP_DIR/absent-$RANDOM"   # intentionally no mkdir
mkdir -p "$H_absent/.claude"          # create .claude so log write doesn't error; no state file
n_absent="$(run_registry "$H_absent" --count 2>/dev/null)"
rc_absent=$?
if [[ $rc_absent -eq 0 && "$n_absent" == "0" ]]; then
  ok "absent session-state.json returns 0 (not an error)"
else
  fail "absent file: rc=$rc_absent n='$n_absent'"
fi

# ---------------------------------------------------------------------------
# 16. Concurrent reservation — two emitters against FREE=1 produce exactly 1 offer
# ---------------------------------------------------------------------------
# Sequential simulation: fill 0 of 1, first wins; then second fails.
H="$(make_home)"
t_a="$(run_registry "$H" --reserve --emitter pm --issue 100 --cap-free 1 2>/dev/null)"
rc_a=$?
t_b="$(run_registry "$H" --reserve --emitter prompt --issue 101 --cap-free 1 2>/dev/null)"
rc_b=$?
if [[ $rc_a -eq 0 && $rc_b -eq 7 ]]; then
  ok "sequential double-reserve against FREE=1: first wins, second exits 7"
else
  fail "sequential double-reserve: rc_a=$rc_a rc_b=$rc_b"
fi
n_conc="$(run_registry "$H" --count)"
if [[ "$n_conc" == "1" ]]; then
  ok "exactly 1 entry after two competing reserves for FREE=1"
else
  fail "concurrent count: expected 1, got $n_conc"
fi

# True concurrent test using parallel subshells.
# Capture each background PID and wait on it individually so the exit codes are
# available: if both subshells fail for the same environmental reason (e.g. a
# broken lock) the count is 0, which is ≤1 but proves nothing about the locking
# logic.  At least one subprocess must exit 0 (winner) or 7 (cap full) to
# confirm the code ran rather than errored out silently.
H2="$(make_home)"
( run_registry "$H2" --reserve --emitter pm --issue 200 --cap-free 1 > /dev/null 2>&1 ) & pid_r1=$!
( run_registry "$H2" --reserve --emitter prompt --issue 201 --cap-free 1 > /dev/null 2>&1 ) & pid_r2=$!
wait "$pid_r1"; rc_r1=$?
wait "$pid_r2"; rc_r2=$?
n_race="$(run_registry "$H2" --count)"
if [[ "$n_race" -le 1 && ( $rc_r1 -eq 0 || $rc_r1 -eq 7 ) && ( $rc_r2 -eq 0 || $rc_r2 -eq 7 ) ]]; then
  ok "true concurrent race against FREE=1: at most 1 winner (rc1=$rc_r1 rc2=$rc_r2)"
else
  fail "concurrent race: count=$n_race rc1=$rc_r1 rc2=$rc_r2 (expected ≤1 entries; both exits 0 or 7)"
fi

# ---------------------------------------------------------------------------
# 17. Usage errors exit 2
# ---------------------------------------------------------------------------
bash "$REGISTRY" >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "no mode → exit 2" || fail "no mode should exit 2"

H="$(make_home)"
HOME="$H" bash "$REGISTRY" --repo test/repo --reserve >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "--reserve missing args → exit 2" || fail "--reserve missing args"

HOME="$H" bash "$REGISTRY" --repo test/repo --transition >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "--transition missing args → exit 2" || fail "--transition missing args"

HOME="$H" bash "$REGISTRY" --repo test/repo --reserve --emitter bad --issue 1 --cap-free 1 >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "invalid emitter → exit 2" || fail "invalid emitter should exit 2"

# ---------------------------------------------------------------------------
# 18. Preserve siblings in session-state.json (other keys are not clobbered)
# ---------------------------------------------------------------------------
H="$(make_home)"
printf '{"repos":{"test/repo":{"root_repo":"/some/path"}}}\n' > "$(sf "$H")"
run_registry "$H" --reserve --emitter pm --issue 300 --cap-free 5 >/dev/null
root="$(jq -r '.repos["test/repo"].root_repo' "$(sf "$H")")"
if [[ "$root" == "/some/path" ]]; then
  ok "--reserve preserves existing sibling fields in session-state.json"
else
  fail "sibling preservation: root_repo='$root' (expected /some/path)"
fi

# 19. Registry lives at repo-scoped key, other repos unaffected
H="$(make_home)"
printf '{"repos":{"other/repo":{"chip_offers":[{"task_id":"x","emitter":"pm","issue":999,"state":"offered","pr":null,"last_updated":"2026-01-01T00:00:00Z"}]}}}\n' \
  > "$(sf "$H")"
n_scoped="$(run_registry "$H" --count)"
if [[ "$n_scoped" == "0" ]]; then
  ok "other-repo chip_offers not counted for test/repo"
else
  fail "repo scoping: expected 0 for test/repo, got $n_scoped"
fi

# ---------------------------------------------------------------------------
# 20. Batch reserve: multiple --issue flags create ONE entry (not N)
# ---------------------------------------------------------------------------
H="$(make_home)"
tid_batch="$(run_registry "$H" --reserve --emitter issue-maker \
  --issue 200 --issue 201 --issue 202 \
  --cap-free 3 2>/dev/null)"
rc_batch=$?
n_batch="$(run_registry "$H" --count)"
# Exactly 1 entry (one chip) regardless of 3 issue numbers passed.
if [[ $rc_batch -eq 0 && "$n_batch" == "1" ]]; then
  ok "batch --reserve with 3 issues creates exactly 1 registry entry"
else
  fail "batch reserve: rc=$rc_batch count=$n_batch (expected 0,1)"
fi

# 21. Batch entry stores all issue numbers in "issues" array
arr_batch="$(run_registry "$H" --list)"
issues_json="$(printf '%s' "$arr_batch" | jq -c '.[0].issues')"
issue_first="$(printf '%s' "$arr_batch" | jq '.[0].issue')"
if [[ "$issues_json" == "[200,201,202]" && "$issue_first" == "200" ]]; then
  ok "batch entry stores issues array and issue scalar"
else
  fail "batch entry schema: issues=$issues_json issue=$issue_first"
fi

# 22. A second batch reserve against the same FREE=3 pool sees count=1 already
tid_batch2="$(run_registry "$H" --reserve --emitter pm \
  --issue 203 --cap-free 3 2>/dev/null)"
rc_batch2=$?
n_batch2="$(run_registry "$H" --count)"
if [[ $rc_batch2 -eq 0 && "$n_batch2" == "2" ]]; then
  ok "second reserve after batch sees count=2 (entries, not issues)"
else
  fail "second reserve after batch: rc=$rc_batch2 count=$n_batch2 (expected 0,2)"
fi

# 23. Batch reserve with cap-free=1 only lets 1 entry through even for 3 issues
H="$(make_home)"
tid_ok="$(run_registry "$H" --reserve --emitter issue-maker \
  --issue 300 --issue 301 --cap-free 1 2>/dev/null)"
rc_ok=$?
run_registry "$H" --reserve --emitter pm --issue 302 --cap-free 1 >/dev/null 2>&1
rc_cap=$?
if [[ $rc_ok -eq 0 && $rc_cap -eq 7 ]]; then
  ok "batch reserve with FREE=1: first batch wins, second exits 7"
else
  fail "batch + cap-free=1: rc_ok=$rc_ok rc_cap=$rc_cap"
fi

# ---------------------------------------------------------------------------
# 24. --retract: frees a reservation (deferral 2 — release on failure)
# ---------------------------------------------------------------------------
H="$(make_home)"
tid_r="$(run_registry "$H" --reserve --emitter pm --issue 400 --cap-free 3)"
n_before="$(run_registry "$H" --count)"
run_registry "$H" --retract --task-id "$tid_r" >/dev/null
rc_ret=$?
n_after="$(run_registry "$H" --count)"
st_after="$(run_registry "$H" --list | jq -r '.[0].state')"
if [[ $rc_ret -eq 0 && "$n_before" == "1" && "$n_after" == "0" && "$st_after" == "retracted" ]]; then
  ok "--retract frees slot: count went from 1 to 0, state=retracted"
else
  fail "--retract: rc=$rc_ret n_before=$n_before n_after=$n_after state=$st_after"
fi

# 25. --retract on unknown task_id is a no-op success (idempotent)
H="$(make_home)"
run_registry "$H" --retract --task-id "nonexistent-id-xyz" >/dev/null 2>&1
rc_noop=$?
if [[ $rc_noop -eq 0 ]]; then
  ok "--retract on unknown task_id exits 0 (no-op)"
else
  fail "--retract no-op: expected exit 0, got $rc_noop"
fi

# 26. task_id entropy: generated ids include timestamp, PID, and hex random
H="$(make_home)"
tid_e="$(run_registry "$H" --reserve --emitter pm --issue 500 --cap-free 5)"
# Generated format: offer-<epoch>-<pid>-<8hexdigits>
if [[ "$tid_e" =~ ^offer-[0-9]+-[0-9]+-[0-9a-f]{8}$ ]]; then
  ok "generated task_id has offer-<ts>-<pid>-<hex> format (entropy fix)"
else
  fail "task_id format: '$tid_e' (expected offer-<ts>-<pid>-<8hex>)"
fi

# 27. --reserve with no --issue exits 2
H="$(make_home)"
HOME="$H" bash "$REGISTRY" --repo test/repo --reserve --emitter pm --cap-free 3 >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "--reserve with no --issue exits 2" || fail "--reserve with no --issue: expected exit 2"

# 28. --retract with no --task-id exits 2
H="$(make_home)"
HOME="$H" bash "$REGISTRY" --repo test/repo --retract >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "--retract with no --task-id exits 2" || fail "--retract no --task-id: expected exit 2"

# ---------------------------------------------------------------------------
# 29. Regression: existing registry entries must not cause false cap exhaustion
#     when the caller passes the absolute admission limit (baseline + FREE).
#
#     Scenario: CAP=6, 3 existing offered entries, FREE=3 → admission limit = 6.
#     All 3 new reservations must succeed; a 7th would exceed the limit.
# ---------------------------------------------------------------------------
H="$(make_home)"
# Seed 3 baseline entries (cap-free=10 as an unconstrained seed)
run_registry "$H" --reserve --emitter pm --issue 700 --cap-free 10 >/dev/null
run_registry "$H" --reserve --emitter prompt --issue 701 --cap-free 10 >/dev/null
run_registry "$H" --reserve --emitter wave --issue 702 --cap-free 10 >/dev/null
baseline_count="$(run_registry "$H" --count)"

# admission limit = baseline (3) + FREE (3) = 6
admission_limit=$(( baseline_count + 3 ))

rc_29a=0; rc_29b=0; rc_29c=0
run_registry "$H" --reserve --emitter pm --issue 703 --cap-free "$admission_limit" >/dev/null 2>&1 || rc_29a=$?
run_registry "$H" --reserve --emitter pm --issue 704 --cap-free "$admission_limit" >/dev/null 2>&1 || rc_29b=$?
run_registry "$H" --reserve --emitter pm --issue 705 --cap-free "$admission_limit" >/dev/null 2>&1 || rc_29c=$?
if [[ $rc_29a -eq 0 && $rc_29b -eq 0 && $rc_29c -eq 0 ]]; then
  ok "existing registry entries: 3 reserves against (baseline+FREE=6) all succeed"
else
  fail "existing registry entries: false exhaustion (rc_29a=$rc_29a rc_29b=$rc_29b rc_29c=$rc_29c; expected all 0)"
fi

# 7th reserve must be rejected (count now = 6 = admission limit)
rc_29d=0
run_registry "$H" --reserve --emitter pm --issue 706 --cap-free "$admission_limit" >/dev/null 2>&1 || rc_29d=$?
if [[ $rc_29d -eq 7 ]]; then
  ok "existing registry entries: 7th reserve exits 7 (admission limit reached)"
else
  fail "existing registry entries: 7th reserve should exit 7, got $rc_29d"
fi

# ---------------------------------------------------------------------------
# 36. Header VALID EMITTERS list matches the --emitter case allowlist.
#     usage() prints the header verbatim (sed '2,/^$/p'), so --help output IS
#     the header: a stale emitter list is a user-facing contract bug, not a
#     comment typo.  Pins the harness-audit drift found in Issue #1464.
#     Both lists are extracted by anchoring on a structural marker and reading
#     the next line -- the VALID EMITTERS heading for the header, the
#     `case "$EMITTER" in` statement for the allowlist -- then sorted before
#     comparison, so reordering the case alternation (semantically a no-op in
#     bash) does not trip the guard.
#     Each list is split into tokens BEFORE whitespace is trimmed, and only the
#     token edges are trimmed, so whitespace interior to a name is preserved --
#     a malformed header entry like "harness -audit" stays distinct from
#     "harness-audit" and is reported as drift rather than normalized away.
#     Fails closed if either list cannot be extracted.
# ---------------------------------------------------------------------------
H="$(make_home)"
HELP_EMITTERS="$(HOME="$H" bash "$REGISTRY" --help 2>/dev/null \
  | awk '/^VALID EMITTERS$/{getline; print; exit}' \
  | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . | sort | tr '\n' ' ')"
CASE_EMITTERS="$(awk '/^[[:space:]]*case[[:space:]]+"\$EMITTER"[[:space:]]+in/{getline; print; exit}' "$REGISTRY" \
  | sed 's/).*$//' | tr '|' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . | sort | tr '\n' ' ')"
if [[ -z "$HELP_EMITTERS" || -z "$CASE_EMITTERS" ]]; then
  fail "emitter drift guard could not extract both lists (help='$HELP_EMITTERS' case='$CASE_EMITTERS')"
elif [[ "$HELP_EMITTERS" == "$CASE_EMITTERS" ]]; then
  ok "header VALID EMITTERS matches the --emitter case allowlist"
else
  fail "emitter drift: header='$HELP_EMITTERS' but case allowlist='$CASE_EMITTERS'"
fi

# ---------------------------------------------------------------------------
# 37. harness-audit is accepted by --reserve (behavioral pin for the sixth
#     canonical emitter named in chip-launching.md).
# ---------------------------------------------------------------------------
H="$(make_home)"
rc_ha=0
tid_ha="$(run_registry "$H" --reserve --emitter harness-audit --issue 1464 --cap-free 3 2>/dev/null)" || rc_ha=$?
if [[ $rc_ha -eq 0 && -n "$tid_ha" ]]; then
  ok "--emitter harness-audit is accepted by --reserve"
else
  fail "--emitter harness-audit should be accepted (rc=$rc_ha, tid='$tid_ha')"
fi

# ---------------------------------------------------------------------------
# 38. Every canonical emitter SKILL.md carries an EXPLICIT --reserve call site.
#     chip-launching.md §Offer Registry requires every spawn_task emitter to
#     reserve first, but a requirement inherited purely by reference is not
#     greppable: /harness-audit satisfied it that way for months and the census
#     silently undercounted whenever it emitted (Issue #1388, found by the
#     chip-emission audit).  Test 37 pins that the registry ACCEPTS
#     harness-audit; this pins that the skill actually CALLS it.
#
#     The check is PROXIMITY-bounded, not same-line and not file-wide.  The file
#     is flattened to one whitespace-normalized line, then chip-offer-registry.sh
#     and --reserve must appear within 120 characters of each other, in either
#     order.  Each bound is deliberate:
#       - Same-line was written first and rejected: prose wraps, and re-wrapping
#         a paragraph would false-fail without any regression having occurred.
#       - File-wide presence of both tokens was rejected too: an emitter that
#         merely name-drops the script in unrelated prose would satisfy it.
#       - Either order is required because emitters genuinely spell the call
#         three ways: bare `chip-offer-registry.sh --reserve` (pm, prompt,
#         wave), `--reserve --emitter X` (start-issue, harness-audit), and
#         `--emitter X ... --reserve` (issue-maker).  Requiring the --emitter
#         value itself would fail the first three outright, so it is not part
#         of the assertion.  The widest real gap is issue-maker's ~60 chars, so
#         120 has headroom without spanning paragraphs.
#     Fails closed when a SKILL.md is missing rather than skipping the emitter.
#
#     Note: `producer | grep -q` is avoided deliberately — under `set -o
#     pipefail` grep exits at the first match, the producer takes SIGPIPE, and
#     the pipeline reports failure ON A SUCCESSFUL MATCH.  Capture first, match
#     from a here-string.
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SKILLS_DIR="$REPO_ROOT/.claude/skills"
CANONICAL_EMITTERS=(pm prompt wave issue-maker start-issue harness-audit)
missing_reserve=()
missing_file=()
for emitter in "${CANONICAL_EMITTERS[@]}"; do
  skill_md="$SKILLS_DIR/$emitter/SKILL.md"
  if [[ ! -f "$skill_md" ]]; then
    missing_file+=("$emitter")
    continue
  fi
  # Flatten to one line so a wrapped call site still matches, then require the
  # two tokens within a bounded window of each other (either order).
  skill_flat="$(tr '\n' ' ' < "$skill_md" 2>/dev/null | tr -s '[:space:]' ' ')"
  if [[ -z "$skill_flat" ]] || ! grep -qE \
      'chip-offer-registry\.sh.{0,120}--reserve|--reserve.{0,120}chip-offer-registry\.sh' \
      <<<"$skill_flat"; then
    missing_reserve+=("$emitter")
  fi
done
if (( ${#missing_file[@]} > 0 )); then
  fail "canonical emitter SKILL.md not found: ${missing_file[*]} (expected under $SKILLS_DIR)"
elif (( ${#missing_reserve[@]} > 0 )); then
  fail "emitters without an explicit chip-offer-registry.sh --reserve call site: ${missing_reserve[*]}"
else
  ok "all ${#CANONICAL_EMITTERS[@]} canonical emitters carry an explicit --reserve call site"
fi

# ---------------------------------------------------------------------------
# 39. /harness-audit's reservation must exist as a RUNNABLE invocation, not only
#     as a mandate sentence.
#
#     Test 38 asks a narrower question than its name suggests: does the skill
#     name the reserve command anywhere in its own text?  For five emitters that
#     IS the call site — a SKILL.md instruction is what gets executed.
#     /harness-audit is the exception: it states the mandate in prose AND ships a
#     runnable snippet, and test 38 sees only the prose, because the snippet
#     spells the command as "$REGISTRY" rather than the literal script name.
#     Measured on this tree: deleting the snippet leaves test 38 green, and the
#     snippet alone does not satisfy test 38 at all (CodeAnt review, PR #1615).
#     So 38 cannot detect the executable call site disappearing.
#
#     Test 38 is deliberately NOT tightened to require a fenced call for every
#     emitter: five of the six state the call in prose only, so a file-wide fence
#     rule would fail them (measured — the reason the same requirement was
#     declined in review round 2).  The fence requirement is therefore scoped to
#     the one emitter that actually ships a fence.
#
#     Fenced blocks are joined with a separator wider than the match window, so a
#     window can never span two blocks and manufacture a false pass.
# ---------------------------------------------------------------------------
HA_SKILL_MD="$SKILLS_DIR/harness-audit/SKILL.md"
if [[ ! -f "$HA_SKILL_MD" ]]; then
  fail "harness-audit SKILL.md not found at $HA_SKILL_MD"
else
  ha_sep="$(printf '%*s' 130 '' | tr ' ' '#')"
  ha_fenced="$(awk -v sep="$ha_sep" '
      /^[[:space:]]*```/ { in_fence = !in_fence; printf "%s ", sep; next }
      in_fence           { print }
    ' "$HA_SKILL_MD" 2>/dev/null | tr '\n' ' ' | tr -s '[:space:]' ' ')"
  if [[ -z "$ha_fenced" ]]; then
    fail "harness-audit SKILL.md: no fenced code blocks found to check"
  elif ! grep -qE -- \
      '--emitter harness-audit.{0,120}--reserve|--reserve.{0,120}--emitter harness-audit' \
      <<<"$ha_fenced"; then
    fail "harness-audit: --reserve invocation missing from every fenced block (test 38 still passes on the prose mandate alone, so it cannot catch this)"
  else
    ok "harness-audit ships a runnable --reserve invocation inside a fenced block"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "OK: chip-offer-registry.sh tests passed ($PASS passed)"
  exit 0
else
  echo "FAIL: $FAIL test(s) failed ($PASS passed)"
  exit 1
fi
