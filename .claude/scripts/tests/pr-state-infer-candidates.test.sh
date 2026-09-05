#!/usr/bin/env bash
# Unit test for `pr-state.sh --infer-candidates` (issues #447 / #448).
# catalog: tests — Tests `pr-state.sh --infer-candidates`
#
# Verifies the shared no-argument PR-inference helper:
#   - missing state file / no `prs` key / no active PRs -> `[]`, exit 0
#   - only PRs with a non-null `.phase` are emitted (active tracking)
#   - candidates sorted newest-activity-first by `.last_cron_action.at`
#   - `same_repo` is true / false / null per owner_repo match vs current repo
#   - `--infer-candidates` rejects `--pr` / `--since` combos (exit 2)
#
# Uses a temporary HOME (never touches ~/.claude) and stubs `gh`/`git` on PATH so
# repo detection is deterministic and offline. Requires jq.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/pr-state.sh"

TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME" "$FAKE_BIN"; }
trap cleanup EXIT

# Stub gh: still needed for non-inference paths that may call gh.
cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
exit 1
GH
chmod +x "$FAKE_BIN/gh"

# Stub git: intercept `git remote get-url origin` (used by the offline same_repo
# detection path and by session-state.sh's repo-scope resolution) and return a
# fixed repo URL so the result is deterministic.
#
# Two details this stub has to get right:
#   - It must also match when the call carries a leading `-C <path>`, which is
#     how session-state.sh asks about a specific checkout (issue #638).
#   - Forwarding to the real git must NOT go through `command -v git`: this
#     stub's own directory is first on PATH, so that resolves back to the stub
#     and recurses forever. Drop our directory from PATH before forwarding.
cat > "$FAKE_BIN/git" <<'GIT'
#!/usr/bin/env bash
args=("$@")
# Skip a leading `-C <path>` when matching the subcommand.
if [[ "${args[0]:-}" == "-C" ]]; then
  args=("${args[@]:2}")
fi
if [[ "${args[0]:-}" == "remote" && "${args[1]:-}" == "get-url" && "${args[2]:-}" == "origin" ]]; then
  echo "https://github.com/auerbachb/skingod.git"
  exit 0
fi
self_dir="$(cd "$(dirname "$0")" && pwd)"
clean_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vFx "$self_dir" | paste -sd: -)"
PATH="$clean_path" exec git "$@"
GIT
chmod +x "$FAKE_BIN/git"

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
# 999 has no phase -> excluded.
# 777 belongs to other/repo -> excluded entirely under per-repo scoping
# (issue #638): a PR known to live in a DIFFERENT repo is no longer a
# candidate here at all, which is the collision this scoping ends.
# 888 has no owner_repo and no resolvable root_repo -> genuinely unattributed,
# so it is still offered (same_repo null), preserving the original
# "unknown repo - do not hide it" behavior.
count=$(jq 'length' <<<"$out")
[[ "$count" == "3" ]] || fail "expected 3 active candidates, got $count: $out"
# Newest activity first: 462 (16:48) > 458 (16:40) > 888 (16:30).
order=$(jq -r '[.[].number] | join(",")' <<<"$out")
[[ "$order" == "462,458,888" ]] || fail "bad recency order: $order"
# same_repo: this repo's scope -> true; unattributed -> null.
[[ "$(jq -r '.[]|select(.number==462)|.same_repo' <<<"$out")" == "true" ]]  || fail "462 same_repo != true"
[[ "$(jq -r '.[]|select(.number==888)|.same_repo' <<<"$out")" == "null" ]]  || fail "888 same_repo != null"
# The other repo's PR must not leak in under any flag.
[[ "$(jq -r '[.[]|select(.number==777)]|length' <<<"$out")" == "0" ]] || fail "777 (other/repo) leaked into candidates"
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

# --- Case 6: a malformed last_cron_action (bare string, not object) on one
# entry must not abort candidates for every OTHER entry (issue #640, CodeAnt
# finding on PR #654 — pr-state.sh has the same last_cron_action.at indexing
# pattern infer-pr.sh was already hardened against).
cat > "$HOME/.claude/session-state.json" <<'JSON'
{ "prs": {
  "542": {"phase":"external_thread","reviewer":"greptile","last_cron_action":"a bare narrative string"},
  "544": {"phase":"merged","reviewer":"greptile","last_cron_action":{"at":"2026-07-16T02:54:00Z"}}
}}
JSON
out=$(bash "$SCRIPT" --infer-candidates)
count=$(jq 'length' <<<"$out")
[[ "$count" == "2" ]] || fail "malformed-entry: expected 2 candidates (both still present), got $count: $out"
malformed_activity=$(jq -r '.[]|select(.number==542)|.last_action_at' <<<"$out")
[[ "$malformed_activity" == "" ]] || fail "malformed-entry: expected empty last_action_at for #542, got: $malformed_activity"
valid_activity=$(jq -r '.[]|select(.number==544)|.last_action_at' <<<"$out")
[[ "$valid_activity" == "2026-07-16T02:54:00Z" ]] || fail "malformed-entry: #544's last_action_at not preserved, got: $valid_activity"

echo "OK: pr-state.sh --infer-candidates (missing file, ordering, active filter, same_repo, flag combos, empty prs, malformed last_cron_action)"
