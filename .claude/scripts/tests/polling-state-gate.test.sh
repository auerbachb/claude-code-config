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
SCOPE_LIB="$REPO_ROOT/.claude/scripts/lib/pr-scope-resolver.sh"

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

# ---- 0. extracted scope-resolver boundary (issue #971) ---------------------
LIB_OUT=""
LIB_RC=0
LIB_OUT="$(bash "$SCOPE_LIB" 2>&1)" || LIB_RC=$?
check_eq "scope resolver refuses direct execution" "2" "$LIB_RC"
check_contains "direct-execution refusal explains the source-only contract" \
  "source this file, do not execute it directly" "$LIB_OUT"

SOURCE_RC=0
# shellcheck source=../lib/pr-scope-resolver.sh
source "$SCOPE_LIB" || SOURCE_RC=$?
check_eq "scope resolver can be sourced" "0" "$SOURCE_RC"

SCOPE_FUNCTIONS=(
  _pr_holders active_scope_key resolve_pr_scope foreign_pr_scopes state_pr_field
  repo_identity is_owner_repo_identity resolve_root_repo validate_root_match
)
# Match the declaration itself rather than requiring its opening brace on the
# same line; both `name() {` and `name()\n{` are legal Bash definitions.
SCOPE_FUNCTION_DECL_RE='^[[:space:]]*(__NAME__[[:space:]]*\(\)|function[[:space:]]+__NAME__([[:space:]]*\(\))?)([[:space:]]*\{)?[[:space:]]*(#.*)?$'
for scope_function in "${SCOPE_FUNCTIONS[@]}"; do
  check_eq "scope resolver exports $scope_function" "function" \
    "$(type -t "$scope_function" 2>/dev/null || true)"
  scope_function_re="${SCOPE_FUNCTION_DECL_RE//__NAME__/$scope_function}"
  check_eq "polling gate does not re-inline $scope_function" "0" \
    "$(grep -Ec "$scope_function_re" "$SCRIPT" || true)"
done
# Match source operations only at a command boundary. A bare `(source|\.)`
# search also matches non-operations such as `resource "$var"` or
# `echo source "$var"`; one such occurrence could mask a removed real source
# while leaving the expected count at one.
SCOPE_SOURCE_OP_RE='(^|[;&|()][[:space:]]*|(^|[[:space:]])(if|elif|then|else|do)[[:space:]]+)!?[[:space:]]*(source|\.)[[:space:]]+("?\$\{?_SCOPE_RESOLVER_LIB\}?"?|"?[^"[:space:]]*pr-scope-resolver\.sh"?)'
check_eq "polling gate sources the resolver exactly once" "1" \
  "$(grep -Ev '^[[:space:]]*#' "$SCRIPT" | grep -Eo "$SCOPE_SOURCE_OP_RE" | wc -l | tr -d '[:space:]')"
check_eq "polling gate hard-fails when the resolver is missing" "1" \
  "$(grep -Ec 'required scope resolver not found' "$SCRIPT" || true)"

# Keep the structural matchers honest for both Bash function syntaxes and for
# multiple source operations sharing one line.
check_eq "anti-reinline matcher catches function declarations without parentheses" "1" \
  "$(printf '%s\n' '  function resolve_pr_scope {' | grep -Ec "${SCOPE_FUNCTION_DECL_RE//__NAME__/resolve_pr_scope}" || true)"
check_eq "anti-reinline matcher catches declarations with a next-line brace" "1" \
  "$(printf '%s\n' '  resolve_pr_scope ()' '{' | grep -Ec "${SCOPE_FUNCTION_DECL_RE//__NAME__/resolve_pr_scope}" || true)"
check_eq "source-site matcher counts two operations on one line" "2" \
  "$(printf 'source "%s"; . "%s"\n' '$_SCOPE_RESOLVER_LIB' '$_SCOPE_RESOLVER_LIB' | grep -Eo "$SCOPE_SOURCE_OP_RE" | wc -l | tr -d '[:space:]')"
check_eq "source-site matcher ignores command names ending in source" "0" \
  "$(printf '%s\n' 'resource "$_SCOPE_RESOLVER_LIB"' | grep -Ec "$SCOPE_SOURCE_OP_RE" || true)"
check_eq "source-site matcher ignores source mentioned as an argument" "0" \
  "$(printf '%s\n' 'echo source "$_SCOPE_RESOLVER_LIB"' | grep -Ec "$SCOPE_SOURCE_OP_RE" || true)"

# Shared gh stub for --ensure-session tests. poll-watermarks.sh (issue #741) calls
# pr-state.sh during --ensure-session, so the stub must satisfy pr-state's gh
# surface in addition to polling-state-gate / pr-authorship.
write_ensure_session_gh_stub() {
  local bin_dir="$1" pr_json="$2" repo_slug="$3" author_login="${4:-testuser}"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
case "\${1:-}" in
  pr)   echo '$pr_json' ;;
  repo) echo '$repo_slug' ;;
  api)
    shift
    [[ "\${1:-}" == "--paginate" ]] && shift
    endpoint="\${1:-}"
    case "\$endpoint" in
      user) echo 'testuser' ;;
      graphql)
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
        ;;
      repos/*/pulls/*)
        if [[ "\$*" == *"/reviews"* || "\$*" == *"/comments"* ]]; then
          echo '[]'
        else
          echo '{"user":{"login":"$author_login","type":"User"}}'
        fi
        ;;
      repos/*/issues/*/comments*) echo '[]' ;;
      repos/*/commits/*/check-runs*) echo '{"check_runs":[]}' ;;
      repos/*/commits/*/statuses*) echo '[]' ;;
      *) echo '[]' ;;
    esac
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$bin_dir/gh"
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

# A declared identity is a safety boundary. If its normalizer fails, validation
# must refuse rather than silently replacing the declaration with checkout_id.
NORMALIZER_DEF="$(declare -f normalize_repo_key)"
normalize_repo_key() { return 1; }
STATE_FILE="$TMP/no-state"
STATE_READ_DIR="$REPO_A"
REPO_KEY_DECLARED=1
ACTIVE_REPO_KEY="org/a"
PR_NUMBER="99647"
out="$(validate_root_match "$REPO_A" quiet 2>&1)"; rc=$?
check_eq "declared repo-key normalization failure refuses validation" "1" "$rc"
check_contains "normalization refusal explains the unusable identity" \
  "could not normalize repo key 'org/a'" "$out"
normalize_repo_key() { printf ''; return 0; }
out="$(validate_root_match "$REPO_A" quiet 2>&1)"; rc=$?
check_eq "empty normalized declared repo key refuses validation" "1" "$rc"
check_contains "empty normalization refusal explains the unusable identity" \
  "could not normalize repo key 'org/a'" "$out"
eval "$NORMALIZER_DEF"

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
write_ensure_session_gh_stub "$STUB_BIN" \
  '{"headRefOid":"cafebabe","state":"OPEN","number":99647,"headRefName":"feature","url":"https://github.com/org/a/pull/99647","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":""}' \
  "org/a"

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
check_eq "--ensure-session initializes poll_watermarks" "0" \
  "$(jq -r --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr].poll_watermarks.last_review_id // "missing"' "$STATE")"

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

# ---- 10. case-parity regression (issue #704) ----------------------------------
# A checkout whose `origin` remote has mixed-case owner/repo (e.g.
# "AuerbachB/Skingod") must produce the SAME scope key from both
# session-state.sh (--repo-key) and polling-state-gate.sh (repo_identity()),
# so --ensure-session writes to the same .repos bucket that --verify-state
# reads from.  Before issue #704 the two functions disagreed on case, so a
# mixed-case remote silently created two .repos scopes for the same repo.
REPO_MIXED="$TMP/repo-mixed"
STATE_HELPER="$(cd "$(dirname "$SCRIPT")" && pwd)/session-state.sh"
mk_repo "$REPO_MIXED" "git@github.com:AuerbachB/Skingod.git"

# session-state.sh --repo-key must return the lowercase form.
mixed_session_key="$(cd "$REPO_MIXED" && "$STATE_HELPER" --repo-key 2>/dev/null || true)"
check_eq "session-state.sh --repo-key lowercases mixed-case remote" \
  "auerbachb/skingod" "$mixed_session_key"

# Simulate --ensure-session: write state under the key session-state.sh
# produced (already lowercase from test above), then --verify-state from the
# same checkout should pass (not refuse as a cross-repo mismatch).
STUB_BIN2="$TMP/bin2"
write_ensure_session_gh_stub "$STUB_BIN2" \
  '{"headRefOid":"c0ffee","state":"OPEN","number":99647,"headRefName":"feature","url":"https://github.com/AuerbachB/Skingod/pull/99647","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":""}' \
  "AuerbachB/Skingod"

rm -f "$STATE"
out2="$(cd "$REPO_MIXED" && PATH="$STUB_BIN2:$PATH" "$SCRIPT" "$PR_NUM" --ensure-session 2>&1)"; rc2=$?
check_eq "--ensure-session with mixed-case remote exits 0" "0" "$rc2"

# The key stored in session-state.json must be lowercase.
stored_key="$(jq -r --arg pr "$PR_NUM" '.repos | keys[]' "$STATE" 2>/dev/null | head -1 || true)"
check_eq "state stored under lowercase key after ensure-session" \
  "auerbachb/skingod" "$stored_key"

# --verify-state from the same mixed-case-remote checkout must pass.
out3="$(cd "$REPO_MIXED" && PATH="$STUB_BIN2:$PATH" "$SCRIPT" "$PR_NUM" --verify-state 2>&1)"; rc3=$?
check_eq "--verify-state passes for mixed-case-remote checkout (no false cross-repo refusal)" "0" "$rc3"

# ---- 11. authorship guard (issue #733): --ensure-session refuses a non-author PR ----
# gh api user (viewer) and the PR author disagree, so pr-authorship.sh returns
# not_mine and enrolment is refused. Enrolling a PR in polling is a "touch".
STUB_BIN3="$TMP/bin3"
write_ensure_session_gh_stub "$STUB_BIN3" \
  '{"headRefOid":"feed1234","state":"OPEN","number":99647,"headRefName":"feature","url":"https://github.com/org/a/pull/99647","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":""}' \
  "org/a" \
  "collab"

rm -f "$STATE" "$HANDOFF"
out="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" "$SCRIPT" "$PR_NUM" --ensure-session 2>&1)"; rc=$?
check_eq "--ensure-session refuses a collaborator-authored PR" "4" "$rc"
check_contains "refusal names the authorship guard" "authorship guard" "$out"
check_eq "no session-state written for the refused PR" "" \
  "$(jq -r --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr] // ""' "$STATE" 2>/dev/null || echo "")"

# ---- 12. --allow-nonauthor bypasses the guard (explicit user override) ------
out="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" "$SCRIPT" "$PR_NUM" --ensure-session --allow-nonauthor 2>&1)"; rc=$?
check_eq "--allow-nonauthor lets --ensure-session enrol a non-author PR" "0" "$rc"
check_eq "override records per-PR owner_repo" "org/a" \
  "$(jq -r --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr].owner_repo // ""' "$STATE")"

echo ""
echo "polling-state-gate.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
