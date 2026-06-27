#!/usr/bin/env bash
# Unit tests for infer-pr.sh (issues #448 / #447 — shared PR inference helper).
# Uses a temporary HOME so it never touches the real ~/.claude/. Requires jq.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/infer-pr.sh"

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0

# Run the script with a fresh PATH so the session-state.sh sibling resolves via
# the in-repo path only (the temp HOME has no ~/.claude/scripts copy).
run() { ( cd "$REPO_ROOT" && bash "$SCRIPT" "$@" ); }

check_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc (exit $actual)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected exit $expected, got $actual)"
  fi
}

check_json() {
  local desc="$1" filter="$2" expected="$3" json="$4" actual
  actual=$(jq -r "$filter" <<<"$json" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc ($filter == $expected)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc ($filter expected '$expected', got '$actual')"
  fi
}

echo "== --explicit parsing =="

OUT=$(run --explicit "https://github.com/auerbachb/skingod/pull/462"); RC=$?
check_exit "full URL valid" 0 "$RC"
check_json "full URL number" '.most_recent.number' "462" "$OUT"
check_json "full URL owner_repo" '.most_recent.owner_repo' "auerbachb/skingod" "$OUT"
check_json "full URL source" '.source' "explicit" "$OUT"

OUT=$(run --explicit "https://github.com/auerbachb/skingod/pull/462/files#diff-abc"); RC=$?
check_exit "URL with trailing path valid" 0 "$RC"
check_json "URL trailing number" '.most_recent.number' "462" "$OUT"

OUT=$(run --explicit "auerbachb/skingod#77"); RC=$?
check_exit "owner/repo#N valid" 0 "$RC"
check_json "shorthand number" '.most_recent.number' "77" "$OUT"
check_json "shorthand owner_repo" '.most_recent.owner_repo' "auerbachb/skingod" "$OUT"

OUT=$(run --explicit "#123"); RC=$?
check_exit "#N valid" 0 "$RC"
check_json "#N number" '.most_recent.number' "123" "$OUT"
check_json "#N owner_repo null" '.most_recent.owner_repo' "null" "$OUT"

OUT=$(run --explicit "456"); RC=$?
check_exit "bare N valid" 0 "$RC"
check_json "bare N number" '.most_recent.number' "456" "$OUT"

OUT=$(run --explicit "  789  "); RC=$?
check_exit "whitespace-padded N valid" 0 "$RC"
check_json "padded N number" '.most_recent.number' "789" "$OUT"

run --explicit "not-a-pr" >/dev/null 2>&1; check_exit "garbage ref invalid" 3 "$?"
run --explicit "#0" >/dev/null 2>&1; check_exit "zero PR number invalid" 3 "$?"
run --explicit "owner/repo#abc" >/dev/null 2>&1; check_exit "non-numeric shorthand invalid" 3 "$?"

echo "== usage errors =="
run --explicit >/dev/null 2>&1; check_exit "missing --explicit value" 64 "$?"
run --bogus >/dev/null 2>&1; check_exit "unknown flag" 64 "$?"
run extra-positional >/dev/null 2>&1; check_exit "unexpected positional" 64 "$?"

echo "== session-state inference: no state file =="
rm -f "$HOME/.claude/session-state.json"
OUT=$(run); RC=$?
check_exit "no state file → no candidates" 2 "$RC"
check_json "empty candidates" '.candidates | length' "0" "$OUT"
check_json "most_recent null" '.most_recent' "null" "$OUT"

echo "== session-state inference: single candidate =="
cat > "$HOME/.claude/session-state.json" <<EOF
{
  "prs": {
    "618": {
      "owner_repo": "org/repo",
      "root_repo": "/repos/proj",
      "last_cron_action": {"type": "create", "at": "2026-04-29T13:55:00Z"}
    }
  }
}
EOF
OUT=$(run); RC=$?
check_exit "single candidate → exit 0" 0 "$RC"
check_json "single candidate count" '.candidates | length' "1" "$OUT"
check_json "single candidate number" '.most_recent.number' "618" "$OUT"
check_json "single candidate source" '.source' "session-state" "$OUT"

echo "== session-state inference: multiple candidates sorted by recency =="
cat > "$HOME/.claude/session-state.json" <<EOF
{
  "prs": {
    "618": {"owner_repo": "org/repo", "last_cron_action": {"at": "2026-04-29T13:55:00Z"}},
    "620": {"owner_repo": "org/repo", "last_cron_action": {"at": "2026-04-29T14:10:00Z"}},
    "619": {"owner_repo": "org/repo", "last_cron_action": {"at": "2026-04-29T13:58:00Z"}}
  }
}
EOF
OUT=$(run); RC=$?
check_exit "multiple candidates → exit 1" 1 "$RC"
check_json "multiple count" '.candidates | length' "3" "$OUT"
check_json "most_recent is newest" '.most_recent.number' "620" "$OUT"
check_json "candidates sorted desc" '[.candidates[].number] | @csv' '620,619,618' "$OUT"

echo "== session-state inference: missing timestamp sorts last =="
cat > "$HOME/.claude/session-state.json" <<EOF
{
  "prs": {
    "700": {"owner_repo": "org/repo"},
    "701": {"owner_repo": "org/repo", "last_cron_action": {"at": "2026-04-29T14:10:00Z"}}
  }
}
EOF
OUT=$(run); RC=$?
check_exit "two candidates → exit 1" 1 "$RC"
check_json "timestamped sorts first" '.most_recent.number' "701" "$OUT"
check_json "missing-ts last" '.candidates[-1].number' "700" "$OUT"

echo "== session-state inference: --root-repo filter =="
cat > "$HOME/.claude/session-state.json" <<EOF
{
  "prs": {
    "800": {"owner_repo": "org/a", "root_repo": "/repos/a", "last_cron_action": {"at": "2026-04-29T14:10:00Z"}},
    "801": {"owner_repo": "org/b", "root_repo": "/repos/b", "last_cron_action": {"at": "2026-04-29T14:20:00Z"}},
    "802": {"owner_repo": "org/c", "last_cron_action": {"at": "2026-04-29T14:30:00Z"}}
  }
}
EOF
OUT=$(run --root-repo "/repos/a"); RC=$?
check_exit "root-repo filter exit" 1 "$RC"
# /repos/a matches #800; #802 has no root_repo (unknown) so it's kept; #801 dropped.
check_json "root filter keeps match + unknown" '[.candidates[].number] | sort | @csv' '800,802' "$OUT"
check_json "root filter drops other repo" '[.candidates[].number] | any(. == 801)' "false" "$OUT"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: infer-pr.sh tests passed"
