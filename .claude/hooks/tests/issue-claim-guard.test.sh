#!/usr/bin/env bash
# Tests for .claude/hooks/issue-claim-guard.sh (issue #2287).
#
# The REAL hook runs against stubs placed where its resolver looks
# ($HOME/.claude/scripts): issue-claim.sh and session-state.sh. Verdicts come
# from per-run tables, so one issue can be claimed while a neighbour is not, and
# a verdict can apply to one holder only (the discriminating shape).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/issue-claim-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export TMPDIR="$TMP/cache"
export STUB_CALLS="$TMP/calls.log"
export STUB_VERDICTS="$TMP/verdicts.txt"
export STUB_SESSION="$TMP/session.txt"
export STUB_DETAIL="$TMP/detail.log"
export STUB_EVIDENCE="$TMP/evidence.txt"
export STUB_RECEIPT="$TMP/receipt.txt"
export CLAUDE_CLAIM_HOLDER="guard-test-holder-$$"
unset CLAUDE_SESSION_ID
mkdir -p "$HOME/.claude/scripts" "$TMPDIR"
: > "$STUB_CALLS"
: > "$STUB_VERDICTS"
: > "$STUB_SESSION"
: > "$STUB_DETAIL"
: > "$STUB_EVIDENCE"
: > "$STUB_RECEIPT"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $*" >&2; }

# Stub helper: prints the --check --json object for the issue in $1. A verdict
# line "N VERDICT" applies to every holder; "N VERDICT HOLDER" only to that
# holder. The last matching line wins. Exit codes match the real helper.
cat > "$HOME/.claude/scripts/issue-claim.sh" <<'STUB'
#!/usr/bin/env bash
n=$1
shift
holder=DEFAULT
repo=NONE
while [ $# -gt 0 ]; do
  case "$1" in
    --holder) holder=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$n" >> "$STUB_CALLS"
printf '%s|%s|%s|%s\n' "$n" "$holder" "$repo" "$PWD" >> "$STUB_DETAIL"
verdict=unclaimed
while read -r a b c; do
  [ "$a" = "$n" ] || continue
  if [ -z "$c" ] || [ "$c" = "$holder" ]; then verdict=$b; fi
done < "$STUB_VERDICTS"
case "$verdict" in
  garbage) printf 'not json\n'; exit 0 ;;
  crash) exit 9 ;;
  claimed) rc=1 ;;
  unknown) rc=4 ;;
  *) rc=0 ;;
esac
# STUB_REPO_NULL=1 reports no repo; an evidence line "N JSON" merges extra fields.
rjson='"example-owner/example-repo"'
if [ "$repo" != NONE ]; then rjson="\"$repo\""; fi
if [ "${STUB_REPO_NULL:-}" = 1 ] && [ "$repo" = NONE ]; then rjson=null; fi
ev='{}'
while read -r a b; do
  if [ "$a" = "$n" ]; then ev=$b; fi
done < "$STUB_EVIDENCE"
printf '{"issue":%s,"repo":%s,"verdict":"%s","claimant":"other-login","claimant_holder":"h-other","provider":"codex","device":"studio","label":"nightly run"}\n' "$n" "$rjson" "$verdict" \
  | jq -c --argjson e "$ev" '. + $e'
exit "$rc"
STUB
chmod +x "$HOME/.claude/scripts/issue-claim.sh"

# Stub Form A receipt reader: prints the holder in $STUB_RECEIPT, else exits 4.
cat > "$HOME/.claude/scripts/chip-claim-receipt.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = read ] || exit 4
h=$(cat "$STUB_RECEIPT")
[ -n "$h" ] || exit 4
printf '%s\n' "$h"
STUB
chmod +x "$HOME/.claude/scripts/chip-claim-receipt.sh"

set_evidence() { printf '%s %s\n' "$1" "$2" >> "$STUB_EVIDENCE"; }

# Stub session state: "--repo-key" and "--get <path>" for pipelines[N].claim_holder.
# A line "N VALUE" sets the recorded holder; VALUE __FAIL__ exits 2 (read failed),
# __MISSING__ exits 3 (no state file). Issues with no line read as null.
cat > "$HOME/.claude/scripts/session-state.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --repo-key) printf 'example-owner/example-repo\n'; exit 0 ;;
  --get)
    n=$(printf '%s' "$2" | sed -n 's/.*pipelines\["\([0-9]*\)"\].*/\1/p')
    val=null
    while read -r a b; do
      if [ "$a" = "$n" ]; then val=$b; fi
    done < "$STUB_SESSION"
    case "$val" in
      __FAIL__) exit 2 ;;
      __MISSING__) exit 3 ;;
    esac
    printf '%s\n' "$val"
    exit 0 ;;
esac
exit 2
STUB
chmod +x "$HOME/.claude/scripts/session-state.sh"

set_verdict() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$STUB_VERDICTS"; }
set_session() { printf '%s %s\n' "$1" "$2" >> "$STUB_SESSION"; }

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
    return
  fi
  case "$reason" in
    *"$needle"*) pass "$label: denied with \"$needle\"" ;;
    *) fail "$label: denied but reason lacks \"$needle\": $reason" ;;
  esac
}

expect_not_deny_text() {
  local label="$1" out="$2" needle="$3" reason
  reason="$(reason_of "$out")"
  case "$reason" in
    *"$needle"*) fail "$label: reason wrongly contains \"$needle\": $reason" ;;
    *) pass "$label: reason does not contain \"$needle\"" ;;
  esac
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

# --- non-issue branches and unrelated commands are never checked -------------
calls_before="$(wc -l < "$STUB_CALLS" | tr -d ' ')"
out="$(run_hook 'git worktree add ../feature-x -b feature-x' "$WORK")"
expect_allow "no issue number: worktree add feature-x" "$out"
out="$(run_hook 'git checkout -b feature-x' "$WORK")"
expect_allow "no issue number: checkout -b feature-x" "$out"
out="$(run_hook 'ls -la && git status' "$WORK")"
expect_allow "unrelated command" "$out"
calls_after="$(wc -l < "$STUB_CALLS" | tr -d ' ')"
if [ "$calls_before" = "$calls_after" ]; then
  pass "no-issue and unrelated commands never reach the helper"
else
  fail "no-issue or unrelated command reached the helper"
fi

# --- Graphite finding: bypasses are closed ----------------------------------
set_verdict 5 claimed
out="$(run_hook $'# set up\ngit checkout -b issue-5-x' "$WORK")"
expect_deny "comment line does not swallow the command (claimed issue-5)" "$out" "claimed by another holder"
out="$(run_hook $'git worktree add \\\n ../wt -b issue-5-x' "$WORK")"
expect_deny "backslash-continued worktree add is joined (claimed issue-5)" "$out" "claimed by another holder"
HD=$'python3 - <<\'EOF\'\nprint("don\'t switch the branch")\n# git checkout -b issue-5-x\nEOF'
out="$(run_hook "$HD" "$WORK")"
expect_allow "heredoc body with an apostrophe and issue text is not a command" "$out"
out="$(run_hook $'python3 - <<\'EOF\'\nprint("don\'t switch")\nEOF\ngit checkout -b issue-5-x' "$WORK")"
expect_deny "command after a heredoc is still checked" "$out" "claimed by another holder"

# --- dynamic branch names are not evidence (allowed; see Known limits) -------
out="$(run_hook 'git checkout -b "$BRANCH"' "$WORK")"
expect_allow "dynamic branch name is allowed" "$out"

# --- helper missing blocks after positive evidence, naming the fallback -----
NOHELP_HOME="$TMP/nohelper/home"
NOHELP_REPO="$TMP/nohelper/repo"
mkdir -p "$NOHELP_HOME" "$NOHELP_REPO"
make_repo "$NOHELP_REPO" "main"
out="$(HOME="$NOHELP_HOME" run_hook 'git checkout -b issue-106-q' "$NOHELP_REPO")"
expect_deny "helper missing: GUARD FAILED" "$out" "GUARD FAILED"
expect_deny "helper missing: names issue-claim.sh" "$out" "issue-claim.sh not found"
expect_deny "helper missing: names the plain-gh fallback" "$out" "agent-issue-claims-block.md"

# --- bad or empty input allows (nothing was identified) ---------------------
out="$(printf 'not json' | bash "$HOOK")"
expect_allow "bad hook input is allowed" "$out"

# --- internal faults after positive evidence block with GUARD FAILED --------
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
date +%s > "$OVR/109"
out="$(run_hook 'git checkout -b issue-109-o' "$WORK")"
expect_allow "override: fresh override allows the named issue 109" "$out"
out="$(run_hook 'git checkout -b issue-110-o' "$WORK")"
expect_deny "override: unnamed issue 110 stays blocked" "$out" "claimed by another holder"

# An override expires after the 4-hour window; garbage content never allows.
echo $(( $(date +%s) - 20000 )) > "$OVR/111"
set_verdict 111 claimed
out="$(run_hook 'git checkout -b issue-111-o' "$WORK")"
expect_deny "override: one older than 4 hours no longer allows" "$out" "claimed by another holder"
echo "not-a-time" > "$OVR/115"
set_verdict 115 claimed
out="$(run_hook 'git checkout -b issue-115-o' "$WORK")"
expect_deny "override: non-integer content does not allow" "$out" "claimed by another holder"

# --- absolute-path and wrapped git/gh are recognised ------------------------
set_verdict 42 claimed
out="$(run_hook '/usr/bin/git switch -c issue-42-fix' "$WORK")"
expect_deny "absolute-path /usr/bin/git switch -c issue-42 is checked" "$out" "claimed by another holder"
out="$(run_hook '/opt/homebrew/bin/gh pr create --head issue-42-fix --title t' "$WORK")"
expect_deny "absolute-path /opt/homebrew/bin/gh pr create --head issue-42 is checked" "$out" "claimed by another holder"
out="$(run_hook 'env GIT_TRACE=0 command git checkout -b issue-42-fix' "$WORK")"
expect_deny "env/command prefixes before git are checked" "$out" "claimed by another holder"
set_verdict 125 claimed
out="$(run_hook 'git switch --orphan issue-125-o' "$WORK")"
expect_deny "switch --orphan issue-125 is checked" "$out" "claimed by another holder"
out="$(run_hook 'git switch issue-42-fix' "$WORK")"
expect_allow "plain switch to an existing issue branch is not a creation" "$out"
out="$(run_hook 'echo git checkout -b issue-42-fix' "$WORK")"
expect_allow "git text as an argument is not a git command" "$out"

# --- dynamic --head is allowed, like other dynamic names --------------------
out="$(run_hook 'gh pr create --head "$BRANCH" --title t' "$WORK")"
expect_allow "dynamic gh pr create --head is allowed" "$out"

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

# --- a cd before gh pr create resolves the branch in the cd target ----------
out="$(run_hook 'cd "'"$PR_REPO"'" && gh pr create --title t --body b' "$TMP/pr-feature")"
expect_deny "cd before gh pr create checks the target repo's branch" "$out" "claimed by another holder"

# --- a branch switch before gh pr create checks the switched-to branch -------
out="$(run_hook 'git switch issue-120-s && gh pr create --title t --body b' "$TMP/pr-feature")"
expect_deny "switch then gh pr create checks issue-120" "$out" "verdict: unclaimed"

# --- git -C names the repo a creation runs in --------------------------------
set_verdict 121 claimed
out="$(run_hook 'git -C "'"$PR_REPO"'" worktree add ../wt-121 -b issue-121-c' "$WORK")"
expect_deny "git -C target repo: claimed issue-121 is checked" "$out" "claimed by another holder"

# --- a dynamic cd before an issue branch cannot be resolved: fault ----------
out="$(run_hook 'cd "$DIR" && git worktree add ../wt-122 -b issue-122-d' "$WORK")"
expect_deny "dynamic cd before issue branch fails closed" "$out" "GUARD FAILED"

# --- non-issue creation after a cd is allowed --------------------------------
out="$(run_hook 'cd "'"$PR_REPO"'" && git worktree add ../feature-z -b feature-z' "$WORK")"
expect_allow "cd then non-issue worktree add is allowed" "$out"
out="$(run_hook 'gh pr create -R example-owner/other --title t' "$TMP/pr-feature")"
expect_allow "gh pr create -R on a non-issue branch is allowed" "$out"

# --- --reason takes a value; the issue branch after it is still checked -----
set_verdict 123 claimed
out="$(run_hook 'git worktree add --reason why -b issue-123-r ../wt-123' "$WORK")"
expect_deny "--reason value is skipped; issue-123 still checked" "$out" "claimed by another holder"

# --- long switch options create branches too ---------------------------------
set_verdict 124 claimed
out="$(run_hook 'git switch --create issue-124-l' "$WORK")"
expect_deny "switch --create issue-124 is checked" "$out" "claimed by another holder"

# --- attached option values are checked --------------------------------------
set_verdict 130 claimed
out="$(run_hook 'git switch --create=issue-130-a' "$WORK")"
expect_deny "switch --create=issue-130 is checked" "$out" "claimed by another holder"
set_verdict 131 claimed
out="$(run_hook 'git checkout -bissue-131-b' "$WORK")"
expect_deny "checkout -bissue-131 (attached) is checked" "$out" "claimed by another holder"

# --- holder recorded at claim time (issue #2287 required fix 1) -------------
SESSION_HOLDER="h-session-$$"
set_session 300 "$SESSION_HOLDER"
set_verdict 300 claimed
set_verdict 300 mine "$SESSION_HOLDER"
out="$(unset CLAUDE_CLAIM_HOLDER; run_hook 'git checkout -b issue-300-s' "$WORK")"
expect_allow "(i) env unset, session holds H, helper mine only for H: allowed" "$out"

set_session 301 "$SESSION_HOLDER"
set_verdict 301 claimed
out="$(unset CLAUDE_CLAIM_HOLDER; run_hook 'git checkout -b issue-301-s' "$WORK")"
expect_deny "(ii) session holds H, claimed for every holder: blocked" "$out" "claimed by another holder"

set_verdict 302 claimed
out="$(unset CLAUDE_CLAIM_HOLDER; run_hook 'git checkout -b issue-302-s' "$WORK")"
expect_deny "(iii) no session entry: default holder decides (claimed)" "$out" "claimed by another holder"

set_session 303 __FAIL__
set_verdict 303 claimed
out="$(unset CLAUDE_CLAIM_HOLDER; run_hook 'git checkout -b issue-303-s' "$WORK")"
expect_deny "(iv) session read fails and default says claimed: blocked" "$out" "GUARD FAILED"

set_verdict 304 claimed
out="$(unset CLAUDE_CLAIM_HOLDER; run_hook 'git checkout -b issue-304-s' "$WORK")"
expect_deny "(v) neighbour holder recorded for 300 does not cover 304" "$out" "claimed by another holder"

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

# --- issue #2366: the caller's own holder, wherever it is visible -------------
make_repo "$TMP/pr-200" "issue-200-a"
set_verdict 200 claimed
set_verdict 200 mine "inline-h1"
out="$(run_hook 'CLAUDE_CLAIM_HOLDER=inline-h1 gh pr create --title t' "$TMP/pr-200")"
expect_allow "#2366 literal command-local holder that reads mine allows" "$out"

make_repo "$TMP/pr-201" "issue-201-a"
set_verdict 201 claimed
set_verdict 201 mine "inline-h2"
out="$(run_hook 'env CLAUDE_CLAIM_HOLDER=inline-h2 gh pr create --title t' "$TMP/pr-201")"
expect_allow "#2366 env-prefixed literal holder allows" "$out"

make_repo "$TMP/pr-202" "issue-202-a"
set_verdict 202 claimed
set_verdict 202 mine "inline-h3"
out="$(run_hook 'export CLAUDE_CLAIM_HOLDER=inline-h3 && gh pr create --title t' "$TMP/pr-202")"
expect_allow "#2366 earlier export in the same command allows" "$out"

make_repo "$TMP/pr-203" "issue-203-a"
set_verdict 203 claimed
set_verdict 203 mine '$H'
out="$(run_hook 'CLAUDE_CLAIM_HOLDER="$H" gh pr create --title t' "$TMP/pr-203")"
expect_deny "#2366 a \$VAR holder is never a candidate" "$out" "claimed by another holder"
out="$(run_hook 'CLAUDE_CLAIM_HOLDER=$(cat h) gh pr create --title t' "$TMP/pr-203")"
expect_deny "#2366 a command-substitution holder is never a candidate" "$out" "claimed by another holder"
if grep -q '^203|[$]' "$STUB_DETAIL"; then
  fail "#2366 a dynamic holder reached the helper"
else
  pass "#2366 dynamic holders never reach the helper"
fi

set_verdict 205 claimed
set_verdict 205 mine "guard-test"
out="$(unset CLAUDE_CLAIM_HOLDER; run_hook 'git checkout -b issue-205-p' "$WORK")"
expect_allow "#2366 payload session_id is a candidate when the env id is empty" "$out"

set_verdict 206 claimed
set_verdict 206 mine "chip:fx:1:2:3:4"
printf 'chip:fx:1:2:3:4\n' > "$STUB_RECEIPT"
out="$(run_hook 'git checkout -b issue-206-r' "$WORK")"
expect_allow "#2366 this worktree's Form A receipt holder allows" "$out"
: > "$STUB_RECEIPT"

set_verdict 207 claimed
out="$(run_hook 'gh pr create -R tgt-owner/tgt-repo --head issue-207-x --title t' "$TMP/pr-feature")"
calls_207="$(grep -c '^207|' "$STUB_DETAIL" || true)"
targeted_207="$(grep -c '^207|.*|tgt-owner/tgt-repo|' "$STUB_DETAIL" || true)"
if [ "$calls_207" = 0 ] || [ "$calls_207" != "$targeted_207" ]; then
  fail "#2366 gh pr create -R: a helper call missed --repo tgt-owner/tgt-repo"
else
  pass "#2366 gh pr create -R passes --repo to every helper call"
fi
expect_deny "#2366 -R target named in the message" "$out" "--claim --repo tgt-owner/tgt-repo"
set_verdict 208 unclaimed
out="$(run_hook 'gh -R glob-owner/glob-repo pr create --head issue-208-x' "$TMP/pr-feature")"
expect_deny "#2366 gh -R before pr create is the target" "$out" "--claim --repo glob-owner/glob-repo"
out="$(run_hook 'GH_REPO=env-owner/env-repo gh pr create --head issue-208-x' "$TMP/pr-feature")"
expect_deny "#2366 a GH_REPO prefix is the target" "$out" "--claim --repo env-owner/env-repo"
out="$(run_hook 'export GH_REPO=github.com/exp-owner/exp-repo && gh pr create --head issue-208-x' "$TMP/pr-feature")"
expect_deny "#2366 an exported HOST/OWNER/REPO GH_REPO is the target" "$out" "--claim --repo exp-owner/exp-repo"
out="$(run_hook 'GH_REPO=env-owner/env-repo gh pr create -R flag-owner/flag-repo --head issue-208-x' "$TMP/pr-feature")"
expect_deny "#2366 -R overrides GH_REPO" "$out" "--claim --repo flag-owner/flag-repo"
out="$(run_hook 'gh pr create -R github.com/host-owner/host-repo --head issue-208-x' "$TMP/pr-feature")"
expect_deny "#2366 -R HOST/OWNER/REPO is the target" "$out" "--claim --repo host-owner/host-repo"
set_verdict 216 claimed
out="$(run_hook 'X=$(a $(b)) gh pr create --head issue-216-n --title t' "$TMP/pr-feature")"
expect_deny "#2366 a nested substitution prefix never hides gh" "$out" "claimed by another holder"

set_verdict 209 unclaimed
out="$(STUB_REPO_NULL=1 run_hook 'git checkout -b issue-209-n' "$WORK")"
expect_deny "#2366 null helper repo: unclaimed still blocks" "$out" "verdict: unclaimed"
expect_not_deny_text "#2366 null helper repo never prints --repo -" "$out" "--repo -"

set_verdict 210 mine
run_hook 'gh pr create -R a-owner/a-repo --head issue-210-c' "$TMP/pr-feature" >/dev/null
run_hook 'gh pr create -R b-owner/b-repo --head issue-210-c' "$TMP/pr-feature" >/dev/null
calls_210="$(grep -c '^210$' "$STUB_CALLS" || true)"
if [ "$calls_210" = "2" ]; then
  pass "#2366 positive cache is keyed by repo (two repos, two checks)"
else
  fail "#2366 positive cache collided across repos: $calls_210 helper calls"
fi

# Message classes.
make_repo "$TMP/pr-211" "issue-211-v"
set_verdict 211 claimed
set_verdict 211 mine "h-abc123def456"
set_evidence 211 '{"claimant":"me","claimant_is_viewer":true,"claimant_device_is_local":true,"claimant_checkout":"/wt/a|b","claimant_checkout_holder_form":"digest","claimant_checkout_holder":"h-abc123def456"}'
out="$(run_hook 'gh pr create --title t' "$TMP/pr-211")"
expect_deny "#2366 not visible: classified" "$out" "may not be visible from this checkout"
expect_deny "#2366 not visible: names the claiming checkout" "$out" "/wt/a|b"
expect_deny "#2366 not visible: gives the prefix" "$out" "export CLAUDE_CLAIM_HOLDER='h-abc123def456' && "
expect_deny "#2366 not visible: gives the persistent option" "$out" "pipelines[\"211\"].claim_holder"
expect_deny "#2366 not visible: states the stop condition" "$out" "did not claim from /wt/a|b"
expect_not_deny_text "#2366 not visible: never prints the marker holder" "$out" "h-other"
out="$(run_hook "export CLAUDE_CLAIM_HOLDER='h-abc123def456' && gh pr create --title t" "$TMP/pr-211")"
expect_allow "#2366 not visible: the printed prefix allows" "$out"

set_verdict 212 claimed
set_evidence 212 '{"claimant":"me","claimant_is_viewer":true,"claimant_device_is_local":true}'
out="$(run_hook 'git checkout -b issue-212-h' "$WORK")"
expect_deny "#2366 holder not visible: classified" "$out" "cannot match from this checkout"
expect_deny "#2366 holder not visible: placeholder retry" "$out" "<your captured holder>"
expect_deny "#2366 holder not visible: verification command" "$out" "212 --check --holder '<your captured holder>' --repo example-owner/example-repo"
expect_not_deny_text "#2366 holder not visible: never prints the marker holder" "$out" "h-other"

set_verdict 213 claimed
out="$(run_hook 'CLAUDE_CLAIM_HOLDER=wrong-h git checkout -b issue-213-s' "$WORK")"
expect_deny "#2366 supplied holder mismatch: another-worker text kept" "$out" "claimed by another holder"
expect_deny "#2366 supplied holder mismatch: says so" "$out" "does not match the live claim"

set_verdict 214 unclaimed
out="$(run_hook 'issue-claim.sh 214 --claim && git checkout -b issue-214-c' "$WORK")"
expect_deny "#2366 claim in the same command: separate-command line" "$out" "as a separate command first"
out="$(run_hook 'git checkout -b issue-214-c' "$WORK")"
expect_not_deny_text "#2366 no in-command claim: no separate-command line" "$out" "separate command"

# A stray backtick or $( in quoted text must not swallow the next command.
set_verdict 215 claimed
out="$(run_hook 'git commit -m "it`s" && git checkout -b issue-215-q && echo "`"' "$WORK")"
expect_deny "#2366 stray backticks in quotes never hide a branch" "$out" "claimed by another holder"
out="$(run_hook "git commit -m 'cost \$(5' && git checkout -b issue-215-q && echo 'x)'" "$WORK")"
expect_deny "#2366 stray \$( in quotes never hides a branch" "$out" "claimed by another holder"

echo
echo "issue-claim-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
