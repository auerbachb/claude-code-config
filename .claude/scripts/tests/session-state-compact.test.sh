#!/usr/bin/env bash
# Tests for session-state-compact.sh and the post-write size trigger in
# session-state.sh (issue #2433 — the state file grew to megabytes and lock
# hold times blocked agent launches).
# catalog: tests — Tests for `session-state-compact.sh`
#
# Uses a temporary HOME so it never touches the real ~/.claude/. Requires jq.
# Run from repo root:
#   bash .claude/scripts/tests/session-state-compact.test.sh
# covers: .claude/scripts/session-state-compact.sh .claude/scripts/session-state.sh .claude/scripts/state-lock.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
COMPACT="$REPO_ROOT/.claude/scripts/session-state-compact.sh"
SS="$REPO_ROOT/.claude/scripts/session-state.sh"
LOCK_LIB="$REPO_ROOT/.claude/scripts/state-lock.sh"

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
STATE="$HOME/.claude/session-state.json"
ARCHIVE_DIR="$HOME/.claude/session-state-archive"
# The post-write trigger stays off unless a case turns it on.
export CLAUDE_STATE_COMPACT_AUTO=0
unset CLAUDE_STATE_LOCK_HELD CLAUDE_STATE_LOCK_TOKEN CLAUDE_STATE_COMPACT_RUNNING CLAUDE_SESSION_STATE_FILE \
      CLAUDE_STATE_COMPACT_PR_AGE_DAYS CLAUDE_STATE_COMPACT_AGENT_AGE_DAYS CLAUDE_STATE_COMPACT_TASK_AGE_DAYS \
      CLAUDE_STATE_COMPACT_HISTORY CLAUDE_STATE_COMPACT_SIZE_CAP CLAUDE_STATE_COMPACT_ARCHIVE_KEEP \
      CLAUDE_STATE_COMPACT_MIN_INTERVAL CLAUDE_STATE_COMPACT_ATTEMPT_INTERVAL
# Pin the archive to the fixture: an inherited override must never send test
# archives (or retention deletes) to a real archive directory.
export CLAUDE_STATE_COMPACT_ARCHIVE_DIR="$ARCHIVE_DIR"

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
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A large, multi-repo state: old and recent entries in every category, plus
# protected, undated and unknown data that must survive byte-for-byte.
build_state() {
  jq -n --arg now "$NOW_ISO" '
    def pad: "x" * 400;
    def repo($r): {
      prs: (
        ([range(0;150)] | map({key:("old\(.)"), value:{phase:"C", note:pad, merged_at:"2020-01-01T00:00:00Z"}}) | from_entries)
        + ([range(0;20)] | map({key:("new\(.)"), value:{phase:"A", note:pad, pipeline_started_at:$now}}) | from_entries)
        + {"babysit": {babysit:{active:true}, updated:"2020-01-01T00:00:00Z"},
           "needs": {wrap_sweep:{needs_decision:["follow up?"]}, merged_at:"2020-01-01T00:00:00Z"},
           "undated": {phase:"B", note:"no timestamp here"},
           "refd": {phase:"C", merged_at:"2020-01-01T00:00:00Z"}}
      ),
      background_tasks: ((
        [range(0;100)] | map({task_id:"old-done-\(.)", status:"done", session_id:"s", started_at:"2020-01-01T00:00:00Z", updated_at:"2020-01-02T00:00:00Z"})
      ) + [ {task_id:"old-running", status:"running", session_id:"s", started_at:"2020-01-01T00:00:00Z", updated_at:"2020-01-01T00:00:00Z"},
            {task_id:"old-stop-failed", status:"stop_failed", session_id:"s", updated_at:"2020-01-01T00:00:00Z"},
            {task_id:"new-done", status:"done", session_id:"s", started_at:$now, updated_at:$now},
            {task_id:"undated-done", status:"done", session_id:"s"} ]),
      mystery: {created:"2020-01-01T00:00:00Z", blob:pad},
      execution_pauses: {"sess-1": {active:true, armed_at:"2020-01-01T00:00:00Z"}}
    };
    {
      schema_version: 2,
      last_updated: $now,
      repos: { "org/one": repo("org/one"), "org/two": repo("org/two"), "_unknown": repo("_unknown") },
      active_agents: (
        ([range(0;30)] | map({key:"old-agent-\(.)", value:{id:"old-agent-\(.)", status:"spawned", launched:"2020-01-01T00:00:00Z"}}) | from_entries)
        + {"refd-agent": {id:"refd-agent", pr:"new3", status:"spawned", launched:"2020-01-01T00:00:00Z"},
           "new-agent": {id:"new-agent", status:"spawned", launched:$now},
           "undated-agent": {id:"undated-agent", status:"spawned"}}
      ),
      polling_failures: [range(0;150) | {at:"2020-01-01T00:00:00Z", n:.}],
      pauses: {"x": {status:"parked", parked_at:"2020-01-01T00:00:00Z"}},
      zzz_unknown_category: {at:"2020-01-01T00:00:00Z", keep:"me"}
    }' > "$STATE"
}

PROTECTED_FILTER='{
  pauses, zzz_unknown_category, schema_version, last_updated,
  repos: (.repos | map_values({mystery, execution_pauses,
            babysit: .prs.babysit, needs: .prs.needs, undated: .prs.undated,
            live: [.background_tasks[] | select(.status == "running" or .status == "stop_failed" or .task_id == "undated-done")]})),
  agents: {refd: .active_agents["refd-agent"], undated: .active_agents["undated-agent"]}
}'

echo "== --check is read-only =="
build_state
touch -t 202001010000 "$STATE"
B_BYTES="$(cat "$STATE")"; B_MTIME="$(mtime_of "$STATE")"
OUT="$(bash "$COMPACT" --check 2>&1)"; RC=$?
check_eq "--check exits 0" "0" "$RC"
check_eq "--check reports eligible items" "1" "$(grep -c 'eligible: .*pr ' <<<"$OUT")"
check_eq "--check leaves bytes unchanged" "$B_BYTES" "$(cat "$STATE")"
check_eq "--check leaves mtime unchanged" "$B_MTIME" "$(mtime_of "$STATE")"
check_eq "--check --json is one JSON object" "object" "$(bash "$COMPACT" --check --json | jq -r 'type')"
check_eq "--check wrote no archive" "0" "$([[ -d "$ARCHIVE_DIR" ]] && echo 1 || echo 0)"

echo
echo "== --apply archives old entries and preserves everything else =="
BEFORE_PROTECTED="$(jq -cS "$PROTECTED_FILTER" "$STATE")"
OUT="$(bash "$COMPACT" --apply 2>&1)"; RC=$?
check_eq "--apply exits 0" "0" "$RC"
check_eq "result is one valid JSON document" "true" "$(jq -s 'length == 1 and (.[0] | type) == "object"' "$STATE")"
check_eq "protected, undated and unknown data byte-equal" "$BEFORE_PROTECTED" "$(jq -cS "$PROTECTED_FILTER" "$STATE")"
check_eq "old PRs gone (every scope, _unknown included)" "0" \
  "$(jq '[.repos[].prs | keys[] | select(startswith("old"))] | length' "$STATE")"
check_eq "recent PRs kept" "60" "$(jq '[.repos[].prs | keys[] | select(startswith("new"))] | length' "$STATE")"
check_eq "old terminal tasks gone" "0" "$(jq '[.repos[].background_tasks[] | select(.task_id | startswith("old-done"))] | length' "$STATE")"
check_eq "recent terminal task kept" "3" "$(jq '[.repos[].background_tasks[] | select(.task_id == "new-done")] | length' "$STATE")"
check_eq "old unreferenced agents gone" "0" "$(jq '[.active_agents | keys[] | select(startswith("old-agent"))] | length' "$STATE")"
check_eq "recent agent kept" "true" "$(jq '.active_agents | has("new-agent")' "$STATE")"
check_eq "history trimmed to newest 100" "100 50" "$(jq -r '.polling_failures | "\(length) \(.[0].n)"' "$STATE")"
ARCH="$(ls "$ARCHIVE_DIR"/compact-*.json 2>/dev/null | head -n 1)"
check_eq "one archive file written" "1" "$(ls "$ARCHIVE_DIR"/compact-*.json 2>/dev/null | wc -l | tr -d ' ')"
check_eq "archive dir mode 700" "700" "$(mode_of "$ARCHIVE_DIR")"
check_eq "archive file mode 600" "600" "$(mode_of "$ARCH")"
check_eq "archive holds every old PR with its path" "450" \
  "$(jq '[.items[] | select(.cat == "pr" and .path[2] == "prs" and (.path[3] | startswith("old")))] | length' "$ARCH")"
check_eq "archived PR value is the original entry" "C" \
  "$(jq -r '.items[] | select(.path == ["repos","org/one","prs","old7"]) | .value.phase' "$ARCH")"
check_eq "archive records a compaction id" "true" "$(jq '.compaction_id | type == "string" and length > 0' "$ARCH")"
check_eq "stamp written" "1" "$([[ -f "$STATE.compact.stamp" ]] && echo 1 || echo 0)"

echo
echo "== A no-op --apply does not rewrite =="
touch -t 202001010000 "$STATE"
B_BYTES="$(cat "$STATE")"; B_MTIME="$(mtime_of "$STATE")"
bash "$COMPACT" --apply >/dev/null 2>&1; RC=$?
check_eq "no-op --apply exits 0" "0" "$RC"
check_eq "bytes unchanged" "$B_BYTES" "$(cat "$STATE")"
check_eq "mtime unchanged" "$B_MTIME" "$(mtime_of "$STATE")"
check_eq "no second archive" "1" "$(ls "$ARCHIVE_DIR"/compact-*.json | wc -l | tr -d ' ')"

echo
echo "== --if-due skips while the stamp is fresh =="
build_state
B_BYTES="$(cat "$STATE")"
bash "$COMPACT" --apply --if-due 3600 >/dev/null 2>&1
check_eq "fresh stamp: nothing applied" "$B_BYTES" "$(cat "$STATE")"
touch -t 202001010000 "$STATE.compact.stamp"
bash "$COMPACT" --apply --if-due 3600 >/dev/null 2>&1
check_eq "(control) stale stamp: compaction applied" "0" \
  "$(jq '[.repos[].prs | keys[] | select(startswith("old"))] | length' "$STATE")"

echo
echo "== A held lock: exit 6, bytes unchanged, stamp untouched =="
build_state
rm -f "$STATE.compact.stamp"
B_BYTES="$(cat "$STATE")"
H="$TMP_HOME/hold"; mkdir -p "$H"
bash -c 'source "$1"; state_lock_acquire "$2" 5 || exit 6; : > "$3/held"
         while [[ ! -e "$3/release" ]]; do sleep 0.05; done; state_lock_release' \
  _ "$LOCK_LIB" "$STATE" "$H" &
HOLDER=$!
for _ in $(seq 1 200); do [[ -e "$H/held" ]] && break; sleep 0.05; done
OUT="$(bash "$COMPACT" --apply --lock-timeout 1 2>&1)"; RC=$?
: > "$H/release"; wait "$HOLDER"
check_eq "exit 6 under a held lock" "6" "$RC"
check_eq "lock diagnostic names a holder" "1" "$(grep -c 'held by pid [0-9]' <<<"$OUT")"
check_eq "bytes unchanged" "$B_BYTES" "$(cat "$STATE")"
check_eq "stamp not written on exit 6" "0" "$([[ -f "$STATE.compact.stamp" ]] && echo 1 || echo 0)"
check_eq "guard released" "0" "$([[ -d "$STATE.compact.run" ]] && echo 1 || echo 0)"

echo
echo "== A concurrent session-state.sh --set is serialized behind the compactor =="
build_state
SHIM="$TMP_HOME/jq-shim"; PARK="$TMP_HOME/park"; rm -rf "$PARK"; mkdir -p "$SHIM" "$PARK"
REAL_JQ="$(command -v jq)"
cat > "$SHIM/jq" <<SH
#!/bin/bash
if [[ -n "\${COMPACT_PARK:-}" && ! -e "\$COMPACT_PARK/parked" && "\$*" == *"def compact_plan"* ]]; then
  : > "\$COMPACT_PARK/parked"
  while [[ ! -e "\$COMPACT_PARK/release" ]]; do sleep 0.05; done
fi
exec "$REAL_JQ" "\$@"
SH
chmod +x "$SHIM/jq"
( PATH="$SHIM:$PATH" COMPACT_PARK="$PARK" bash "$COMPACT" --apply >/dev/null 2>&1; echo "$?" > "$PARK/compact.rc" ) &
CPID=$!
for _ in $(seq 1 200); do [[ -e "$PARK/parked" ]] && break; sleep 0.05; done
check_eq "(setup) compactor parked inside its jq pass, under the lock" "1" \
  "$([[ -e "$PARK/parked" && -d "$STATE.lock" ]] && echo 1 || echo 0)"
( CLAUDE_STATE_LOCK_TIMEOUT=30 bash "$SS" --set '.marker="survives"'; echo "$?" > "$PARK/set.rc" ) &
SPID=$!
sleep 0.5
check_eq "the --set is waiting on the lock" "0" "$([[ -e "$PARK/set.rc" ]] && echo 1 || echo 0)"
: > "$PARK/release"
wait "$CPID" "$SPID"
check_eq "compactor exited 0" "0" "$(cat "$PARK/compact.rc")"
check_eq "--set exited 0" "0" "$(cat "$PARK/set.rc")"
check_eq "the concurrent --set value survived" "survives" "$(jq -r '.marker' "$STATE")"
check_eq "the compaction landed too" "0" "$(jq '[.repos[].prs | keys[] | select(startswith("old"))] | length' "$STATE")"

echo
echo "== Negative control: an UNLOCKED rewrite loses the concurrent value =="
build_state
SNAPSHOT="$(cat "$STATE")"
bash "$SS" --set '.marker="lost"' >/dev/null 2>&1
printf '%s\n' "$SNAPSHOT" > "$STATE"   # a writer that read before the --set and never locked
check_eq "the unlocked rewrite dropped the value (the race the lock prevents)" "null" "$(jq -r '.marker' "$STATE")"

echo
echo "== Size cap: recent unprotected items go oldest first; protected never =="
build_state
BEFORE_PROTECTED="$(jq -cS "$PROTECTED_FILTER" "$STATE")"
bash "$COMPACT" --apply --size-cap 20000 >/dev/null 2>&1; RC=$?
check_eq "size-cap --apply exits 0" "0" "$RC"
check_eq "protected data still byte-equal" "$BEFORE_PROTECTED" "$(jq -cS "$PROTECTED_FILTER" "$STATE")"
check_eq "recent PRs were archived to meet the cap" "true" \
  "$(jq '[.repos[].prs | keys[] | select(startswith("new"))] | length < 60' "$STATE")"
check_eq "size pass recorded in the archive" "true" \
  "$(jq -s '[.[].items[] | select(.cat == "pr" and (.path[3] | startswith("new")))] | length > 0' "$ARCHIVE_DIR"/compact-*.json)"
# An unreachable cap drains every eligible item: a recent agent with no PR
# link must still survive (it may be live).
bash "$COMPACT" --apply --size-cap 1 >/dev/null 2>&1
check_eq "size pass never archives a live (recent) agent" "spawned" \
  "$(jq -r '.active_agents["new-agent"].status' "$STATE")"

echo
echo "== Size cap is met in real bytes, even with multibyte-heavy retained data =="
rm -rf "$ARCHIVE_DIR"
jq -n --arg now "$NOW_ISO" '{
  repos: {"org/u": {
    notes: ("€" * 60000),
    prs: ([range(0;200)] | map({key:"p\(.)", value:{note:("a" * 1000), pipeline_started_at:$now}}) | from_entries)}}
}' > "$STATE"
U_CAP=250000
bash "$COMPACT" --apply --size-cap "$U_CAP" >/dev/null 2>&1; RC=$?
check_eq "multibyte fixture: --apply exits 0" "0" "$RC"
check_eq "multibyte fixture: committed file is at or under the cap" "1" \
  "$(( $(wc -c < "$STATE") <= U_CAP ))"
check_eq "multibyte fixture: the multibyte text is retained" "60000" "$(jq '.repos["org/u"].notes | length' "$STATE")"

echo
echo "== Post-write trigger: fires only above the cap, never recursively =="
rm -rf "$ARCHIVE_DIR"; build_state
rm -f "$STATE.compact.stamp" "$STATE.compact.attempt"
SMALL="$(( $(wc -c < "$STATE") - 1 ))"
BIG="$(( $(wc -c < "$STATE") * 4 ))"
CLAUDE_STATE_COMPACT_AUTO=1 CLAUDE_STATE_COMPACT_SIZE_CAP="$BIG" bash "$SS" --set '.t1=1'
check_eq "below the cap: no spawn" "0" "$([[ -e "$STATE.compact.attempt" ]] && echo 1 || echo 0)"
CLAUDE_STATE_COMPACT_AUTO=1 CLAUDE_STATE_COMPACT_SIZE_CAP="$SMALL" CLAUDE_STATE_COMPACT_RUNNING=1 bash "$SS" --set '.t2=1'
check_eq "inside a compactor run: no spawn" "0" "$([[ -e "$STATE.compact.attempt" ]] && echo 1 || echo 0)"
bash -c 'source "$1"; state_lock_acquire "$2" 5 || exit 6
         CLAUDE_STATE_COMPACT_AUTO=1 CLAUDE_STATE_COMPACT_SIZE_CAP="$3" bash "$4" --set ".t3=1"
         state_lock_release' _ "$LOCK_LIB" "$STATE" "$SMALL" "$SS"
check_eq "inside an inherited lock: no spawn" "0" "$([[ -e "$STATE.compact.attempt" ]] && echo 1 || echo 0)"
check_eq "(control) the nested write itself landed" "1" "$(jq -r '.t3' "$STATE")"
CLAUDE_STATE_COMPACT_AUTO=1 CLAUDE_STATE_COMPACT_SIZE_CAP="$SMALL" bash "$SS" --set '.t4=1'; RC=$?
check_eq "above the cap: the --set itself still exits 0" "0" "$RC"
check_eq "above the cap: spawn recorded" "1" "$([[ -e "$STATE.compact.attempt" ]] && echo 1 || echo 0)"
for _ in $(seq 1 200); do [[ -f "$STATE.compact.stamp" ]] && break; sleep 0.05; done
check_eq "the detached compactor ran and stamped" "1" "$([[ -f "$STATE.compact.stamp" ]] && echo 1 || echo 0)"
check_eq "the detached compactor archived old entries" "0" \
  "$(jq '[.repos[].prs | keys[] | select(startswith("old"))] | length' "$STATE")"
check_eq "the --set value survived the compaction" "1" "$(jq -r '.t4' "$STATE")"
rm -f "$STATE.compact.attempt"
CLAUDE_STATE_COMPACT_AUTO=1 CLAUDE_STATE_COMPACT_SIZE_CAP=1 bash "$SS" --set '.t5=1'
check_eq "a fresh stamp gates the next spawn" "0" "$([[ -e "$STATE.compact.attempt" ]] && echo 1 || echo 0)"

echo
echo "== Eligibility edge cases: malformed status, offsets, invalid dates, agent-referenced PRs =="
rm -rf "$ARCHIVE_DIR"
jq -n --arg now "$NOW_ISO" '{
  repos: {"org/e": {
    prs: {
      "11": {merged_at:"2020-01-01T00:00:00Z"},
      "12": {merged_at:"2020-00-01T00:00:00Z"},
      "13": {merged_at:($now[0:10] + "T23:59:59-11:00")},
      "14": {merged_at:"2020-01-01T00:00:00+05:30"},
      "15": {merged_at:"2020-01-01T00:00:00+99:99"}
    },
    background_tasks: [
      {task_id:"arr-status", status:["done"], updated_at:"2020-01-01T00:00:00Z"},
      {task_id:"plain-done", status:"done", updated_at:"2020-01-01T00:00:00Z"},
      {task_id:"bad-offset-done", status:"done", updated_at:"2020-01-01T00:00:00+99:99"},
      {task_id:"stopped-recent", status:"stopped", updated_at:(($now | fromdateiso8601) - 5*86400 | todateiso8601)},
      {task_id:"failed-recent", status:"failed", updated_at:(($now | fromdateiso8601) - 5*86400 | todateiso8601)},
      {task_id:"stopped-ancient", status:"stopped", updated_at:"2020-01-01T00:00:00Z"}
    ]}},
  active_agents: {"recent": {id:"recent", pr:"11", launched:$now}}
}' > "$STATE"
bash "$COMPACT" --apply --pr-age-days 08 >/dev/null 2>&1; RC=$?
check_eq "leading-zero day count accepted as decimal" "0" "$RC"
check_eq "PR referenced by a kept agent is retained" "true" "$(jq '.repos["org/e"].prs | has("11")' "$STATE")"
check_eq "invalid date is not a timestamp: retained" "true" "$(jq '.repos["org/e"].prs | has("12")' "$STATE")"
check_eq "offset timestamp that is recent in UTC is retained" "true" "$(jq '.repos["org/e"].prs | has("13")' "$STATE")"
check_eq "old offset timestamp is eligible" "false" "$(jq '.repos["org/e"].prs | has("14")' "$STATE")"
check_eq "array status is not terminal: retained" "1" \
  "$(jq '[.repos["org/e"].background_tasks[] | select(.task_id == "arr-status")] | length' "$STATE")"
check_eq "plain terminal status archived" "0" \
  "$(jq '[.repos["org/e"].background_tasks[] | select(.task_id == "plain-done")] | length' "$STATE")"
check_eq "out-of-range offset is not a timestamp: PR retained" "true" "$(jq '.repos["org/e"].prs | has("15")' "$STATE")"
check_eq "out-of-range offset is not a timestamp: task retained" "1" \
  "$(jq '[.repos["org/e"].background_tasks[] | select(.task_id == "bad-offset-done")] | length' "$STATE")"
check_eq "recoverable stopped/failed tasks inside the 30-day window retained" "2" \
  "$(jq '[.repos["org/e"].background_tasks[] | select(.task_id | test("-recent$"))] | length' "$STATE")"
check_eq "a stopped task past the 30-day window is archived" "0" \
  "$(jq '[.repos["org/e"].background_tasks[] | select(.task_id == "stopped-ancient")] | length' "$STATE")"

echo
echo "== Size pass keeps a PR any retained agent names; candidate is owner-only =="
rm -rf "$ARCHIVE_DIR"
jq -n --arg now "$NOW_ISO" '{
  repos: {"org/s": {prs: {
    "21": {note:("x" * 4000), pipeline_started_at:$now},
    "22": {note:("x" * 4000), pipeline_started_at:$now}}}},
  active_agents: {"old-but-kept": {id:"old-but-kept", pr:21, launched:"2020-01-01T00:00:00Z"}}
}' > "$STATE"
chmod 600 "$STATE"
(umask 022; bash "$COMPACT" --apply --size-cap 1 >/dev/null 2>&1)
check_eq "PR named by an old agent the age pass kept survives the size pass" "true" \
  "$(jq '.repos["org/s"].prs | has("21")' "$STATE")"
check_eq "(control) an unreferenced recent PR is size-archived" "false" "$(jq '.repos["org/s"].prs | has("22")' "$STATE")"
check_eq "state file stays 0600 after an apply under umask 022" "600" "$(mode_of "$STATE")"

echo
echo "== Archive retention only rotates this state file's archives =="
rm -rf "$ARCHIVE_DIR"; mkdir -p "$ARCHIVE_DIR"; chmod 700 "$ARCHIVE_DIR"
: > "$ARCHIVE_DIR/compact-other-state.json-20200101T000000Z-1-1.json"
build_state
bash "$COMPACT" --apply --keep-archives 1 >/dev/null 2>&1
check_eq "another state file's archive survives rotation" "1" \
  "$([[ -f "$ARCHIVE_DIR/compact-other-state.json-20200101T000000Z-1-1.json" ]] && echo 1 || echo 0)"
# Same basename, different directory, shared archive dir.
OTHER="$HOME/elsewhere/session-state.json"; mkdir -p "${OTHER%/*}"
build_state; cp "$STATE" "$OTHER"
bash "$COMPACT" --apply --keep-archives 1 --state-file "$OTHER" >/dev/null 2>&1
build_state
bash "$COMPACT" --apply --keep-archives 1 >/dev/null 2>&1
check_eq "same-basename state files keep separate archives under rotation" "2" \
  "$(find "$ARCHIVE_DIR" -name 'compact-session-state.json-*.json' | wc -l | tr -d ' ')"
build_state
bash "$COMPACT" --apply --keep-archives 1 >/dev/null 2>&1
check_eq "(control) rotation still trims this file's own archives" "2" \
  "$(find "$ARCHIVE_DIR" -name 'compact-session-state.json-*.json' | wc -l | tr -d ' ')"
# A checksum collision: same prefix, older name, but another state_file.
PFX="compact-session-state.json-$(printf '%s' "$STATE" | cksum | awk '{print $1}')-"
printf '{"state_file":"/elsewhere/colliding/session-state.json","items":[]}\n' \
  > "$ARCHIVE_DIR/${PFX}20000101T000000.000000Z-1-1.json"
build_state
bash "$COMPACT" --apply --keep-archives 1 >/dev/null 2>&1
check_eq "a colliding-prefix archive of another state file survives rotation" "1" \
  "$([[ -f "$ARCHIVE_DIR/${PFX}20000101T000000.000000Z-1-1.json" ]] && echo 1 || echo 0)"
# Back-to-back runs (same second is likely): the newest archive is the one kept.
build_state; bash "$COMPACT" --apply --keep-archives 1 >/dev/null 2>&1
build_state
LAST="$(bash "$COMPACT" --apply --keep-archives 1 2>/dev/null | sed -n 's/.* to \(.*\.json\)$/\1/p' | head -n 1)"
check_eq "back-to-back runs keep the newest archive" "1" "$([[ -n "$LAST" && -f "$LAST" ]] && echo 1 || echo 0)"
check_eq "back-to-back runs keep exactly one own archive" "1" \
  "$(find "$ARCHIVE_DIR" -name "${PFX}*.json" ! -name '*20000101T*' | wc -l | tr -d ' ')"
# Seconds-only clock fallback: same-second runs must still sort in creation
# order (no reliance on pid order).
# Deterministic: an existing archive whose stamp is not older than the clock
# (here: far future) must still sort BEFORE the new run's archive.
jq -n --arg s "$STATE" '{state_file:$s, items:[]}' > "$ARCHIVE_DIR/${PFX}29991231T235959.000000Z-99999-1.json"
build_state
LAST="$(CLAUDE_STATE_COMPACT_CLOCK_FALLBACK=1 bash "$COMPACT" --apply --keep-archives 1 2>/dev/null \
        | sed -n 's/.* to \(.*\.json\)$/\1/p' | head -n 1)"
check_eq "clock fallback: the newest archive survives same-second rotation" "1" \
  "$([[ -n "$LAST" && -f "$LAST" ]] && echo 1 || echo 0)"
check_eq "clock fallback: exactly one own archive kept" "1" \
  "$(find "$ARCHIVE_DIR" -name "${PFX}*.json" ! -name '*20000101T*' | wc -l | tr -d ' ')"
# Microsecond rollover: after .999999 the next id carries into the next second.
find "$ARCHIVE_DIR" -name "${PFX}*.json" ! -name '*20000101T*' -exec rm -f {} +
jq -n --arg s "$STATE" '{state_file:$s, items:[]}' > "$ARCHIVE_DIR/${PFX}29991231T235958.999999Z-99999-1.json"
build_state
LAST="$(CLAUDE_STATE_COMPACT_CLOCK_FALLBACK=1 bash "$COMPACT" --apply --keep-archives 1 2>/dev/null \
        | sed -n 's/.* to \(.*\.json\)$/\1/p' | head -n 1)"
check_eq "rollover: the new id carries into the next second" "1" \
  "$([[ "$LAST" == *"-29991231T235959.000000Z-"* && -f "$LAST" ]] && echo 1 || echo 0)"
check_eq "rollover: the older .999999 archive is the one rotated out" "0" \
  "$(find "$ARCHIVE_DIR" -name "${PFX}29991231T235958.999999Z-*" | wc -l | tr -d ' ')"

echo
echo "== Run guard: ownerless fresh guard is in progress; dead owner is reclaimed =="
build_state
B_BYTES="$(cat "$STATE")"
mkdir "$STATE.compact.run"
bash "$COMPACT" --apply >/dev/null 2>&1; RC=$?
check_eq "fresh ownerless guard: exit 0, nothing applied" "0 same" \
  "$RC $([[ "$(cat "$STATE")" == "$B_BYTES" ]] && echo same || echo changed)"
( : ) & DEAD=$!; wait "$DEAD"
printf '%s\n' "$DEAD" > "$STATE.compact.run/pid"
bash "$COMPACT" --apply >/dev/null 2>&1
check_eq "dead-owner guard reclaimed and compaction applied" "0" \
  "$(jq '[.repos[].prs | keys[] | select(startswith("old"))] | length' "$STATE")"
check_eq "guard released afterwards" "0" "$([[ -d "$STATE.compact.run" ]] && echo 1 || echo 0)"

echo
echo "== Missing and invalid state files =="
rm -f "$STATE"
bash "$COMPACT" --apply >/dev/null 2>&1; check_eq "missing file: exit 3" "3" "$?"
printf '[1,2]\n' > "$STATE"
bash "$COMPACT" --apply >/dev/null 2>&1; check_eq "non-object state: exit 4" "4" "$?"
check_eq "non-object state untouched" "[1,2]" "$(tr -d '\n' < "$STATE")"
printf '{}\n{}\n' > "$STATE"
bash "$COMPACT" --check >/dev/null 2>&1; check_eq "two documents: --check exit 4" "4" "$?"
bash "$COMPACT" --bogus >/dev/null 2>&1; check_eq "unknown flag: exit 2" "2" "$?"

echo
echo "== summary: $PASS passed, $FAIL failed =="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED: session-state compaction tests" >&2
  exit 1
fi
echo "OK: session-state compaction tests passed"
