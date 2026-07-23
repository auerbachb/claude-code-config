#!/usr/bin/env bash
# Offline unit tests for polling-state-gate.sh repo scoping (issue #647).
#
# The bug: ~/.claude/session-state.json is shared across concurrent sessions, so
# the single global .root_repo is owned by whichever session wrote last. The gate
# refused to poll whenever a *different* repo's session owned that field, even
# though the PR, branch and checkout all agreed. These tests pin the discrimination
# the gate has to get right: false positive (foreign global) passes, genuine
# cross-repo mismatch still refuses.
#
# Everything runs offline against throwaway git repos in a temp HOME. `gh` is
# stubbed on PATH for --ensure-session; --verify-state never shells out to it.
# Requires git + jq. Run from anywhere in the repo:
#   bash .claude/scripts/tests/polling-state-gate.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/polling-state-gate.sh"
HANDOFF_HELPER="$REPO_ROOT/.claude/scripts/handoff-state.sh"

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
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (missing '$needle' in: $haystack)"
  fi
}

# ---- throwaway repos --------------------------------------------------------
# mk_repo <dir> <origin-url>
mk_repo() {
  local dir="$1" origin="$2"
  mkdir -p "$dir"
  git -C "$dir" init --quiet
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  : > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit --quiet -m init
}

# Resolve symlinks up front (macOS /var -> /private/var) so recorded paths compare
# equal to what the script canonicalizes.
TMP="$(cd "$TMP" && pwd -P)"
REPO_A="$TMP/repo-a"
REPO_B="$TMP/repo-b"
mk_repo "$REPO_A" "git@github.com:org/a.git"
mk_repo "$REPO_B" "https://github.com/org/b.git"

# Sibling worktree of repo A — same repo, different path.
WT_A="$TMP/wt-a"
git -C "$REPO_A" worktree add --quiet -b feature "$WT_A" >/dev/null 2>&1

PR_NUM="99647"
HANDOFF="$HOME/.claude/handoffs/pr-${PR_NUM}-handoff.json"
STATE="$HOME/.claude/session-state.json"

write_handoff() {
  # Optional first arg: owner/repo slug (e.g. "org/a"). When supplied the
  # handoff is written to the scoped path via handoff-state.sh so it lands
  # in ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json (issue #655).
  # Using --create (not --init) ensures any stale handoff at that path is
  # replaced, providing test-to-test isolation: --ensure-session (test 6)
  # creates a scoped handoff for "org/a" that would otherwise shadow a
  # fresh flat write in tests 8/9 (root cause of CI head_sha mismatch).
  # Use if/else rather than "${arr[@]}" expansion to stay compatible with
  # bash 3.2 (macOS system bash), which raises "unbound variable" for empty
  # arrays under set -u.
  local owner_repo="${1:-}"
  local json_body
  json_body="$(jq -n --argjson pr "$PR_NUM" --arg sha "deadbeef" \
    '{schema_version:"1.0", pr_number:$pr, head_sha:$sha, reviewer:"cr",
      phase_completed:"B", created_at:"2026-07-21T00:00:00Z",
      findings_fixed:[], threads_replied:[], threads_resolved:[],
      files_changed:[], push_timestamp:"2026-07-21T00:00:00Z"}')"
  if [[ -n "$owner_repo" ]]; then
    "$HANDOFF_HELPER" --owner-repo "$owner_repo" --create "$PR_NUM" "$json_body"
  else
    "$HANDOFF_HELPER" --create "$PR_NUM" "$json_body"
  fi
}
# write_state <global_root_repo> <per-pr fields as jq object or 'null'>
write_state() {
  local global_root="$1" per_pr="$2"
  jq -n --arg root "$global_root" --arg pr "$PR_NUM" --argjson perpr "$per_pr" \
    '{root_repo:$root, prs:{($pr): $perpr}}' > "$STATE"
}

# ---- 1. false positive: foreign session owns the global .root_repo ----------
# This is the exact PR #637 failure — repo B's session wrote .root_repo last while
# we legitimately poll a repo A PR from repo A.
write_handoff
write_state "$REPO_B" "$(jq -n --arg r "$REPO_A" '{root_repo:$r, owner_repo:"org/a", head_sha:"deadbeef", reviewer:"cr"}')"
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_NUM" --verify-state 2>&1)"; rc=$?
check_eq "correct checkout passes while a foreign repo owns global .root_repo" "0" "$rc"
check_eq "…and emits no refusal message" "0" "$(printf '%s' "$out" | grep -c 'refuse')"

# ---- 2. true positive: PR genuinely belongs to another repo -----------------
out="$(cd "$REPO_B" && "$SCRIPT" "$PR_NUM" --verify-state --root-repo "$REPO_B" 2>&1)"; rc=$?
check_eq "genuine cross-repo mismatch is refused" "4" "$rc"
check_contains "refusal names the PR" "PR #$PR_NUM" "$out"
check_contains "refusal names the scoped repo" "org/a" "$out"
check_contains "refusal names the active repo" "org/b" "$out"

# ---- 3. sibling worktree of the same repo is not a mismatch ----------------
write_state "$REPO_B" "$(jq -n --arg r "$REPO_A" '{root_repo:$r, head_sha:"deadbeef", reviewer:"cr"}')"
out="$(cd "$WT_A" && "$SCRIPT" "$PR_NUM" --verify-state 2>&1)"; rc=$?
check_eq "sibling worktree of the scoped repo passes" "0" "$rc"

# ---- 4. path-only scoping still catches a real cross-repo mismatch ---------
out="$(cd "$REPO_B" && "$SCRIPT" "$PR_NUM" --verify-state --root-repo "$REPO_B" 2>&1)"; rc=$?
check_eq "path-only scoping still refuses a foreign checkout" "4" "$rc"
check_contains "path-only refusal names both repos" "org/b" "$out"

# ---- 5. legacy state (no per-PR scoping) degrades, does not refuse ---------
write_state "$REPO_B" "$(jq -n --arg r "$REPO_A" '{root_repo:$r, head_sha:"deadbeef", reviewer:"cr"}')"
# Point per-PR root_repo at a path that no longer exists — carries no signal.
tmpstate="$(mktemp)"
jq --arg pr "$PR_NUM" '.prs[$pr].root_repo = "/nonexistent/gone"' "$STATE" > "$tmpstate" && mv "$tmpstate" "$STATE"
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_NUM" --verify-state 2>&1)"; rc=$?
check_eq "unscoped/stale state passes instead of refusing" "0" "$rc"
check_contains "unscoped state emits a notice recommending --ensure-session" "--ensure-session" "$out"

# ---- 6. --ensure-session records per-PR scoping ----------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  pr)   echo '{"headRefOid":"cafebabe","state":"OPEN"}' ;;
  repo) echo 'org/a' ;;
  *)    exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

rm -f "$STATE" "$HANDOFF"
out="$(cd "$REPO_A" && PATH="$STUB_BIN:$PATH" "$SCRIPT" "$PR_NUM" --ensure-session 2>&1)"; rc=$?
check_eq "--ensure-session succeeds on a fresh PR" "0" "$rc"
# Per-PR state is stored under the repo's own scope since issue #638
# (`.repos["<owner>/<name>"].prs["<N>"]`), so these read the scoped path. The
# recorded values themselves are unchanged — owner_repo is still #647's
# scoping signal, and is also the migration key for pre-#638 state.
check_eq "--ensure-session records per-PR owner_repo" "org/a" \
  "$(jq -r --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr].owner_repo // ""' "$STATE")"
check_eq "--ensure-session records per-PR root_repo" "$REPO_A" \
  "$(jq -r --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr].root_repo // ""' "$STATE")"

# A later tick validates against that scoping even after another session
# overwrites the global field.
tmpstate="$(mktemp)"
jq --arg r "$REPO_B" '.root_repo = $r' "$STATE" > "$tmpstate" && mv "$tmpstate" "$STATE"
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_NUM" --verify-state 2>&1)"; rc=$?
check_eq "later tick passes after a foreign session overwrites global .root_repo" "0" "$rc"

# ---- 7. owner_repo scoping is case-insensitive -----------------------------
tmpstate="$(mktemp)"
jq --arg pr "$PR_NUM" '.prs[$pr].owner_repo = "Org/A"' "$STATE" > "$tmpstate" && mv "$tmpstate" "$STATE"
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_NUM" --verify-state 2>&1)"; rc=$?
check_eq "owner_repo comparison ignores case" "0" "$rc"

# ---- 8. owner and repo sharing a name is still a valid identity ------------
REPO_SAME="$TMP/repo-same"
mk_repo "$REPO_SAME" "git@github.com:foo/foo.git"
write_handoff "foo/foo"
write_state "$REPO_B" "$(jq -n --arg r "$REPO_SAME" '{root_repo:$r, owner_repo:"foo/foo", head_sha:"deadbeef", reviewer:"cr"}')"
out="$(cd "$REPO_SAME" && "$SCRIPT" "$PR_NUM" --verify-state 2>&1)"; rc=$?
check_eq "owner/repo with identical names resolves and passes" "0" "$rc"

# ---- 9. recorded scoping that cannot be compared fails closed --------------
# owner_repo is recorded, but the active checkout has no `origin` remote and the
# recorded path is gone — nothing is verifiable, so the gate must refuse rather
# than fall through to the legacy "proceed" path.
REPO_NOREMOTE="$TMP/repo-noremote"
mkdir -p "$REPO_NOREMOTE"
git -C "$REPO_NOREMOTE" init --quiet
git -C "$REPO_NOREMOTE" config user.email test@example.com
git -C "$REPO_NOREMOTE" config user.name Test
: > "$REPO_NOREMOTE/README.md"
git -C "$REPO_NOREMOTE" add README.md
git -C "$REPO_NOREMOTE" commit --quiet -m init
write_handoff "org/a"
write_state "$REPO_B" "$(jq -n '{root_repo:"/nonexistent/gone", owner_repo:"org/a", head_sha:"deadbeef", reviewer:"cr"}')"
out="$(cd "$REPO_NOREMOTE" && "$SCRIPT" "$PR_NUM" --verify-state 2>&1)"; rc=$?
check_eq "uncomparable identity with recorded scoping fails closed" "4" "$rc"
check_contains "fail-closed message names the PR" "PR #$PR_NUM" "$out"
check_contains "fail-closed message names the scoped repo" "org/a" "$out"

echo ""
echo "polling-state-gate.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
