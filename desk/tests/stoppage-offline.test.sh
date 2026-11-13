#!/usr/bin/env bash
# desk/tests/stoppage-offline.test.sh — offline contract tests for the stoppage
# log (issue #2292): the `stoppage` command and the Stop / UserPromptSubmit
# hook. Needs no database: with HUMAN_QUEUE_DATABASE_URL unset the CLI reaches
# its database step and exits 7, which is exactly the "unreachable" case.
#
# Asserts:
#   CLI
#   - --help is offline and names every command and every cause
#   - validation exits 4 before any connection (bad thread, repo, ref, source,
#     time, option; correct without a cause or with an unknown one; list with
#     a bad or reversed range), and a secret-shaped evidence or note exits 5
#     and is never echoed
#   - with the database unreachable, `record` and `resume` exit 0 and keep
#     one operation each in the keep directory (mode 600, directory 700), the
#     file carrying only the entry's fields; a missing cause is stored as
#     `unknown`; an unrecognised one too, with a note in the evidence
#   - `why` answers from a kept entry, marked as not stored yet; `flush` with
#     the database down sends nothing and loses nothing
#   - `list` and `correct` against an unreachable database exit 7 (correct is
#     kept locally), one stderr line
#   - the grouping (stoppages.jq) on fixtures: counts and idle time per cause,
#     a correction counted instead of the original cause, an unresumed entry
#     counted but not totalled, ordering by idle time
#   HOOK
#   - nothing is recorded off an issue branch, with a stop already continued
#     by a hook, with an open entry, during a /pause or /end gate (session or
#     repo), at or after a declared leave time's pause point, while background
#     work or a recorded subagent runs, or with the work finished
#   - one entry is recorded, with the right cause and ref, for dirty work and
#     for unpushed work, and the hook prints nothing and exits 0
#   - the cause follows the recorded handoff reason, the pipeline phase, and a
#     final message ending in a question; no message text reaches the entry
#   - UserPromptSubmit closes an open entry once, then does nothing
#   - a failing CLI or a database that is down never changes the hook's exit
#     status or output, and the entry is kept locally
#
# Every CLI case runs under `bash` on PATH and, when /bin/bash is 3.x (macOS),
# under /bin/bash too.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: stoppage-offline.test.sh — jq is not installed"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-stoppage-offline-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

KEEP="$TMP/keep"
ALNUM36="abcdefghijklmnopqrstuvwxyz0123456789"
FAKE_GH="gh""p_$ALNUM36"

# cli SHELL ARGS... — the CLI with no database; sets OUT, ERR, RC.
cli() {
  local sh="$1"
  shift
  RC=0
  env -u HUMAN_QUEUE_DATABASE_URL HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" "$sh" "$HQ_T_CLI" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

kept_count() { find "$KEEP" -maxdepth 1 -name '[0-9]*.json' 2>/dev/null | wc -l | tr -d ' '; }
reset_keep() { rm -rf "$KEEP"; }

# expect_bad SHELL CODE LABEL NEEDLE ARGS... — exit CODE, one stderr line naming
# NEEDLE, nothing on stdout, nothing kept.
expect_bad() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  reset_keep
  cli "$sh" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  check "[$sh] $label: nothing kept" "$(kept_count)" "0"
  if [ -n "$needle" ]; then check_contains "[$sh] $label: names it" "$ERR" "$needle"; fi
}

for SH in $SHELLS; do
  # ---- help -----------------------------------------------------------------
  cli "$SH" stoppage --help
  check "[$SH] --help: exit 0" "$RC" "0"
  check "[$SH] --help: nothing on stderr" "$ERR" ""
  for w in record resume why correct list flush out_of_work waiting_on_review waiting_on_operator \
           usage_limit token_exhaustion blocked_by_error crash unknown "EXIT CODES"; do
    check_contains "[$SH] --help names $w" "$OUT" "$w"
  done
  cli "$SH" stoppage record --help
  check "[$SH] record --help: exit 0" "$RC" "0"

  # ---- validation -----------------------------------------------------------
  expect_bad "$SH" 4 "no thread" "--thread" stoppage record --repo a/b
  expect_bad "$SH" 4 "bad thread" "--thread" stoppage record --thread 'bad thread!'
  expect_bad "$SH" 4 "bad repo" "--repo" stoppage record --thread t1 --repo notarepo
  expect_bad "$SH" 4 "bad ref" "--ref" stoppage record --thread t1 --ref '#12'
  expect_bad "$SH" 4 "bad source" "--source" stoppage record --thread t1 --source cron
  expect_bad "$SH" 4 "bad time" "--at" stoppage record --thread t1 --at yesterday
  expect_bad "$SH" 4 "impossible date" "--at" stoppage record --thread t1 --at 2026-02-30T10:00:00Z
  expect_bad "$SH" 4 "impossible hour" "--at" stoppage resume --thread t1 --at 2026-11-13T25:00:00Z
  expect_bad "$SH" 4 "unknown option" "unknown option" stoppage record --thread t1 --frobnicate
  expect_bad "$SH" 4 "stray argument" "options only" stoppage record --thread t1 extra
  expect_bad "$SH" 4 "multi-line evidence" "--evidence" stoppage record --thread t1 --evidence "$(printf 'a\nb')"
  expect_bad "$SH" 4 "long evidence" "--evidence" stoppage record --thread t1 --evidence "$(printf 'x%.0s' $(seq 1 201))"
  expect_bad "$SH" 5 "secret evidence" "--evidence" stoppage record --thread t1 --evidence "token $FAKE_GH"
  check_absent "[$SH] secret evidence never echoed" "$ERR" "$FAKE_GH"
  expect_bad "$SH" 5 "secret note" "--note" stoppage correct --thread t1 --cause crash --note "key $FAKE_GH"
  expect_bad "$SH" 4 "correct without a cause" "--cause" stoppage correct --thread t1
  expect_bad "$SH" 4 "correct with an unknown cause" "--cause" stoppage correct --thread t1 --cause laziness
  expect_bad "$SH" 4 "correct with id and thread" "not both" stoppage correct 5 --thread t1 --cause crash
  expect_bad "$SH" 4 "correct with a bad id" "whole number" stoppage correct 5x --cause crash
  expect_bad "$SH" 4 "list bad date" "--from" stoppage list --from 2026-13-40
  expect_bad "$SH" 4 "list reversed range" "after --to" stoppage list --from 2026-11-13 --to 2026-11-01
  expect_bad "$SH" 4 "unknown command" "unknown command" stoppage frob
  expect_bad "$SH" 4 "no command" "missing command" stoppage

  # ---- unreachable database: keep locally -----------------------------------
  reset_keep
  cli "$SH" stoppage record --thread t1 --repo a/b --ref issue#9 --cause waiting_on_review \
    --evidence "ci pending" --at 2026-11-13T10:00:00Z
  check "[$SH] record, database down: exit 0" "$RC" "0"
  check_contains "[$SH] record, database down: says kept locally" "$OUT" "kept locally"
  check "[$SH] record, database down: one file kept" "$(kept_count)" "1"
  F=$(find "$KEEP" -maxdepth 1 -name '[0-9]*.json' | sed -n '1p')
  check "[$SH] kept file fields" "$(jq -c 'keys' "$F")" \
    '["at","cause","evidence","key","op","ref","repo","source","thread"]'
  check "[$SH] kept file cause" "$(jq -r .cause "$F")" "waiting_on_review"
  check "[$SH] kept file has no connection string" "$(grep -c 'postgres' "$F")" "0"
  MODE=""
  if stat -c '%a' "$F" >/dev/null 2>&1; then MODE=$(stat -c '%a' "$F"); else MODE=$(stat -f '%Lp' "$F"); fi
  check "[$SH] kept file mode" "$MODE" "600"
  if stat -c '%a' "$KEEP" >/dev/null 2>&1; then DMODE=$(stat -c '%a' "$KEEP"); else DMODE=$(stat -f '%Lp' "$KEEP"); fi
  check "[$SH] keep directory mode" "$DMODE" "700"

  cli "$SH" stoppage record --thread t1 --repo a/b --at 2026-11-13T10:00:00Z --cause waiting_on_review --evidence "again"
  check "[$SH] the same thread and time keeps the same key" \
    "$(cat "$KEEP"/[0-9]*.json | jq -r .key | sort -u | wc -l | tr -d ' ')" "1"

  cli "$SH" stoppage record --thread t2 --at 2026-11-13T10:00:00Z
  F=$(grep -l '"thread":"t2"' "$KEEP"/[0-9]*.json | sed -n '1p')
  check "[$SH] a missing cause is unknown" "$(jq -r .cause "$F")" "unknown"
  check "[$SH] a missing repo is unknown" "$(jq -r .repo "$F")" "unknown"
  check "[$SH] a missing evidence is filled" "$(jq -r .evidence "$F")" "no evidence given"
  cli "$SH" stoppage record --thread t3 --at 2026-11-13T10:00:00Z --cause bored --evidence "x"
  F=$(grep -l '"thread":"t3"' "$KEEP"/[0-9]*.json | sed -n '1p')
  check "[$SH] an unrecognised cause is stored as unknown" "$(jq -r .cause "$F")" "unknown"
  check_contains "[$SH] and says so in the evidence" "$(jq -r .evidence "$F")" "unrecognised cause"

  cli "$SH" stoppage why --thread t1
  check "[$SH] why from a kept entry: exit 0" "$RC" "0"
  check_contains "[$SH] why names the cause" "$OUT" "waiting_on_review"
  check_contains "[$SH] why marks it not stored yet" "$OUT" "not stored yet"
  cli "$SH" stoppage why --thread nobody
  check "[$SH] why with no entry and no database: exit 7" "$RC" "7"

  BEFORE=$(kept_count)
  cli "$SH" stoppage flush
  check "[$SH] flush, database down: exit 0" "$RC" "0"
  check "[$SH] flush, database down: sends nothing" "$OUT" "sent 0"
  check "[$SH] flush, database down: loses nothing" "$(kept_count)" "$BEFORE"

  cli "$SH" stoppage resume --thread t1 --at 2026-11-13T11:10:00Z
  check "[$SH] resume, database down: exit 0, kept" "$RC:$(kept_count)" "0:$((BEFORE + 1))"
  cli "$SH" stoppage correct --thread t1 --cause unknown --note "was waiting on me"
  check "[$SH] correct, database down: exit 0, kept" "$RC:$(kept_count)" "0:$((BEFORE + 2))"
  check_contains "[$SH] correct says kept locally" "$OUT" "kept locally"
  cli "$SH" stoppage list
  check "[$SH] list, database down: exit 7" "$RC" "7"
  check "[$SH] list, database down: one stderr line" "$(hq_t_lines "$ERR")" "1"
done

# ---- grouping --------------------------------------------------------------
STP_JQ="$HQ_T_DESK_DIR/bin/lib/stoppages.jq"
STP_TXT="$HQ_T_DESK_DIR/bin/lib/stoppages-text.jq"
ROWS='[
 {"id":1,"cause":"waiting_on_review","corrected_cause":null,"idle_seconds":4200},
 {"id":2,"cause":"out_of_work","corrected_cause":null,"idle_seconds":3600},
 {"id":3,"cause":"out_of_work","corrected_cause":null,"idle_seconds":7200},
 {"id":4,"cause":"unknown","corrected_cause":"crash","idle_seconds":600},
 {"id":5,"cause":"crash","corrected_cause":null,"idle_seconds":null}]'
G=$(printf '%s' "$ROWS" | jq -c --arg from 2026-11-07 --arg to 2026-11-13 -f "$STP_JQ")
check "grouping: total" "$(printf '%s' "$G" | jq -r .total)" "5"
check "grouping: open" "$(printf '%s' "$G" | jq -r .open)" "1"
check "grouping: idle total" "$(printf '%s' "$G" | jq -r .idle_seconds)" "15600"
check "grouping: causes by idle time" "$(printf '%s' "$G" | jq -c '[.causes[] | [.cause, .count, .idle_seconds]]')" \
  '[["out_of_work",2,10800],["waiting_on_review",1,4200],["crash",2,600]]'
check "grouping: a correction counts instead of the cause" \
  "$(printf '%s' "$G" | jq -r '.causes[] | select(.cause == "unknown") | .count')" ""
T=$(printf '%s' "$G" | jq -r -f "$STP_TXT")
check_contains "text: heading" "$T" "2026-11-07 to 2026-11-13 · 5 stoppages · 4h 20m idle · 1 still stopped, not totalled"
check_contains "text: a cause line" "$T" "out_of_work          2 · 3h 00m"
check "grouping: an empty range" "$(printf '[]' | jq -c --arg from a --arg to b -f "$STP_JQ" | jq -r .total)" "0"

# ---- the hook --------------------------------------------------------------
HOOK="$HQ_T_DESK_DIR/hooks/stoppage.sh"
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
CALLS="$TMP/calls"

# The CLI stub records its argument list; the helper stubs read their answers
# from files so each case sets only what it needs.
cat >"$STUBS/cli.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STP_CALLS"
exit "${STP_CLI_RC:-0}"
EOF
cat >"$STUBS/execution-pause.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STP_PAUSE_FILE"
EOF
cat >"$STUBS/bgwork-ceiling.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STP_BG_FILE"
EOF
cat >"$STUBS/background-task-registry.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STP_REG_FILE"
EOF
cat >"$STUBS/session-state.sh" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  .active_agents) cat "$STP_AGENTS_FILE" ;;
  *) cat "$STP_REPO_FILE" ;;
esac
EOF
chmod +x "$STUBS"/*.sh

# A repo whose HEAD is on an issue branch, dirty or pushed as each case needs.
REPO="$TMP/repo"
ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" remote add origin "https://user:pw@github.com/acme/widgets.git"
printf 'a\n' >"$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -q -m one
git -C "$REPO" checkout -q -b issue-77-thing
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

reset_state() {
  printf 'inactive\n' >"$TMP/pause"
  printf '{"session":"s","background_work":[],"armed":false}\n' >"$TMP/bg"
  printf '[]\n' >"$TMP/reg"
  printf '{}\n' >"$TMP/repostate"
  printf '{}\n' >"$TMP/agents"
  printf 'x\n' >>"$REPO/f.txt"
  : >"$CALLS"
  rm -rf "$KEEP"
}

# run_hook EVENT [JSON-EXTRA] — sets HOUT, HERR, HRC and leaves the calls.
run_hook() {
  local event="$1" extra="${2:-}" payload
  payload=$(jq -cn --arg e "$event" --arg c "$REPO" '{hook_event_name: $e, session_id: "sess-1", cwd: $c}')
  if [ -n "$extra" ]; then payload=$(printf '%s' "$payload" | jq -c ". + $extra"); fi
  HRC=0
  printf '%s' "$payload" | env HUMAN_QUEUE_CLI="$STUBS/cli.sh" STOPPAGE_SCRIPTS_DIR="$STUBS" \
    HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" STP_CALLS="$CALLS" STP_PAUSE_FILE="$TMP/pause" \
    STP_BG_FILE="$TMP/bg" STP_REG_FILE="$TMP/reg" STP_REPO_FILE="$TMP/repostate" \
    STP_AGENTS_FILE="$TMP/agents" CLAUDE_CODE_SESSION_ID="" CLAUDE_SESSION_ID="" \
    bash "$HOOK" >"$TMP/hout" 2>"$TMP/herr" || HRC=$?
  HOUT=$(cat "$TMP/hout")
  HERR=$(cat "$TMP/herr")
}

calls() { cat "$CALLS"; }

reset_state
run_hook Stop
check "hook, dirty issue branch: exit 0" "$HRC" "0"
check "hook: prints nothing" "$HOUT$HERR" ""
check "hook, dirty issue branch: one record call" "$(hq_t_lines "$(calls)")" "1"
check_contains "hook: record, thread" "$(calls)" "stoppage record --thread sess-1"
check_contains "hook: repo from origin without credentials" "$(calls)" "--repo acme/widgets"
check_contains "hook: an issue ref" "$(calls)" "--ref issue#77"
check_contains "hook: unknown cause by default" "$(calls)" "--cause unknown"
check_contains "hook: source" "$(calls)" "--source hook"
check_contains "hook: evidence names the signal" "$(calls)" "uncommitted changes"
check_absent "hook: no credentials from the remote" "$(calls)" "pw@"
check "hook: opens a marker" "$([ -f "$KEEP/open/sess-1" ] && echo yes || echo no)" "yes"

: >"$CALLS"
run_hook Stop
check "hook: an open entry is not recorded twice" "$(calls)" ""

run_hook UserPromptSubmit
check_contains "hook: a prompt closes the entry" "$(calls)" "stoppage resume --thread sess-1"
check "hook: and removes the marker" "$([ -f "$KEEP/open/sess-1" ] && echo yes || echo no)" "no"
: >"$CALLS"
run_hook UserPromptSubmit
check "hook: a second prompt does nothing" "$(calls)" ""

reset_state
run_hook Stop '{"stop_hook_active": true}'
check "hook: a continued stop is not recorded" "$(calls)" ""
run_hook Stop
: >"$CALLS"
run_hook Stop '{"stop_hook_active": true}'
check_contains "hook: a continued stop closes the entry its first stop opened" "$(calls)" "stoppage resume --thread sess-1"
check "hook: and removes the marker" "$([ -f "$KEEP/open/sess-1" ] && echo yes || echo no)" "no"

reset_state
git -C "$REPO" checkout -q -- f.txt
run_hook Stop
check "hook: finished work (clean, pushed) is not a stoppage" "$(calls)" ""
reset_state

git -C "$REPO" checkout -q -b scratch-branch
run_hook Stop
check "hook: off an issue branch nothing is recorded" "$(calls)" ""
git -C "$REPO" checkout -q issue-77-thing

reset_state
printf 'active\n' >"$TMP/pause"
run_hook Stop
check "hook: an active /pause or /end gate is a planned stop" "$(calls)" ""
printf 'garbled\n' >"$TMP/pause"
run_hook Stop
check "hook: an unreadable gate is not 'no gate'" "$(calls)" ""

reset_state
printf '{"execution_pauses":{"other":{"active":true,"cleared_at":null,"command":"end"}}}\n' >"$TMP/repostate"
run_hook Stop
check "hook: a repo-wide gate is a planned stop" "$(calls)" ""

reset_state
NOW=$(date +%s)
printf '{"window":{"deadline_epoch":%d},"leave":{"lead_minutes":20}}\n' "$((NOW + 600))" >"$TMP/repostate"
run_hook Stop
check "hook: inside a leave time's lead window is a planned stop" "$(calls)" ""
printf '{"window":{"deadline_epoch":%d},"leave":{"lead_minutes":20}}\n' "$((NOW + 7200))" >"$TMP/repostate"
run_hook Stop
check "hook: well before a leave time is a stoppage" "$(hq_t_lines "$(calls)")" "1"

reset_state
printf '{"session":"s","background_work":["subagent"],"armed":true}\n' >"$TMP/bg"
run_hook Stop
check "hook: background work in flight is not a stoppage" "$(calls)" ""

reset_state
printf '[{"session_id":"sess-1","status":"running","stale":false}]\n' >"$TMP/reg"
run_hook Stop
check "hook: a live registered task is not a stoppage" "$(calls)" ""
printf '[{"session_id":"sess-1","status":"running","stale":true}]\n' >"$TMP/reg"
run_hook Stop
check "hook: a stale registry leftover does not hide a stoppage" "$(hq_t_lines "$(calls)")" "1"

reset_state
printf '{"a1":{"issue":77,"status":"running"}}\n' >"$TMP/agents"
run_hook Stop
check "hook: a recorded subagent on the issue is not a stoppage" "$(calls)" ""

reset_state
printf '{"prs":{"812":{"head_sha":"%s","phase":"B","reviewer":"cr"}}}\n' "${HEAD_SHA:0:7}" >"$TMP/repostate"
run_hook Stop
check_contains "hook: a pipeline in review is waiting_on_review" "$(calls)" "--cause waiting_on_review"
check_contains "hook: a recorded pipeline gives the PR ref" "$(calls)" "--ref pr#812"

reset_state
printf '{"prs":{"812":{"head_sha":"%s","phase":"B","handoff_reason":"usage_limit_park"}}}\n' "${HEAD_SHA:0:7}" >"$TMP/repostate"
run_hook Stop
check_contains "hook: a usage-limit park is usage_limit" "$(calls)" "--cause usage_limit"
printf '{"prs":{"812":{"head_sha":"%s","phase":"A","handoff_reason":"token_exhaustion"}}}\n' "${HEAD_SHA:0:7}" >"$TMP/repostate"
: >"$CALLS"; rm -rf "$KEEP"
run_hook Stop
check_contains "hook: a token-exhaustion handoff is token_exhaustion" "$(calls)" "--cause token_exhaustion"

reset_state
run_hook Stop '{"last_assistant_message": "Which of these do you want?"}'
check_contains "hook: a final question is waiting_on_operator" "$(calls)" "--cause waiting_on_operator"
check_absent "hook: no message text reaches the entry" "$(calls)" "Which of these"
reset_state
run_hook Stop '{"last_assistant_message": "Done for now."}'
check_contains "hook: a plain final message stays unknown" "$(calls)" "--cause unknown"

reset_state
git -C "$REPO" checkout -q -- f.txt
git -C "$REPO" push -q "$ORIGIN" issue-77-thing 2>/dev/null
git -C "$REPO" remote set-url origin "$ORIGIN"
git -C "$REPO" fetch -q origin 2>/dev/null
git -C "$REPO" branch -q --set-upstream-to=origin/issue-77-thing 2>/dev/null
printf 'y\n' >>"$REPO/f.txt"
git -C "$REPO" commit -q -am two
run_hook Stop
check_contains "hook: unpushed commits are unfinished work" "$(calls)" "unpushed commits"
git -C "$REPO" remote set-url origin "https://user:pw@github.com/acme/widgets.git"

# A clean branch with commits that were never pushed (no upstream) is unfinished.
reset_state
git -C "$REPO" checkout -q -- f.txt
git -C "$REPO" checkout -q -b issue-88-fresh
printf 'z\n' >>"$REPO/f.txt"
git -C "$REPO" commit -q -am three
git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-list --max-parents=0 HEAD)"
run_hook Stop
check_contains "hook: a never-pushed branch with commits is unfinished work" "$(calls)" "unpushed commits"
git -C "$REPO" checkout -q issue-77-thing
git -C "$REPO" branch -q -D issue-88-fresh

# A failing CLI never changes the hook's status, output, or marker rules.
reset_state
HRC=0
payload=$(jq -cn --arg c "$REPO" '{hook_event_name: "Stop", session_id: "sess-2", cwd: $c}')
printf '%s' "$payload" | env HUMAN_QUEUE_CLI="$STUBS/cli.sh" STOPPAGE_SCRIPTS_DIR="$STUBS" \
  HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" STP_CALLS="$CALLS" STP_CLI_RC=4 STP_PAUSE_FILE="$TMP/pause" \
  STP_BG_FILE="$TMP/bg" STP_REG_FILE="$TMP/reg" STP_REPO_FILE="$TMP/repostate" \
  STP_AGENTS_FILE="$TMP/agents" bash "$HOOK" >"$TMP/hout" 2>"$TMP/herr" || HRC=$?
check "hook: a refusing CLI leaves exit 0" "$HRC" "0"
check "hook: a refusing CLI leaves no output" "$(cat "$TMP/hout")$(cat "$TMP/herr")" ""
check "hook: a refusing CLI leaves no marker" "$([ -f "$KEEP/open/sess-2" ] && echo yes || echo no)" "no"

# The real CLI with no database: the hook still exits 0 silently and the
# entry is kept locally.
reset_state
HRC=0
payload=$(jq -cn --arg c "$REPO" '{hook_event_name: "Stop", session_id: "sess-3", cwd: $c}')
# The hook's default CLI is desk-cli.sh (it finds the account's bound queue and
# the store URL; the raw CLI would use `public`), here pointed at a closed port.
check "hook: the default CLI is desk-cli.sh" \
  "$(grep -c 'HUMAN_QUEUE_CLI:-\$stp_here/../bin/desk-cli.sh' "$HOOK" | tr -d ' ')" "1"
printf '%s' "$payload" | env -u HUMAN_QUEUE_CLI HUMAN_QUEUE_DATABASE_URL="postgresql://u:pw@127.0.0.1:1/db" \
  HUMAN_QUEUE_SCHEMA=hq_test_stoppage_offline STOPPAGE_SCRIPTS_DIR="$STUBS" \
  HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" STP_PAUSE_FILE="$TMP/pause" STP_BG_FILE="$TMP/bg" \
  STP_REG_FILE="$TMP/reg" STP_REPO_FILE="$TMP/repostate" STP_AGENTS_FILE="$TMP/agents" \
  bash "$HOOK" >"$TMP/hout" 2>"$TMP/herr" || HRC=$?
check "hook, database down: exit 0" "$HRC" "0"
check "hook, database down: silent" "$(cat "$TMP/hout")$(cat "$TMP/herr")" ""
check "hook, database down: the entry is kept locally" "$(kept_count)" "1"
check "hook, database down: the kept entry has the thread" \
  "$(cat "$KEEP"/[0-9]*.json | jq -r .thread)" "sess-3"

# ---- /go-on: the open marker survives a failed close --------------------------
GOON="$HQ_T_DESK_DIR/../.claude/skills/go-on/SKILL.md"
if [ -f "$GOON" ]; then
  check "go-on: a failed resume never ends in '|| true'" \
    "$(grep -c 'stoppage resume.*|| true' "$GOON" | tr -d ' ')" "0"
  check "go-on: the marker is removed only inside the successful-resume branch" \
    "$(grep -c '^  if "\$HQ_CLI" stoppage resume' "$GOON" | tr -d ' ')" "1"
fi

hq_t_finish "stoppage-offline.test.sh"
