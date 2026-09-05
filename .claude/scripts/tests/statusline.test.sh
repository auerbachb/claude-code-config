#!/usr/bin/env bash
# statusline.test.sh — Offline unit tests for statusline.sh (issue #779).
# catalog: tests — Tests for `statusline.sh`
#
# Fully offline and hermetic: a temp HOME holds the session-state fixtures, temp
# git repos make branch resolution deterministic, and global/system git config is
# disabled so a developer's own settings cannot change a result. No network, no
# gh, no stubs — the real session-state.sh runs against the sandboxed HOME.
#
# Run from repo root: bash .claude/scripts/tests/statusline.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Run the real script in place: it resolves session-state.sh next to itself.
SUT="$REPO_ROOT/.claude/scripts/statusline.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
# Hermetic git: ignore whatever the developer or CI runner has configured.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/gitconfig-none"
# A repo key inherited from the environment would override the cwd-origin
# resolution these fixtures depend on.
unset CLAUDE_SESSION_REPO

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi
}
check_contains() { # needle haystack label
  if [[ "$2" == *"$1"* ]]; then ok "$3"; else bad "$3 (missing '$1' in: $2)"; fi
}
check_lacks() { # needle haystack label
  if [[ "$2" != *"$1"* ]]; then ok "$3"; else bad "$3 (unexpected '$1' in: $2)"; fi
}

# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------
mk_repo() { # dir branch [origin-url]
  local d="$1" b="$2" origin="${3:-https://github.com/test/repo.git}"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  git -C "$d" config commit.gpgsign false
  [[ -n "$origin" ]] && git -C "$d" remote add origin "$origin"
  : > "$d/f.txt"
  git -C "$d" add f.txt
  git -C "$d" commit -qm init
  git -C "$d" checkout -q -b "$b"
}

STATE="$HOME/.claude/session-state.json"
write_state() { printf '%s\n' "$1" > "$STATE"; }
clear_state() { rm -f "$STATE"; }

# One agent entry. `pr` is what --session-view attributes by, so these must name
# PRs tracked under the fixture repo to survive the repo-scoped projection.
agent() { jq -cn --argjson pr "$1" '{id:("a" + ($pr|tostring)), task:"work", pr:$pr, phase:"A"}'; }

# Full state document. Args: agents-json prs-json polling-json pmm-bool
state_doc() {
  jq -cn --argjson agents "$1" --argjson prs "$2" \
         --argjson polling "$3" --argjson pmm "$4" \
    '{schema_version:2, active_agents:$agents, polling_jobs:$polling,
      pmm_active:$pmm, repos:{"test/repo":{prs:$prs}}}'
}

REPO="$TMP/wt"
mk_repo "$REPO" "issue-779-statusline"

NOREPO="$TMP/plain"; mkdir -p "$NOREPO"

DETACHED="$TMP/detached"
mk_repo "$DETACHED" "some-branch"
git -C "$DETACHED" checkout -q --detach HEAD

session_json() { jq -cn --arg d "$1" '{workspace:{current_dir:$d, project_dir:$d}, cwd:$d}'; }

OUT=""
RC=0
run_sl() { OUT=$(printf '%s' "$1" | "$SUT" 2>/dev/null); RC=$?; }

# --------------------------------------------------------------------------
# 1. --help
# --------------------------------------------------------------------------
HELP_OUT=$("$SUT" --help 2>/dev/null); HELP_RC=$?
check_eq 0 "$HELP_RC" "--help exits 0"
check_contains "statusline.sh --help" "$HELP_OUT" "--help prints the usage block"

# --------------------------------------------------------------------------
# 2. Baseline — no state file at all. Time + branch only, never an error.
# --------------------------------------------------------------------------
clear_state
run_sl "$(session_json "$REPO")"
check_eq 0 "$RC" "no session-state file: exit 0 (fail-open)"
check_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "no session-state file: exactly one line"
check_contains "issue-779-statusline" "$OUT" "no session-state file: branch is rendered"
check_lacks "agent" "$OUT" "no session-state file: no agent segment"
check_lacks "watcher" "$OUT" "no session-state file: no watcher segment"

# The ET segment must match the format CLAUDE.md's timestamp-prefix rule uses.
ET_RE='^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{1,2} [0-9]{2}:[0-9]{2} (AM|PM) ET · '
if [[ "$OUT" =~ $ET_RE ]]; then
  ok "ET time segment matches the CLAUDE.md timestamp format"
else
  bad "ET time segment matches the CLAUDE.md timestamp format (got: $OUT)"
fi

# Separator is the middle dot used by the heartbeat format.
check_contains " · " "$OUT" "segments are joined with the middle-dot separator"

# --------------------------------------------------------------------------
# 3. Zero counts are omitted, not rendered as "0 agents".
# --------------------------------------------------------------------------
write_state "$(state_doc '[]' '{}' '[]' false)"
run_sl "$(session_json "$REPO")"
check_eq 0 "$RC" "empty state: exit 0"
check_lacks "0 agent" "$OUT" "empty state: zero agents omitted"
check_lacks "0 watcher" "$OUT" "empty state: zero watchers omitted"
check_eq "$(printf '%s' "$OUT" | awk -F' · ' '{print NF}')" 2 "empty state: exactly two segments"

# --------------------------------------------------------------------------
# 4. Active agents
# --------------------------------------------------------------------------
PRS_3='{"11":{},"12":{},"13":{}}'
write_state "$(state_doc "[$(agent 11),$(agent 12),$(agent 13)]" "$PRS_3" '[]' false)"
run_sl "$(session_json "$REPO")"
check_contains "· 3 agents" "$OUT" "three active agents render as '3 agents'"
check_lacks "watcher" "$OUT" "three active agents: watcher segment still omitted"

write_state "$(state_doc "[$(agent 11)]" '{"11":{}}' '[]' false)"
run_sl "$(session_json "$REPO")"
check_contains "· 1 agent" "$OUT" "one active agent is singularized"
check_lacks "1 agents" "$OUT" "one active agent: not pluralized"

# --------------------------------------------------------------------------
# 5. Watchers — polling_jobs, per-PR babysit, and the PR-fleet manager
# --------------------------------------------------------------------------
write_state "$(state_doc '[]' '{}' '[{"id":"j1"},{"id":"j2"}]' false)"
run_sl "$(session_json "$REPO")"
check_contains "· 2 watchers" "$OUT" "two polling_jobs render as '2 watchers'"

BABYSIT_2='{"21":{"babysit":{"active":true}},"22":{"babysit":{"active":true}}}'
write_state "$(state_doc '[]' "$BABYSIT_2" '[]' false)"
run_sl "$(session_json "$REPO")"
check_contains "· 2 watchers" "$OUT" "two active babysitters render as '2 watchers'"

BABYSIT_MIXED='{"21":{"babysit":{"active":true}},"22":{"babysit":{"active":false}},"23":{}}'
write_state "$(state_doc '[]' "$BABYSIT_MIXED" '[]' false)"
run_sl "$(session_json "$REPO")"
check_contains "· 1 watcher" "$OUT" "an inactive babysitter is not counted"

write_state "$(state_doc '[]' '{}' '[]' true)"
run_sl "$(session_json "$REPO")"
check_contains "· 1 watcher" "$OUT" "pmm_active alone counts as one watcher"

# All three watcher sources add up, alongside the agent count.
write_state "$(state_doc "[$(agent 21)]" '{"21":{"babysit":{"active":true}}}' '[{"id":"j1"}]' true)"
run_sl "$(session_json "$REPO")"
check_contains "· 1 agent · 3 watchers" "$OUT" "agents and all three watcher sources combine"

# --------------------------------------------------------------------------
# 5b. An inherited CLAUDE_SESSION_REPO must not skew the counts
# --------------------------------------------------------------------------
# session-state.sh resolves repo scope as --repo > $CLAUDE_SESSION_REPO > cwd
# origin, so a key inherited from another checkout outranks the renderer's cd
# into WORK_DIR. Left alone it would pair this repo's branch with another
# repo's counts. The renderer clears the variable for that lookup; the export
# below is what proves it, since "other/elsewhere" holds no state of its own
# and every count would collapse to zero if the variable still won.
write_state "$(state_doc "[$(agent 21)]" '{"21":{"babysit":{"active":true}}}' '[]' false)"
export CLAUDE_SESSION_REPO=other/elsewhere
run_sl "$(session_json "$REPO")"
unset CLAUDE_SESSION_REPO
check_contains "· 1 agent · 1 watcher" "$OUT" \
  "inherited CLAUDE_SESSION_REPO does not skew agent/watcher counts"
check_contains "issue-779-statusline" "$OUT" \
  "inherited CLAUDE_SESSION_REPO: branch still resolves from WORK_DIR"

# The parent environment must survive the renderer untouched — the unset lives
# inside a command substitution precisely so it cannot leak back out.
export CLAUDE_SESSION_REPO=other/elsewhere
run_sl "$(session_json "$REPO")"
check_eq "other/elsewhere" "${CLAUDE_SESSION_REPO:-}" \
  "renderer does not clobber the caller's CLAUDE_SESSION_REPO"
unset CLAUDE_SESSION_REPO

# --------------------------------------------------------------------------
# 5c. A render must not touch script-usage.log — through ANY script
# --------------------------------------------------------------------------
# The renderer staying silent is only half the story: it shells out to
# session-state.sh, which logs a line per call. Left alone that moves the flood
# one script to the left, inflating session-state.sh's count in
# script-usage-report.sh's denominator with thousands of automatic reads a day.
USAGE_LOG="$HOME/.claude/script-usage.log"
write_state "$(state_doc "[$(agent 21)]" '{"21":{"babysit":{"active":true}}}' '[]' false)"
rm -f "$USAGE_LOG"
run_sl "$(session_json "$REPO")"
check_contains "· 1 agent · 1 watcher" "$OUT" "usage-log case: the render still produced its counts"
if [[ ! -s "$USAGE_LOG" ]]; then
  ok "a render appends nothing to script-usage.log (renderer or session-state.sh)"
else
  bad "a render appends nothing to script-usage.log (got: $(tr '\n' '; ' < "$USAGE_LOG"))"
fi

# The opt-out must be exactly that — an opt-out. An ordinary call still logs, or
# the suppression above would be silently disabling telemetry for everyone.
SS="$REPO_ROOT/.claude/scripts/session-state.sh"
rm -f "$USAGE_LOG"
(cd "$REPO" && "$SS" --session-view >/dev/null 2>&1) || true
if [[ -s "$USAGE_LOG" ]]; then
  ok "session-state.sh still logs on an ordinary call (opt-out is not the default)"
else
  bad "session-state.sh still logs on an ordinary call (opt-out is not the default)"
fi
rm -f "$USAGE_LOG"

# --------------------------------------------------------------------------
# 6. Repo scoping — another repo's agents and babysitters must not leak in.
# --------------------------------------------------------------------------
OTHER_STATE=$(jq -cn --argjson mine "[$(agent 11)]" --argjson theirs "[$(agent 99)]" \
  '{schema_version:2,
    active_agents:($mine + $theirs),
    polling_jobs:[],
    pmm_active:false,
    repos:{"test/repo":{prs:{"11":{}}},
           "other/repo":{prs:{"99":{"babysit":{"active":true}}}}}}')
write_state "$OTHER_STATE"
run_sl "$(session_json "$REPO")"
check_contains "· 1 agent" "$OUT" "repo scoping: only this repo's agent is counted"
check_lacks "watcher" "$OUT" "repo scoping: another repo's babysitter is not counted"

# --------------------------------------------------------------------------
# 7. Degraded inputs — every one of these must still render and exit 0.
# --------------------------------------------------------------------------
write_state "$(state_doc '[]' '{}' '[]' false)"

run_sl ""
check_eq 0 "$RC" "empty stdin: exit 0"
check_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "empty stdin: exactly one line"
if [[ "$OUT" =~ $ET_RE ]]; then
  ok "empty stdin: ET time still rendered"
else
  bad "empty stdin: ET time still rendered (got: $OUT)"
fi

run_sl 'this is not json {{{'
check_eq 0 "$RC" "malformed stdin: exit 0"
check_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "malformed stdin: exactly one line"

run_sl '{"workspace":{}}'
check_eq 0 "$RC" "session JSON with no current_dir: exit 0"

# .cwd is the documented fallback when .workspace.current_dir is absent.
run_sl "$(jq -cn --arg d "$REPO" '{cwd:$d}')"
check_contains "issue-779-statusline" "$OUT" "branch resolves from .cwd when .workspace is absent"

# A path that does not exist falls back to the process working directory.
run_sl '{"workspace":{"current_dir":"/nonexistent/path/for/test"}}'
check_eq 0 "$RC" "nonexistent current_dir: exit 0"

run_sl "$(session_json "$NOREPO")"
check_contains "(no repo)" "$OUT" "a non-git directory renders the (no repo) placeholder"
check_eq 0 "$RC" "non-git directory: exit 0"

run_sl "$(session_json "$DETACHED")"
check_contains "(detached)" "$OUT" "a detached HEAD renders the (detached) placeholder"
check_lacks "(no repo)" "$OUT" "detached HEAD is distinguished from not-a-repo"

# --------------------------------------------------------------------------
# 8. Corrupt state file — fail open to the time+branch line, never an error.
# --------------------------------------------------------------------------
write_state '{ this is not valid json'
run_sl "$(session_json "$REPO")"
check_eq 0 "$RC" "corrupt session-state.json: exit 0 (fail-open)"
check_contains "issue-779-statusline" "$OUT" "corrupt session-state.json: branch still rendered"
check_lacks "agent" "$OUT" "corrupt session-state.json: no agent segment invented"
check_lacks "watcher" "$OUT" "corrupt session-state.json: no watcher segment invented"

# A wrong-typed active_agents must not be counted or crash the render.
write_state '{"schema_version":2,"active_agents":"not-an-array","repos":{}}'
run_sl "$(session_json "$REPO")"
check_eq 0 "$RC" "wrong-typed active_agents: exit 0"
check_lacks "agent" "$OUT" "wrong-typed active_agents: no agent segment"

# --------------------------------------------------------------------------
# 9. No sibling session-state.sh — the counts are unavailable, not fatal.
#    Reached when the script is copied somewhere on its own, or mid-install
#    before the skills worktree is fully populated.
# --------------------------------------------------------------------------
ORPHAN_DIR="$TMP/orphan"; mkdir -p "$ORPHAN_DIR"
cp "$SUT" "$ORPHAN_DIR/statusline.sh"
chmod +x "$ORPHAN_DIR/statusline.sh"
write_state "$(state_doc "[$(agent 11)]" '{"11":{}}' '[]' true)"
ORPHAN_OUT=$(printf '%s' "$(session_json "$REPO")" | "$ORPHAN_DIR/statusline.sh" 2>/dev/null)
ORPHAN_RC=$?
check_eq 0 "$ORPHAN_RC" "missing sibling session-state.sh: exit 0"
check_contains "issue-779-statusline" "$ORPHAN_OUT" "missing sibling session-state.sh: time and branch still render"
check_lacks "agent" "$ORPHAN_OUT" "missing sibling session-state.sh: counts silently omitted"

echo "----------------------------------------"
echo "statusline.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
