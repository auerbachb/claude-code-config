#!/usr/bin/env bash
# catalog: tests — Prove lock-free execution-pause --status matches the locked read on every fixture
#
# Issue #2402: `--status` reads the state file once without the state lock,
# then checks markers. This suite compares its stdout and exit code with the
# retained locked read (CLAUDE_EXECUTION_PAUSE_STATUS_LOCKED=1) across primary
# and legacy-hold fixtures, in normal and launch-check mode, and checks that
# status answers while another process holds the lock. No timing assertions
# here (those live in the serial pause-lifecycle-hooks suite). Isolated HOME.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATE="$ROOT/.claude/scripts/execution-pause.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/execution-pause-status-2402.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
export HOME="$TMP/home"
export CLAUDE_EXECUTION_PAUSE_MARKER_DIR="$TMP/markers"
unset CLAUDE_EXECUTION_PAUSE_STATUS_LOCKED CLAUDE_EXECUTION_PAUSE_LAUNCH_CHECK CLAUDE_STATE_LOCK_HELD CLAUDE_STATE_LOCK_TOKEN
mkdir -p "$HOME/.claude" "$CLAUDE_EXECUTION_PAUSE_MARKER_DIR"
STATE="$HOME/.claude/session-state.json"
REPO=owner/repo
SID=11111111-1111-4111-8111-111111111111
LEGACY=legacy-session-2402

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}
scope_hash() { printf '%s\0%s' "$REPO" "$1" | sha; }
marker_of() { printf '%s/claude-execution-pause-v2-%s' "$CLAUDE_EXECUTION_PAUSE_MARKER_DIR" "$(scope_hash "$1")"; }
# The token a guarded legacy clear records for a native gate record ($1, JSON).
native_token() { printf '%s\0%s' "$(scope_hash "$SID")" "$(jq -cS . <<< "$1")" | sha; }

reset() {
  rm -f "$STATE" "$CLAUDE_EXECUTION_PAUSE_MARKER_DIR"/claude-execution-pause-v2-* 2>/dev/null || true
}
write_state() { printf '%s' "$1" > "$STATE"; }

run_status() { # $1 locked(0/1) $2 launch(0/1) $3 session -> "<rc>|<stdout>"
  local out rc=0 envs=()
  [[ "$1" == 1 ]] && envs+=(CLAUDE_EXECUTION_PAUSE_STATUS_LOCKED=1)
  [[ "$2" == 1 ]] && envs+=(CLAUDE_EXECUTION_PAUSE_LAUNCH_CHECK=1)
  out="$(env ${envs[@]+"${envs[@]}"} "$GATE" --repo "$REPO" --status --session "$3" 2>/dev/null)" || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# Assert fast == locked in both modes, and (optionally) the expected verdicts.
check() { # name expected_normal expected_launch [session]
  local name="$1" exp_n="$2" exp_l="$3" session="${4:-$SID}" mode fast locked exp
  for mode in 0 1; do
    fast="$(run_status 0 "$mode" "$session")"
    locked="$(run_status 1 "$mode" "$session")"
    exp="$exp_n"; [[ "$mode" == 1 ]] && exp="$exp_l"
    if [[ "$fast" != "$locked" ]]; then
      fail "$name (launch=$mode): fast [$fast] != locked [$locked]"
    elif [[ "$fast" != "$exp" ]]; then
      fail "$name (launch=$mode): got [$fast], expected [$exp]"
    else
      pass
    fi
  done
}

gate_rec() { jq -nc --arg s "$1" --argjson a "$2" '{active:$a,command:"end",session_id:$s,at:"2026-11-19T00:00:00Z",cleared_at:null}'; }
repo_state() { jq -nc --arg r "$REPO" --argjson body "$1" '{repos:{($r):$body}}'; }

# --- primary gate --------------------------------------------------------
reset; check "missing state file" "0|inactive" "0|inactive"
reset; write_state 'not json{'; check "invalid JSON" "4|" "4|"
reset; write_state '{}{}'; check "two documents" "4|" "4|"
reset; write_state '[1]'; check "array root" "4|" "4|"
reset; write_state ''; check "empty file" "4|" "4|"
reset; write_state '{}'; check "empty object" "0|inactive" "0|inactive"
reset; write_state '{"repos":"x"}'; check "repos not an object" "4|" "4|"
for pair in 'true:0|active' 'false:0|inactive' 'null:0|inactive' '"true":0|active' \
            '"false":0|inactive' '"null":0|inactive' '1:4|' '{}:4|' '"yes":4|'; do
  value="${pair%%:*}"; expect="${pair#*:}"
  reset
  write_state "$(repo_state "$(jq -nc --arg s "$SID" --argjson v "$value" '{execution_pauses:{($s):{active:$v}}}')")"
  check "primary active=$value" "$expect" "$expect"
done

# --- markers -----------------------------------------------------------------
reset; write_state "$(repo_state "$(jq -nc --arg s "$SID" '{execution_pauses:{($s):{active:false}}}')")"
printf '{}\n' > "$(marker_of "$SID")"
check "marker wins over inactive state (interrupted clear)" "0|active" "0|active"
reset; write_state '{}'; printf '{}\n' > "$(marker_of "$SID")"
check "marker with no state record (interrupted activation)" "0|active" "0|active"
reset; write_state 'garbage'; printf '{}\n' > "$(marker_of "$SID")"
check "marker with corrupt state" "0|active" "0|active"
reset; printf '{}\n' > "$(marker_of "$SID")"
check "marker with missing state file" "0|active" "0|active"
reset; write_state '{}'; printf '{}\n' > "$TMP/marker-target"; ln -s "$TMP/marker-target" "$(marker_of "$SID")"
check "symlinked marker to a regular file" "0|active" "0|active"
reset; write_state '{}'; ln -s "$TMP/nowhere" "$(marker_of "$SID")"
check "dangling marker symlink" "0|inactive" "0|inactive"

# --- legacy rearming hold (launch-check mode, UUID session) --------------------
NULL_TOKEN="$(native_token null)"
legacy_fixture() { # binding-json tasks-json legacy-active-json [native-json]
  local native="${4:-null}"
  reset
  write_state "$(jq -nc --arg r "$REPO" --arg s "$SID" --arg l "$LEGACY" \
    --argjson b "$1" --argjson t "$2" --argjson la "$3" --argjson n "$native" '
    {repos:{($r):({legacy_end_resume_scopes:{($s):$b}, background_tasks:$t,
                  execution_pauses:{($l):{active:$la}}}
                 | if $n == null then . else .execution_pauses[$s] = $n end)}}')"
}
REARMING="$(jq -nc --arg l "$LEGACY" '[{session_id:$l,status:"rearming"}]')"
BINDING="$(jq -nc --arg l "$LEGACY" --arg t "$NULL_TOKEN" '{legacy:$l,native_token:$t}')"

legacy_fixture null "$REARMING" true
check "binding absent" "0|inactive" "0|inactive"
legacy_fixture '"not-an-object"' "$REARMING" true
check "malformed binding (string) holds" "0|inactive" "0|active"
legacy_fixture "$(jq -nc --arg t "$NULL_TOKEN" '{native_token:$t}')" "$REARMING" true
check "binding without legacy holds" "0|inactive" "0|active"
legacy_fixture "$(jq -nc --arg l "$LEGACY" '{legacy:$l,native_token:"short"}')" "$REARMING" true
check "binding with malformed token holds" "0|inactive" "0|active"
legacy_fixture "$(jq -nc --arg l "$LEGACY" '{legacy:$l,native_token:("0"*64)}')" "$REARMING" true
check "token mismatch releases" "0|inactive" "0|inactive"
legacy_fixture "$BINDING" "$REARMING" true
check "matching token + rearming + legacy gate active holds" "0|inactive" "0|active"
legacy_fixture "$BINDING" "$REARMING" '"true"'
check "legacy gate active as string holds" "0|inactive" "0|active"
legacy_fixture "$BINDING" "$REARMING" false
check "legacy gate inactive releases" "0|inactive" "0|inactive"
legacy_fixture "$BINDING" "$REARMING" false; printf '{}\n' > "$(marker_of "$LEGACY")"
check "legacy marker holds" "0|inactive" "0|active"
legacy_fixture "$BINDING" '[]' true
check "no rearming task releases" "0|inactive" "0|inactive"
legacy_fixture "$BINDING" null true
check "null task inventory releases" "0|inactive" "0|inactive"
legacy_fixture "$BINDING" '{"not":"array"}' true
check "malformed task inventory holds" "0|inactive" "0|active"
legacy_fixture "$BINDING" '["string-row"]' true
check "task row of wrong type holds" "0|inactive" "0|active"
legacy_fixture "$BINDING" "$REARMING" true; ln -s "$TMP/nowhere" "$(marker_of "$SID")"
check "dangling native marker holds" "0|inactive" "0|active"
INACTIVE_NATIVE='{"active":false,"command":"end","cleared_at":"2026-11-19T00:00:00Z"}'
legacy_fixture "$(jq -nc --arg l "$LEGACY" --arg t "$(native_token "$INACTIVE_NATIVE")" '{legacy:$l,native_token:$t}')" \
  "$REARMING" true "$INACTIVE_NATIVE"
check "inactive native gate record with matching token holds" "0|inactive" "0|active"
legacy_fixture "$BINDING" "$REARMING" true "$INACTIVE_NATIVE"
check "native gate changed since binding releases" "0|inactive" "0|inactive"
legacy_fixture "$BINDING" "$REARMING" true
check "non-UUID session never takes the legacy hold" "0|inactive" "0|inactive" "not-a-uuid"

# --- documented difference: flat legacy container -----------------------------
reset; write_state "$(jq -nc --arg s "$SID" '{prs:"malformed", repos:{"owner/repo":{execution_pauses:{($s):{active:false}}}}}')"
fast="$(run_status 0 1 "$SID")"
if [[ "$fast" == "0|inactive" ]]; then pass; else fail "malformed flat .prs: fast path should read inactive, got [$fast]"; fi

# --- status answers while another process holds the lock ------------------------
reset; write_state "$(repo_state "$(jq -nc --arg s "$SID" '{execution_pauses:{($s):{active:false}}}')")"
READY="$TMP/holder.ready"; RELEASE="$TMP/holder.release"
(
  # shellcheck source=../state-lock.sh
  source "$ROOT/.claude/scripts/state-lock.sh"
  state_lock_acquire "$STATE" 5 || exit 1
  : > "$READY"
  while [[ ! -e "$RELEASE" ]]; do sleep 0.05; done
  state_lock_release
) &
HOLDER=$!
for _ in $(seq 1 100); do [[ -e "$READY" ]] && break; sleep 0.05; done
if [[ -e "$READY" ]]; then
  got="$(CLAUDE_STATE_LOCK_TIMEOUT=1 run_status 0 1 "$SID")"
  if [[ "$got" == "0|inactive" ]]; then pass; else fail "fast status under a held lock: got [$got]"; fi
  printf '{}\n' > "$(marker_of "$SID")"
  got="$(CLAUDE_STATE_LOCK_TIMEOUT=1 run_status 0 1 "$SID")"
  if [[ "$got" == "0|active" ]]; then pass; else fail "fast status under a held lock with marker: got [$got]"; fi
  got="$(CLAUDE_STATE_LOCK_TIMEOUT=1 run_status 1 1 "$SID")"
  if [[ "$got" == 6\|* ]]; then pass; else fail "locked status under a held lock should exit 6: got [$got]"; fi
  if [[ -d "$STATE.lock" ]]; then pass; else fail "fast status must not touch the held lock"; fi
else
  fail "lock holder never became ready"
fi
: > "$RELEASE"; wait "$HOLDER" 2>/dev/null || true
if [[ ! -e "$STATE.lock" ]]; then pass; else fail "holder did not release the lock"; fi

# --- activation racing the lock-free status (CodeAnt 4630476552) ---------------
# (1) Activation blocked behind another lock holder: it has started but cannot
# take the lock. The marker must already be published, so status says active.
# Before the fix the marker came after acquisition and status read inactive.
reset; write_state "$(repo_state "$(jq -nc --arg s "$SID" '{execution_pauses:{($s):{active:false}}}')")"
READY="$TMP/race1.ready"; RELEASE="$TMP/race1.release"; rm -f "$READY" "$RELEASE"
(
  # shellcheck source=../state-lock.sh
  source "$ROOT/.claude/scripts/state-lock.sh"
  state_lock_acquire "$STATE" 5 || exit 1
  : > "$READY"
  while [[ ! -e "$RELEASE" ]]; do sleep 0.05; done
  state_lock_release
) &
HOLDER=$!
for _ in $(seq 1 100); do [[ -e "$READY" ]] && break; sleep 0.05; done
if [[ -e "$READY" ]]; then
  CLAUDE_STATE_LOCK_TIMEOUT=20 "$GATE" --repo "$REPO" --activate --session "$SID" \
    --command pause --window-minutes 5 >/dev/null 2>&1 &
  ACTIVATOR=$!
  for _ in $(seq 1 100); do [[ -f "$(marker_of "$SID")" ]] && break; sleep 0.05; done
  if [[ -f "$(marker_of "$SID")" ]]; then pass; else fail "activation waiting on the lock published no marker"; fi
  if [[ "$(jq -c --arg s "$SID" '.repos["owner/repo"].execution_pauses[$s].active' "$STATE")" == false ]]; then
    pass
  else
    fail "activation wrote state without holding the lock"
  fi
  for mode in 0 1; do
    got="$(run_status 0 "$mode" "$SID")"
    if [[ "$got" == "0|active" ]]; then pass; else fail "status during activation waiting on the lock (launch=$mode): got [$got]"; fi
  done
  : > "$RELEASE"; wait "$HOLDER" 2>/dev/null || true
  if wait "$ACTIVATOR"; then pass; else fail "activation failed after the lock freed"; fi
  got="$(run_status 0 1 "$SID")"
  if [[ "$got" == "0|active" ]]; then pass; else fail "status after activation: got [$got]"; fi
else
  fail "race lock holder never became ready"; : > "$RELEASE"; wait "$HOLDER" 2>/dev/null || true
fi

# (2) Activation holding the lock, stopped before its state write: a copy of
# the gate whose session-state.sh blocks every --set until released.
reset; write_state "$(repo_state "$(jq -nc --arg s "$SID" '{execution_pauses:{($s):{active:false}}}')")"
STUB="$TMP/stubbed-scripts"; mkdir -p "$STUB"
cp "$GATE" "$ROOT/.claude/scripts/state-lock.sh" "$STUB/"
REAL_SS="$ROOT/.claude/scripts/session-state.sh"
cat > "$STUB/session-state.sh" <<STUBEOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == --set ]]; then
    : > "$TMP/race2.entered"
    while [[ ! -e "$TMP/race2.release" ]]; do sleep 0.05; done
    break
  fi
done
exec "$REAL_SS" "\$@"
STUBEOF
chmod +x "$STUB/session-state.sh" "$STUB/execution-pause.sh"
"$STUB/execution-pause.sh" --repo "$REPO" --activate --session "$SID" \
  --command pause --window-minutes 5 >/dev/null 2>&1 &
ACTIVATOR=$!
for _ in $(seq 1 200); do [[ -e "$TMP/race2.entered" ]] && break; sleep 0.05; done
if [[ -e "$TMP/race2.entered" && -d "$STATE.lock" ]]; then
  pass
  for mode in 0 1; do
    got="$(run_status 0 "$mode" "$SID")"
    if [[ "$got" == "0|active" ]]; then pass; else fail "status while activation holds the lock (launch=$mode): got [$got]"; fi
  done
else
  fail "stubbed activation never reached its state write under the lock"
fi
: > "$TMP/race2.release"
if wait "$ACTIVATOR"; then pass; else fail "stubbed activation failed"; fi
got="$(run_status 0 0 "$SID")"
if [[ "$got" == "0|active" ]]; then pass; else fail "status after stubbed activation: got [$got]"; fi

echo "execution-pause-status: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
