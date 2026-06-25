#!/usr/bin/env bash
# Unit test for `pr-state.sh --infer-candidates` (issues #447 / #448).
#
# Verifies the shared no-argument PR-inference helper:
#   - missing state file / no `prs` key / no active PRs -> `[]`, exit 0
#   - only PRs with a non-null `.phase` are emitted (active tracking)
#   - candidates sorted newest-activity-first by `.last_cron_action.at`
#   - `same_repo` is true / false / null per owner_repo match vs current repo
#   - `--infer-candidates` rejects `--pr` / `--since` combos (exit 2)
#
# Uses a temporary HOME (never touches ~/.claude) and a stub `gh` on PATH so
# repo detection is deterministic and offline. Requires jq.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/pr-state.sh"

TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME" "$FAKE_BIN"; }
trap cleanup EXIT

# Stub gh: only `gh repo view --json nameWithOwner ...` is exercised by the
# inference path. Return a fixed repo so same_repo is deterministic offline.
cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo "auerbachb/skingod"
  exit 0
fi
exit 1
GH
chmod +x "$FAKE_BIN/gh"

export HOME="$TMP_HOME"
export PATH="$FAKE_BIN:$PATH"
mkdir -p "$HOME/.claude"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- Case 1: missing state file -> [] exit 0 ---
out=$(bash "$SCRIPT" --infer-candidates) || fail "missing-file: non-zero exit"
[[ "$out" == "[]" ]] || fail "missing-file: expected [] got: $out"

# --- Case 2: ordering + active filter + same_repo true/false/null ---
cat > "$HOME/.claude/session-state.json" <<'JSON'
{ "prs": {
  "462": {"phase":"B","reviewer":"cr","needs":"cr_confirmation_pass","owner_repo":"auerbachb/skingod","last_cron_action":{"at":"2026-05-04T16:48:00Z"}},
  "458": {"phase":"B","reviewer":"bugbot","needs":"bugbot_review_poll","owner_repo":"auerbachb/skingod","last_cron_action":{"at":"2026-05-04T16:40:00Z"}},
  "777": {"phase":"C","owner_repo":"other/repo","last_cron_action":{"at":"2026-05-04T16:59:00Z"}},
  "888": {"phase":"A","last_cron_action":{"at":"2026-05-04T16:30:00Z"}},
  "999": {"reviewer":"cr"}
}}
JSON
out=$(bash "$SCRIPT" --infer-candidates)
# 999 has no phase -> excluded; 4 active candidates remain.
count=$(jq 'length' <<<"$out")
[[ "$count" == "4" ]] || fail "expected 4 active candidates, got $count: $out"
# Newest activity first: 777 (16:59) > 462 (16:48) > 458 (16:40) > 888 (16:30).
order=$(jq -r '[.[].number] | join(",")' <<<"$out")
[[ "$order" == "777,462,458,888" ]] || fail "bad recency order: $order"
# same_repo: matching owner_repo -> true, different -> false, missing -> null.
[[ "$(jq -r '.[]|select(.number==462)|.same_repo' <<<"$out")" == "true" ]]  || fail "462 same_repo != true"
[[ "$(jq -r '.[]|select(.number==777)|.same_repo' <<<"$out")" == "false" ]] || fail "777 same_repo != false"
[[ "$(jq -r '.[]|select(.number==888)|.same_repo' <<<"$out")" == "null" ]]  || fail "888 same_repo != null"
# number is emitted as an integer, not a string.
[[ "$(jq -r '.[0].number | type' <<<"$out")" == "number" ]] || fail "number not emitted as integer"

# --- Case 3: incompatible flag combos -> exit 2 ---
rc=0; bash "$SCRIPT" --infer-candidates --pr 5 >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "--infer-candidates --pr expected exit 2, got $rc"
rc=0; bash "$SCRIPT" --infer-candidates --since 2020-01-01T00:00:00Z >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "--infer-candidates --since expected exit 2, got $rc"

# --- Case 4: state file with no `prs` key -> [] ---
echo '{"root_repo":"/r"}' > "$HOME/.claude/session-state.json"
out=$(bash "$SCRIPT" --infer-candidates)
[[ "$out" == "[]" ]] || fail "no-prs-key: expected [] got: $out"

# --- Case 5: prs present but none active (all phase null) -> [] ---
echo '{"prs":{"1":{"reviewer":"cr"},"2":{"head_sha":"abc"}}}' > "$HOME/.claude/session-state.json"
out=$(bash "$SCRIPT" --infer-candidates)
[[ "$out" == "[]" ]] || fail "no-active: expected [] got: $out"

echo "OK: pr-state.sh --infer-candidates (missing file, ordering, active filter, same_repo, flag combos, empty prs)"
