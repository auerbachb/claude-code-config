#!/usr/bin/env bash
# Offline unit tests for candidate-ownership.sh (issue #1431 — /pm's pre-dispatch
# ownership sweep).
#
# Seeds the real state sources — a session-state.json under a temp HOME, handoff
# and marker files, a session listing — and stubs `gh` and `issue-claim.sh` so a
# whole ownership scenario can be constructed and asserted without network or
# auth. The stubs are stateful per scenario: each `scenario` call resets them.
#
# Run from repo root:
#   bash .claude/scripts/tests/candidate-ownership.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/candidate-ownership.sh"
REAL_SESSION_STATE="$REPO_ROOT/.claude/scripts/session-state.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT

export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude/handoffs"

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
check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected to contain '$needle', got '$haystack')"
  fi
}
check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected NOT to contain '$needle')"
  fi
}

# Negative control: a check that cannot fail is not a check. Run the assertion
# helpers IN THIS SHELL (not a subshell — the counters would not survive) against
# inputs that must fail, and confirm they actually registered.
check_eq "negative control (expected to fail)" "a" "b" >/dev/null
check_contains "negative control (expected to fail)" "needle" "haystack" >/dev/null
check_not_contains "negative control (expected to fail)" "hay" "haystack" >/dev/null
if [[ "$FAIL" -ne 3 || "$PASS" -ne 0 ]]; then
  echo "FAIL — negative control: assertion helpers did not register 3 failures (got $FAIL fail / $PASS pass)" >&2
  exit 1
fi
FAIL=0; PASS=0

# ---- stub tree ----------------------------------------------------------------
STUB_BIN="$TMP/bin"        # gh + git shims on PATH
STUB_SCRIPTS="$TMP/scripts" # sibling helpers resolved by the script under test
mkdir -p "$STUB_BIN" "$STUB_SCRIPTS"
export CANDIDATE_OWNERSHIP_SCRIPT_DIR="$STUB_SCRIPTS"

# Every helper the sweep may invoke records its argv here, so the read-only
# guarantee is asserted against calls that ACTUALLY happened rather than against
# a log nothing writes (a guard that passes by not running is not a guard).
HELPER_LOG="$TMP/helper-calls.log"
: > "$HELPER_LOG"
export CANDIDATE_OWNERSHIP_TEST_LOG="$HELPER_LOG"

# The real session-state.sh does the reading — the sweep must work against the
# actual reader, including its "invisible to --session-view" blocks. It runs
# from its own directory (it sources sibling libraries) behind a logging shim,
# and writes to the temp state file named by $CLAUDE_SESSION_STATE_FILE.
cat > "$STUB_SCRIPTS/session-state.sh" <<STUB
#!/usr/bin/env bash
printf 'session-state.sh %s\n' "\$*" >> "\${CANDIDATE_OWNERSHIP_TEST_LOG:-/dev/null}"
exec bash "$REAL_SESSION_STATE" "\$@"
STUB
chmod +x "$STUB_SCRIPTS/session-state.sh"

# issue-claim.sh stub: verdict comes from $FAKE_CLAIM_<issue>, default unclaimed.
cat > "$STUB_SCRIPTS/issue-claim.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf 'issue-claim.sh %s\n' "$*" >> "${CANDIDATE_OWNERSHIP_TEST_LOG:-/dev/null}"
ISSUE=""
for a in "$@"; do [[ "$a" =~ ^[0-9]+$ ]] && { ISSUE="$a"; break; }; done
VAR="FAKE_CLAIM_${ISSUE}"
SPEC="${!VAR:-unclaimed}"
# SPEC is "verdict[:holder[:login]]"; the literal "__FAIL__" exits like a gh error.
if [[ "$SPEC" == "__FAIL__" ]]; then
  echo "issue-claim.sh: boom" >&2
  exit 4
fi
# A gate that runs but returns something unreadable — the "unavailable" verdict.
if [[ "$SPEC" == "__GARBAGE__" ]]; then
  echo "not json <<<"
  exit 5
fi
VERDICT="${SPEC%%:*}"
REST="${SPEC#*:}"; [[ "$REST" == "$SPEC" ]] && REST=""
HOLDER="${REST%%:*}"
LOGIN="${REST#*:}"; [[ "$LOGIN" == "$REST" ]] && LOGIN=""
STALE=false; [[ "$VERDICT" == "stale" ]] && STALE=true
jq -cn --argjson issue "$ISSUE" --arg verdict "$VERDICT" \
   --arg holder "$HOLDER" --arg login "$LOGIN" --argjson stale "$STALE" \
  '{issue:$issue, repo:null, viewer:"alice", holder:"selfholder", verdict:$verdict,
    claimant:(if $login == "" then null else $login end),
    claimant_holder:(if $holder == "" then null else $holder end),
    claimed_at:"2026-08-28T00:00:00Z", stale:$stale, overridden:false, reason:"stub"}'
case "$VERDICT" in
  claimed) exit 1 ;;
  unknown) exit 4 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_SCRIPTS/issue-claim.sh"

# gh stub: issue list (in-progress index) + pr list (open PRs) + repo view.
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  issue)
    if [[ "${FAKE_GH_ISSUE_LIST_MODE:-ok}" == "error" ]]; then
      echo "gh: HTTP 500" >&2; exit 1
    fi
    cat "${FAKE_LABELED_FILE:-/dev/null}" 2>/dev/null || true
    ;;
  pr)
    if [[ "${FAKE_GH_PR_LIST_MODE:-ok}" == "error" ]]; then
      echo "gh: HTTP 500" >&2; exit 1
    fi
    cat "${FAKE_PRS_FILE:-/dev/null}" 2>/dev/null || echo '[]'
    ;;
  repo) printf '%s\n' "${FAKE_REPO:-testowner/testrepo}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# git shim: only `for-each-ref` matters (surviving-branch probe). Everything else
# forwards to the real git by absolute path — never by `command -v git`, which
# would re-enter this shim (self-recursion).
REAL_GIT="$(command -v git)"
cat > "$STUB_BIN/git" <<STUB
#!/usr/bin/env bash
set -uo pipefail
if [[ "\${1:-}" == "for-each-ref" ]]; then
  cat "\${FAKE_BRANCHES_FILE:-/dev/null}" 2>/dev/null || true
  exit 0
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$STUB_BIN/git"
export PATH="$STUB_BIN:$PATH"

# ---- fixtures ------------------------------------------------------------------
STATE_FILE="$HOME/.claude/session-state.json"
export CLAUDE_SESSION_STATE_FILE="$STATE_FILE"
export CLAUDE_SESSION_REPO="testowner/testrepo"
export CLAUDE_SESSION_ID="selfsession"
export CLAUDE_CLAIM_HOLDER="selfholder"
REPO_KEY="testowner/testrepo"

PRS_FILE="$TMP/prs.json"
LABELED_FILE="$TMP/labeled.txt"
BRANCHES_FILE="$TMP/branches.txt"
SESSIONS_FILE="$TMP/sessions.json"
export FAKE_PRS_FILE="$PRS_FILE" FAKE_LABELED_FILE="$LABELED_FILE" \
       FAKE_BRANCHES_FILE="$BRANCHES_FILE"

scenario() { # scenario <name> — reset every seeded source
  echo
  echo "== $1 =="
  echo '[]' > "$PRS_FILE"
  : > "$LABELED_FILE"
  : > "$BRANCHES_FILE"
  echo '{"schema_version":2,"repos":{}}' > "$STATE_FILE"
  rm -f "$SESSIONS_FILE"
  rm -rf "${HOME:?}/.claude/handoffs"
  mkdir -p "$HOME/.claude/handoffs"
  unset FAKE_GH_ISSUE_LIST_MODE FAKE_GH_PR_LIST_MODE
  # shellcheck disable=SC2046  # deliberate: clear every per-scenario claim var
  unset $(compgen -v | grep '^FAKE_CLAIM_' || true) 2>/dev/null || true
}

seed_pr() { # seed_pr <pr> <issue> <branch>
  jq --argjson n "$1" --arg body "Closes #$2" --arg br "$3" \
    '. + [{number:$n, title:"t", body:$body, headRefName:$br, url:"u",
           author:{login:"alice"}}]' "$PRS_FILE" > "$PRS_FILE.tmp" \
    && mv "$PRS_FILE.tmp" "$PRS_FILE"
}

# Repo-scoped seeding. session-state.sh only auto-scopes `.prs` and `.root_repo`,
# so `.pause` / `.background_tasks` MUST be written at their explicit
# `.repos["<key>"]` path — a bare `.pause=` lands at the top level, where the
# sweep (correctly) never looks.
seed_pr_body() { # seed_pr_body <pr> <body> <branch>
  jq --argjson n "$1" --arg body "$2" --arg br "$3" \
    '. + [{number:$n, title:"t", body:$body, headRefName:$br, url:"u",
           author:{login:"alice"}}]' "$PRS_FILE" > "$PRS_FILE.tmp" \
    && mv "$PRS_FILE.tmp" "$PRS_FILE"
}

seed_state() { # seed_state <repo-scoped-subpath>=<json>   e.g. .pause={...}
  "$STUB_SCRIPTS/session-state.sh" --set ".repos[\"$REPO_KEY\"]$1" >/dev/null
}

seed_sessions() { # seed_sessions <json-array>
  printf '%s' "$1" > "$SESSIONS_FILE"
}

seed_handoff() { # seed_handoff <pr> <phase>
  local dir="$HOME/.claude/handoffs/testowner/testrepo"
  mkdir -p "$dir"
  jq -n --argjson pr "$1" --arg phase "$2" \
    '{schema_version:"1.0", pr_number:$pr, head_sha:"abc1234", reviewer:"cr",
      phase_completed:$phase, created_at:"2026-08-28T00:00:00Z",
      findings_fixed:[], findings_dismissed:[], threads_replied:[],
      threads_resolved:[], files_changed:[], push_timestamp:"2026-08-28T00:00:00Z",
      notes:"seeded"}' > "$dir/pr-$1-handoff.json"
}

sweep() { # sweep <issue>... ; sets OUT/ERR/RC (JSON mode)
  local errfile="$TMP/err" args=("$@")
  # Fixture seeding also goes through the logging shim; truncate so the
  # read-only assertion only ever sees calls the sweep itself made.
  : > "$HELPER_LOG"
  [[ -f "$SESSIONS_FILE" ]] && args+=(--sessions "$SESSIONS_FILE")
  OUT="$(bash "$SCRIPT" "${args[@]}" --json 2>"$errfile")"; RC=$?
  ERR="$(cat "$errfile")"
}

field() { # field <issue> <jq-path>
  printf '%s' "$OUT" | jq -r --argjson n "$1" \
    'select(.issue == $n) | '"$2"
}

############################################################################
scenario "(1) no other threads — a seeded backlog dispatches unchanged (regression control)"
sweep 101 102
check_eq "exit 0" 0 "$RC"
check_eq "#101 dispatches" "dispatch" "$(field 101 '.action')"
check_eq "#101 unowned" "unowned" "$(field 101 '.verdict')"
check_eq "#101 not owned" "false" "$(field 101 '.owned')"
check_eq "#102 dispatches too" "dispatch" "$(field 102 '.action')"
check_eq "no degradation noise" "0" "$(field 101 '.degraded | length')"
check_eq "one line per candidate" 2 "$(printf '%s' "$OUT" | jq -s 'length')"
check_eq "the clean path says nothing on stderr" "" "$ERR"

############################################################################
scenario "(2) parked-but-live thread owning an issue — skip, name the thread + route"
export FAKE_CLAIM_201="claimed:threadX:alice"
seed_pr 900 201 "issue-201-feature"
seed_state ".pause={\"active\":true,\"paused_at\":\"2026-08-28T00:00:00Z\",\"parked\":[{\"kind\":\"pr\",\"ref\":900,\"branch\":\"issue-201-feature\",\"stopped_at\":\"awaiting review\",\"next_move\":\"poll\"}],\"marker_path\":\"$HOME/.claude/handoffs/pause-x.md\"}"
seed_sessions '[{"id":"threadX","status":"paused","title":"Issue #201 coding thread"}]'
sweep 201
check_eq "owned" "true" "$(field 201 '.owned')"
check_eq "verdict owned_live" "owned_live" "$(field 201 '.verdict')"
check_eq "action skip" "skip" "$(field 201 '.action')"
check_eq "state paused" "paused" "$(field 201 '.state')"
check_eq "liveness live" "live" "$(field 201 '.liveness')"
check_eq "human-readable owner label wins over the id" "Issue #201 coding thread" "$(field 201 '.owner_label')"
check_eq "owner session id carried" "threadX" "$(field 201 '.owner_session_id')"
check_eq "resume route /go-on" "/go-on" "$(field 201 '.resume_route')"
check_contains "parked evidence named" "parked by /pause" "$(field 201 '.evidence | join("|")')"
check_contains "reason points at the route" "resume it there with /go-on" "$(field 201 '.reason')"

echo "-- (2b) the same fixture with NO session listing stays live (indeterminate -> live) --"
rm -f "$SESSIONS_FILE"
sweep 201
check_eq "liveness indeterminate" "indeterminate" "$(field 201 '.liveness')"
check_eq "still surfaced, never adopted" "skip" "$(field 201 '.action')"
check_eq "verdict owned_live" "owned_live" "$(field 201 '.verdict')"

############################################################################
scenario "(3) dead/archived owner with surviving branch + handoff — adopt from the PR"
export FAKE_CLAIM_301="stale:threadDead:alice"
seed_pr 901 301 "issue-301-feature"
seed_handoff 901 A
printf 'issue-301-feature\n' > "$BRANCHES_FILE"
seed_sessions '[{"id":"threadOther","status":"open","title":"unrelated"}]'
sweep 301
check_eq "owned" "true" "$(field 301 '.owned')"
check_eq "verdict owned_dead" "owned_dead" "$(field 301 '.verdict')"
check_eq "action adopt" "adopt" "$(field 301 '.action')"
check_eq "liveness dead (absent from the listing)" "dead" "$(field 301 '.liveness')"
check_eq "adopts from the open PR, not a fresh start" "pr" "$(field 301 '.adopt.from')"
check_eq "adopt PR number" "901" "$(field 301 '.adopt.pr')"
check_eq "adopt resumes at phase b (Phase A already completed)" "b" "$(field 301 '.adopt.phase')"
check_contains "handoff file named as the resume state" "pr-901-handoff.json" "$(field 301 '.adopt.handoff_path')"
check_contains "owned-resumable upgrade recorded" "owned-resumable upgrade" "$(field 301 '.evidence | join("|")')"

echo "-- (3b) dead owner, Phase B handoff — adoption moves to phase c --"
seed_handoff 901 B
sweep 301
check_eq "phase c" "c" "$(field 301 '.adopt.phase')"

echo "-- (3c) dead owner, branch only (no PR) — adopt at phase a --"
scenario "(3c) dead owner with only a surviving branch"
export FAKE_CLAIM_302="stale:threadDead:alice"
printf 'issue-302-feature\n' > "$BRANCHES_FILE"
seed_state ".background_tasks=[{\"task_id\":\"t1\",\"name\":\"phase-a-302\",\"type\":\"agent\",\"session_id\":\"threadDead\",\"work_item\":\"Issue #302\",\"status\":\"stopped\",\"recovery_path\":\"/w/issue-302-feature\"}]"
seed_sessions '[]'
sweep 302
check_eq "adopt" "adopt" "$(field 302 '.action')"
check_eq "from branch" "branch" "$(field 302 '.adopt.from')"
check_eq "phase a" "a" "$(field 302 '.adopt.phase')"
check_eq "owner label from the registry entry name" "phase-a-302" "$(field 302 '.owner_label')"

############################################################################
scenario "(4) stale claim with NO resumable state — warn-and-proceed preserved"
export FAKE_CLAIM_401="stale:threadGone:alice"
sweep 401
check_eq "not owned" "false" "$(field 401 '.owned')"
check_eq "verdict unowned" "unowned" "$(field 401 '.verdict')"
check_eq "action dispatch" "dispatch" "$(field 401 '.action')"
check_contains "says why the upgrade did not fire" "bare stale claim" "$(field 401 '.evidence | join("|")')"

echo "-- (4b) the SAME stale claim WITH a marker behind it flips to owned --"
printf 'Repository: testowner/testrepo\nParked: #401 mid-implementation\n' \
  > "$HOME/.claude/handoffs/pause-20260828T000000Z-9-testowner-8-testrepo-threadGone-AbCdEf.md"
seed_sessions '[{"id":"threadGone","status":"paused","title":"parked thread"}]'
sweep 401
check_eq "now owned" "true" "$(field 401 '.owned')"
check_eq "skipped, not dispatched" "skip" "$(field 401 '.action')"
check_eq "state paused" "paused" "$(field 401 '.state')"
check_eq "session id parsed out of the marker filename" "threadGone" "$(field 401 '.owner_session_id')"

echo "-- (4c) a marker written by THIS session is not foreign ownership --"
scenario "(4c) self-owned marker"
export FAKE_CLAIM_402="stale:selfholder:alice"
printf 'Parked: #402\n' \
  > "$HOME/.claude/handoffs/pause-20260828T000000Z-9-testowner-8-testrepo-selfsession-AbCdEf.md"
sweep 402
check_eq "dispatch (own marker)" "dispatch" "$(field 402 '.action')"
check_contains "self-attribution stated" "belongs to this session" "$(field 402 '.evidence | join("|")')"

# $HANDOFF_DIR is shared across repositories and the marker match is issue/PR
# TEXT only, so #403 exists in every repo. Before the repo check, a foreign
# marker owned this candidate outright — and, with its session archived, carried
# it into owned_dead/adopt: /pm would have adopted another repo's parked work.
echo "-- (4d) a marker belonging to ANOTHER repo is not evidence at all --"
scenario "(4d) foreign-repo marker"
export FAKE_CLAIM_403="stale:threadFar:alice"
# Real markers render the repo inside backticks; 4b covers the bare form, so
# between them both shapes the parser must strip are exercised. The backtick is
# built from a variable rather than written literally inside single quotes,
# which shellcheck reads as an unexpanded command substitution (SC2016).
BT='`'
printf 'Repository: %sotherowner/otherrepo%s\nParked: #403 mid-implementation\n' "$BT" "$BT" \
  > "$HOME/.claude/handoffs/pause-20260828T000000Z-10-otherowner-9-otherrepo-threadFar-AbCdEf.md"
seed_sessions '[{"id":"threadOther","status":"open","title":"unrelated"}]'
sweep 403
check_eq "not owned by a foreign marker" "false" "$(field 403 '.owned')"
check_eq "still dispatchable" "dispatch" "$(field 403 '.action')"
check_eq "and never adopted from it" "unowned" "$(field 403 '.verdict')"
check_not_contains "foreign marker is not cited as evidence" "otherrepo" \
  "$(field 403 '.evidence | join("|")')"

# The name says `unknown` (a `/`-less repo key) and there is no Repository line,
# so the marker may or may not be ours. It still surfaces — fail toward
# surfacing — but its session id must not reach the liveness lookup, where
# `absent from the listing` = dead would turn it into an adoption.
# The candidate is deliberately UNCLAIMED so the marker is the sole evidence:
# a stale claim would supply an owner session of its own (that one IS attributable
# to this repo), and the assertions below would then be testing the claim path.
echo "-- (4e) an unattributable marker surfaces but can never adopt --"
scenario "(4e) unattributable marker"
printf 'Parked: #404 mid-implementation\n' \
  > "$HOME/.claude/handoffs/pause-20260828T000000Z-unknown-threadUnk-AbCdEf.md"
seed_sessions '[{"id":"someoneElse","status":"open","title":"unrelated"}]'
sweep 404
check_eq "owned (surfaced)" "true" "$(field 404 '.owned')"
check_eq "skip, never adopt" "skip" "$(field 404 '.action')"
check_eq "owner session withheld (emitted null, per the JSON contract)" "null" \
  "$(field 404 '.owner_session_id')"
check_not_contains "the marker's session never becomes the owner" "threadUnk" \
  "$(field 404 '.owner_session_id')"
check_eq "liveness stays indeterminate" "indeterminate" "$(field 404 '.liveness')"
check_contains "ambiguity is named, not silent" "repository unattributable" \
  "$(field 404 '.evidence | join("|")')"
check_contains "and recorded as degradation" "no repository attribution" \
  "$(field 404 '.degraded | join("|")')"

# Real session ids are UUIDs and /pause keeps their dashes in the filename.
# Reading the id as a single dash field returned only the UUID's LAST group, and
# a truncated id is absent from the listing — which this script reads as `dead`,
# the one verdict that adopts. A live paused thread would be resumed underneath.
echo "-- (4h) a UUID session id survives the filename parse intact --"
# Unclaimed on purpose: a claim supplies an owner session of its own, and
# note_owner is first-write-wins, so a claimed candidate would never exercise
# the marker's own parse.
scenario "(4h) dashed session id"
UUID_SESSION="1d4add05-6a7b-4fad-804b-4986398d6642"
printf 'Repository: testowner/testrepo\nParked: #407 mid-implementation\n' \
  > "$HOME/.claude/handoffs/pause-20260828T000000Z-9-testowner-8-testrepo-$UUID_SESSION-QW3tbW.md"
seed_sessions "[{\"id\":\"$UUID_SESSION\",\"status\":\"paused\",\"title\":\"parked uuid thread\"}]"
sweep 407
check_eq "full UUID recovered, not its last group" "$UUID_SESSION" \
  "$(field 407 '.owner_session_id')"
check_eq "so the listing matches and the owner reads live" "live" "$(field 407 '.liveness')"
check_eq "surfaced, never adopted" "skip" "$(field 407 '.action')"
check_eq "verdict owned_live" "owned_live" "$(field 407 '.verdict')"
check_eq "and the listing title is used" "parked uuid thread" "$(field 407 '.owner_label')"

echo "-- (4i) and a UUID-named marker from THIS session is still self-attributed --"
scenario "(4i) dashed self session id"
export CLAUDE_SESSION_ID="aaaa1111-bbbb-2222-cccc-333344445555"
export FAKE_CLAIM_408="stale:selfholder:alice"
printf 'Repository: testowner/testrepo\nParked: #408\n' \
  > "$HOME/.claude/handoffs/pause-20260828T000000Z-9-testowner-8-testrepo-$CLAUDE_SESSION_ID-QW3tbW.md"
sweep 408
check_eq "own UUID marker is not foreign ownership" "dispatch" "$(field 408 '.action')"
check_contains "self-attribution stated" "belongs to this session" \
  "$(field 408 '.evidence | join("|")')"
export CLAUDE_SESSION_ID="selfsession"

# `claimant_holder` is whatever the claiming thread resolved, and the documented
# last resort is `<hostname>:<worktree path>` — never a session-listing entry.
# Looking it up returns "absent", which this script reads as `dead`, so a
# readable listing turned an ordinary claim into an adoption.
# The real fallback token is `<hostname>:<path>`, carrying both a colon and a
# slash; the stub's own SPEC separator is `:`, so the path half is what this
# fixture can express. Either character alone is enough to prove the token is
# not a session id, which is exactly what the guard keys on.
echo "-- (4j) a holder-shaped owner token is not looked up as a session --"
scenario "(4j) path-shaped holder"
export FAKE_CLAIM_409="stale:/Users/dev/worktrees/repo:alice"
seed_pr 909 409 "issue-409-feature"
seed_sessions '[{"id":"someoneElse","status":"open","title":"unrelated"}]'
sweep 409
check_eq "liveness indeterminate, not dead" "indeterminate" "$(field 409 '.liveness')"
check_eq "so the owner is treated as live" "owned_live" "$(field 409 '.verdict')"
check_eq "surfaced, never adopted" "skip" "$(field 409 '.action')"
check_contains "and the reason is named, not silent" "holder-shaped" \
  "$(field 409 '.degraded | join("|")')"

############################################################################
# execution-pause.sh writes ONLY to .repos[<key>].execution_pauses[<session>],
# and session-state.sh rewrites just `.prs`/`.root_repo` into repo scope — so
# the original top-level `.execution_pauses` read matched nothing and every
# /end and /pause launch gate was invisible to the sweep.
scenario "(4f) an active execution pause is read at its repo-scoped path"
export FAKE_CLAIM_405="claimed:threadPaused:alice"
seed_state ".execution_pauses={\"threadPaused\":{\"active\":true,\"command\":\"pause\",\"session_id\":\"threadPaused\",\"window_minutes\":10,\"deadline_epoch\":9999999999,\"at\":\"2026-08-28T00:00:00Z\",\"cleared_at\":null}}"
seed_sessions '[{"id":"threadPaused","status":"open","title":"gated thread"}]'
sweep 405
check_eq "owned" "true" "$(field 405 '.owned')"
check_eq "state paused, not active" "paused" "$(field 405 '.state')"
check_contains "launch gate cited" "execution pause active for session threadPaused" \
  "$(field 405 '.evidence | join("|")')"
# Negative control: the same record at the TOP level is the pre-fix shape, and
# must NOT be picked up — otherwise this pair would pass against either path.
scenario "(4g) a top-level execution_pauses record is not the contract"
export FAKE_CLAIM_406="claimed:threadPaused:alice"
"$STUB_SCRIPTS/session-state.sh" --raw-path --set '.execution_pauses={"threadPaused":{"active":true,"command":"pause"}}' >/dev/null
seed_sessions '[{"id":"threadPaused","status":"open","title":"gated thread"}]'
sweep 406
check_not_contains "top-level record ignored" "execution pause active" \
  "$(field 406 '.evidence | join("|")')"

############################################################################
scenario "(5) candidate owned by the paused PR fleet — route is /pmm-wake"
export FAKE_CLAIM_501="claimed:threadFleet:alice"
seed_pr 902 501 "issue-501-feature"
"$STUB_SCRIPTS/session-state.sh" --set '.pmm_active=false' >/dev/null
"$STUB_SCRIPTS/session-state.sh" --set '.pmm={"paused_at":"2026-08-28T00:00:00Z","fleet_at_pause":[902]}' >/dev/null
seed_sessions '[{"id":"threadFleet","status":"open","title":"fleet"}]'
sweep 501
check_eq "owned" "true" "$(field 501 '.owned')"
check_eq "skip" "skip" "$(field 501 '.action')"
check_eq "fleet route" "/pr-monitor-and-manage-wake" "$(field 501 '.resume_route')"
check_contains "fleet evidence named" "paused /pr-monitor-and-manage fleet" "$(field 501 '.evidence | join("|")')"

############################################################################
scenario "(6) corrupt session-state and handoff — named, degraded, never a whole-sweep skip"
export FAKE_CLAIM_601="stale:threadZ:alice"
printf 'not json at all' > "$STATE_FILE"
seed_pr 903 601 "issue-601-feature"
mkdir -p "$HOME/.claude/handoffs/testowner/testrepo"
printf '{{{ broken' > "$HOME/.claude/handoffs/testowner/testrepo/pr-903-handoff.json"
sweep 601 602
check_eq "sweep still exits 0" 0 "$RC"
check_eq "both candidates still answered" 2 "$(printf '%s' "$OUT" | jq -s 'length')"
check_contains "corrupt state named" "session-state.sh --get" "$(field 601 '.degraded | join("|")')"
check_contains "corrupt handoff named" "pr-903-handoff.json" "$(field 601 '.degraded | join("|")')"
check_eq "the unowned sibling still dispatches" "dispatch" "$(field 602 '.action')"
check_eq "a read failure alone never marks a candidate owned" "false" "$(field 602 '.owned')"

echo "-- (6b) gh failures degrade, they do not block dispatch --"
scenario "(6b) gh list failures"
export FAKE_GH_PR_LIST_MODE=error FAKE_GH_ISSUE_LIST_MODE=error
sweep 611
check_eq "still dispatches" "dispatch" "$(field 611 '.action')"
check_contains "gh pr list named" "gh pr list" "$(field 611 '.degraded | join("|")')"
check_contains "gh issue list named" "gh issue list" "$(field 611 '.degraded | join("|")')"
unset FAKE_GH_PR_LIST_MODE FAKE_GH_ISSUE_LIST_MODE

############################################################################
scenario "(7) the claim gate still outranks the sweep"
export FAKE_CLAIM_701="unknown"
export FAKE_CLAIM_702="claimed:threadFresh:alice"
seed_sessions '[]'   # threadFresh is absent -> dead
sweep 701 702
check_eq "unknown claim is skipped (fail-closed)" "skip" "$(field 701 '.action')"
check_contains "and says why" "fail-closed" "$(field 701 '.reason')"
check_eq "fresh foreign claim + dead session is still NOT adopted" "skip" "$(field 702 '.action')"
check_eq "verdict records the dead owner" "owned_dead" "$(field 702 '.verdict')"
check_contains "names the override requirement" "explicit user override" "$(field 702 '.reason')"

echo "-- (7b) an UNDETERMINED claim never authorizes a takeover, dead owner or not --"
# Adoption re-uses issue-claim.sh's stale-takeover path, which fails closed on
# `unknown`. Reporting `adopt` here would promise a takeover that cannot happen.
scenario "(7b) unknown claim + dead owner + surviving state"
export FAKE_CLAIM_703="unknown"
seed_pr 905 703 "issue-703-feature"
seed_state ".background_tasks=[{\"task_id\":\"t9\",\"name\":\"phase-a-703\",\"type\":\"agent\",\"session_id\":\"threadGhost\",\"work_item\":\"Issue #703\",\"status\":\"stopped\"}]"
seed_sessions '[]'
sweep 703
check_eq "owner is dead" "dead" "$(field 703 '.liveness')"
check_eq "verdict still owned_dead" "owned_dead" "$(field 703 '.verdict')"
check_eq "but the action is skip, never adopt" "skip" "$(field 703 '.action')"
check_contains "and the reason names the fail-closed rule" "fail-closed" "$(field 703 '.reason')"

echo "-- (7c) an unreadable claim gate: surface, never take over a claim we cannot read --"
scenario "(7c) issue-claim.sh returns garbage"
export FAKE_CLAIM_704="__GARBAGE__"
seed_pr 906 704 "issue-704-feature"
seed_state ".background_tasks=[{\"task_id\":\"t10\",\"name\":\"phase-a-704\",\"type\":\"agent\",\"session_id\":\"threadGhost2\",\"work_item\":\"Issue #704\",\"status\":\"stopped\"}]"
seed_sessions '[]'
sweep 704
check_eq "claim verdict is unavailable" "unavailable" "$(field 704 '.claim_verdict')"
check_eq "skip, not adopt" "skip" "$(field 704 '.action')"
check_contains "the broken gate is named" "issue-claim.sh --check: unparseable output" \
  "$(field 704 '.degraded | join("|")')"
unset FAKE_CLAIM_704

############################################################################
scenario "(8) plain (non-JSON) output is one stable line per candidate"
export FAKE_CLAIM_801="claimed:threadX:alice"
seed_pr 904 801 "issue-801-feature"
seed_state ".pause={\"active\":true,\"parked\":[{\"kind\":\"pr\",\"ref\":904,\"branch\":\"issue-801-feature\",\"stopped_at\":\"parked\"}]}"
seed_sessions '[{"id":"threadX","status":"paused","title":"Thread X"}]'
PLAIN="$(bash "$SCRIPT" 801 802 --sessions "$SESSIONS_FILE" 2>/dev/null)"
check_contains "owned line names action, state and route" \
  "#801 skip verdict=owned_live state=paused liveness=live owner=Thread X route=/go-on" "$PLAIN"
check_contains "unowned line present" "#802 dispatch verdict=unowned" "$PLAIN"
check_not_contains "no degraded line when nothing degraded" "#802 degraded:" "$PLAIN"

############################################################################
scenario "(9) usage errors and the read-only guarantee"
run_rc() { bash "$SCRIPT" "$@" >/dev/null 2>&1; echo $?; }
check_eq "no candidates" 2 "$(run_rc)"
check_eq "non-numeric candidate" 2 "$(run_rc abc)"
check_eq "unknown flag" 2 "$(run_rc 1 --nope)"
check_eq "--repo without a value" 2 "$(run_rc 1 --repo)"
check_eq "malformed --repo" 2 "$(run_rc 1 --repo not-a-repo)"
check_eq "--help exits 0" 0 "$(run_rc --help)"
HELP_OUT="$(bash "$SCRIPT" --help 2>/dev/null)"
for section in '--sessions' '--json' 'EXIT STATUS' 'owned_dead'; do
  check_contains "--help documents $section" "$section" "$HELP_OUT"
done

# Read-only: the script must never mutate state, and must never call a claim
# write. A `--claim`/`--release`/`--set` reaching a stub is a hard failure.
scenario "(9b) read-only guarantee"
seed_state '.refill={"paused":false}'
# Resolve a hash tool ONCE and fail loudly if there is none: two empty strings
# compare equal, so an unavailable hasher would make this assertion pass while
# proving nothing about the file.
HASHER=""
for h in shasum sha1sum md5sum cksum; do
  command -v "$h" >/dev/null 2>&1 && { HASHER="$h"; break; }
done
[[ -n "$HASHER" ]] || { echo "FAIL — no hash tool available; cannot verify the read-only guarantee" >&2; exit 1; }
hash_state() { "$HASHER" "$STATE_FILE" | awk '{print $1}'; }
BEFORE="$(hash_state)"
export FAKE_CLAIM_901="stale:threadQ:alice"
printf 'issue-901-x\n' > "$BRANCHES_FILE"
sweep 901
AFTER="$(hash_state)"
check_eq "the state hash is non-empty (the hasher actually ran)" "true" \
  "$([[ -n "$BEFORE" ]] && echo true || echo false)"
check_eq "session-state.json is byte-identical after a sweep" "$BEFORE" "$AFTER"
# The log must be non-empty first, or "zero writes" would be satisfied by a
# sweep that called nothing at all.
# `grep -c` PRINTS 0 and EXITS 1 on no match, so a `|| echo 0` fallback would
# emit a second line and the comparison would read "0\n0". Swallow the status.
HELPER_CALLS="$(grep -c . "$HELPER_LOG" 2>/dev/null || true)"
check_eq "the sweep did call its helpers" "true" "$( (( ${HELPER_CALLS:-0} > 0 )) && echo true || echo false )"
check_eq "and every call was a read — no --claim / --release / --set" "0" \
  "$(grep -cE -- '(--claim|--release|--set)( |$)' "$HELPER_LOG" 2>/dev/null || true)"
check_eq "the claim gate was consulted with --check" "true" \
  "$(grep -q -- '--check' "$HELPER_LOG" && echo true || echo false)"

############################################################################
scenario "(9c) closing-ref matching is repo-scoped and keyword-tolerant"
# A PR that closes ANOTHER repo's #950 must not be read as this repo's #950 —
# a false link would adopt or skip a candidate on someone else's work.
export FAKE_CLAIM_950="stale:threadFar:alice"
seed_pr_body 950 "Closes otherowner/otherrepo#950" "issue-950-elsewhere"
seed_sessions '[]'
sweep 950
check_eq "a cross-repo closing ref does not link" "dispatch" "$(field 950 '.action')"
check_eq "and leaves nothing to adopt" "null" "$(field 950 '.adopt.from')"

scenario "(9d) the no-space and colon keyword forms both link"
export FAKE_CLAIM_951="stale:threadNear:alice"
export FAKE_CLAIM_952="stale:threadNear:alice"
seed_pr_body 960 "Closes:#951" "issue-951-x"
seed_pr_body 961 "Fixes testowner/testrepo#952" "issue-952-x"
seed_sessions '[]'
sweep 951 952
check_eq "Closes:#N links (adoption has a PR)" "pr" "$(field 951 '.adopt.from')"
check_eq "own-repo qualified ref links" "pr" "$(field 952 '.adopt.from')"
check_eq "and the linked PR is the right one" "961" "$(field 952 '.adopt.pr')"

############################################################################
# The helper is only half the feature: `/pm` has to run it at both dispatch
# points and print a stable line. These assert the wiring, since a sweep nothing
# calls is indistinguishable from no sweep at all.
echo
echo "== (10) /pm wiring and output contract =="
PM_SKILL="$REPO_ROOT/.claude/skills/pm/SKILL.md"
in_pm() { grep -qF -- "$1" "$PM_SKILL" && echo true || echo false; }

# The needles are literal snippets containing `$(`, backticks, and braces. They
# live in a QUOTED heredoc so every character stays literal without a suppression
# comment — a doc-contract fixture that expanded would match nothing forever.
NEEDLES_FILE="$TMP/pm-needles.txt"
cat > "$NEEDLES_FILE" <<'NEEDLES'
CANDIDATE_OWNERSHIP=$(resolve_script candidate-ownership.sh || true)
DEGRADED: candidate-ownership.sh not found
**Ownership sweep (runs after ranking and window-fit selection, before dispatch).**
- `#N` — owned by {owner_label} ({state}); resume with {resume_route}
- `#N` — adopted from {owner_label} (archived); resuming from {adopt.from} #{adopt.pr}
- `#N` — sweep degraded: {degraded[0]}; using claim gate only
plus the 1B.5 ownership sweep
**Read ownership per pick, not once per tick**
/pr-monitor-and-manage-wake
NEEDLES
while IFS= read -r needle; do
  [[ -z "$needle" ]] && continue
  check_eq "pm/SKILL.md contains: $needle" "true" "$(in_pm "$needle")"
done < "$NEEDLES_FILE"
# Negative control for in_pm(): a string that is certainly absent must read false.
check_eq "in_pm() control" "false" "$(in_pm 'candidate-ownership.sh --claim')"

REF="$REPO_ROOT/.claude/reference/pm-ownership-sweep.md"
check_eq "reference doc exists" "true" "$([[ -f "$REF" ]] && echo true || echo false)"
for needle in 'owned-resumable upgrade' 'Liveness fails toward surfacing' \
              'Degradation contract' 'Read-only guarantee' 'Reader set'; do
  check_eq "reference doc covers: $needle" "true" \
    "$(grep -qF -- "$needle" "$REF" && echo true || echo false)"
done

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: candidate-ownership.sh tests passed"
