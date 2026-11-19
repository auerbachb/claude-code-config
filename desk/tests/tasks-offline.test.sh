#!/usr/bin/env bash
# desk/tests/tasks-offline.test.sh — offline tests for the desk's view of the
# operator's open human tasks (issue #2542). Needs no database and no network:
# owner-task.sh is a stub under a throwaway HOME, and the check-in's store is
# a stub psql. Never writes to a real tracker or the real Desk database.
#
# Asserts:
#   tasks       the list (two open tasks in one repo, with why and where from,
#               oldest first, a done task left out, control characters as
#               spaces), --json's shape, the empty case, and every read
#               failure (script missing, non-zero exit, unparseable output, not
#               an array, an array of non-tasks, empty output) as exit 1 with
#               one stderr line — never "no tasks"; the stub is called with
#               `list --all-repos --json`; the three-path resolution order; no
#               connection attempt; validation (exit 4); --help
#   checkin     `get --tasks`: the text line gains the open-task count after
#               the store's Decision and Review counts, --json gains a `tasks`
#               object; a task read failure still exits 0 with the store's
#               output and says the list could not be read; `set`/`due
#               --tasks` exit 4 before connecting
#   no jq       `tasks --json` still prints readable false, and `checkin get
#               --tasks --json` still prints the store's JSON with tasks unreadable
#   desk.jq     checkin_card's "Waiting now" line with the counts, with an
#               unreadable list, and unchanged without them
#   skill       tasks.md's anchored block run as written against the stub
#               (bash, /bin/bash 3.2, zsh); the router names tasks.md
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: tasks-offline.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-tasks-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"
SKILL_DIR="$HQ_T_DESK_DIR/skill"
FIX="$TESTS_DIR/fixtures/checkin"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi
BLOCK_SHELLS="$SHELLS"
if command -v zsh >/dev/null 2>&1; then BLOCK_SHELLS="$BLOCK_SHELLS zsh"; fi

# The owner-task.sh stub: $STUB_MODE picks what `list` prints; each call's
# arguments are logged, one line, each in brackets.
STUB="$TMP/owner-task.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
line=""
for a in "$@"; do line="$line[$a]"; done
printf '%s\n' "$line" >> "$STUB_LOG"
case "${STUB_MODE:-two}" in
  two)
    cat <<'J'
[{"id":"ht-0000aaaa","repo":"acme/web","what":"Fill in .env\nfor staging","why":"needs your API key","source":"PR #12","created_at":"2026-11-18T10:00:00Z","state":"open","done_at":null,"proof":null},
 {"id":"ht-0000bbbb","repo":"acme/web","what":"Accept the hosting terms","why":"only a person can accept an agreement","source":"issue #3","created_at":"2026-11-17T09:00:00Z","state":"open","done_at":null,"proof":null},
 {"id":"ht-0000cccc","repo":"acme/api","what":"Sign in to the registry","why":"interactive login","source":"thread abc","created_at":"2026-11-10T10:00:00Z","state":"done","done_at":"2026-11-11T00:00:00Z","proof":"npm whoami prints the account"}]
J
    ;;
  one) printf '%s\n' '[{"id":"ht-0000dddd","repo":"acme/api","what":"Rotate the key","why":"needs the console","source":"PR #9","created_at":"2026-11-19T08:00:00Z","state":"open","done_at":null,"proof":null}]' ;;
  empty) printf '[]\n' ;;
  fail) echo "owner-task: could not list repos with a human-tasks tracker (gh search failed)" >&2; exit 4 ;;
  garbage) printf 'not json at all\n' ;;
  object) printf '{"tasks": []}\n' ;;
  nontasks) printf '[1, 2]\n' ;;
  nothing) : ;;
esac
EOF
chmod +x "$STUB"

# home NAME WHERE — a throwaway HOME with the stub at WHERE: sw (the skills
# worktree), scripts (~/.claude/scripts), noexec (sw, not executable), none.
home() {
  local h="$TMP/homes/$1"
  mkdir -p "$h/.claude/skills-worktree/.claude/scripts" "$h/.claude/scripts"
  case "$2" in
    sw) cp "$STUB" "$h/.claude/skills-worktree/.claude/scripts/owner-task.sh" ;;
    scripts) cp "$STUB" "$h/.claude/scripts/owner-task.sh" ;;
    noexec) cp "$STUB" "$h/.claude/skills-worktree/.claude/scripts/owner-task.sh"
            chmod -x "$h/.claude/skills-worktree/.claude/scripts/owner-task.sh" ;;
    none) ;;
  esac
  printf '%s' "$h"
}
H_SW=$(home sw sw)
H_SCRIPTS=$(home scripts scripts)
H_NOEXEC=$(home noexec noexec)
H_NONE=$(home none none)
# A working directory with no .claude/scripts, and one with the stub there
# (the third path).
CWD_EMPTY="$TMP/cwd-empty"
CWD_LOCAL="$TMP/cwd-local"
mkdir -p "$CWD_EMPTY" "$CWD_LOCAL/.claude/scripts"
cp "$STUB" "$CWD_LOCAL/.claude/scripts/owner-task.sh"
export STUB_LOG="$TMP/stub-log"

# A psql that only records that it ran: any connection attempt, the version
# check included, leaves $TMP/psql-ran. No wall-clock bound, so the suite is
# load-independent.
NEVER_PSQL="$TMP/psql-never"
cat > "$NEVER_PSQL" <<'EOF'
#!/bin/sh
: > "$PSQL_RAN"
exit 2
EOF
chmod +x "$NEVER_PSQL"
export PSQL_RAN="$TMP/psql-ran"

# run SHELL HOME CWD MODE ARGS... — human-queue.sh ARGS with a store URL and
# the recording psql; sets RC, OUT, ERR.
run() {
  local sh="$1" h="$2" cwd="$3" mode="$4"
  shift 4
  rm -f "$STUB_LOG" "$PSQL_RAN"
  RC=0
  (cd "$cwd" && env HOME="$h" STUB_MODE="$mode" HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" \
     HUMAN_QUEUE_PSQL="$NEVER_PSQL" "$sh" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null) || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
stub_calls() { cat "$STUB_LOG" 2>/dev/null; }
fast() {
  if [ -e "$PSQL_RAN" ]; then bad "$1 ran psql — it tried to connect"
  else ok "$1 (no connection attempt)"; fi
}

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="
  printf '== tasks: the list\n'
  run "$SH" "$H_SW" "$CWD_EMPTY" two tasks
  check "[$SH] list: exit 0" "$RC" "0"
  check "[$SH] list: nothing on stderr" "$ERR" ""
  check "[$SH] list: owner-task.sh list --all-repos --json, once" "$(stub_calls)" "[list][--all-repos][--json]"
  check "[$SH] list: header counts the open tasks" "$(printf '%s\n' "$OUT" | sed -n 1p)" "2 open human tasks in 1 repo"
  check "[$SH] list: the repo" "$(printf '%s\n' "$OUT" | sed -n 2p)" "acme/web"
  check "[$SH] list: oldest first" "$(printf '%s\n' "$OUT" | sed -n 3p)" "  ht-0000bbbb  Accept the hosting terms"
  check "[$SH] list: why and where from" "$(printf '%s\n' "$OUT" | sed -n 4p)" \
    "               why a person: only a person can accept an agreement · from: issue #3 · since 2026-11-17"
  check "[$SH] list: a newline in the text becomes a space" "$(printf '%s\n' "$OUT" | sed -n 5p)" "  ht-0000aaaa  Fill in .env for staging"
  check_contains "[$SH] list: the second reason" "$OUT" "why a person: needs your API key · from: PR #12 · since 2026-11-18"
  check_absent "[$SH] list: a done task is left out" "$OUT" "ht-0000cccc"
  check "[$SH] list: six lines" "$(hq_t_lines "$OUT")" "6"
  fast "[$SH] list"

  run "$SH" "$H_SW" "$CWD_EMPTY" two tasks --json
  check "[$SH] --json: exit 0" "$RC" "0"
  check "[$SH] --json: the shape" \
    "$(printf '%s' "$OUT" | jq -c '[.readable, .reason, .count, .repos, [.tasks[].id], (.tasks[0] | keys)]')" \
    '[true,null,2,1,["ht-0000bbbb","ht-0000aaaa"],["created_at","done_at","id","proof","repo","source","state","what","why"]]'
  check "[$SH] --json: one line" "$(hq_t_lines "$OUT")" "1"

  run "$SH" "$H_SW" "$CWD_EMPTY" one tasks
  check "[$SH] one task: singular" "$(printf '%s\n' "$OUT" | sed -n 1p)" "1 open human task in 1 repo"

  printf '== tasks: empty\n'
  run "$SH" "$H_SW" "$CWD_EMPTY" empty tasks
  check "[$SH] empty: exit 0, says so" "$RC:$OUT:$ERR" "0:No open human tasks.:"
  run "$SH" "$H_SW" "$CWD_EMPTY" empty tasks --json
  check "[$SH] empty --json" "$RC:$(printf '%s' "$OUT" | jq -c '[.readable, .count, .repos, .tasks]')" "0:[true,0,0,[]]"

  printf '== tasks: read failures\n'
  for mode in fail garbage object nontasks nothing; do
    run "$SH" "$H_SW" "$CWD_EMPTY" "$mode" tasks
    check "[$SH] $mode: exit 1" "$RC" "1"
    check "[$SH] $mode: nothing on stdout" "$OUT" ""
    check "[$SH] $mode: one stderr line" "$(hq_t_lines "$ERR")" "1"
    check_contains "[$SH] $mode: says the list could not be read" "$ERR" "the task list could not be read"
    check_absent "[$SH] $mode: never no tasks" "$OUT$ERR" "No open human tasks"
    run "$SH" "$H_SW" "$CWD_EMPTY" "$mode" tasks --json
    check "[$SH] $mode --json: exit 1, readable false" \
      "$RC:$(printf '%s' "$OUT" | jq -c '[.readable, .count, .tasks]')" "1:[false,null,[]]"
  done
  run "$SH" "$H_SW" "$CWD_EMPTY" fail tasks
  check_contains "[$SH] fail: names owner-task.sh's exit and its line" "$ERR" \
    "owner-task.sh list exited 4: could not list repos with a human-tasks tracker (gh search failed)"
  run "$SH" "$H_SW" "$CWD_EMPTY" garbage tasks
  check_contains "[$SH] garbage: names it" "$ERR" "not a task list"
  run "$SH" "$H_NONE" "$CWD_EMPTY" two tasks
  check "[$SH] script missing: exit 1" "$RC" "1"
  check_contains "[$SH] script missing: names the paths checked" "$ERR" \
    "owner-task.sh not found (checked ~/.claude/skills-worktree/.claude/scripts, ~/.claude/scripts, .claude/scripts)"
  fast "[$SH] script missing"
  run "$SH" "$H_NOEXEC" "$CWD_EMPTY" two tasks
  check "[$SH] a non-executable copy is skipped" "$RC" "1"

  printf '== tasks: resolution order\n'
  run "$SH" "$H_SCRIPTS" "$CWD_EMPTY" two tasks
  check "[$SH] ~/.claude/scripts is the second path" "$RC:$(stub_calls)" "0:[list][--all-repos][--json]"
  run "$SH" "$H_NONE" "$CWD_LOCAL" two tasks
  check "[$SH] .claude/scripts is the third path" "$RC:$(stub_calls)" "0:[list][--all-repos][--json]"
  RC=0
  (cd "$CWD_LOCAL" && env -u HOME STUB_MODE=one HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" \
     "$SH" "$HQ_T_CLI" tasks >"$TMP/out" 2>"$TMP/err" </dev/null) || RC=$?
  check "[$SH] HOME unset: only .claude/scripts" "$RC:$(sed -n 1p "$TMP/out")" "0:1 open human task in 1 repo"

  printf '== tasks: validation and help\n'
  run "$SH" "$H_SW" "$CWD_EMPTY" two tasks today
  check "[$SH] a stray argument: exit 4, one line" "$RC:$(hq_t_lines "$ERR")" "4:1"
  check "[$SH] a stray argument: the stub is not called" "$(stub_calls)" ""
  run "$SH" "$H_SW" "$CWD_EMPTY" two tasks --all
  check "[$SH] an unknown option: exit 4" "$RC" "4"
  check_contains "[$SH] an unknown option: named" "$ERR" "unknown option '--all'"
  run "$SH" "$H_SW" "$CWD_EMPTY" two tasks --help
  check "[$SH] --help: exit 0" "$RC" "0"
  check_contains "[$SH] --help: names its source" "$OUT" "owner-task.sh list --all-repos --json"
  check_contains "[$SH] --help: never no tasks" "$OUT" 'That is never "no tasks".'
  run "$SH" "$H_SW" "$CWD_EMPTY" two --help
  check_contains "[$SH] human-queue.sh --help lists tasks" "$OUT" "  tasks "
  run "$SH" "$H_SW" "$CWD_EMPTY" two checkin --help
  check_contains "[$SH] checkin --help documents --tasks" "$OUT" "checkin get [--tasks] [--json]"
  run "$SH" "$H_SW" "$CWD_EMPTY" two checkin set --session s1 --hours 4 --energy ok --tasks
  check "[$SH] checkin set --tasks: exit 4" "$RC:$ERR" "4:human-queue: checkin set: --tasks goes only with get"
  fast "[$SH] checkin set --tasks"
  run "$SH" "$H_SW" "$CWD_EMPTY" two checkin due --session s1 --at 04:00 --tasks
  check "[$SH] checkin due --tasks: exit 4" "$RC:$ERR" "4:human-queue: checkin due: --tasks goes only with get"
  fast "[$SH] checkin due --tasks"
done

# ------------------------------------------------- checkin get --tasks (stub psql)
printf '== checkin get --tasks\n'
# The store is a stub psql: --version is 16, the probe answers, and a script
# gets the canned JSON (the --json query) or text line. It records each
# script so the counts' SQL is checked as sent.
PSQL="$TMP/psql-stub"
cat > "$PSQL" <<'EOF'
#!/usr/bin/env bash
if [ "${1-}" = --version ]; then echo 'psql (PostgreSQL) 16.4'; exit 0; fi
for a in "$@"; do if [ "$a" = 'SELECT 1' ]; then echo 1; exit 0; fi; done
sql=$(cat)
printf '%s\n----\n' "$sql" >> "$PSQL_LOG"
case "$sql" in
  *"'open_decisions'"*) cat "$PSQL_JSON" ;;
  *) printf '%s\n' 'no check-in today · 9 Reviews read today · last measured day 2026-11-18: 7.0 Reviews an hour · 3 open Decisions · 19 unreviewed Reviews' ;;
esac
EOF
chmod +x "$PSQL"
export PSQL_LOG="$TMP/psql-log" PSQL_JSON="$FIX/get-none.json"
URL="postgresql://u:pw@db.example.test:5432/db?sslmode=require"
cget() {
  local sh="$1" h="$2" mode="$3"
  shift 3
  rm -f "$STUB_LOG" "$PSQL_LOG"
  RC=0
  (cd "$CWD_EMPTY" && env HOME="$h" STUB_MODE="$mode" HUMAN_QUEUE_DATABASE_URL="$URL" HUMAN_QUEUE_PSQL="$PSQL" \
     "$sh" "$HQ_T_CLI" checkin get "$@" >"$TMP/out" 2>"$TMP/err" </dev/null) || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
for SH in $SHELLS; do
  cget "$SH" "$H_SW" two --tasks
  check "[$SH] text: exit 0, the count follows the Decisions and Reviews" "$RC:$OUT" \
    "0:no check-in today · 9 Reviews read today · last measured day 2026-11-18: 7.0 Reviews an hour · 3 open Decisions · 19 unreviewed Reviews · 2 open tasks"
  check "[$SH] text: one owner-task.sh read" "$(stub_calls)" "[list][--all-repos][--json]"
  check_contains "[$SH] text: the counts' SQL is sent" "$(cat "$PSQL_LOG")" "CASE WHEN :'hq_counts' = '1' THEN"
  cget "$SH" "$H_SW" one --tasks
  check "[$SH] text: one task, singular" "${OUT##* · }" "1 open task"
  cget "$SH" "$H_SW" two --tasks --json
  check "[$SH] --json: exit 0, a tasks object, the store's fields kept" \
    "$RC:$(printf '%s' "$OUT" | jq -c '[.tasks, .unreviewed, .today]')" \
    '0:[{"readable":true,"open":2,"reason":null},18,"2026-10-08"]'
  cget "$SH" "$H_SW" fail --tasks
  check "[$SH] unreadable text: exit 0, Decisions and Reviews still shown" "$RC:$OUT" \
    "0:no check-in today · 9 Reviews read today · last measured day 2026-11-18: 7.0 Reviews an hour · 3 open Decisions · 19 unreviewed Reviews · task list could not be read"
  check "[$SH] unreadable text: nothing on stderr" "$ERR" ""
  cget "$SH" "$H_NONE" two --tasks --json
  check "[$SH] unreadable --json: exit 0, readable false with a reason" \
    "$RC:$(printf '%s' "$OUT" | jq -c '[.tasks.readable, .tasks.open, (.tasks.reason | test("owner-task.sh not found")), .unreviewed]')" \
    "0:[false,null,true,18]"
  cget "$SH" "$H_SW" two --json
  check "[$SH] without --tasks: owner-task.sh is not called" "$RC:$(stub_calls)" "0:"
  check "[$SH] without --tasks: no tasks field" "$(printf '%s' "$OUT" | jq -c 'has("tasks")')" "false"
done

# ------------------------------------------------- no jq on PATH
printf '== no jq\n'
# A PATH holding every command on the current PATH except jq (first one wins,
# as on the real PATH), so both commands' no-jq paths run as shipped.
NOJQ="$TMP/nojq-bin"
mkdir -p "$NOJQ"
IFS=: read -r -a HQ_T_PATH_DIRS <<<"$PATH"
for d in "${HQ_T_PATH_DIRS[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    n=${f##*/}
    if [ "$n" != jq ] && [ -x "$f" ] && [ ! -e "$NOJQ/$n" ]; then ln -s "$f" "$NOJQ/$n"; fi
  done
done
for SH in $SHELLS; do
  RC=0
  (cd "$CWD_EMPTY" && env PATH="$NOJQ" HOME="$H_SW" STUB_MODE=two HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" \
     HUMAN_QUEUE_PSQL="$NEVER_PSQL" "$SH" "$HQ_T_CLI" tasks --json >"$TMP/out" 2>"$TMP/err" </dev/null) || RC=$?
  check "[$SH] no jq: tasks --json still prints readable false, exit 1" \
    "$RC:$(jq -c '[.readable, .reason, .count, .tasks]' "$TMP/out")" '1:[false,"jq is not installed",null,[]]'
  RC=0
  (cd "$CWD_EMPTY" && env PATH="$NOJQ" HOME="$H_SW" STUB_MODE=two HUMAN_QUEUE_DATABASE_URL="$URL" \
     HUMAN_QUEUE_PSQL="$PSQL" "$SH" "$HQ_T_CLI" checkin get --tasks --json >"$TMP/out" 2>"$TMP/err" </dev/null) || RC=$?
  check "[$SH] no jq: checkin get --tasks --json still prints, tasks unreadable" \
    "$RC:$(jq -c '[.tasks, .unreviewed]' "$TMP/out")" \
    '0:[{"readable":false,"open":null,"reason":"jq is not installed"},18]'
done

# ------------------------------------------------------------------ desk.jq
printf '== checkin_card\n'
djq() { jq -L "$SKILL_DIR" "$@"; }
wline() { djq -r 'include "desk"; '"$1"' | checkin_card' "$FIX/get-none.json" | grep '^> Waiting now'; }
check "card: unchanged without the counts" "$(wline '.')" "> Waiting now: 18 unreviewed Reviews."
check "card: Decisions, Reviews, tasks" \
  "$(wline '. + {open_decisions: 3, tasks: {readable: true, open: 2, reason: null}}')" \
  "> Waiting now: 3 open Decisions · 18 unreviewed Reviews · 2 open human tasks."
check "card: singular, and none" \
  "$(wline '. + {open_decisions: 1, unreviewed: 0, tasks: {readable: true, open: 1, reason: null}}')" \
  "> Waiting now: 1 open Decision · no unreviewed Reviews · 1 open human task."
check "card: no open tasks" "$(wline '. + {open_decisions: 0, tasks: {readable: true, open: 0, reason: null}}')" \
  "> Waiting now: no open Decisions · 18 unreviewed Reviews · no open human tasks."
check "card: an unreadable list is said, never 0" \
  "$(wline '. + {open_decisions: 3, tasks: {readable: false, open: null, reason: "gh failed"}}')" \
  "> Waiting now: 3 open Decisions · 18 unreviewed Reviews · the task list could not be read."

# -------------------------------------------------------------------- skill
printf '== skill\n'
RC=0
hq_t_skill_block "$SKILL_DIR/tasks.md" desk-tasks-list > "$TMP/block.sh" 2>"$TMP/err" || RC=$?
check "tasks.md: anchor desk-tasks-list extracts" "$RC:$(cat "$TMP/err")" "0:"
check_absent "tasks.md: the block needs no store URL (not \$HQ)" "$(cat "$TMP/block.sh")" '"$HQ"'
for SH in $BLOCK_SHELLS; do
  for case_ in "two:0:2 open human tasks in 1 repo" "empty:0:No open human tasks." "fail:1:the task list could not be read"; do
    mode="${case_%%:*}"; rest="${case_#*:}"; want_rc="${rest%%:*}"; needle="${rest#*:}"
    OUT=$(cd "$CWD_EMPTY" && env -u HUMAN_QUEUE_DATABASE_URL HOME="$H_SW" STUB_MODE="$mode" DESK="$HQ_T_DESK_DIR" \
            "$SH" "$TMP/block.sh" 2>&1)
    check "[$SH] block ($mode): exit=$want_rc" "$(printf '%s\n' "$OUT" | tail -1)" "exit=$want_rc"
    check_contains "[$SH] block ($mode): output" "$OUT" "$needle"
  done
done
ROUTER=$(cat "$SKILL_DIR/SKILL.md")
check_contains "router: a row for tasks.md" "$ROUTER" '| `tasks.md` |'
check_contains "router: the tasks verb loads tasks.md" "$ROUTER" '→ load `tasks.md`'
check_contains "checkin.md: the card reads the task count" "$(cat "$SKILL_DIR/checkin.md")" '"$HQ" checkin get --tasks --json'

hq_t_finish "tasks-offline.test.sh"
