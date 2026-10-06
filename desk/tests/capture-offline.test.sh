#!/usr/bin/env bash
# desk/tests/capture-offline.test.sh — offline tests for the capture hook
# (issue #1755): desk/hooks/capture.sh, run through its registered symlink
# .claude/hooks/human-queue-capture.sh. Needs no database: the store is a stub
# CLI (HUMAN_QUEUE_CLI) that logs every call, or the real CLI pointed at a
# TEST-NET address. Runs in CI through .github/scripts/run-hook-tests.sh.
#
# Every hook run gets ONLY the environment written here (env -i), the way the
# desktop app starts hooks without sourcing a shell profile.
#
# Asserts:
#   registration  global-settings.json has one PreToolUse entry, matcher
#                 AskUserQuestion, the placeholder command, timeout 15; the
#                 .claude/hooks entry is a symlink to desk/hooks/capture.sh
#   4.2           no control session, a stale tick, or no tick at all: allow,
#                 nothing queued; a live desk and a worker session: deny with
#                 the exact receipt reason, one add; the desk's own session:
#                 allow, one add; the bound comes from desk/policy.json when
#                 set; two questions: two adds and both ids in the reason
#   4.1           add carries the question, options, the (Recommended) or
#                 first option as --default, the session, the header and
#                 descriptions as context; repo and key come from the cwd's
#                 origin and branch; text is shaped to the store's limits
#   4.3 / 5.3     CLI missing, store unreachable (real CLI, TEST-NET), a
#                 failing or hanging call, malformed input, no python
#                 entry point: exit 0, empty stdout, ONE stderr line; the
#                 URL never appears in any output
#   4.3a          the URL comes from an owner-only config file or a literal
#                 export in a shell profile when the environment lacks it;
#                 a non-literal or group-readable source is refused
#   and           control-status validates offline; state set tick_at is
#                 refused
#
# Cases run under `bash` and, when /bin/bash is 3.x (macOS), under /bin/bash.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

REPO_ROOT=$(dirname "$HQ_T_DESK_DIR")
HOOK="$REPO_ROOT/.claude/hooks/human-queue-capture.sh"
SETTINGS="$REPO_ROOT/global-settings.json"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: capture-offline.test.sh — python3 is not installed (the hook fails open without it)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-capture-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

MINPATH="/usr/bin:/bin"
HOMEDIR="$TMP/home"
STUB_DIR="$TMP/stub"
STUB="$STUB_DIR/human-queue.sh"
mkdir -p "$HOMEDIR" "$STUB_DIR"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

FAKE_URL="postgres://hq-stub@db.invalid/hq?sslmode=require"
FAKE_PW='hunter2-SECRET-pw'
BLACKHOLE_URL="postgresql://u:${FAKE_PW}@192.0.2.1:5432/db?sslmode=require"

NO_DESK='{"session": null, "last_tick_at": null, "tick_age_seconds": null}'
NO_TICK='{"session": "desk-1", "last_tick_at": null, "tick_age_seconds": null}'
LIVE='{"session": "desk-1", "last_tick_at": "2026-10-06T21:40:00Z", "tick_age_seconds": 60}'
STALE='{"session": "desk-1", "last_tick_at": "2026-10-06T20:40:00Z", "tick_age_seconds": 3600}'

# The stub CLI: logs each call as one line of \037-separated arguments, notes
# whether it received the expected URL, and answers control-status and add as
# configured by STUB_* variables.
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\037' "$@" >> "$STUB_DIR/calls"
printf '\n' >> "$STUB_DIR/calls"
if [ "${HUMAN_QUEUE_DATABASE_URL:-}" = "${STUB_EXPECT_URL:-}" ]; then
  echo url-ok >> "$STUB_DIR/url"
else
  echo url-bad >> "$STUB_DIR/url"
fi
case "$1" in
  control-status)
    if [ -n "${STUB_SLEEP:-}" ]; then sleep "$STUB_SLEEP"; fi
    if [ "${STUB_STATUS_RC:-0}" != 0 ]; then
      echo "human-queue: database unreachable (stub)" >&2
      exit "$STUB_STATUS_RC"
    fi
    printf '%s\n' "${STUB_STATUS:-}"
    ;;
  add)
    n=$(( $(cat "$STUB_DIR/n" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$STUB_DIR/n"
    if [ "$n" = "${STUB_ADD_FAIL_AT:-0}" ]; then
      echo "human-queue: stub add failure" >&2
      exit "${STUB_ADD_RC:-7}"
    fi
    echo "D-$n"
    ;;
esac
EOF
chmod +x "$STUB"

# A git checkout for the asking thread's cwd: origin acme/widgets, branch
# issue-77-capture (unborn: no commit needed for --show-current).
REPO_DIR="$TMP/widgets"
git init -q "$REPO_DIR"
on_branch() { git -C "$REPO_DIR" symbolic-ref HEAD "refs/heads/$1"; }
on_branch issue-77-capture
git -C "$REPO_DIR" remote add origin git@github.com:acme/widgets.git

reset_stub() { rm -f "$STUB_DIR/calls" "$STUB_DIR/url" "$STUB_DIR/n"; }

# n_calls SUBCOMMAND — how many times the stub ran SUBCOMMAND.
n_calls() {
  if [ ! -f "$STUB_DIR/calls" ]; then printf '0\n'; return 0; fi
  grep -c "^$1"$'\037' "$STUB_DIR/calls" || true
}

# call_of SUBCOMMAND K — the K-th call of SUBCOMMAND, arguments joined by |.
call_of() {
  grep "^$1"$'\037' "$STUB_DIR/calls" 2>/dev/null | sed -n "${2}p" | tr '\037' '|'
}

# arg_after SUBCOMMAND K FLAG — the value after FLAG in that call (first one).
arg_after() {
  grep "^$1"$'\037' "$STUB_DIR/calls" 2>/dev/null | sed -n "${2}p" |
    awk -v flag="$3" 'BEGIN { RS = "\037" } prev == flag { print; exit } { prev = $0 }'
}

# hook SHELL INPUT [VAR=VALUE...] — runs the hook through its symlink with only
# the given environment; sets OUT, ERR, RC.
hook() {
  local sh="$1" input="$2"
  shift 2
  RC=0
  env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" STUB_DIR="$STUB_DIR" "$@" \
    "$sh" "$HOOK" >"$TMP/out" 2>"$TMP/err" <<<"$input" || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# The stubbed environment: a URL in the environment, the stub as the CLI.
STUBBED=("HUMAN_QUEUE_DATABASE_URL=$FAKE_URL" "STUB_EXPECT_URL=$FAKE_URL" "HUMAN_QUEUE_CLI=$STUB")

# reason / decision — fields of the deny JSON on stdout ("" when none).
reason() {
  printf '%s' "$OUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])
except Exception:
    print("")'
}
decision() {
  printf '%s' "$OUT" | python3 -c 'import json,sys
try:
    o = json.load(sys.stdin)["hookSpecificOutput"]
    print(o["hookEventName"] + " " + o["permissionDecision"])
except Exception:
    print("")'
}

# expect_allow_silent LABEL — exit 0, nothing on stdout or stderr.
expect_allow_silent() {
  check "$1: exit 0" "$RC" "0"
  check "$1: nothing on stdout (the menu renders)" "$OUT" ""
  check "$1: nothing on stderr" "$ERR" ""
}

# expect_fail_open LABEL NEEDLE — exit 0, nothing on stdout, one stderr line
# naming NEEDLE, and neither URL anywhere.
expect_fail_open() {
  check "$1: exit 0" "$RC" "0"
  check "$1: nothing on stdout (the menu renders)" "$OUT" ""
  check "$1: exactly one stderr line" "$(hq_t_lines "$ERR")" "1"
  check_contains "$1: the line is the hook's" "$ERR" "human-queue-capture: "
  if [ -n "$2" ]; then check_contains "$1: names the cause" "$ERR" "$2"; fi
  check_absent "$1: the URL is never printed" "$OUT$ERR" "db.invalid"
  check_absent "$1: the password is never printed" "$OUT$ERR" "$FAKE_PW"
}

# question JSON pieces
Q1='{"question": "Ship the migration before the CLI?", "header": "Rollout", "multiSelect": false, "options": [{"label": "Ship now (Recommended)", "description": "Merges today"}, {"label": "Wait for review", "description": "One more day"}]}'
Q2='{"question": "Which region?", "header": "Region", "multiSelect": true, "options": [{"label": "us-east-1", "description": "Closest"}, {"label": "eu-west-1", "description": "Cheaper"}]}'

# input SESSION CWD QUESTIONS... — the hook input for one AskUserQuestion call.
input() {
  local session="$1" cwd="$2" qs=""
  shift 2
  while [ "$#" -gt 0 ]; do
    qs="$qs${qs:+, }$1"
    shift
  done
  printf '{"session_id": "%s", "transcript_path": "/dev/null", "cwd": "%s", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": {"questions": [%s]}}' \
    "$session" "$cwd" "$qs"
}

R1="Queued as D-1. Print exactly: question D-1 sent to human queue. Then proceed on your recommended default or park and wait for a wake-up."
R12="Queued as D-1, D-2. Print exactly: questions D-1, D-2 sent to human queue. Then proceed on your recommended defaults or park and wait for a wake-up."

# ---------------------------------------------------------------- registration
printf '== registration\n'
REG=$(python3 - "$SETTINGS" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
hits = [
    h
    for g in data.get("hooks", {}).get("PreToolUse", [])
    if g.get("matcher") == "AskUserQuestion"
    for h in g.get("hooks", [])
    if h.get("command", "").endswith("/human-queue-capture.sh")
]
anywhere = sum(
    1
    for groups in data.get("hooks", {}).values()
    for g in groups
    for h in g.get("hooks", [])
    if h.get("command", "").endswith("/human-queue-capture.sh")
)
if len(hits) == 1 and anywhere == 1:
    h = hits[0]
    print("%s %s %s" % (h.get("type"), h.get("command"), h.get("timeout")))
else:
    print("entries=%d anywhere=%d" % (len(hits), anywhere))
PY
)
check "global-settings.json: one PreToolUse/AskUserQuestion entry" "$REG" \
  "command /path/to/claude-code-config/.claude/hooks/human-queue-capture.sh 15"
if [ -L "$HOOK" ]; then ok "the .claude/hooks entry is a symlink"; else bad "the .claude/hooks entry is not a symlink"; fi
check "the symlink is relative and points into desk/hooks" "$(readlink "$HOOK")" "../../desk/hooks/capture.sh"
if [ -x "$HQ_T_DESK_DIR/hooks/capture.sh" ]; then ok "desk/hooks/capture.sh is executable"; else bad "desk/hooks/capture.sh is not executable"; fi

for SH in $SHELLS; do
  printf '== %s\n' "$SH"

  # ------------------------------------------------------------ the 4.2 gate
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS="$NO_DESK"
  expect_allow_silent "[$SH] no control session"
  check "[$SH] no control session: nothing queued" "$(n_calls add)" "0"
  check "[$SH] no control session: control-status was asked once" "$(n_calls control-status)" "1"
  check "[$SH] the CLI received the URL" "$(sort -u "$STUB_DIR/url")" "url-ok"

  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS="$NO_TICK"
  expect_allow_silent "[$SH] registered, never ticked"
  check "[$SH] registered, never ticked: nothing queued" "$(n_calls add)" "0"

  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS="$STALE"
  expect_allow_silent "[$SH] stale tick (60 min > 15)"
  check "[$SH] stale tick: nothing queued" "$(n_calls add)" "0"

  # 5.1: live desk, worker session
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  check "[$SH] worker: exit 0" "$RC" "0"
  check "[$SH] worker: denied" "$(decision)" "PreToolUse deny"
  check "[$SH] worker: the reason names D-1 and the receipt line" "$(reason)" "$R1"
  check "[$SH] worker: nothing on stderr" "$ERR" ""
  check "[$SH] worker: one item queued" "$(n_calls add)" "1"
  check "[$SH] worker: add's arguments" "$(call_of add 1)" \
    "add|--kind|decision|--repo|acme/widgets|--key|issue-77|--question|Ship the migration before the CLI?|--session|worker-1|--context|Header: Rollout|--context|Options: Ship now (Recommended): Merges today; Wait for review: One more day|--option|Ship now (Recommended)|--option|Wait for review|--default|Ship now (Recommended)|"

  # 5.2: live desk, the desk's own session
  reset_stub
  hook "$SH" "$(input desk-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  expect_allow_silent "[$SH] desk session"
  check "[$SH] desk session: the item is still queued" "$(n_calls add)" "1"
  check "[$SH] desk session: its session is the return address" "$(arg_after add 1 --session)" "desk-1"

  # two questions in one call
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1" "$Q2")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  check "[$SH] two questions: denied" "$(decision)" "PreToolUse deny"
  check "[$SH] two questions: both ids and one receipt line" "$(reason)" "$R12"
  check "[$SH] two questions: two items" "$(n_calls add)" "2"
  check "[$SH] two questions: the second's question" "$(arg_after add 2 --question)" "Which region?"
  check "[$SH] multiSelect is noted in context" \
    "$(call_of add 2 | grep -c 'More than one option may be chosen.')" "1"

  # the bound from desk/policy.json
  reset_stub
  printf '{"tick_cadence_min": 5, "live_desk_max_tick_age_min": 90}\n' > "$TMP/policy.json"
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS="$STALE" HUMAN_QUEUE_POLICY="$TMP/policy.json"
  check "[$SH] policy bound 90 min: a 60-min-old tick is live" "$(decision)" "PreToolUse deny"
  reset_stub
  printf '{"live_desk_max_tick_age_min": "soon"}\n' > "$TMP/policy.json"
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS="$STALE" HUMAN_QUEUE_POLICY="$TMP/policy.json"
  check "[$SH] invalid policy value: the 15-min default applies" "$OUT" ""
  check "[$SH] invalid policy value: one warning line" "$(hq_t_lines "$ERR")" "1"
  check_contains "[$SH] invalid policy value: names the key" "$ERR" "live_desk_max_tick_age_min"

  # ------------------------------------------------------- 4.3 / 5.3 fail open
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_CLI="$TMP/missing/human-queue.sh"
  expect_fail_open "[$SH] CLI missing" "human-queue.sh not found"

  reset_stub
  START=$(hq_t_now)
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL"
  END=$(hq_t_now)
  expect_fail_open "[$SH] database unreachable (real CLI, TEST-NET)" "exit 7"
  check_contains "[$SH] database unreachable: says so" "$ERR" "unreachable"
  if hq_t_elapsed_under "$START" "$END" 5; then
    ok "[$SH] database unreachable: allowed in $(hq_t_elapsed "$START" "$END")s"
  else
    bad "[$SH] database unreachable took $(hq_t_elapsed "$START" "$END")s"
  fi

  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS_RC=7
  expect_fail_open "[$SH] control-status exit 7" "the store is unreachable (human-queue.sh exit 7"

  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS="not json"
  expect_fail_open "[$SH] control-status prints garbage" "other than JSON"

  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1" "$Q2")" "${STUBBED[@]}" STUB_STATUS="$LIVE" STUB_ADD_FAIL_AT=2 STUB_ADD_RC=7
  expect_fail_open "[$SH] second add unreachable" "question 2: the store is unreachable"
  check_contains "[$SH] second add unreachable: names what was queued" "$ERR" "already queued: D-1"

  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS="$LIVE" STUB_ADD_FAIL_AT=1 STUB_ADD_RC=5
  expect_fail_open "[$SH] add refuses a secret" "looks like it holds a secret"

  reset_stub
  hook "$SH" "this is not json" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_CLI="$STUB"
  expect_fail_open "[$SH] malformed input" "not JSON"
  check "[$SH] malformed input: the store is not asked" "$(n_calls control-status)" "0"

  reset_stub
  hook "$SH" '{"session_id": "w", "tool_name": "AskUserQuestion", "tool_input": {}}' \
    HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_CLI="$STUB"
  expect_fail_open "[$SH] no questions" "no questions"

  reset_stub
  hook "$SH" '{"session_id": "w", "tool_name": "Bash", "tool_input": {"command": "ls"}}' \
    HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_CLI="$STUB"
  expect_allow_silent "[$SH] another tool"
  check "[$SH] another tool: the store is not asked" "$(n_calls control-status)" "0"

  # ------------------------------------------------------------- 4.3a the URL
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_CLI="$STUB"
  expect_fail_open "[$SH] no URL anywhere" "HUMAN_QUEUE_DATABASE_URL is not in the environment"
  check "[$SH] no URL anywhere: the store is not asked" "$(n_calls control-status)" "0"

  # profile forms: the URL is absent from the environment, present in a profile
  for form in "export HUMAN_QUEUE_DATABASE_URL='$FAKE_URL'" \
              "export HUMAN_QUEUE_DATABASE_URL=\"$FAKE_URL\"  # the store" \
              "export HUMAN_QUEUE_DATABASE_URL='$FAKE_URL';" \
              "  HUMAN_QUEUE_DATABASE_URL=$FAKE_URL"; do
    reset_stub
    printf '# profile\nexport EDITOR=vim\n%s\n' "$form" > "$HOMEDIR/.zprofile"
    hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_CLI="$STUB" STUB_EXPECT_URL="$FAKE_URL" STUB_STATUS="$LIVE"
    check "[$SH] URL from a profile line ($(printf '%s' "$form" | cut -c1-34)…): captured" "$(decision)" "PreToolUse deny"
    check "[$SH] URL from a profile line: the CLI received it" "$(sort -u "$STUB_DIR/url" 2>/dev/null)" "url-ok"
    check_absent "[$SH] URL from a profile line: never printed" "$OUT$ERR" "db.invalid"
  done

  reset_stub
  printf "export HUMAN_QUEUE_DATABASE_URL='postgres://old@db.invalid/old'\nexport HUMAN_QUEUE_DATABASE_URL='%s'\n" "$FAKE_URL" > "$HOMEDIR/.zprofile"
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_CLI="$STUB" STUB_EXPECT_URL="$FAKE_URL" STUB_STATUS="$LIVE"
  check "[$SH] the profile's last assignment wins" "$(sort -u "$STUB_DIR/url" 2>/dev/null)" "url-ok"

  reset_stub
  printf "export HUMAN_QUEUE_DATABASE_URL='%s'\nexport HUMAN_QUEUE_DATABASE_URL=\"\$(security find-generic-password -w -s hq)\"\n" "$FAKE_URL" > "$HOMEDIR/.zprofile"
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_CLI="$STUB" STUB_EXPECT_URL="$FAKE_URL" STUB_STATUS="$LIVE"
  expect_fail_open "[$SH] a command substitution is never run" "other than a literal"
  check "[$SH] a command substitution: the store is not asked" "$(n_calls control-status)" "0"
  rm -f "$HOMEDIR/.zprofile"

  reset_stub
  printf "export HUMAN_QUEUE_DATABASE_URL='%s'\n" "$FAKE_URL" > "$HOMEDIR/.zshrc"
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_CLI="$STUB" STUB_EXPECT_URL="$FAKE_URL" STUB_STATUS="$LIVE"
  check "[$SH] URL from ~/.zshrc: captured" "$(decision)" "PreToolUse deny"

  printf "export HUMAN_QUEUE_DATABASE_URL='postgres://other@db.invalid/other'\n" > "$HOMEDIR/.zshrc"
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  check "[$SH] the environment wins over a profile" "$(sort -u "$STUB_DIR/url" 2>/dev/null)" "url-ok"
  printf "export HUMAN_QUEUE_DATABASE_URL='%s'\n" "$FAKE_URL" > "$HOMEDIR/.zshrc"

  # the owner-only config file wins over the profile
  CONF_URL="postgres://hq-conf@db.invalid/hq"
  mkdir -p "$HOMEDIR/.config/human-queue"
  printf '%s\n' "$CONF_URL" > "$HOMEDIR/.config/human-queue/database_url"
  chmod 600 "$HOMEDIR/.config/human-queue/database_url"
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_CLI="$STUB" STUB_EXPECT_URL="$CONF_URL" STUB_STATUS="$LIVE"
  check "[$SH] owner-only config file: used first" "$(sort -u "$STUB_DIR/url" 2>/dev/null)" "url-ok"
  check "[$SH] owner-only config file: captured, quietly" "$(decision) [$ERR]" "PreToolUse deny []"

  chmod 644 "$HOMEDIR/.config/human-queue/database_url"
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_CLI="$STUB" STUB_EXPECT_URL="$FAKE_URL" STUB_STATUS="$LIVE"
  check "[$SH] group-readable config file: ignored, the profile is used" "$(sort -u "$STUB_DIR/url" 2>/dev/null)" "url-ok"
  check "[$SH] group-readable config file: one warning line" "$(hq_t_lines "$ERR")" "1"
  check_contains "[$SH] group-readable config file: says why" "$ERR" "mode 600"

  rm -f "$HOMEDIR/.zshrc"
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_CLI="$STUB" STUB_STATUS="$LIVE"
  expect_fail_open "[$SH] group-readable config file and no profile" "mode 600"

  mkdir -p "$TMP/xdg/human-queue"
  printf '%s\n' "$CONF_URL" > "$TMP/xdg/human-queue/database_url"
  chmod 600 "$TMP/xdg/human-queue/database_url"
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_CLI="$STUB" STUB_EXPECT_URL="$CONF_URL" STUB_STATUS="$LIVE" XDG_CONFIG_HOME="$TMP/xdg"
  check "[$SH] XDG_CONFIG_HOME locates the config file" "$(sort -u "$STUB_DIR/url" 2>/dev/null)" "url-ok"
  rm -rf "$HOMEDIR/.config" "$TMP/xdg"

  # ------------------------------------------------------ 4.1 shaping and keys
  QX='{"question": "Pick\none\u001b[31m now?", "options": [{"label": "Alpha"}, {"label": "Beta (Recommended)"}, {"label": "Alpha"}]}'
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$QX")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  check "[$SH] line breaks and control characters are removed" "$(arg_after add 1 --question)" "Pick one[31m now?"
  check "[$SH] a later (Recommended) option is the default" "$(arg_after add 1 --default)" "Beta (Recommended)"
  check "[$SH] duplicate options are dropped" "$(call_of add 1 | grep -o -- '--option' | wc -l | tr -d ' ')" "2"

  QN='{"question": "Anything else?", "options": []}'
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$QN")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  check "[$SH] no options: no --option or --default" "$(call_of add 1)" \
    "add|--kind|decision|--repo|acme/widgets|--key|issue-77|--question|Anything else?|--session|worker-1|"

  QF='{"question": "Pick a lane?", "options": [{"label": "Left"}, {"label": "Right"}]}'
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$QF")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  check "[$SH] no (Recommended): the first option is the default" "$(arg_after add 1 --default)" "Left"

  LONG=""
  i=0
  while [ "$i" -lt 200 ]; do LONG="${LONG}why "; i=$((i + 1)); done
  QL="{\"question\": \"$LONG\", \"header\": \"H\", \"options\": [{\"label\": \"A\", \"description\": \"$LONG\"}]}"
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$QL")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  QARG=$(arg_after add 1 --question)
  check "[$SH] a long question is cut to 500 bytes" "$(printf '%s' "$QARG" | wc -c | tr -d ' ')" "500"
  CTX=$(call_of add 1 | awk 'BEGIN { RS = "|" } prev == "--context" { n += length($0) } { prev = $0 } END { print (n <= 600) ? "fits" : "too long: " n }')
  check "[$SH] context stays within 600 characters" "$CTX" "fits"

  git -C "$REPO_DIR" remote set-url origin https://github.com/acme/gadgets
  on_branch feature-x
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$QF")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  check "[$SH] https origin and a plain branch" "$(arg_after add 1 --repo) $(arg_after add 1 --key)" "acme/gadgets branch:feature-x"

  on_branch main
  reset_stub
  hook "$SH" "$(input worker-1 "$REPO_DIR" "$QF")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  check "[$SH] on main the key is the session" "$(arg_after add 1 --key)" "session:worker-1"
  on_branch issue-77-capture
  git -C "$REPO_DIR" remote set-url origin git@github.com:acme/widgets.git

  mkdir -p "$TMP/plain dir"
  reset_stub
  hook "$SH" "$(input worker-1 "$TMP/plain dir" "$QF")" "${STUBBED[@]}" STUB_STATUS="$LIVE"
  check "[$SH] outside git: a local repo name and the session key" \
    "$(arg_after add 1 --repo) $(arg_after add 1 --key)" "local/plain-dir session:worker-1"
done

# ------------------------------------------------------------- the launcher
printf '== launcher\n'
mkdir -p "$TMP/lonely" "$TMP/broken"
cp "$HQ_T_DESK_DIR/hooks/capture.sh" "$TMP/lonely/capture.sh"
SAVED_HOOK="$HOOK"
HOOK="$TMP/lonely/capture.sh"
hook bash "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_CLI="$STUB"
expect_fail_open "capture.py missing" "capture.py is missing"
cp "$HQ_T_DESK_DIR/hooks/capture.sh" "$TMP/broken/capture.sh"
printf 'raise SystemExit(3)\n' > "$TMP/broken/capture.py"
HOOK="$TMP/broken/capture.sh"
hook bash "$(input worker-1 "$REPO_DIR" "$Q1")" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" HUMAN_QUEUE_CLI="$STUB"
expect_fail_open "capture.py cannot run" "capture.py exited 3"
HOOK="$SAVED_HOOK"

# A hanging store: the call is killed and the menu renders, inside the
# registered 15-second timeout.
reset_stub
START=$(hq_t_now)
hook bash "$(input worker-1 "$REPO_DIR" "$Q1")" "${STUBBED[@]}" STUB_SLEEP=30
END=$(hq_t_now)
expect_fail_open "a hanging store" "took longer than"
if hq_t_elapsed_under "$START" "$END" 10; then
  ok "a hanging store is abandoned in $(hq_t_elapsed "$START" "$END")s (< 10 s, under the 15 s registered timeout)"
else
  bad "a hanging store took $(hq_t_elapsed "$START" "$END")s"
fi

# ------------------------------------------------- control-status and tick_at
printf '== control-status and tick_at (offline)\n'
RC=0
OUT=$(env -u HUMAN_QUEUE_DATABASE_URL bash "$HQ_T_CLI" control-status --help 2>&1) || RC=$?
check "control-status --help is offline: exit 0" "$RC" "0"
check_contains "control-status --help documents the JSON" "$OUT" "tick_age_seconds"
for args in "extra" "--bogus"; do
  RC=0
  # shellcheck disable=SC2086
  ERR=$(env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" bash "$HQ_T_CLI" control-status $args 2>&1 >/dev/null) || RC=$?
  check "control-status $args: exit 4 before connecting" "$RC" "4"
done
RC=0
ERR=$(env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" bash "$HQ_T_CLI" state set tick_at "2026-10-06T00:00:00Z" 2>&1 >/dev/null) || RC=$?
check "state set tick_at: exit 4 (reserved)" "$RC" "4"
check_contains "state set tick_at: names the owner" "$ERR" "only tick writes it"
RC=0
env -u HUMAN_QUEUE_DATABASE_URL bash "$HQ_T_CLI" control-status >/dev/null 2>&1 || RC=$?
check "control-status passes validation (exit 7, URL unset)" "$RC" "7"
# Captured first: under pipefail, `producer | grep -q` fails when grep stops
# reading early.
HELP=$(bash "$HQ_T_CLI" --help 2>&1)
case "$HELP" in
  *$'\n  control-status '*) ok "human-queue.sh --help lists control-status" ;;
  *) bad "human-queue.sh --help does not list control-status" ;;
esac

hq_t_finish "capture-offline.test.sh"
