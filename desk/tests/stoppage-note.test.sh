#!/usr/bin/env bash
# desk/tests/stoppage-note.test.sh — offline contract tests for stoppage-note.sh
# (issue #2292, round 2): the one call the orchestration steps make to log the
# causes only they know (`out_of_work`, `blocked_by_error`). Needs no database:
# the CLI is a stub that records its arguments.
#
# Asserts:
#   - usage errors exit 2 and write nothing (no command, bad picked count, bad
#     phase, missing reason, bad pr)
#   - refill with nothing launched and `nothing eligible` records one
#     out_of_work entry (thread, repo, source, ref from the round, evidence),
#     opens the marker, and a second call writes nothing more
#   - every other idle reason (chained, paused, budget, horizon, priority) and
#     an empty reason record nothing: they are held or planned, not out of work
#   - nothing is recorded while a subagent still works a pipeline of the repo or
#     a round issue, during a /pause or /end gate, an unreadable gate, or at a
#     leave time's pause point
#   - refill that launched work closes an open entry (resume) and removes the
#     marker, and does nothing without one
#   - blocked records blocked_by_error with the phase, the ref and a bounded
#     one-line reason, once per stretch
#   - no session id, a failing CLI, or a missing helper script keep exit 0 and
#     silence; a secret-shaped or odd reason never reaches the call as shell
#     syntax
#
# Every case runs under `bash` on PATH and, when /bin/bash is 3.x (macOS), too.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: stoppage-note.test.sh — jq is not installed"
  exit 0
fi

NOTE="$HQ_T_DESK_DIR/bin/stoppage-note.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-stoppage-note-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

STUBS="$TMP/stubs"
KEEP="$TMP/keep"
CALLS="$TMP/calls"
mkdir -p "$STUBS"
cat >"$STUBS/cli.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STP_CALLS"
exit "${STP_CLI_RC:-0}"
EOF
cat >"$STUBS/execution-pause.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STP_PAUSE_FILE"
EOF
cat >"$STUBS/session-state.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--session-view*) printf '{"active_agents":%s}\n' "$(cat "$STP_AGENTS_FILE")" ;;
  *) cat "$STP_REPO_FILE" ;;
esac
EOF
chmod +x "$STUBS"/*.sh

REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" remote add origin "https://user:pw@github.com/acme/widgets.git"

ROUND='{"rounds":{"sess-1":{"members":["2292","2293"],"dispatched_at":"2026-11-13T18:00:00Z","session":"sess-1"}},"pipelines":{"2292":{"started_at":"2026-11-13T18:01:00Z"}}}'

reset() {
  printf 'inactive\n' >"$TMP/pause"
  printf '%s\n' "$ROUND" >"$TMP/repostate"
  printf '{}\n' >"$TMP/agents"
  : >"$CALLS"
  rm -rf "$KEEP"
}

# note SHELL ARGS... — sets NOUT (stdout+stderr), NRC; leaves the CLI calls.
note() {
  local sh="$1"
  shift
  NRC=0
  (cd "$REPO" && env HUMAN_QUEUE_CLI="$STUBS/cli.sh" STOPPAGE_SCRIPTS_DIR="$STUBS" \
    HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" STP_CALLS="$CALLS" STP_PAUSE_FILE="$TMP/pause" \
    STP_REPO_FILE="$TMP/repostate" STP_AGENTS_FILE="$TMP/agents" \
    CLAUDE_SESSION_ID="${SID-sess-1}" "$sh" "$NOTE" "$@") >"$TMP/nout" 2>&1 || NRC=$?
  NOUT=$(cat "$TMP/nout")
}
calls() { cat "$CALLS"; }
marker() { [ -f "$KEEP/open/sess-1" ] && echo yes || echo no; }

for SH in $SHELLS; do
  P="[$SH] "
  SID=sess-1

  # ---- usage -------------------------------------------------------------------
  reset
  for bad in "" "frobnicate" "refill" "refill --picked x" "refill --picked 0 --nope 1" \
             "blocked --phase D --pr 5 --reason r" "blocked --phase B --pr 5" \
             "blocked --phase B --reason r" "blocked --phase B --pr x --reason r"; do
    # shellcheck disable=SC2086
    note "$SH" $bad
    check "${P}usage error '$bad' exits 2" "$NRC" "2"
    check "${P}usage error '$bad' writes nothing" "$(calls)" ""
  done

  # ---- out_of_work -------------------------------------------------------------
  reset
  note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}out_of_work: exit 0" "$NRC" "0"
  check "${P}out_of_work: silent" "$NOUT" ""
  check "${P}out_of_work: one record call" "$(hq_t_lines "$(calls)")" "1"
  check_contains "${P}out_of_work: thread and repo" "$(calls)" "stoppage record --thread sess-1 --repo acme/widgets"
  check_contains "${P}out_of_work: cause" "$(calls)" "--cause out_of_work"
  check_contains "${P}out_of_work: the round's first issue is the ref" "$(calls)" "--ref issue#2292"
  check_contains "${P}out_of_work: evidence" "$(calls)" "--evidence slot idle: nothing eligible"
  check_contains "${P}out_of_work: source" "$(calls)" "--source manual"
  check_absent "${P}out_of_work: no credentials from the remote" "$(calls)" "pw@"
  check "${P}out_of_work: opens the marker" "$(marker)" "yes"
  : >"$CALLS"
  note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}out_of_work: one entry per stretch" "$(calls)" ""

  reset
  note "$SH" refill --picked 0 --reason "nothing eligible (scope: #2292)"
  check_contains "${P}out_of_work: the scope reason is kept" "$(calls)" "nothing eligible (scope: #2292)"

  for why in "" "chained" "paused" "paused (pipeline failures)" "paused (budget reached)" \
             "paused (priority unreadable)" "paused (horizon approaching)" "ceiling reached"; do
    reset
    note "$SH" refill --picked 0 ${why:+--reason "$why"}
    check "${P}non-case: idle reason '$why' is not out of work" "$(calls)$(marker)" "no"
  done

  # ---- the thread is not stopped / the stop is planned -------------------------
  reset
  printf '{"a1":{"issue":2293,"status":"running"}}\n' >"$TMP/agents"
  note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}running subagent on a round issue: nothing" "$(calls)" ""
  reset
  printf '{"a1":{"issue":2292,"status":"spawned"}}\n' >"$TMP/agents"
  note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}spawned subagent on a pipeline issue: nothing" "$(calls)" ""
  reset
  printf '{"a1":{"issue":555,"status":"running"}}\n' >"$TMP/agents"
  note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}a subagent on some other issue does not hide it" "$(hq_t_lines "$(calls)")" "1"
  reset
  printf '{"a1":{"issue":2293,"status":"done"}}\n' >"$TMP/agents"
  note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}a finished subagent does not hide it" "$(hq_t_lines "$(calls)")" "1"
  reset
  printf 'active\n' >"$TMP/pause"
  note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}non-case: /pause or /end is a planned stop" "$(calls)" ""
  printf 'garbled\n' >"$TMP/pause"
  note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}an unreadable gate is not 'no gate'" "$(calls)" ""
  reset
  printf '%s\n' "$ROUND" | jq -c --argjson d "$(( $(date +%s) + 600 ))" \
    '. + {window: {deadline_epoch: $d}, leave: {lead_minutes: 20}}' >"$TMP/repostate"
  note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}non-case: a leave time at its pause point is a planned stop" "$(calls)" ""

  # ---- refill that launched work -----------------------------------------------
  reset
  note "$SH" refill --picked 0 --reason "nothing eligible"
  : >"$CALLS"
  note "$SH" refill --picked 2
  check_contains "${P}picked > 0 closes the open entry" "$(calls)" "stoppage resume --thread sess-1"
  check "${P}and removes the marker" "$(marker)" "no"
  : >"$CALLS"
  note "$SH" refill --picked 2
  check "${P}picked > 0 with no open entry does nothing" "$(calls)" ""
  reset
  mkdir -p "$KEEP/open" && printf '2026-11-13T18:00:00Z\n' >"$KEEP/open/sess-1"
  STP_CLI_RC=4 note "$SH" refill --picked 1
  check "${P}a failed close leaves the marker" "$(marker)" "yes"

  # ---- blocked_by_error --------------------------------------------------------
  reset
  note "$SH" blocked --phase C --pr 2310 --reason "ac-checkboxes.sh failed (exit 4)"
  check "${P}blocked: exit 0" "$NRC" "0"
  check "${P}blocked: silent" "$NOUT" ""
  check "${P}blocked: one record call" "$(hq_t_lines "$(calls)")" "1"
  check_contains "${P}blocked: cause" "$(calls)" "--cause blocked_by_error"
  check_contains "${P}blocked: phase and reason in the evidence" "$(calls)" "--evidence phase C blocked: ac-checkboxes.sh failed (exit 4)"
  check_contains "${P}blocked: the PR ref" "$(calls)" "--ref pr#2310"
  check "${P}blocked: opens the marker" "$(marker)" "yes"
  : >"$CALLS"
  note "$SH" blocked --phase B --pr 2311 --reason "no reviewer"
  check "${P}blocked: one entry per stretch" "$(calls)" ""
  reset
  note "$SH" blocked --phase B --issue 2292 --reason "x"
  check_contains "${P}blocked: an issue ref when no PR exists" "$(calls)" "--ref issue#2292"
  reset
  printf 'active\n' >"$TMP/pause"
  note "$SH" blocked --phase C --pr 5 --reason "late result during /pause"
  check "${P}non-case: a blocked result during /pause or /end is the wind-down" "$(calls)" ""
  printf 'garbled\n' >"$TMP/pause"
  note "$SH" blocked --phase C --pr 5 --reason "x"
  check "${P}blocked: an unreadable gate is not 'no gate'" "$(calls)" ""
  reset
  printf '%s\n' "$ROUND" | jq -c --argjson d "$(( $(date +%s) + 600 ))" \
    '. + {window: {deadline_epoch: $d}, leave: {lead_minutes: 20}}' >"$TMP/repostate"
  note "$SH" blocked --phase B --pr 5 --reason "x"
  check "${P}non-case: a blocked result at a leave time's pause point" "$(calls)" ""
  reset
  printf '{"a1":{"issue":2293,"status":"running"}}\n' >"$TMP/agents"
  note "$SH" blocked --phase B --pr 5 --reason "self review only"
  check "${P}blocked: a pipeline blocked is logged even with others running" "$(hq_t_lines "$(calls)")" "1"
  reset
  note "$SH" blocked --phase C --pr 5 --reason "$(printf 'bad "quote" $(x) `y`\nline2 %s' "$(printf 'z%.0s' $(seq 1 400))")"
  check_absent "${P}blocked: no quotes, substitutions or newlines survive" "$(calls)" '"'
  check_absent "${P}blocked: no command substitution syntax survives" "$(calls)" '$('
  check "${P}blocked: still one line" "$(hq_t_lines "$(calls)")" "1"
  check "${P}blocked: the evidence is bounded" \
    "$([ "$(calls | wc -c | tr -d ' ')" -lt 520 ] && echo yes || echo no)" "yes"

  # ---- fail open ---------------------------------------------------------------
  reset
  SID="" note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}no session id: exit 0, silent, nothing recorded" "$NRC:$NOUT:$(calls)" "0::"
  SID=sess-1
  reset
  STP_CLI_RC=4 note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}a failing CLI: exit 0 and silent" "$NRC:$NOUT" "0:"
  check "${P}a failing CLI leaves no marker" "$(marker)" "no"
  reset
  NRC=0
  (cd "$REPO" && env HUMAN_QUEUE_CLI="$STUBS/cli.sh" STOPPAGE_SCRIPTS_DIR="$TMP/nowhere" \
    HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" STP_CALLS="$CALLS" CLAUDE_SESSION_ID=sess-1 \
    "$SH" "$NOTE" refill --picked 0 --reason "nothing eligible") >"$TMP/nout" 2>&1 || NRC=$?
  check "${P}missing state scripts: exit 0, silent, nothing recorded" "$NRC:$(cat "$TMP/nout"):$(calls)" "0::"
  reset
  printf 'not json\n' >"$TMP/repostate"
  note "$SH" refill --picked 0 --reason "nothing eligible"
  check "${P}unreadable state: exit 0 and nothing recorded" "$NRC:$(calls)" "0:"
done

hq_t_finish "stoppage-note.test.sh"
