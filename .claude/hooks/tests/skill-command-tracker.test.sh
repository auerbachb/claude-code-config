#!/usr/bin/env bash
# Integration tests for skill-command-tracker.sh + lib/skill-usage-recorder.sh (issue #584).
# Runs against a temp HOME and a temp skills catalog, so real telemetry in
# ~/.claude is never read or written.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DETECTOR="$REPO_ROOT/.claude/hooks/skill-command-tracker.sh"
TRACKER="$REPO_ROOT/.claude/hooks/skill-usage-tracker.sh"

TMP_BASE="$(mktemp -d)"
cleanup() { rm -rf "$TMP_BASE"; }
trap cleanup EXIT

export HOME="$TMP_BASE/home"
LOG="$HOME/.claude/skill-usage.log"
CSV="$HOME/.claude/skill-usage.csv"
MARKER_DIR="$HOME/.claude/.skill-usage-pending"
TAB=$'\t'

# Global catalog: the skills a user actually has installed.
mkdir -p "$HOME/.claude/skills/issue-maker"
touch "$HOME/.claude/skills/issue-maker/SKILL.md"
mkdir -p "$HOME/.claude/skills/wrap"
touch "$HOME/.claude/skills/wrap/SKILL.md"

# Project-local catalog, to exercise the walk-up from the hook's cwd.
PROJECT="$TMP_BASE/project"
mkdir -p "$PROJECT/.claude/skills/proj-only"
touch "$PROJECT/.claude/skills/proj-only/SKILL.md"
mkdir -p "$PROJECT/nested/deep"

fail() { echo "FAIL: $*" >&2; exit 1; }

reset_state() {
  rm -f "$LOG" "$CSV" "$CSV.lock"
  rm -rf "$MARKER_DIR"
}

# UserPromptSubmit payload: prompt, session, cwd.
prompt_payload() {
  python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "session_id": sys.argv[2], "cwd": sys.argv[3]}))' "$1" "$2" "$3"
}

# PostToolUse:Skill payload.
skill_payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name": "Skill", "tool_input": {"skill": sys.argv[1]}, "session_id": sys.argv[2]}))' "$1" "$2"
}

detect() { prompt_payload "$1" "$2" "${3:-$PROJECT}" | bash "$DETECTOR"; }
track() { skill_payload "$1" "$2" | bash "$TRACKER"; }

log_lines() {
  if [[ -f "$LOG" ]]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi
}

expect_lines() {
  local want="$1" ctx="$2" got
  got="$(log_lines)"
  [[ "$got" == "$want" ]] || fail "$ctx: expected $want log line(s), got $got"
}

csv_count() {
  python3 -c '
import csv, os, sys
p = os.path.expanduser("~/.claude/skill-usage.csv")
if not os.path.exists(p):
    print(0); raise SystemExit
try:
    rows = list(csv.reader(open(p, newline="")))[1:]
except Exception:
    print(0); raise SystemExit
for row in rows:
    if len(row) >= 3 and row[0] == sys.argv[1]:
        print(row[2]); raise SystemExit
print(0)
' "$1"
}

# --- Expanded form: the real payload shape a typed command produces ----------
# Lifted verbatim from a recorded transcript: the surface expands the command
# into the prompt and the model never calls the Skill tool.
reset_state
out="$(detect '<command-message>issue-maker</command-message>
<command-name>/issue-maker</command-name>' 's-expanded')"
expect_lines 1 "expanded form"
[[ "$out" == "{}" ]] || fail "detector must inject no context, got: $out"

# Format is a contract read by skill-usage-report.sh — assert it byte-exactly.
line_re="^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z${TAB}issue-maker${TAB}s-expanded$"
grep -qE "$line_re" "$LOG" || fail "log line format changed: $(cat "$LOG")"

# --- Tag order tolerated, args tolerated ------------------------------------
reset_state
detect '<command-name>/issue-maker</command-name>
<command-message>issue-maker</command-message>' 's-order' >/dev/null
expect_lines 1 "command-name first"

reset_state
detect '<command-message>issue-maker</command-message>
<command-name>/issue-maker</command-name>
<command-args>draft an issue</command-args>' 's-args' >/dev/null
expect_lines 1 "expanded form with args"

# --- Raw form, and exactly-once against a Skill call for the same invocation -
reset_state
detect '/issue-maker draft a thing' 's-raw' >/dev/null
expect_lines 1 "raw form"

# Same session + skill: this Skill call is the same logical invocation, so the
# fresh marker suppresses it.
track 'issue-maker' 's-raw' >/dev/null
expect_lines 1 "Skill call after typed command must not double-count"

# Consume-once: the marker is spent, so a genuinely separate later call logs.
track 'issue-maker' 's-raw' >/dev/null
expect_lines 2 "second Skill call must log (marker consumed once)"

# One line per logical invocation in the CSV too.
[[ "$(csv_count issue-maker)" == "2" ]] || fail "csv use_count should be 2, got $(csv_count issue-maker)"

# A marker is scoped to its session: another session's Skill call still logs.
reset_state
detect '/issue-maker' 's-one' >/dev/null
track 'issue-maker' 's-two' >/dev/null
expect_lines 2 "marker must not suppress a different session"

# ...and to its skill: a different skill in the same session still logs.
reset_state
detect '/issue-maker' 's-skill' >/dev/null
track 'wrap' 's-skill' >/dev/null
expect_lines 2 "marker must not suppress a different skill"

# --- Stale marker: suppression is time-bounded ------------------------------
reset_state
mkdir -p "$MARKER_DIR"
printf '%s\n' "$(( $(date -u +%s) - 400 ))" > "$MARKER_DIR/s-stale__issue-maker"
track 'issue-maker' 's-stale' >/dev/null
expect_lines 1 "stale marker (>300s) must not suppress a Skill call"

# A marker is spent whether or not it suppressed anything.
[[ -e "$MARKER_DIR/s-stale__issue-maker" ]] && fail "stale marker should have been consumed"

# An unreadable marker falls back to recording — losing a line beats silently
# skipping one.
reset_state
mkdir -p "$MARKER_DIR"
printf 'not-an-epoch\n' > "$MARKER_DIR/s-corrupt__issue-maker"
track 'issue-maker' 's-corrupt' >/dev/null
expect_lines 1 "corrupt marker must not suppress a Skill call"

# --- An unidentified session must not dedupe against another one ------------
# "unknown" is a placeholder, not an identity: two sessions that both lack an id
# would share a marker and silently lose an invocation. Dedupe switches off.
reset_state
detect '/issue-maker' '' >/dev/null
expect_lines 1 "typed command with no session id still logs"
[[ -z "$(ls "$MARKER_DIR" 2>/dev/null)" ]] || fail "no marker should be written for an unknown session"
track 'issue-maker' '' >/dev/null
expect_lines 2 "unknown-session Skill call must not be suppressed"

# --- A marker is never written for a line that failed to persist ------------
# The marker asserts "already logged". If the append fails and the marker is
# written anyway, the Skill call suppresses itself and the invocation vanishes
# from both paths.
reset_state
mkdir -p "$LOG"   # log path is a directory, so the append cannot succeed
err="$(detect '/issue-maker' 's-nolog' 2>&1 >/dev/null)"
[[ -z "$(ls "$MARKER_DIR" 2>/dev/null)" ]] || fail "marker written despite a failed log append"
# Even when its writes fail, a hook must stay silent on stderr.
[[ -z "$err" ]] || fail "hook leaked to stderr: $err"
rmdir "$LOG"

# --- Plugin prefix is stripped, so both paths key the same name -------------
reset_state
mkdir -p "$HOME/.claude/skills/pdf"
touch "$HOME/.claude/skills/pdf/SKILL.md"
detect '/anthropic-skills:pdf' 's-plugin' >/dev/null
expect_lines 1 "plugin-prefixed command should log under its bare name"
grep -qE "^[^${TAB}]+${TAB}pdf${TAB}s-plugin$" "$LOG" || fail "plugin prefix not stripped: $(cat "$LOG")"
# ...and that name is what the Skill path would mark, so it dedupes.
track 'anthropic-skills:pdf' 's-plugin' >/dev/null
expect_lines 1 "Skill call for the same plugin skill must not double-count"

# --- Regression: the model/chip path is untouched when no marker exists ------
reset_state
track 'wrap' 's-model' >/dev/null
expect_lines 1 "Skill call with no marker must log as before"
grep -qE "^[^${TAB}]+${TAB}wrap${TAB}s-model$" "$LOG" || fail "model path line malformed: $(cat "$LOG")"

# --- Non-invocations must stay silent ---------------------------------------
reset_state
detect 'please run /issue-maker when you get a chance' 's-mid' >/dev/null
expect_lines 0 "mid-text /name must not log"

detect 'what does <command-name>/issue-maker</command-name> do?' 's-quoted' >/dev/null
expect_lines 0 "pasted command block mid-prompt must not log"

detect '/clear' 's-builtin' >/dev/null
expect_lines 0 "built-in (not an installed skill) must not log"

detect '/definitely-not-a-skill' 's-unknown' >/dev/null
expect_lines 0 "unknown token must not log"

detect 'how do hooks work?' 's-prose' >/dev/null
expect_lines 0 "plain prose must not log"

detect '/Users/someone/notes.md is the file' 's-path' >/dev/null
expect_lines 0 "leading absolute path must not log"

detect '' 's-empty' >/dev/null
expect_lines 0 "empty prompt must not log"

# --- Catalog resolution -----------------------------------------------------
# Project-local skill found by walking up from a nested cwd.
reset_state
detect '/proj-only' 's-proj' "$PROJECT/nested/deep" >/dev/null
expect_lines 1 "project-local skill resolved by walking up from cwd"

# A project-local skill is not visible from an unrelated cwd.
reset_state
detect '/proj-only' 's-outside' "$TMP_BASE" >/dev/null
expect_lines 0 "project-local skill must not resolve outside its project"

# --- Path traversal cannot escape the catalog or the marker dir -------------
reset_state
detect '/../../etc/passwd' 's-traversal' >/dev/null
expect_lines 0 "traversal attempt must not log"

echo "OK: skill-command-tracker integration tests passed"
