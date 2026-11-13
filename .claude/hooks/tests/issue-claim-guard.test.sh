#!/usr/bin/env bash
# Tests for .claude/hooks/issue-claim-guard.sh (issue #2287).
#
# The REAL hook runs against a stub issue-claim.sh placed where the hook's
# resolver looks ($HOME/.claude/scripts). Verdicts come from a per-run table, so
# one issue can be claimed while a neighbour is not — the discriminating shape.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/issue-claim-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export TMPDIR="$TMP/cache"
export STUB_CALLS="$TMP/calls.log"
export STUB_VERDICTS="$TMP/verdicts.txt"
export CLAUDE_CLAIM_HOLDER="guard-test-holder-$$"
unset CLAUDE_SESSION_ID
mkdir -p "$HOME/.claude/scripts" "$TMPDIR"
: > "$STUB_CALLS"
: > "$STUB_VERDICTS"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $*" >&2; }

# Stub helper: prints the --check --json object for the issue in $1, with the
# exit codes the real helper uses (0 mine/unclaimed/stale, 1 claimed, 4 unknown).
cat > "$HOME/.claude/scripts/issue-claim.sh" <<'STUB'
#!/usr/bin/env bash
n=$1
printf '%s\n' "$n" >> "$STUB_CALLS"
verdict=unclaimed
while read -r a b; do
  if [ "$a" = "$n" ]; then verdict=$b; fi
done < "$STUB_VERDICTS"
case "$verdict" in
  garbage) printf 'not json\n'; exit 0 ;;
  crash) exit 9 ;;
  claimed) rc=1 ;;
  unknown) rc=4 ;;
  *) rc=0 ;;
esac
printf '{"issue":%s,"repo":"example-owner/example-repo","verdict":"%s","claimant":"other-login","claimant_holder":"h-other","provider":"codex","device":"studio","label":"nightly run"}\n' "$n" "$verdict"
exit "$rc"
STUB
chmod +x "$HOME/.claude/scripts/issue-claim.sh"

set_verdict() { printf '%s %s\n' "$1" "$2" >> "$STUB_VERDICTS"; }

# A scratch checkout with no .claude/ directory, on an arbitrary branch.
make_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
}

# run_hook COMMAND CWD -> hook stdout
run_hook() {
  jq -nc --arg c "$1" --arg d "$2" \
    '{session_id:"guard-test",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' \
    | bash "$HOOK"
}

reason_of() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null
}

expect_allow() {
  local label="$1" out="$2"
  if [ -z "$out" ]; then pass "$label: allowed"; else fail "$label: expected allow, got: $(reason_of "$out")"; fi
}

expect_deny() {
  local label="$1" out="$2" needle="$3" reason
  reason="$(reason_of "$out")"
  if [ -z "$reason" ]; then
    fail "$label: expected deny, got no decision"
  elif printf '%s' "$reason" | grep -q -F -- "$needle"; then
    pass "$label: denied with \"$needle\""
  else
    fail "$label: denied but reason lacks \"$needle\": $reason"
  fi
}

expect_not_deny_text() {
  local label="$1" out="$2" needle="$3" reason
  reason="$(reason_of "$out")"
  if printf '%s' "$reason" | grep -q -F -- "$needle"; then
    fail "$label: reason wrongly contains \"$needle\": $reason"
  else
    pass "$label: reason does not contain \"$needle\""
  fi
}

WORK="$TMP/work"
make_repo "$WORK" "main"

# --- mine allows ------------------------------------------------------------
set_verdict 101 mine
out="$(run_hook 'git worktree add ../wt-101 -b issue-101-thing' "$WORK")"
expect_allow "mine: worktree add on issue-101 branch" "$out"

# --- claimed blocks, naming the holder and the claim command ----------------
set_verdict 102 claimed
out="$(run_hook 'git checkout -b issue-102-x' "$WORK")"
expect_deny "claimed: checkout -b issue-102" "$out" "claimed by another holder"
expect_deny "claimed: names provider" "$out" "codex"
expect_deny "claimed: names device" "$out" "studio"
expect_deny "claimed: names label" "$out" "nightly run"
expect_deny "claimed: names the claim command" "$out" "issue-claim.sh 102 --claim"

# --- unknown blocks, and is not described as claimed -------------------------
set_verdict 103 unknown
out="$(run_hook 'git switch -c issue-103-y' "$WORK")"
expect_deny "unknown: switch -c issue-103" "$out" "claim state of issue #103"
expect_not_deny_text "unknown: not worded as a live claim" "$out" "claimed by another holder"

# --- unclaimed blocks, pointing at --claim -----------------------------------
set_verdict 104 unclaimed
out="$(run_hook 'git worktree add ../wt-104 issue-104-q' "$WORK")"
expect_deny "unclaimed: worktree add names issue-104" "$out" "verdict: unclaimed"
expect_deny "unclaimed: message names --claim" "$out" "--claim"

# --- stale blocks with the take-over path -----------------------------------
set_verdict 105 stale
out="$(run_hook 'git worktree add ../wt-105 -b issue-105-z' "$WORK")"
expect_deny "stale: blocks, takeover happens through --claim" "$out" "verdict: stale"

# --- branch naming no issue, and unrelated commands, are never checked -------
calls_before="$(wc -l < "$STUB_CALLS" | tr -d ' ')"
out="$(run_hook 'git worktree add ../feature-x -b feature-x' "$WORK")"
expect_allow "no issue number: worktree add feature-x" "$out"
out="$(run_hook 'ls -la && git status' "$WORK")"
expect_allow "unrelated command" "$out"
calls_after="$(wc -l < "$STUB_CALLS" | tr -d ' ')"
if [ "$calls_before" = "$calls_after" ]; then
  pass "no-issue and unrelated commands never reach the helper"
else
  fail "no-issue or unrelated command reached the helper"
fi

# --- helper missing blocks, naming the fallback recipe -----------------------
NOHELP_HOME="$TMP/nohelper/home"
NOHELP_REPO="$TMP/nohelper/repo"
mkdir -p "$NOHELP_HOME" "$NOHELP_REPO"
make_repo "$NOHELP_REPO" "main"
out="$(HOME="$NOHELP_HOME" run_hook 'git checkout -b issue-106-q' "$NOHELP_REPO")"
expect_deny "helper missing: blocks" "$out" "issue-claim.sh not found"
expect_deny "helper missing: names the plain-gh fallback" "$out" "agent-issue-claims-block.md"

# --- internal faults block with the distinct GUARD FAILED message ------------
out="$(printf 'not json' | bash "$HOOK")"
expect_deny "fault: unreadable hook input" "$out" "GUARD FAILED"
expect_not_deny_text "fault: unreadable input is not worded as claimed" "$out" "claimed by another holder"

set_verdict 107 garbage
out="$(run_hook 'git checkout -b issue-107-g' "$WORK")"
expect_deny "fault: helper prints non-JSON" "$out" "GUARD FAILED"

set_verdict 108 crash
out="$(run_hook 'git checkout -b issue-108-c' "$WORK")"
expect_deny "fault: helper exits 9" "$out" "GUARD FAILED"
expect_not_deny_text "fault: crash is not worded as claimed" "$out" "claimed by another holder"

# --- override lets ONLY the named issue through ------------------------------
set_verdict 109 claimed
set_verdict 110 claimed
OVR="$HOME/.claude/issue-claim-overrides/example-owner__example-repo"
mkdir -p "$OVR"
: > "$OVR/109"
out="$(run_hook 'git checkout -b issue-109-o' "$WORK")"
expect_allow "override: named issue 109 is allowed" "$out"
out="$(run_hook 'git checkout -b issue-110-o' "$WORK")"
expect_deny "override: unnamed issue 110 stays blocked" "$out" "claimed by another holder"

# --- gh pr create checks the current branch ----------------------------------
PR_REPO="$TMP/pr-repo"
make_repo "$PR_REPO" "issue-112-z"
set_verdict 112 claimed
out="$(run_hook 'gh pr create --title t --body b' "$PR_REPO")"
expect_deny "gh pr create on claimed issue-112 branch" "$out" "claimed by another holder"

make_repo "$TMP/pr-feature" "feature-q"
out="$(run_hook 'gh pr create --title t --body b' "$TMP/pr-feature")"
expect_allow "gh pr create on a non-issue branch" "$out"

# --- owner-qualified --head is matched on its branch part -------------------
set_verdict 114 claimed
out="$(run_hook 'gh pr create --head example-owner:issue-114-h --title t' "$TMP/pr-feature")"
expect_deny "gh pr create --head owner:issue-114 is checked" "$out" "claimed by another holder"

# --- a cd before gh pr create leaves the checked branch unresolved ----------
out="$(run_hook 'cd "'"$PR_REPO"'" && gh pr create --title t --body b' "$TMP/pr-feature")"
expect_deny "cd before gh pr create fails closed" "$out" "GUARD FAILED"
expect_not_deny_text "cd fault is not worded as claimed" "$out" "claimed by another holder"

# --- a branch switch before gh pr create fails closed ------------------------
out="$(run_hook 'git switch issue-120-s && gh pr create --title t --body b' "$TMP/pr-feature")"
expect_deny "switch then gh pr create fails closed" "$out" "GUARD FAILED"

# --- git -C names the repo a creation runs in --------------------------------
set_verdict 121 claimed
out="$(run_hook 'git -C "'"$PR_REPO"'" worktree add ../wt-121 -b issue-121-c' "$WORK")"
expect_deny "git -C target repo: claimed issue-121 is checked" "$out" "claimed by another holder"

# --- non-issue creation after a cd is allowed; gh -R fails closed -----------
out="$(run_hook 'cd "'"$PR_REPO"'" && git worktree add ../feature-z -b feature-z' "$WORK")"
expect_allow "cd then non-issue worktree add is allowed" "$out"
out="$(run_hook 'gh pr create -R example-owner/other --title t' "$TMP/pr-feature")"
expect_deny "gh pr create -R fails closed" "$out" "GUARD FAILED"

# --- --reason takes a value; the issue branch after it is still checked -----
set_verdict 122 claimed
out="$(run_hook 'git worktree add --reason why -b issue-122-r ../wt-122' "$WORK")"
expect_deny "--reason value is skipped; issue-122 still checked" "$out" "claimed by another holder"

# --- long switch options create branches too ---------------------------------
set_verdict 123 claimed
out="$(run_hook 'git switch --create issue-123-l' "$WORK")"
expect_deny "switch --create issue-123 is checked" "$out" "claimed by another holder"

# --- attached option values and dynamic names are not bypasses --------------
set_verdict 130 claimed
out="$(run_hook 'git switch --create=issue-130-a' "$WORK")"
expect_deny "switch --create=issue-130 is checked" "$out" "claimed by another holder"
set_verdict 131 claimed
out="$(run_hook 'git checkout -bissue-131-b' "$WORK")"
expect_deny "checkout -bissue-131 (attached) is checked" "$out" "claimed by another holder"
out="$(run_hook 'git checkout -b "$BR"' "$WORK")"
expect_deny "dynamic branch name fails closed" "$out" "GUARD FAILED"

# --- a mine verdict is cached for a short window -----------------------------
set_verdict 113 mine
run_hook 'git checkout -b issue-113-c1' "$WORK" >/dev/null
run_hook 'git checkout -b issue-113-c1' "$WORK" >/dev/null
calls_113="$(grep -c '^113$' "$STUB_CALLS" || true)"
if [ "$calls_113" = "1" ]; then
  pass "mine verdict cached: second call did not re-query the helper"
else
  fail "mine verdict not cached: helper called $calls_113 times"
fi

echo
echo "issue-claim-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
