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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/polling-state-gate-fixtures.sh
source "$TEST_DIR/lib/polling-state-gate-fixtures.sh"
SCRIPT="$REPO_ROOT/.claude/scripts/polling-state-gate.sh"
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
# Match the declaration prefix rather than requiring a particular body layout;
# `name() {`, `name()\n{`, and `name() { :; }` are all legal Bash definitions.
SCOPE_FUNCTION_DECL_RE='^[[:space:]]*(__NAME__[[:space:]]*\(\)|function[[:space:]]+__NAME__([[:space:]]*\(\))?)[[:space:]]*(\{|(#.*)?$)'
for scope_function in "${SCOPE_FUNCTIONS[@]}"; do
  check_eq "scope resolver exports $scope_function" "function" \
    "$(type -t "$scope_function" 2>/dev/null || true)"
  scope_function_re="${SCOPE_FUNCTION_DECL_RE//__NAME__/$scope_function}"
  check_eq "polling gate does not re-inline $scope_function" "0" \
    "$(grep -Ec "$scope_function_re" "$SCRIPT" || true)"
done
# Match source operations only at a command boundary. Include legal grouped,
# conditional, assignment-prefixed, and builtin/command-prefixed forms. A bare
# `(source|\.)` search also matches non-operations such as `resource "$var"` or
# `echo source "$var"`; one such occurrence could mask a removed real source
# while leaving the expected count at one.
SCOPE_SOURCE_BOUNDARY_RE='(^|[;&|(){}])[[:space:]]*((if|elif|then|else|do|while|until|time|coproc)[[:space:]]+)?'
SCOPE_SOURCE_PREFIX_RE="!?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=([^[:space:];&|(){}\"']+|\"[^\"]*\"|'[^']*')+[[:space:]]+)*(command[[:space:]]+|builtin[[:space:]]+)?"
SCOPE_SOURCE_TARGET_RE='(source|\.)[[:space:]]+("?\$\{?_SCOPE_RESOLVER_LIB\}?"?|"?[^"[:space:]]*pr-scope-resolver\.sh"?)'
SCOPE_SOURCE_OP_RE="${SCOPE_SOURCE_BOUNDARY_RE}${SCOPE_SOURCE_PREFIX_RE}${SCOPE_SOURCE_TARGET_RE}"
check_eq "polling gate sources the resolver exactly once" "1" \
  "$(grep -Ev '^[[:space:]]*#' "$SCRIPT" | grep -Eo "$SCOPE_SOURCE_OP_RE" | wc -l | tr -d '[:space:]')"

# Exercise both load-failure branches instead of merely grepping for their
# diagnostics. These copies stop at the resolver boundary, before any other
# helper from SCRIPT_DIR is needed.
MISSING_LIB_DIR="$TMP/missing-resolver"
mkdir -p "$MISSING_LIB_DIR"
cp "$SCRIPT" "$MISSING_LIB_DIR/polling-state-gate.sh"
missing_out="$(HOME="$TMP_HOME" bash "$MISSING_LIB_DIR/polling-state-gate.sh" 1 2>&1)"; missing_rc=$?
check_eq "polling gate exits 4 when the resolver is missing" "4" "$missing_rc"
check_contains "missing-resolver failure names the required dependency" \
  "required scope resolver not found" "$missing_out"

BROKEN_LIB_DIR="$TMP/broken-resolver"
mkdir -p "$BROKEN_LIB_DIR/lib"
cp "$SCRIPT" "$BROKEN_LIB_DIR/polling-state-gate.sh"
printf '%s\n' 'return 7' > "$BROKEN_LIB_DIR/lib/pr-scope-resolver.sh"
broken_out="$(HOME="$TMP_HOME" bash "$BROKEN_LIB_DIR/polling-state-gate.sh" 1 2>&1)"; broken_rc=$?
check_eq "polling gate exits 4 when resolver sourcing fails" "4" "$broken_rc"
check_contains "source-failure diagnostic names the resolver" \
  "failed to source required scope resolver" "$broken_out"

# Keep the structural matchers honest for both Bash function syntaxes and for
# multiple source operations sharing one line.
check_eq "anti-reinline matcher catches function declarations without parentheses" "1" \
  "$(printf '%s\n' '  function resolve_pr_scope {' | grep -Ec "${SCOPE_FUNCTION_DECL_RE//__NAME__/resolve_pr_scope}" || true)"
check_eq "anti-reinline matcher catches declarations with a next-line brace" "1" \
  "$(printf '%s\n' '  resolve_pr_scope ()' '{' | grep -Ec "${SCOPE_FUNCTION_DECL_RE//__NAME__/resolve_pr_scope}" || true)"
check_eq "anti-reinline matcher catches declarations with an inline body" "1" \
  "$(printf '%s\n' 'resolve_pr_scope() { :; }' | grep -Ec "${SCOPE_FUNCTION_DECL_RE//__NAME__/resolve_pr_scope}" || true)"
check_eq "source-site matcher counts two operations on one line" "2" \
  "$(printf 'source "%s"; . "%s"\n' '$_SCOPE_RESOLVER_LIB' '$_SCOPE_RESOLVER_LIB' | grep -Eo "$SCOPE_SOURCE_OP_RE" | wc -l | tr -d '[:space:]')"
check_eq "source-site matcher catches grouped source operations" "1" \
  "$(printf '%s\n' '{ source "$_SCOPE_RESOLVER_LIB"; }' | grep -Eoc "$SCOPE_SOURCE_OP_RE" || true)"
check_eq "source-site matcher catches assignment-prefixed source operations" "1" \
  "$(printf '%s\n' 'TRACE=1 source "$_SCOPE_RESOLVER_LIB"' | grep -Eoc "$SCOPE_SOURCE_OP_RE" || true)"
check_eq "source-site matcher catches quoted assignment-prefixed source operations" "1" \
  "$(printf '%s\n' 'TRACE="two words" source "$_SCOPE_RESOLVER_LIB"' | grep -Eoc "$SCOPE_SOURCE_OP_RE" || true)"
check_eq "source-site matcher catches conditional source operations" "1" \
  "$(printf '%s\n' 'while command source "$_SCOPE_RESOLVER_LIB"; do :; done' | grep -Eoc "$SCOPE_SOURCE_OP_RE" || true)"
check_eq "source-site matcher ignores command names ending in source" "0" \
  "$(printf '%s\n' 'resource "$_SCOPE_RESOLVER_LIB"' | grep -Ec "$SCOPE_SOURCE_OP_RE" || true)"
check_eq "source-site matcher ignores source mentioned as an argument" "0" \
  "$(printf '%s\n' 'echo source "$_SCOPE_RESOLVER_LIB"' | grep -Ec "$SCOPE_SOURCE_OP_RE" || true)"
check_eq "source-site matcher ignores source text inside an argument" "0" \
  "$(printf '%s\n' 'echo '\''x then source "$_SCOPE_RESOLVER_LIB"'\''' | grep -Ec "$SCOPE_SOURCE_OP_RE" || true)"

# ---- throwaway repos (mk_repo from lib) -------------------------------------

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

# write_handoff is provided by lib/polling-state-gate-fixtures.sh.
# Signature: write_handoff <owner_repo_or_empty> <pr_number> <head_sha>
# write_state <global_root_repo> <per-pr fields as jq object or 'null'>
write_state() {
  local global_root="$1" per_pr="$2"
  jq -n --arg root "$global_root" --arg pr "$PR_NUM" --argjson perpr "$per_pr" \
    '{root_repo:$root, prs:{($pr): $perpr}}' > "$STATE"
}

# ---- 1. false positive: foreign session owns the global .root_repo ----------
# This is the exact PR #637 failure — repo B's session wrote .root_repo last while
# we legitimately poll a repo A PR from repo A.
write_handoff "" "$PR_NUM" "deadbeef"
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
write_polling_gh_stub "$STUB_BIN"

rm -f "$STATE" "$HANDOFF"
out="$(cd "$REPO_A" && PATH="$STUB_BIN:$PATH" \
  STUB_PR_JSON='{"headRefOid":"cafebabe","state":"OPEN","number":99647,"headRefName":"feature","url":"https://github.com/org/a/pull/99647","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":""}' \
  STUB_OWNER_REPO="org/a" \
  "$SCRIPT" "$PR_NUM" --ensure-session 2>&1)"; rc=$?
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
write_handoff "foo/foo" "$PR_NUM" "deadbeef"
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
write_handoff "org/a" "$PR_NUM" "deadbeef"
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
write_polling_gh_stub "$STUB_BIN2"

rm -f "$STATE"
( cd "$REPO_MIXED" && PATH="$STUB_BIN2:$PATH" \
  STUB_PR_JSON='{"headRefOid":"c0ffee","state":"OPEN","number":99647,"headRefName":"feature","url":"https://github.com/AuerbachB/Skingod/pull/99647","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":""}' \
  STUB_OWNER_REPO="AuerbachB/Skingod" \
  "$SCRIPT" "$PR_NUM" --ensure-session > /dev/null 2>&1 ); rc2=$?
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
write_polling_gh_stub "$STUB_BIN3"
# Tests 11, 12, and 13 use the same stub with collab as the PR author. The
# `author` field is read only by merge-gate.sh's own inline authorship check
# (test 13); pr-authorship.sh — used by --ensure-session in tests 11/12 — reads
# a separate `gh api repos/.../pulls/N` call keyed off STUB_PR_AUTHOR instead,
# so adding this field does not change tests 11/12's behavior.
_STUB3_PR_JSON='{"headRefOid":"feed1234","state":"OPEN","number":99647,"headRefName":"feature","url":"https://github.com/org/a/pull/99647","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"","author":{"login":"collab","type":"User"}}'

rm -f "$STATE" "$HANDOFF"
out="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" --ensure-session 2>&1)"; rc=$?
check_eq "--ensure-session refuses a collaborator-authored PR" "4" "$rc"
check_contains "refusal names the authorship guard" "authorship guard" "$out"
check_eq "no session-state written for the refused PR" "" \
  "$(jq -r --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr] // ""' "$STATE" 2>/dev/null || echo "")"

# ---- 12. --allow-nonauthor bypasses the guard (explicit user override) ------
out="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" --ensure-session --allow-nonauthor 2>&1)"; rc=$?
check_eq "--allow-nonauthor lets --ensure-session enrol a non-author PR" "0" "$rc"
check_eq "override records per-PR owner_repo" "org/a" \
  "$(jq -r --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr].owner_repo // ""' "$STATE")"

# ---- 13. Regression (issue #1251): --allow-nonauthor must also reach the
# default poll-cycle mode's merge-gate.sh call, not just --ensure-session's own
# pr-authorship.sh check. Reuses the PR enrolled by test 12 (org/a #99647,
# HEAD feed1234, non-author "collab" vs viewer "testuser"). Asserts on the
# authorship-guard string's presence/absence in merge-gate.sh's own `missing[]`
# — not on the overall exit code, since unrelated CI/review gate items also
# stay unmet in this fixture and are irrelevant to what's under test here.
#
# Since issue #1266 the enrolment in test 12 ALSO persists the override, so the
# no-flag negative control must clear that persisted field first. Without this
# reset the flagless run would be suppressed by the persisted decision and the
# control would pass for a reason unrelated to what #1251 pinned — the classic
# guard that passes by not running.
gate_authorship_blocked() {
  # yes/no: does merge-gate.sh's missing[] carry the authorship blocker?
  jq -e '[.missing[]? | select(contains("authorship guard"))] | length > 0' \
    >/dev/null 2>&1 <<<"$1" && echo yes || echo no
}
PSG_STATE_HELPER="$(cd "$(dirname "$SCRIPT")" && pwd)/session-state.sh"
( cd "$REPO_A" && "$PSG_STATE_HELPER" --set ".prs[\"$PR_NUM\"].allow_nonauthor=false" )
check_eq "persisted override can be cleared to false" "false" \
  "$(jq -r --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr].allow_nonauthor' "$STATE")"

out="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" 2>/dev/null)"
check_eq "poll-cycle mode, no flag and no persisted override: authorship block fires" "yes" \
  "$(gate_authorship_blocked "$out")"
err="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" 2>&1 >/dev/null)"
check_eq "no override notice when the bypass is not applied" "0" \
  "$(printf '%s' "$err" | grep -c 'authorship override')"

out="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" --allow-nonauthor 2>/dev/null)"
check_eq "poll-cycle mode forwards --allow-nonauthor: authorship block is suppressed" "no" \
  "$(gate_authorship_blocked "$out")"
check_eq "authorship field still reflects reality (not_mine) even with the override" "not_mine" \
  "$(echo "$out" | jq -r '.authorship')"

# ---- 14. Regression (issue #1266): the enrolment-time override is PERSISTED
# per PR and read back by a FLAGLESS poll-cycle call. #1251 only forwarded a
# flag passed on that same invocation, but cr-github-review.md's per-cycle
# contract calls `polling-state-gate.sh <PR_NUMBER>` with no extra flags — so
# merge-gate.sh's own authorship check re-added the blocker on every tick and
# the gate could never report met for an overridden PR.
out="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" --ensure-session --allow-nonauthor 2>&1)"; rc=$?
check_eq "re-enrolment under the override succeeds" "0" "$rc"
check_eq "--ensure-session --allow-nonauthor persists allow_nonauthor=true" "true" \
  "$(jq -r --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr].allow_nonauthor' "$STATE")"
check_eq "persisted override is a real JSON boolean, not the string \"true\"" "boolean" \
  "$(jq -r --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr].allow_nonauthor | type' "$STATE")"

# The acceptance criterion: no flags on this call at all.
out="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" 2>/dev/null)"
check_eq "flagless poll-cycle reads the persisted override: authorship block absent" "no" \
  "$(gate_authorship_blocked "$out")"
check_eq "persisted override does not falsify the authorship field" "not_mine" \
  "$(echo "$out" | jq -r '.authorship')"

# safety.md requires a tool operating under the override to say so. The notice
# must not reach stdout: callers pipe that into jq as merge-gate.sh's JSON.
# Both streams come from ONE run here — asserting stdout purity against some
# earlier invocation's output would prove nothing about the run that actually
# emitted the notice.
notice_out="$TMP/notice-stdout.json"
err="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" 2>&1 >"$notice_out")"
check_contains "persisted override announces itself on stderr" \
  "authorship override recorded at enrolment" "$err"
check_contains "override notice names the PR" "PR #$PR_NUM" "$err"
check_eq "stdout of that same run is still parseable JSON" "not_mine" \
  "$(jq -r '.authorship' "$notice_out")"
check_eq "the notice never reaches stdout" "0" \
  "$(grep -c 'authorship override' "$notice_out")"

err="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" --allow-nonauthor 2>&1 >/dev/null)"
check_contains "per-invocation override announces its own source" \
  "override passed on this invocation" "$err"

# Only the literal boolean true grants the bypass — a bypass must be granted
# affirmatively, never inferred from a value we could not read. These two write
# $STATE with raw jq on purpose: session-state.sh cannot produce either state
# (see the field-type assertion below), so the helper is the wrong tool for
# staging them. Absent is the real backward-compat case — state enrolled before
# this field existed must keep behaving exactly as it did.
tmpstate="$(mktemp)"
jq --arg pr "$PR_NUM" 'del(.repos["org/a"].prs[$pr].allow_nonauthor)' "$STATE" > "$tmpstate" && mv "$tmpstate" "$STATE"
out="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" 2>/dev/null)"
check_eq "pre-#1266 state with no allow_nonauthor field does not grant the bypass" "yes" \
  "$(gate_authorship_blocked "$out")"

tmpstate="$(mktemp)"
jq --arg pr "$PR_NUM" '.repos["org/a"].prs[$pr].allow_nonauthor = null' "$STATE" > "$tmpstate" && mv "$tmpstate" "$STATE"
out="$(cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB3_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="collab" \
  "$SCRIPT" "$PR_NUM" 2>/dev/null)"
check_eq "null persisted override does not grant the bypass" "yes" \
  "$(gate_authorship_blocked "$out")"

# A value that is not a boolean is refused at write time by the field-type
# contract (session-state.sh exit 4), so it can never be stored through the
# supported write path and later misread as permission. The string "true" is
# the one that matters: the read-back compares against the literal `true`, so a
# stringly-typed value would otherwise sail straight through.
for bad_value in yes true 1; do
  set_rc=0
  ( cd "$REPO_A" && "$PSG_STATE_HELPER" --set ".prs[\"$PR_NUM\"].allow_nonauthor=\"$bad_value\"" ) >/dev/null 2>&1 || set_rc=$?
  check_eq "string allow_nonauthor=\"$bad_value\" is rejected by the field-type contract" "4" "$set_rc"
done

# Re-enrolment WITHOUT the override clears a stale true rather than leaving the
# bypass latched on. Uses a self-authored PR because a non-author PR cannot be
# re-enrolled without the flag at all (test 11).
PR_NUM_OWN="99266"
_STUB_OWN_PR_JSON='{"headRefOid":"0wned123","state":"OPEN","number":99266,"headRefName":"feature","url":"https://github.com/org/a/pull/99266","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"","author":{"login":"testuser","type":"User"}}'
( cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB_OWN_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="testuser" \
  "$SCRIPT" "$PR_NUM_OWN" --ensure-session --allow-nonauthor ) >/dev/null 2>&1
check_eq "self-authored PR enrolled under the override persists true" "true" \
  "$(jq -r --arg pr "$PR_NUM_OWN" '.repos["org/a"].prs[$pr].allow_nonauthor' "$STATE")"
( cd "$REPO_A" && PATH="$STUB_BIN3:$PATH" \
  STUB_PR_JSON="$_STUB_OWN_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="testuser" \
  "$SCRIPT" "$PR_NUM_OWN" --ensure-session ) >/dev/null 2>&1
check_eq "re-enrolment without the override clears the stale true" "false" \
  "$(jq -r --arg pr "$PR_NUM_OWN" '.repos["org/a"].prs[$pr].allow_nonauthor' "$STATE")"

echo ""
echo "== Handoff resolution: scoped path + missing/unreadable exit (issues #1507, #1559) =="
# FAILS-WITHOUT-FIX. Every assertion in this block was replayed against
# origin/main (7c83394) in a DETACHED WORKTREE of the base commit — not a copy
# of the script in /tmp, which cannot resolve its lib/pr-scope-resolver.sh and
# lib/repo-normalizer.sh siblings and so fails for the wrong reason. Observed on
# the pre-change script, in this order:
#
#   scoped-only, no recorded owner_repo        rc=4  "missing handoff …/pr-N-handoff.json"   (#1507)
#   scoped(stale)+flat(fresh), no owner_repo   rc=0  no output at all                        (#1559)
#   no handoff anywhere                        rc=4  (folded into the generic error code)
#   unreadable handoff (mode 000)              rc=2  raw "jq: error: Could not open file …"
#   handoff that is not valid JSON             rc=5  raw "jq: parse error: …"
#   --root-repo override from a foreign cwd    rc=4  "missing handoff …"
#   flat-only with no recorded owner_repo      rc=0  silent (no fallback notice)
#   cross-repo mismatch                        rc=4  but as "missing handoff", not the mismatch
#
# Note the fourth and fifth rows: an unreadable handoff exited 2 — this script's
# documented *usage* code — and invalid JSON exited 5 by coincidence, because
# that is jq's own status for a parse error. So the invalid-JSON case is pinned
# on its MESSAGE, not its code: asserting the code alone would pass vacuously
# against the pre-change script.
#
# Positive controls (pass on both copies, so the harness itself is sound):
# "scoped + recorded owner_repo" and "flat-only + recorded owner_repo".

PR_HS="99507"
HS_SHA="a1b2c3d4"
HS_STALE="0000dead"
hs_state() { # <repo> [owner_repo]  — register PR_HS in <repo>'s own scope
  ( cd "$1" && "$PSG_STATE_HELPER" \
      --set ".root_repo=\"$1\"" \
      --set ".prs[\"$PR_HS\"].root_repo=\"$1\"" \
      --set ".prs[\"$PR_HS\"].head_sha=\"$HS_SHA\"" \
      --set ".prs[\"$PR_HS\"].reviewer=\"cr\"" ) >/dev/null
  if [[ -n "${2:-}" ]]; then
    ( cd "$1" && "$PSG_STATE_HELPER" --set ".prs[\"$PR_HS\"].owner_repo=\"$2\"" ) >/dev/null
  fi
}
hs_reset() { # forget every handoff and every registration for PR_HS
  chmod -R u+rwX "$HOME/.claude/handoffs" 2>/dev/null || true
  rm -f "$HOME/.claude/handoffs/pr-${PR_HS}-handoff.json" \
        "$HOME/.claude/handoffs/org/a/pr-${PR_HS}-handoff.json" \
        "$HOME/.claude/handoffs/org/b/pr-${PR_HS}-handoff.json"
  # `.repos` and a scope's `.prs` are both normalized before del(): jq errors on
  # `del` against null, and a filter that dies here would leave the previous
  # fixture's registration in place — every later assertion would then be
  # measuring the wrong state while still looking like it ran.
  tmpstate="$(mktemp)"
  if jq --arg pr "$PR_HS" \
      '.repos = ((.repos // {}) | with_entries(.value.prs = ((.value.prs // {}) | del(.[$pr]))))' \
      "$STATE" > "$tmpstate" && mv "$tmpstate" "$STATE"; then
    :
  else
    rm -f "$tmpstate"
    FAIL=$((FAIL + 1)); echo "FAIL — hs_reset could not rewrite $STATE (fixture state is unreliable)"
  fi
}

# ---- A. #1507: the scoped handoff is found with NO per-PR owner_repo -------
# The field the pre-change script read is exactly the one that is absent here;
# scope now also comes from $CLAUDE_SESSION_REPO / the resolved checkout.
hs_reset; hs_state "$REPO_A"
write_handoff "org/a" "$PR_HS" "$HS_SHA" >/dev/null
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state 2>&1)"; rc=$?
check_eq "scoped-only handoff resolves with no recorded owner_repo" "0" "$rc"
check_eq "…and reports no missing handoff" "0" "$(printf '%s' "$out" | grep -c 'missing handoff')"

# ---- B. #1559: a stale flat file no longer answers for a scoped handoff ----
# Both files exist; only the flat one agrees with session-state. The pre-change
# script validated it and exited 0 in silence. The scoped handoff is this PR's
# record, so the SHA disagreement must surface instead.
hs_reset; hs_state "$REPO_A"
write_handoff "org/a" "$PR_HS" "$HS_STALE" >/dev/null
write_handoff "" "$PR_HS" "$HS_SHA" >/dev/null
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state 2>&1)"; rc=$?
check_eq "stale flat file no longer passes in place of the scoped handoff" "4" "$rc"
check_contains "refusal names the scoped handoff that was read" \
  "handoffs/org/a/pr-${PR_HS}-handoff.json" "$out"
check_contains "refusal names the disagreeing SHAs" "$HS_STALE" "$out"

# ---- C. #1559: missing handoff exits 5, not 4 and never 0 -----------------
hs_reset; hs_state "$REPO_A" "org/a"
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state 2>&1)"; rc=$?
check_eq "no handoff anywhere exits with the distinct code 5" "5" "$rc"
check_contains "missing-handoff message names the scoped path it expected" \
  "handoffs/org/a/pr-${PR_HS}-handoff.json" "$out"

# ---- D. #1559: an unreadable handoff is exit 5, not a raw jq failure ------
# Mode 000 denies nothing to uid 0, so under a root test runner this fixture
# cannot construct its own precondition. Announced rather than silently
# skipped: a case that quietly stops running is indistinguishable from one that
# passes.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "skip — unreadable-handoff case: mode 000 does not deny reads to root"
else
  hs_reset; hs_state "$REPO_A" "org/a"
  write_handoff "org/a" "$PR_HS" "$HS_SHA" >/dev/null
  chmod 000 "$HOME/.claude/handoffs/org/a/pr-${PR_HS}-handoff.json"
  out="$(cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state 2>&1)"; rc=$?
  chmod 644 "$HOME/.claude/handoffs/org/a/pr-${PR_HS}-handoff.json"
  check_eq "unreadable handoff exits 5" "5" "$rc"
  check_contains "unreadable handoff says so in the gate's own voice" "unreadable handoff" "$out"
  check_eq "…and does not leak jq's own error" "0" "$(printf '%s' "$out" | grep -c '^jq:')"
fi

# ---- E. #1559: a corrupt handoff is exit 5 with a message, not jq's ------
# Pinned on the message: jq's parse-error status is also 5, so the code alone
# cannot tell the fix from the pre-change abort.
hs_reset; hs_state "$REPO_A" "org/a"
write_handoff "org/a" "$PR_HS" "$HS_SHA" >/dev/null
printf 'not json{' > "$HOME/.claude/handoffs/org/a/pr-${PR_HS}-handoff.json"
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state 2>&1)"; rc=$?
check_eq "handoff that is not valid JSON exits 5" "5" "$rc"
check_contains "corrupt handoff is reported by the gate, naming the file" \
  "not valid JSON" "$out"
check_eq "…and does not leak jq's own parse error" "0" "$(printf '%s' "$out" | grep -c '^jq:')"

# ---- F. legacy flat handoffs are still honored (AC: fallback preserved) ---
# Two shapes: with a recorded owner_repo (a positive control — passes on both
# copies) and without one, where the pre-change script also passed but printed
# nothing, because the fallback notice was gated on the missing field.
hs_reset; hs_state "$REPO_A" "org/a"
write_handoff "" "$PR_HS" "$HS_SHA" >/dev/null
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state 2>&1)"; rc=$?
check_eq "flat-only handoff still resolves with a recorded owner_repo" "0" "$rc"
check_contains "flat fallback announces itself" "falling back to flat" "$out"

hs_reset; hs_state "$REPO_A"
write_handoff "" "$PR_HS" "$HS_SHA" >/dev/null
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state 2>&1)"; rc=$?
check_eq "flat-only handoff still resolves with no recorded owner_repo" "0" "$rc"
check_contains "flat fallback announces itself even with no recorded scope" \
  "falling back to flat" "$out"

# ---- G. positive control: the ordinary scoped case is untouched -----------
hs_reset; hs_state "$REPO_A" "org/a"
write_handoff "org/a" "$PR_HS" "$HS_SHA" >/dev/null
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state 2>&1)"; rc=$?
check_eq "scoped handoff + recorded owner_repo still passes" "0" "$rc"
check_eq "…silently" "" "$out"

# ---- H. --root-repo override is not regressed ----------------------------
# cwd is repo B; the gate operates on repo A. Scope must follow the RESOLVED
# checkout, not the cwd — the memory note about this script's worktree/root_repo
# false refusals is the reason this path gets its own assertion.
hs_reset; hs_state "$REPO_A"
write_handoff "org/a" "$PR_HS" "$HS_SHA" >/dev/null
out="$(cd "$REPO_B" && "$SCRIPT" "$PR_HS" --verify-state --root-repo "$REPO_A" 2>&1)"; rc=$?
check_eq "--root-repo resolves the target repo's scoped handoff from a foreign cwd" "0" "$rc"
check_eq "…and reports no missing handoff" "0" "$(printf '%s' "$out" | grep -c 'missing handoff')"

# ---- I. a genuine cross-repo mismatch still refuses, and now says why -----
# The pre-change script also exited 4 here, but as "missing handoff" — it never
# reached the mismatch check, so the diagnosis named the wrong problem.
hs_reset; hs_state "$REPO_A" "org/b"
write_handoff "org/a" "$PR_HS" "$HS_SHA" >/dev/null
out="$(cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state 2>&1)"; rc=$?
check_eq "cross-repo mismatch is still refused" "4" "$rc"
check_contains "refusal is the mismatch, not a missing file" "refuse to poll from the wrong repo" "$out"

# ---- I2. a helper NOTE on stderr must not become part of the path --------
# handoff-state.sh prints a note on a successful --path call when
# CLAUDE_HANDOFF_FLAT_OK=1 is exported alongside an explicit --owner-repo —
# which /wrap does around its flat-layout sweeps. Capturing that call as `2>&1`
# splices the note into the resolved path, so the scoped file stops matching
# and the flat fallback answers again: the #1559 defect, rebuilt out of a
# stream merge. (CodeRabbit CLI, this PR.)
hs_reset; hs_state "$REPO_A" "org/a"
write_handoff "org/a" "$PR_HS" "$HS_SHA" >/dev/null
out="$(cd "$REPO_A" && CLAUDE_HANDOFF_FLAT_OK=1 "$SCRIPT" "$PR_HS" --verify-state 2>&1)"; rc=$?
check_eq "a stderr note from handoff-state.sh does not corrupt the resolved path" "0" "$rc"
check_eq "…so the scoped handoff still answers, not the flat fallback" "0" \
  "$(printf '%s' "$out" | grep -c 'falling back to flat')"

# ---- I3. the remedy exit 5 advertises actually works ---------------------
# Exit 5 tells the caller to run --ensure-session. Before this PR that advice
# was a dead end for a handoff that exists but cannot be parsed: the refresh
# branch is a read-modify-write, so handoff-state.sh --set failed on the
# unparseable file and the loop had no way out. Each exit-5 shape is now
# followed by the advertised command and re-checked. (CodeRabbit CLI, this PR.)
HS_STUB_BIN="$TMP/bin-hs"
write_polling_gh_stub "$HS_STUB_BIN"
_HS_STUB_PR_JSON="$(jq -nc --arg sha "$HS_SHA" --argjson pr "$PR_HS" \
  '{headRefOid:$sha, state:"OPEN", number:$pr, headRefName:"feature",
    url:"https://github.com/org/a/pull/99507", mergeStateStatus:"CLEAN",
    mergeable:"MERGEABLE", reviewDecision:"", author:{login:"testuser", type:"User"}}')"
hs_ensure() { # run the advertised remedy in repo A
  ( cd "$REPO_A" && PATH="$HS_STUB_BIN:$PATH" \
      STUB_PR_JSON="$_HS_STUB_PR_JSON" STUB_OWNER_REPO="org/a" STUB_PR_AUTHOR="testuser" \
      "$SCRIPT" "$PR_HS" --ensure-session ) >/dev/null 2>&1
}

# missing everywhere -> --ensure-session writes the checkpoint, gate then passes
hs_reset; hs_state "$REPO_A" "org/a"
rc=0; out="$(cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state 2>&1)" || rc=$?
check_eq "exit-5 precondition: missing handoff" "5" "$rc"
hs_ensure; ensure_rc=$?
check_eq "--ensure-session recovers from a missing handoff" "0" "$ensure_rc"
rc=0; (cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state >/dev/null 2>&1) || rc=$?
check_eq "…and the gate then passes" "0" "$rc"

# corrupt JSON -> --ensure-session re-creates it rather than failing the RMW
hs_reset; hs_state "$REPO_A" "org/a"
write_handoff "org/a" "$PR_HS" "$HS_SHA" >/dev/null
printf 'not json{' > "$HOME/.claude/handoffs/org/a/pr-${PR_HS}-handoff.json"
rc=0; (cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state >/dev/null 2>&1) || rc=$?
check_eq "exit-5 precondition: corrupt handoff" "5" "$rc"
hs_ensure; ensure_rc=$?
check_eq "--ensure-session repairs a corrupt handoff" "0" "$ensure_rc"
check_eq "…leaving valid JSON on disk" "0" \
  "$(jq -e . "$HOME/.claude/handoffs/org/a/pr-${PR_HS}-handoff.json" >/dev/null 2>&1; echo $?)"
rc=0; (cd "$REPO_A" && "$SCRIPT" "$PR_HS" --verify-state >/dev/null 2>&1) || rc=$?
check_eq "…and the gate then passes" "0" "$rc"

# a corrupt FLAT handoff is repaired in place, not shadowed by a new scoped one
hs_reset; hs_state "$REPO_A" "org/a"
write_handoff "" "$PR_HS" "$HS_SHA" >/dev/null
printf 'not json{' > "$HOME/.claude/handoffs/pr-${PR_HS}-handoff.json"
hs_ensure >/dev/null 2>&1
check_eq "corrupt flat handoff is repaired at the flat path" "0" \
  "$(jq -e . "$HOME/.claude/handoffs/pr-${PR_HS}-handoff.json" >/dev/null 2>&1; echo $?)"
check_eq "…and no scoped duplicate is created beside it" "0" \
  "$([[ -f "$HOME/.claude/handoffs/org/a/pr-${PR_HS}-handoff.json" ]] && echo 1 || echo 0)"

# ---- J. the flat path itself comes from handoff-state.sh -----------------
# AC (#1559): no hardcoded flat path anywhere in the gate. Both literals are
# gone, so the only remaining source of a flat path is the helper's own
# --legacy-flat resolution.
# Comments are stripped first: the header and the note standing where
# HANDOFF_DIR used to be both spell the flat path out on purpose, and a check
# that counted those would fail for documenting the very thing it enforces.
check_eq "gate holds no hardcoded flat handoff path in code" "0" \
  "$(grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -cE 'handoffs/pr-|HANDOFF_DIR' || true)"
check_eq "gate resolves the flat path through handoff-state.sh --legacy-flat" "yes" \
  "$([[ "$(grep -cE '"\$HANDOFF_HELPER" --legacy-flat --path' "$SCRIPT" || true)" -ge 1 ]] && echo yes || echo no)"
# Companion to I2, expressed structurally: no --path capture may merge stderr
# into the value it assigns. The diagnostic re-read uses `2>&1 >/dev/null`,
# which captures stderr ONLY and is therefore not matched here.
check_eq "no --path capture merges stderr into the resolved path" "0" \
  "$(grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -cE '[A-Za-z_]+="\$\("\$HANDOFF_HELPER".*--path[^)]*2>&1\)"' || true)"

echo ""
echo "polling-state-gate.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
