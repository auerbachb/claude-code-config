#!/usr/bin/env bash
# admin-merge.test.sh — Offline unit tests for admin-merge.sh (issue #451).
# Stubs `gh` and `merge-gate.sh` so no network / real repo is touched.
# Run from repo root: bash .claude/scripts/tests/admin-merge.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="$REPO_ROOT/.claude/scripts/admin-merge.sh"

TMP="$(mktemp -d)"
cleanup() {
  # Test 31's stall stub spawns a self-limiting sleeper; kill any survivor so a
  # failing process-group kill cannot leak one into the runner.
  pkill -f "$TMP/gitstub/stub-sleeper" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
BIN="$TMP/bin"; mkdir -p "$BIN"
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"
CLONE="$TMP/clone"; mkdir -p "$CLONE"

# admin-merge.sh resolves merge-gate.sh next to itself, so run a copy from $SCRIPTS.
cp "$SRC" "$SCRIPTS/admin-merge.sh"; chmod +x "$SCRIPTS/admin-merge.sh"
SUT="$SCRIPTS/admin-merge.sh"

# lib/bounded-run.sh ships beside the script and supplies the wall-clock bound
# on resolve_repo_path's `git rev-parse --show-toplevel` fallback (issue #1404).
# Copied here so $SCRIPTS looks like a real install; test 30b removes it again
# to pin the refusal that fires when it is genuinely absent.
mkdir -p "$SCRIPTS/lib"
cp "$REPO_ROOT/.claude/scripts/lib/bounded-run.sh" "$SCRIPTS/lib/"

# --- Fake merge-gate.sh: emits JSON; behaviour driven by env vars. ----------
# FAKE_GATE_LOG (issue #1251) — when set, every invocation's raw argv ("$*") is
# appended as a line, so a test can assert --allow-nonauthor actually reached
# THIS call rather than only admin-merge.sh's own separate pr-authorship.sh
# pre-check. FAKE_GATE_AUTHORSHIP_BLOCK=1 simulates merge-gate.sh's OWN
# independent authorship guard: it appends the authorship-blocker string to
# missing[] unless --allow-nonauthor is present in argv — modeling the real
# script's "adds a `missing` entry unless --allow-nonauthor is passed" behavior.
#
# FAKE_GATE_PWD_LOG (issue #1439) — when set, each invocation's cwd is appended.
# merge-gate.sh is cwd-scoped, so this proves the pre-flight SUBPROCESSES were
# scoped to --repo-path too, not just admin-merge.sh's own gh calls.
cat > "$SCRIPTS/merge-gate.sh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_GATE_LOG:-}" ]; then printf '%s\n' "$*" >> "$FAKE_GATE_LOG"; fi
if [ -n "${FAKE_GATE_PWD_LOG:-}" ]; then printf '%s\n' "$PWD" >> "$FAKE_GATE_PWD_LOG"; fi
MISSING="${FAKE_GATE_MISSING:-[]}"
HUMAN="${FAKE_GATE_HUMAN:-[]}"
SAW_ALLOW_NONAUTHOR=0
for a in "$@"; do [ "$a" = "--allow-nonauthor" ] && SAW_ALLOW_NONAUTHOR=1; done
if [ -n "${FAKE_GATE_AUTHORSHIP_BLOCK:-}" ] && [ "$SAW_ALLOW_NONAUTHOR" -eq 0 ]; then
  MISSING="$(printf '%s' "$MISSING" | jq -c '. + ["PR #1 is authored by other (not you, solouser) — automated merge is blocked by the authorship guard (.claude/rules/safety.md); pass --allow-nonauthor only under an explicit per-PR user override"]')"
fi
jq -cn --argjson m "$MISSING" --argjson h "$HUMAN" \
  '{met:false, missing:$m, human_changes_requested:$h}'
exit "${FAKE_GATE_EXIT:-1}"
EOF
chmod +x "$SCRIPTS/merge-gate.sh"

# --- Fake clean-behind-check.sh: exit code IS the safe_to_offer verdict -------
# (0 = safe to offer / clean BEHIND, 1 = not safe). Only consulted when the gate
# lists a BEHIND blocker (issue #631). Emits a realistic subset of the real
# script's JSON so --auto-plain's evidence report can be asserted (issue #754).
#
# FAKE_CBC_EXIT     — exit code for every call (default 1).
# FAKE_CBC_EXIT_SEQ — space-separated per-call exit codes ("0 1" = safe on the
#                     pre-flight call, unsafe on the pre-merge re-validation).
#                     Requires FAKE_CBC_COUNT_FILE to count calls.
# FAKE_CBC_OVERLAP_COUNT / FAKE_CBC_AC_ALL_CHECKED / FAKE_CBC_RESIDUAL /
# FAKE_CBC_REASONS / FAKE_CBC_MERGE_STATE / FAKE_CBC_MERGEABLE control the
# mechanical evidence emitted for each call.
# FAKE_CBC_LOG (issue #1257) — when set, every invocation's raw argv ("$*") is
#   appended as a line, so a test can assert --allow-nonauthor actually reached
#   this helper via CBC_ARGS.
# FAKE_CBC_AUTHORSHIP_BLOCK (issue #1257) — when 1, models the real helper's
#   NESTED merge-gate.sh authorship check: without --allow-nonauthor in argv the
#   non-author blocker lands in residual_blockers and the verdict is exit 1
#   (which fails clean_behind_evidence_allows_admin's reviewDecision-only match,
#   so CLEAN_BEHIND_OK stays false); with the flag it is suppressed → exit 0.
cat > "$SCRIPTS/clean-behind-check.sh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_CBC_LOG:-}" ]; then printf '%s\n' "$*" >> "$FAKE_CBC_LOG"; fi
N=1
if [ -n "${FAKE_CBC_COUNT_FILE:-}" ]; then
  N=$(cat "$FAKE_CBC_COUNT_FILE" 2>/dev/null || echo 0)
  N=$((N + 1))
  echo "$N" > "$FAKE_CBC_COUNT_FILE"
fi
RC="${FAKE_CBC_EXIT:-1}"
if [ -n "${FAKE_CBC_EXIT_SEQ:-}" ]; then
  I=0
  for code in $FAKE_CBC_EXIT_SEQ; do
    I=$((I + 1))
    if [ "$I" -eq "$N" ]; then RC="$code"; fi
  done
fi
RESIDUAL="${FAKE_CBC_RESIDUAL:-[]}"
if [ "${FAKE_CBC_AUTHORSHIP_BLOCK:-0}" = "1" ]; then
  SAW_ALLOW_NONAUTHOR=0
  for a in "$@"; do
    if [ "$a" = "--allow-nonauthor" ]; then SAW_ALLOW_NONAUTHOR=1; fi
  done
  if [ "$SAW_ALLOW_NONAUTHOR" -eq 0 ]; then
    RC=1
    RESIDUAL='["PR #1 is authored by other (not you, solouser) — automated merge is blocked by the authorship guard (.claude/rules/safety.md); pass --allow-nonauthor only under an explicit per-PR user override"]'
    FAKE_CBC_REASONS='["merge gate blocker: PR #1 is authored by other (not you, solouser) — automated merge is blocked by the authorship guard (.claude/rules/safety.md)"]'
  else
    RC=0
  fi
fi
OVERLAP="${FAKE_CBC_OVERLAP_COUNT:-}"
if [ -z "$OVERLAP" ]; then
  if [ "$RC" -eq 0 ]; then OVERLAP=0; else OVERLAP=1; fi
fi
REASONS="${FAKE_CBC_REASONS:-}"
if [ -z "$REASONS" ]; then
  if [ "$RC" -eq 0 ]; then REASONS='[]'; else REASONS='["base delta overlaps PR files (dirty.txt)"]'; fi
fi
jq -cn \
  --argjson rc "$RC" \
  --arg merge_state "${FAKE_CBC_MERGE_STATE:-BEHIND}" \
  --arg mergeable "${FAKE_CBC_MERGEABLE:-MERGEABLE}" \
  --argjson overlap "$OVERLAP" \
  --argjson ac_all_checked "${FAKE_CBC_AC_ALL_CHECKED:-true}" \
  --argjson residual "$RESIDUAL" \
  --argjson reasons "$REASONS" '{
  safe_to_offer: ($rc == 0), head_sha: "abc1234def",
  reasons_not_safe: $reasons,
  merge_state: $merge_state,
  mergeable: $mergeable,
  residual_blockers: $residual,
  ac: {checked: (if $ac_all_checked then 6 else 5 end), total: 6, all_checked: $ac_all_checked},
  file_overlap: {count: $overlap, granularity: "hunk"},
  churn: {base_ahead_by: 2}
}'
exit "$RC"
EOF
chmod +x "$SCRIPTS/clean-behind-check.sh"

# --- Fake pr-authorship.sh: exit code IS the authorship verdict (issue #733) --
# 0 = mine (default → guard passes), non-zero = not_mine/unknown → admin-merge
# refuses. Faked here so the admin-merge authorship guard is exercised without a
# real gh author lookup (pr-authorship.sh has its own dedicated test).
cat > "$SCRIPTS/pr-authorship.sh" <<'EOF'
#!/usr/bin/env bash
echo "${FAKE_AUTHORSHIP_MSG:-mine}"
exit "${FAKE_AUTHORSHIP_EXIT:-0}"
EOF
chmod +x "$SCRIPTS/pr-authorship.sh"

# --- Fake gh (safe defaults: no brace-heavy ${VAR:-...} expansions) ----------
# Every invocation is appended to $FAKE_GH_LOG when set, so tests can assert on
# the calls actually ISSUED (e.g. "no protection API call") rather than only on
# printed output (issue #754).
#
# GH_FAKE_REPO_BY_CWD (issue #1439) — when 1, repo identity is resolved from the
# fake's OWN cwd via a `.fake-repo-slug` marker file, the way real gh infers
# owner/repo from the cwd's git remote, and `gh pr view` only finds the PR in the
# repo that holds it. That makes a cwd-scoped call OBSERVABLE: without it the
# fake answers "solo/repo" from anywhere, so a cross-cwd test would pass whether
# or not --repo-path was honoured. Off by default so every other test is
# unaffected.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
if [ -n "${FAKE_GH_LOG:-}" ]; then printf '%s\n' "$ARGS" >> "$FAKE_GH_LOG"; fi
if [ "${GH_FAKE_REPO_BY_CWD:-0}" = "1" ]; then
  CWD_SLUG=""
  if [ -f "$PWD/.fake-repo-slug" ]; then CWD_SLUG=$(cat "$PWD/.fake-repo-slug"); fi
  case "$ARGS" in
    "repo view --json nameWithOwner --jq .nameWithOwner")
      if [ -z "$CWD_SLUG" ]; then
        echo "fake gh: not a git repository (cwd=$PWD)" >&2; exit 1
      fi
      echo "$CWD_SLUG"; exit 0 ;;
    "pr view "*baseRefName*)
      # The PR lives in ONE repo. Anywhere else, fail the way real gh does.
      if [ "$CWD_SLUG" != "${GH_FAKE_PR_HOME:-solo/repo}" ]; then
        echo "fake gh: no pull request found (cwd=$PWD, repo=${CWD_SLUG:-none})" >&2
        exit 1
      fi ;;
  esac
fi
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "${FAKE_OWNER_REPO:-solo/repo}"; exit 0 ;;
  "pr merge "*)
    exit "${FAKE_MERGE_EXIT:-0}" ;;
  "pr view "*baseRefName*)
    if [ -n "${FAKE_PR_JSON:-}" ]; then echo "$FAKE_PR_JSON"
    else echo '{"number":1,"state":"OPEN","baseRefName":"main","headRefName":"feat"}'; fi
    exit 0 ;;
  "pr view "*"--json state"*)
    echo "${FAKE_MERGED_STATE:-true}"; exit 0 ;;
  "api user --jq .login")
    echo "${FAKE_USER:-solouser}"; exit 0 ;;
  api*collaborators*)
    for u in ${FAKE_ADMINS:-solouser}; do echo "$u"; done; exit 0 ;;
  *contents/*)
    CO="${FAKE_CODEOWNERS:-* @solouser @coderabbitai}"
    CONTENT_B64=$(printf '%s' "$CO" | base64 | tr -d '\n')
    jq -cn --arg c "$CONTENT_B64" '{content:$c}'; exit 0 ;;
  *branches/*/protection)
    if [ -n "${FAKE_PROTECTION:-}" ]; then echo "$FAKE_PROTECTION"
    else echo '{"enforce_admins":{"enabled":true}}'; fi
    exit 0 ;;
  *) echo "{}"; exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"

PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

run() { OUT="$("$SUT" "$@" 2>&1)"; RC=$?; }

expect_rc() {  # expect_rc <want> <desc>
  if [[ "$RC" -eq "$1" ]]; then ok "$2"; else bad "$2 (got rc=$RC: $OUT)"; fi
}
grep_ok() {    # grep_ok <pattern> <desc>
  if printf '%s\n' "$OUT" | grep -q "$1"; then ok "$2"; else bad "$2 (output: $OUT)"; fi
}
grep_absent() {  # grep_absent <pattern> <desc>
  if printf '%s\n' "$OUT" | grep -q "$1"; then bad "$2 (output: $OUT)"; else ok "$2"; fi
}

# --- gh call-log helpers (issue #754) ---------------------------------------
# Assert on the gh calls actually ISSUED, not just on printed output — the
# difference is the whole point of "the toggle command is printed, never run".
LOG_N=0
new_log() { LOG_N=$((LOG_N + 1)); export FAKE_GH_LOG="$TMP/ghcalls.$LOG_N"; : > "$FAKE_GH_LOG"; }
log_calls() { tr '\n' '|' < "$FAKE_GH_LOG" 2>/dev/null; }
log_present() {  # log_present <ere> <desc>
  if grep -qE -- "$1" "$FAKE_GH_LOG" 2>/dev/null; then ok "$2"; else bad "$2 (calls: $(log_calls))"; fi
}
log_absent() {   # log_absent <ere> <desc>
  if grep -qE -- "$1" "$FAKE_GH_LOG" 2>/dev/null; then bad "$2 (calls: $(log_calls))"; else ok "$2"; fi
}

# --- clean-behind-check.sh argv helper (issue #1257, CodeAnt review) ---------
# A forwarded override must reach EVERY clean-behind-check.sh invocation, not
# only the pre-flight one: admin-merge.sh re-runs the helper immediately before
# it acts (issue #631 TOCTOU re-validation), and an override that stopped
# propagating at that second call would re-acquire the nested authorship blocker
# and resurrect issue #1257's misleading "not safe to skip a rebase" at the worst
# possible moment. An aggregate `grep -q` over the log cannot see that — any one
# matching call satisfies it — so assert each invocation's argv separately, and
# pin the call COUNT so a silently-skipped re-validation cannot pass by vacuum.
cbc_argv_all() {  # cbc_argv_all <logfile> <want_calls> <flag> <desc>
  local log="$1" want="$2" flag="$3" desc="$4" n miss
  n=$(grep -c . "$log" 2>/dev/null); [[ -n "$n" ]] || n=0
  if [[ "$n" -ne "$want" ]]; then
    bad "$desc (expected $want clean-behind-check.sh call(s), got $n: $(tr '\n' '|' < "$log" 2>/dev/null))"
    return 0
  fi
  miss=$(grep -cv -- "$flag" "$log" 2>/dev/null); [[ -n "$miss" ]] || miss=0
  if [[ "$miss" -ne 0 ]]; then
    bad "$desc ($miss of $n invocation(s) missing $flag: $(tr '\n' '|' < "$log" 2>/dev/null))"
  else
    ok "$desc"
  fi
}

# 1. Happy path: solo + enforce_admins + clean gate → print exact command.
FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' run 1 --print --repo-path "$CLONE" --branch main
expect_rc 0 "print exits 0 on merge-ready solo repo"
grep_ok "cd $CLONE && \\\\" "command has cd-prefix"
grep_ok "gh api -X DELETE repos/solo/repo/branches/main/protection/enforce_admins" "DELETE enforce_admins present"
grep_ok "gh pr merge 1 --squash --admin" "merge --admin present"
POST_LINE=$(printf '%s\n' "$OUT" | grep "gh api -X POST repos/solo/repo/branches/main/protection/enforce_admins")
if [[ -n "$POST_LINE" ]]; then ok "re-enable POST present"; else bad "missing POST: $OUT"; fi
if printf '%s\n' "$POST_LINE" | grep -qiE -- '-f |--field|enabled='; then
  bad "POST must have NO body (found a field flag): $POST_LINE"
else
  ok "POST sent with no body (no -f/--field/enabled=)"
fi

# 2. Hard blocker (unresolved thread) → refuse, exit 1, no bypass printed.
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING='["1 unresolved review thread(s) — resolve via GraphQL before merge"]' \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 1 "refuses on hard blocker (exit 1)"
grep_absent "X DELETE" "no bypass printed on hard blocker"

# 3. Only a code-owner reviewDecision blocker → bypassable, still prints.
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING='["branch protection reviewDecision is REVIEW_REQUIRED, not APPROVED, with CodeRabbit in CODEOWNERS — if the prior CR approval was dismissed as stale, trigger @coderabbitai full review"]' \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 0 "reviewDecision-only blocker is bypassable (exit 0)"

# 4. Human change request → refuse even if everything else clean.
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING='[]' FAKE_GATE_HUMAN='["alice"]' \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 1 "refuses on human CHANGES_REQUESTED (exit 1)"

# 5. Not solo-owned (two human admins) → refuse, exit 5.
FAKE_GATE_EXIT=0 FAKE_ADMINS="solouser otheruser" \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 5 "refuses non-solo repo (exit 5)"

# 6. --force-solo bypasses the solo heuristic.
FAKE_GATE_EXIT=0 FAKE_ADMINS="solouser otheruser" \
  run 1 --print --force-solo --repo-path "$CLONE" --branch main
expect_rc 0 "--force-solo overrides solo heuristic (exit 0)"

# 7. enforce_admins not enabled → refuse, exit 6.
FAKE_GATE_EXIT=0 FAKE_PROTECTION='{"enforce_admins":{"enabled":false}}' \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 6 "refuses when enforce_admins off (exit 6)"

# 8. --launch-terminal on non-macOS falls back to inline print (exit 0).
if [[ "$(uname)" != "Darwin" ]]; then
  FAKE_GATE_EXIT=0 run 1 --launch-terminal --repo-path "$CLONE" --branch main
  expect_rc 0 "launch-terminal falls back on non-macOS (exit 0)"
  grep_ok "macOS-only" "launch-terminal prints macOS-only note"
fi

# 9. Static: execute mode has a trap that re-enables protection.
if grep -q "trap reenable_protection EXIT" "$SRC"; then ok "execute mode installs re-enable trap"; else bad "missing trap in execute mode"; fi

# 9b. Static (issue #1439): the process enters $REPO_PATH BEFORE the first
# repo-identity call, so `gh` — and every cwd-scoped helper — resolves the
# --repo-path target instead of the invoker's cwd. This supersedes the old
# per-branch cd in --execute/--auto-plain (a BugBot finding that only covered the
# two executing modes): one early cd now covers all four, and the ORDER relative
# to `gh repo view` is the property that actually fixes the cross-repo bug.
if awk '/^if ! cd "\$REPO_PATH"/{cd_seen=1}
        /OWNER_REPO=\$\(gh repo view/{if (cd_seen) good=1; exit}
        END{exit !good}' "$SRC"; then
  ok "the early cd into \$REPO_PATH precedes the cwd-based owner/repo resolution"
else
  bad "repo identity is resolved before the process enters \$REPO_PATH (issue #1439 regression)"
fi

# 9c. Static: execute mode revalidates a clean-BEHIND bypass BEFORE disabling
#     protection (issue #631) — the CLEAN_BEHIND_OK re-check must precede ENFORCE_DISABLED=0.
if awk '/MODE" == "execute"/{f=1} f && /CLEAN_BEHIND_OK" == true/{seen=1} f && seen && /ENFORCE_DISABLED=0/{good=1; exit} END{exit !good}' "$SRC"; then
  ok "execute mode revalidates clean-BEHIND before disabling protection"
else
  bad "execute mode does not revalidate clean-BEHIND before the dance"
fi

# 10. Mutually exclusive modes.
run 1 --print --execute --repo-path "$CLONE" --branch main
expect_rc 2 "mutually exclusive modes rejected (exit 2)"

# 11. Clean BEHIND (issue #631): BEHIND is the only blocker AND clean-behind-check
#     reports safe → bypassable, prints the command.
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=0 \
  FAKE_GATE_MISSING='["branch is BEHIND base — rebase + force-push before merging"]' \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 0 "clean BEHIND (clean-behind-check safe) is bypassable (exit 0)"
grep_ok "gh pr merge 1 --squash --admin" "clean BEHIND still prints the admin merge command"

# 12. Non-clean BEHIND: BEHIND blocker but clean-behind-check reports NOT safe
#     (e.g. base delta touches the PR's files) → stays a hard blocker, refuse.
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=1 \
  FAKE_GATE_MISSING='["branch is BEHIND base — rebase + force-push before merging"]' \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 1 "non-clean BEHIND stays a hard blocker (exit 1)"
grep_absent "gh pr merge 1 --squash --admin" "no admin-merge command printed for non-clean BEHIND"

# 13. Plain shape: enforce_admins=false + strict=true + clean-BEHIND → exit 0,
#     prints plain --admin merge command exactly once, no protection toggle calls.
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=0 \
  FAKE_GATE_MISSING='["branch is BEHIND base — rebase + force-push before merging"]' \
  FAKE_PROTECTION='{"enforce_admins":{"enabled":false},"required_status_checks":{"strict":true}}' \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 0 "plain shape: enforce_admins=false + strict=true + clean-BEHIND exits 0"
grep_ok "gh pr merge 1 --squash --admin" "plain shape: plain --admin merge command printed"
grep_absent "protection/enforce_admins" "plain shape: no protection toggle calls in output"
PLAIN_COUNT=$(printf '%s\n' "$OUT" | grep -c "gh pr merge 1 --squash --admin" 2>/dev/null || echo 0)
if [[ "$PLAIN_COUNT" -eq 1 ]]; then ok "plain shape: merge command appears exactly once"; else bad "plain shape: merge command should appear exactly once (found $PLAIN_COUNT: $OUT)"; fi

# 14. Gate-not-met (non-BEHIND hard blocker) with enforce_admins=false → exit 1;
#     gate short-circuits before the protection check, no bypass or protection call printed.
FAKE_GATE_EXIT=1 \
  FAKE_GATE_MISSING='["1 unresolved review thread(s) — resolve via GraphQL before merge"]' \
  FAKE_PROTECTION='{"enforce_admins":{"enabled":false}}' \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 1 "gate-not-met (non-BEHIND) with enforce_admins=false still refuses (exit 1)"
grep_absent "gh pr merge" "no merge command when gate not met with enforce_admins=false"
grep_absent "protection/enforce_admins" "no protection API call when gate not met with enforce_admins=false"

# 15. Regression: enforce_admins=true path unchanged — toggle chain still printed.
FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' \
  FAKE_PROTECTION='{"enforce_admins":{"enabled":true}}' \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 0 "enforce_admins=true toggle path unchanged (regression, exit 0)"
grep_ok "gh api -X DELETE repos/solo/repo/branches/main/protection/enforce_admins" "enforce_admins=true: DELETE toggle call still present"
grep_ok "gh api -X POST repos/solo/repo/branches/main/protection/enforce_admins" "enforce_admins=true: POST re-enable call still present"

# 16. Authorship guard (issue #733): non-author PR → refuse, exit 1, no bypass.
#     The refusal fires before the merge-readiness pre-flight even with a clean gate.
FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' FAKE_AUTHORSHIP_EXIT=1 FAKE_AUTHORSHIP_MSG='not_mine' \
  run 1 --print --repo-path "$CLONE" --branch main
expect_rc 1 "authorship guard refuses a non-author PR (exit 1)"
grep_ok "authorship guard" "refusal names the authorship guard"
grep_absent "gh pr merge" "no merge command printed for a non-author PR"
grep_absent "protection/enforce_admins" "no protection API call for a non-author PR"

# 17. --allow-nonauthor overrides the authorship guard (explicit user override).
FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' FAKE_AUTHORSHIP_EXIT=1 \
  FAKE_PROTECTION='{"enforce_admins":{"enabled":true}}' \
  run 1 --print --allow-nonauthor --repo-path "$CLONE" --branch main
expect_rc 0 "--allow-nonauthor overrides the authorship guard (exit 0)"
grep_ok "gh pr merge 1 --squash --admin" "override lets the bypass command print"

# ============================================================================
# --auto-plain: the Claude-invocable executor for the PLAIN shape (issue #754).
# Distinct PR numbers per case so the per-PR repeat guard does not cross-talk
# (test 19 deliberately reuses PR 1 to exercise it).
# ============================================================================
PLAIN_PROT='{"enforce_admins":{"enabled":false},"required_status_checks":{"strict":true}}'
BEHIND_ONLY='["branch is BEHIND base — rebase + force-push before merging"]'

# 18. Plain shape → merges, issues no protection call, prints the evidence report.
new_log
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=0 FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 1 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 0 "--auto-plain merges the plain shape (exit 0)"
log_present "^pr merge 1 --squash --admin" "auto-plain issued the admin squash-merge"
log_absent "protection/enforce_admins" "auto-plain issued NO protection API call"
grep_ok "AUTO_PLAIN_MERGED: PR #1" "auto-plain reports the merged PR after the fact"
grep_ok "shape:      plain" "evidence report names the shape"
grep_ok "head SHA:   abc1234def" "evidence report carries the head SHA"
grep_ok "base ahead by:  2 commit" "evidence report carries base_ahead_by from the re-validation"
grep_ok "file overlap:   0 (hunk granularity)" "evidence report carries the hunk-level overlap count"
grep_ok "AC checkboxes:  6/6" "evidence report carries the AC counts"
grep_ok "solo-owner verified" "evidence report carries the solo-owner note"

# 19. Repeat guard: a second --auto-plain on the SAME PR refuses and prints.
new_log
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=0 FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 1 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 8 "--auto-plain refuses a second attempt on the same PR (exit 8)"
grep_ok "AUTO_PLAIN_REFUSED: reason=repeat" "repeat refusal names the repeat guard"
log_absent "^pr merge" "repeat refusal issues no merge call"
grep_ok "gh pr merge 1 --squash --admin" "repeat refusal falls back to printing the command"

# 20. HARD SHAPE GATE: toggle shape → refuse, print only, zero protection calls.
new_log
FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' FAKE_PROTECTION='{"enforce_admins":{"enabled":true}}' \
  run 4 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 8 "--auto-plain refuses the toggle shape (exit 8)"
grep_ok "AUTO_PLAIN_REFUSED: shape=toggle" "toggle refusal names the diagnosed shape"
log_absent "-X DELETE" "toggle refusal issued NO protection DELETE call"
log_absent "-X POST" "toggle refusal issued NO protection POST call"
log_absent "^pr merge" "toggle refusal issued no merge call"
grep_ok "gh api -X DELETE repos/solo/repo/branches/main/protection/enforce_admins" "toggle refusal still PRINTS the command for the user"

# 21. Non-clean BEHIND (clean-behind-check exit 1) → refuse, route to rebase.
new_log
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=1 FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 3 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 1 "--auto-plain refuses a non-clean BEHIND (exit 1)"
grep_ok "not safe to skip a rebase" "non-clean BEHIND gets the distinct unsafe-to-skip refusal"
grep_ok "base delta overlaps PR files" "non-clean BEHIND refusal surfaces clean-behind reasons"
log_absent "^pr merge" "non-clean BEHIND: no merge call issued"
log_absent "protection/enforce_admins" "non-clean BEHIND: no protection API call issued"

# 21b. CBC can exit 1 solely because its bundled gate keeps the branch-protection
#      reviewDecision residual. Safe mechanical evidence still reaches the merge.
new_log
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=1 FAKE_CBC_OVERLAP_COUNT=0 \
  FAKE_CBC_RESIDUAL='["branch protection reviewDecision is REVIEW_REQUIRED, not APPROVED, with CodeRabbit in CODEOWNERS — if the prior CR approval was dismissed as stale, trigger @coderabbitai full review"]' \
  FAKE_CBC_REASONS='["merge gate blocker: branch protection reviewDecision is REVIEW_REQUIRED, not APPROVED, with CodeRabbit in CODEOWNERS"]' \
  FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 9 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 0 "--auto-plain accepts safe mechanics when CBC only retains reviewDecision (exit 0)"
log_present "^pr merge 9 --squash --admin" "reviewDecision-only CBC asymmetry reaches the merge call"
log_absent "protection/enforce_admins" "reviewDecision-only CBC asymmetry issues no protection call"

# 21c. A real non-BEHIND blocker wins over the special dirty-BEHIND refusal.
new_log
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=1 \
  FAKE_GATE_MISSING='["branch is BEHIND base — rebase + force-push before merging","CI incomplete: rule-lint"]' \
  FAKE_PROTECTION="$PLAIN_PROT" \
  run 10 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 1 "--auto-plain refuses dirty BEHIND plus CI blocker (exit 1)"
grep_ok "not merge-ready apart from branch protection" "non-BEHIND blockers retain the generic refusal"
grep_ok "CI incomplete" "generic refusal surfaces the non-BEHIND blocker"
log_absent "^pr merge" "dirty BEHIND plus CI blocker issues no merge call"

# 21d. A residual that merely contains the magic words is not the canonical
#      branch-protection blocker and must not be bypassed.
new_log
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=1 FAKE_CBC_OVERLAP_COUNT=0 \
  FAKE_CBC_RESIDUAL='["CI failed while reporting branch protection reviewDecision"]' \
  FAKE_CBC_REASONS='["merge gate blocker: CI failed"]' \
  FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 11 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 1 "--auto-plain refuses a non-canonical reviewDecision residual (exit 1)"
grep_ok "not safe to skip a rebase" "non-canonical reviewDecision residual uses the safe refusal"
log_absent "^pr merge" "non-canonical reviewDecision residual issues no merge call"

# 22. TOCTOU: clean-behind-check safe at pre-flight, UNSAFE at merge time (main
#     advanced in between) → refuse, no merge. Proves the re-validation is real.
new_log
CBC_COUNT="$TMP/cbc.count"; rm -f "$CBC_COUNT"
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT_SEQ="0 1" FAKE_CBC_COUNT_FILE="$CBC_COUNT" \
  FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 2 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 1 "--auto-plain catches a base that moved between pre-flight and merge (exit 1)"
grep_ok "clean-BEHIND state no longer holds" "TOCTOU refusal names the stale clean-BEHIND state"
log_absent "^pr merge" "TOCTOU refusal issues no merge call"
CBC_CALLS=$(cat "$CBC_COUNT" 2>/dev/null || echo 0)
if [[ "$CBC_CALLS" -eq 2 ]]; then
  ok "clean-behind-check.sh genuinely runs twice (pre-flight + pre-merge re-validation)"
else
  bad "expected 2 clean-behind-check.sh calls, got $CBC_CALLS"
fi

# 23. Authorship guard (issue #733) still refuses under the new auto path.
new_log
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=0 FAKE_AUTHORSHIP_EXIT=1 FAKE_AUTHORSHIP_MSG='not_mine' \
  FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 5 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 1 "authorship guard refuses --auto-plain on a non-author PR (exit 1)"
grep_ok "authorship guard" "auto-plain refusal names the authorship guard"
log_absent "^pr merge" "no merge call for a non-author PR under --auto-plain"
log_absent "protection/enforce_admins" "no protection API call for a non-author PR under --auto-plain"

# 23b. AC gate: --auto-plain without --ac-verified refuses and prints. The ticked-
#      checkbox proxy in clean-behind-check.sh is not per-criterion verification,
#      and an unattended merge must not rest on it (BugBot high-severity finding).
new_log
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=0 FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 7 --auto-plain --repo-path "$CLONE" --branch main
expect_rc 8 "--auto-plain without --ac-verified refuses (exit 8)"
grep_ok "AUTO_PLAIN_REFUSED: reason=ac-unverified" "AC refusal names the missing attestation"
grep_ok "Step 2" "AC refusal points at cr-merge-gate.md Step 2"
log_absent "^pr merge" "AC refusal issues no merge call"
log_absent "protection/enforce_admins" "AC refusal issues no protection API call"
grep_ok "gh pr merge 7 --squash --admin" "AC refusal falls back to printing the command"

# 23c. Repeat guard must FAIL CLOSED: when the marker cannot be written, refuse
#      rather than merge with the retry guard silently disarmed (BugBot finding).
#      $HOME/.claude/admin-merge-auto is a regular file here, so mkdir -p fails.
new_log
RO_HOME="$TMP/home-noguard"; mkdir -p "$RO_HOME/.claude"; : > "$RO_HOME/.claude/admin-merge-auto"
HOME="$RO_HOME" FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=0 FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 8 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 8 "--auto-plain refuses when the repeat-guard marker is unwritable (exit 8)"
grep_ok "AUTO_PLAIN_REFUSED: reason=guard-unwritable" "unwritable-guard refusal names the cause"
log_absent "^pr merge" "unwritable guard: no merge issued (fails closed, never unguarded)"

# 24. Modes stay mutually exclusive.
run 6 --auto-plain --execute --repo-path "$CLONE" --branch main
expect_rc 2 "--auto-plain and --execute are mutually exclusive (exit 2)"

# 25. Static: the auto-plain branch contains NO protection-modifying call. This
#     is the structural guarantee — Claude cannot reach the toggle through it.
AUTO_BLOCK=$(awk '/^if \[\[ "\$MODE" == "auto-plain" \]\]; then/{f=1} f{print} f && /^fi$/{exit}' "$SRC")
if [[ -z "$AUTO_BLOCK" ]]; then
  bad "could not extract the auto-plain branch for static analysis"
elif printf '%s\n' "$AUTO_BLOCK" | grep -qE '\$(DELETE_CALL|REENABLE_CALL)|-X (DELETE|POST)'; then
  bad "auto-plain branch contains a protection-modifying call"
else
  ok "auto-plain branch contains no protection-modifying call (static)"
fi

# 26. Static: the shape gate precedes the merge call inside the auto-plain branch.
if awk '/MODE" == "auto-plain"/{f=1} f && /BYPASS_MODE" != "plain"/{seen=1} f && seen && /MERGE_CALL/{good=1; exit} END{exit !good}' "$SRC"; then
  ok "auto-plain: the hard shape gate precedes the merge call"
else
  bad "auto-plain: shape gate does not precede the merge call"
fi

# ============================================================================
# Regression (issue #1251): --allow-nonauthor was parsed and cleared this
# script's OWN authorship pre-check, but was never forwarded to merge-gate.sh
# — which runs its own INDEPENDENT authorship check and re-added the blocker,
# making the documented override unreachable. FAKE_GATE_AUTHORSHIP_BLOCK
# simulates that independent check; FAKE_GATE_LOG proves the flag's presence
# (or absence) in the actual merge-gate.sh invocation, not just in the printed
# output.
# ============================================================================

# 27. --allow-nonauthor reaches merge-gate.sh's own authorship check (--print).
new_log
GATE_LOG="$TMP/gatecalls.log"; : > "$GATE_LOG"
FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' FAKE_GATE_AUTHORSHIP_BLOCK=1 FAKE_GATE_LOG="$GATE_LOG" \
  FAKE_PROTECTION='{"enforce_admins":{"enabled":true}}' \
  run 12 --print --allow-nonauthor --repo-path "$CLONE" --branch main
expect_rc 0 "--allow-nonauthor forwarded to merge-gate.sh unblocks its own authorship check (exit 0)"
grep_ok "gh pr merge 12 --squash --admin" "bypass command still printed with the forwarded override"
if grep -q -- "--allow-nonauthor" "$GATE_LOG"; then
  ok "--allow-nonauthor literally appears in the merge-gate.sh invocation (--print)"
else
  bad "--allow-nonauthor was NOT forwarded to merge-gate.sh (logged calls: $(cat "$GATE_LOG"))"
fi

# 27b. Sanity companion: without the flag, the simulated merge-gate.sh authorship
#      block still fires — proves the fixture models the real bug, not a tautology.
new_log
GATE_LOG2="$TMP/gatecalls2.log"; : > "$GATE_LOG2"
FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' FAKE_GATE_AUTHORSHIP_BLOCK=1 FAKE_GATE_LOG="$GATE_LOG2" \
  FAKE_PROTECTION='{"enforce_admins":{"enabled":true}}' \
  run 14 --print --repo-path "$CLONE" --branch main
expect_rc 1 "without --allow-nonauthor, merge-gate.sh's own authorship block still refuses (exit 1)"
grep_ok "authored by other" "refusal surfaces merge-gate.sh's own authorship blocker text"
if grep -q -- "--allow-nonauthor" "$GATE_LOG2"; then
  bad "--allow-nonauthor unexpectedly present when the flag was not passed (logged calls: $(cat "$GATE_LOG2"))"
else
  ok "no --allow-nonauthor forwarded when the flag was not passed"
fi

# ============================================================================
# Regression (issue #1251 review round — CodeAnt): --auto-plain runs UNATTENDED
# (no human confirms the merge), so combining it with --allow-nonauthor is a
# hard usage error, refused before ANY pre-flight work — not merely a gate
# outcome that happens to fail. Verified by asserting zero gh calls and zero
# merge-gate.sh calls, not just the exit code.
# ============================================================================

# 27c. --auto-plain + --allow-nonauthor is refused immediately (exit 2), no
#      gh calls and no merge-gate.sh call at all — even on an otherwise
#      merge-ready, clean-BEHIND PR.
new_log
GATE_LOG3="$TMP/gatecalls3.log"; : > "$GATE_LOG3"
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=0 FAKE_GATE_AUTHORSHIP_BLOCK=1 FAKE_GATE_LOG="$GATE_LOG3" \
  FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 15 --auto-plain --ac-verified --allow-nonauthor --repo-path "$CLONE" --branch main
expect_rc 2 "--auto-plain + --allow-nonauthor is a hard usage error (exit 2)"
grep_ok "does not accept --allow-nonauthor" "refusal names the specific disallowed combination"
grep_ok "UNATTENDED" "refusal explains why (auto-plain runs unattended)"
grep_ok "Use --print" "refusal points at --print as the alternative"
log_absent "." "no gh call of any kind before this refusal fires"
if [[ -s "$GATE_LOG3" ]]; then
  bad "merge-gate.sh was invoked despite the auto-plain + --allow-nonauthor refusal (logged calls: $(cat "$GATE_LOG3"))"
else
  ok "merge-gate.sh was never invoked — refusal fires before any pre-flight work"
fi

# 27d. Sanity companion: --auto-plain WITHOUT --allow-nonauthor is unaffected —
#      the new hard refusal is scoped to the flag combination, not the mode.
new_log
GATE_LOG4="$TMP/gatecalls4.log"; : > "$GATE_LOG4"
FAKE_GATE_EXIT=1 FAKE_CBC_EXIT=0 FAKE_GATE_LOG="$GATE_LOG4" \
  FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_PROTECTION="$PLAIN_PROT" \
  run 16 --auto-plain --ac-verified --repo-path "$CLONE" --branch main
expect_rc 0 "--auto-plain without --allow-nonauthor still merges normally (exit 0)"

# 27e. Sanity companion: --print + --allow-nonauthor is unaffected — the
#      override still works for the modes that keep a human in the loop.
new_log
GATE_LOG5="$TMP/gatecalls5.log"; : > "$GATE_LOG5"
FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' FAKE_GATE_AUTHORSHIP_BLOCK=1 FAKE_GATE_LOG="$GATE_LOG5" \
  FAKE_PROTECTION='{"enforce_admins":{"enabled":true}}' \
  run 17 --print --allow-nonauthor --repo-path "$CLONE" --branch main
expect_rc 0 "--print + --allow-nonauthor is unaffected by the auto-plain-only refusal (exit 0)"
if grep -q -- "--allow-nonauthor" "$GATE_LOG5"; then
  ok "--print still forwards --allow-nonauthor to merge-gate.sh"
else
  bad "--print no longer forwards --allow-nonauthor to merge-gate.sh (logged calls: $(cat "$GATE_LOG5"))"
fi

# ============================================================================
# Regression (issue #1257): --allow-nonauthor cleared this script's own guard
# and (after #1251) merge-gate.sh's, but was never forwarded to
# clean-behind-check.sh — whose NESTED merge-gate.sh call re-added the
# authorship blocker into its residual_blockers. That failed
# clean_behind_evidence_allows_admin()'s reviewDecision-only match, so
# CLEAN_BEHIND_OK stayed false and a BEHIND non-author PR was refused with a
# MISLEADING "not safe to skip a rebase" — a rebase would not have helped.
# FAKE_CBC_AUTHORSHIP_BLOCK models that nested check; FAKE_CBC_LOG proves the
# flag's presence (or absence) in the actual clean-behind-check.sh invocation.
# ============================================================================

# 28. BEHIND + non-author + --allow-nonauthor reaches the plain-shape bypass
#     instead of the misleading rebase refusal.
new_log
CBC_LOG="$TMP/cbccalls.log"; : > "$CBC_LOG"
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_GATE_AUTHORSHIP_BLOCK=1 \
  FAKE_CBC_AUTHORSHIP_BLOCK=1 FAKE_CBC_LOG="$CBC_LOG" FAKE_PROTECTION="$PLAIN_PROT" \
  run 18 --print --allow-nonauthor --repo-path "$CLONE" --branch main
expect_rc 0 "BEHIND + non-author + --allow-nonauthor reaches the bypass (exit 0)"
grep_ok "gh pr merge 18 --squash --admin" "plain-shape bypass command is printed"
if grep -q -- "not safe to skip a rebase" <<<"$OUT"; then
  bad "the misleading rebase refusal still fires under --allow-nonauthor"
else
  ok "the misleading 'not safe to skip a rebase' refusal no longer fires"
fi
cbc_argv_all "$CBC_LOG" 1 "--allow-nonauthor" \
  "--allow-nonauthor literally appears in the clean-behind-check.sh invocation (--print makes exactly 1)"

# 28b. Negative control — the fail-closed default is unchanged: the same PR
#      WITHOUT the flag still gets refused, and the flag is never fabricated.
#      Also proves 28's fixture models the real bug rather than passing freely.
new_log
CBC_LOG2="$TMP/cbccalls2.log"; : > "$CBC_LOG2"
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING="$BEHIND_ONLY" \
  FAKE_CBC_AUTHORSHIP_BLOCK=1 FAKE_CBC_LOG="$CBC_LOG2" FAKE_PROTECTION="$PLAIN_PROT" \
  FAKE_AUTHORSHIP_EXIT=0 \
  run 19 --print --repo-path "$CLONE" --branch main
expect_rc 1 "without --allow-nonauthor, the nested authorship blocker still refuses (exit 1)"
grep_ok "not safe to skip a rebase" "refusal text preserved for a genuinely unsafe BEHIND"
grep_ok "authorship guard" "refusal surfaces the nested authorship blocker as the reason"
if grep -q -- "--allow-nonauthor" "$CBC_LOG2"; then
  bad "--allow-nonauthor unexpectedly forwarded when not passed (logged: $(cat "$CBC_LOG2"))"
else
  ok "no --allow-nonauthor forwarded to clean-behind-check.sh when not passed"
fi

# 28c. The #1251 unattended guard is now LOAD-BEARING (its accidental backstop
#      in clean-behind-check.sh is gone), so re-assert it holds after this fix:
#      --auto-plain + --allow-nonauthor still refuses before any pre-flight, with
#      no clean-behind-check.sh call and no merge call at all.
new_log
CBC_LOG3="$TMP/cbccalls3.log"; : > "$CBC_LOG3"
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_CBC_AUTHORSHIP_BLOCK=1 \
  FAKE_CBC_LOG="$CBC_LOG3" FAKE_PROTECTION="$PLAIN_PROT" \
  run 20 --auto-plain --ac-verified --allow-nonauthor --repo-path "$CLONE" --branch main
expect_rc 2 "--auto-plain + --allow-nonauthor still refused after the #1257 fix (exit 2)"
log_absent "^pr merge" "no merge call for --auto-plain + --allow-nonauthor"
if [[ -s "$CBC_LOG3" ]]; then
  bad "clean-behind-check.sh was invoked despite the pre-flight usage refusal (logged: $(cat "$CBC_LOG3"))"
else
  ok "clean-behind-check.sh never invoked — refusal precedes all pre-flight work"
fi

# 28d. Per-invocation argv coverage on the re-validation path (CodeAnt review).
#      --execute over a clean BEHIND calls clean-behind-check.sh TWICE: once at
#      pre-flight, then again as the issue #631 safety re-validation immediately
#      before the bypass acts. Today CBC_ARGS is built once and reused, so both
#      calls carry the flag by construction — but that is precisely the invariant
#      worth pinning: a refactor that rebuilt the argv per call site could forward
#      the override at pre-flight only, and 28's log would still contain a
#      matching line while the re-validation silently re-acquired the nested
#      authorship blocker and refused. --execute is the reachable double-call
#      path for this flag; --auto-plain is not (28c: the combination is refused
#      outright, before any clean-behind-check.sh call exists to assert on).
new_log
CBC_LOG4="$TMP/cbccalls4.log"; : > "$CBC_LOG4"
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING="$BEHIND_ONLY" FAKE_GATE_AUTHORSHIP_BLOCK=1 \
  FAKE_CBC_AUTHORSHIP_BLOCK=1 FAKE_CBC_LOG="$CBC_LOG4" FAKE_PROTECTION="$PLAIN_PROT" \
  run 21 --execute --allow-nonauthor --repo-path "$CLONE" --branch main
expect_rc 0 "--execute + --allow-nonauthor merges a clean-BEHIND non-author PR (exit 0)"
log_present "^pr merge 21 --squash --admin" "the plain-shape admin merge actually ran"
cbc_argv_all "$CBC_LOG4" 2 "--allow-nonauthor" \
  "--allow-nonauthor reaches EVERY clean-behind-check.sh call, re-validation included"

# 28e. Negative control for 28d — same --execute path WITHOUT the flag refuses at
#      the re-validation rather than merging, and no invocation fabricates it.
#      Without this, 28d's count assertion could not distinguish "both calls
#      carry the override" from "the override is unconditional".
new_log
CBC_LOG5="$TMP/cbccalls5.log"; : > "$CBC_LOG5"
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING="$BEHIND_ONLY" \
  FAKE_CBC_AUTHORSHIP_BLOCK=1 FAKE_CBC_LOG="$CBC_LOG5" FAKE_PROTECTION="$PLAIN_PROT" \
  FAKE_AUTHORSHIP_EXIT=0 \
  run 22 --execute --repo-path "$CLONE" --branch main
expect_rc 1 "--execute without --allow-nonauthor still refuses the non-author clean BEHIND (exit 1)"
log_absent "^pr merge" "no merge call when the nested authorship blocker stands"
if grep -q -- "--allow-nonauthor" "$CBC_LOG5"; then
  bad "--allow-nonauthor fabricated on the --execute path (logged: $(cat "$CBC_LOG5"))"
else
  ok "no --allow-nonauthor forwarded on --execute when not passed"
fi

# 29. repo-root.sh exit 4 — "git could not run" (issue #1403) ---------------
# repo-root.sh now separates "git never launched" (4) from the DETERMINATE "not
# a git repo" (1). Only the determinate answer may take the historic fallback
# chain; on 4 the very next statement would be an unbounded `git rev-parse`
# against that same broken git, and the `$PWD` behind it would substitute the
# invoker's cwd for the root repo on an irreversible merge.
#
# Installed last, and removed immediately after, because every earlier test
# resolves the repo path through the absence of this helper.
cat > "$SCRIPTS/repo-root.sh" <<'EOF'
#!/usr/bin/env bash
echo "repo-root.sh: git could not run (missing, not executable, or a broken PATH), so nothing was determined about the current directory — git said: git: command not found" >&2
exit "${FAKE_REPO_ROOT_EXIT:-4}"
EOF
chmod +x "$SCRIPTS/repo-root.sh"

export FAKE_REPO_ROOT_EXIT=4
run 1 --print --branch main
expect_rc 4 "repo-root.sh exit 4 refuses the merge instead of guessing the repo path"
grep_ok "could not run git at all" "the refusal names a broken git, not a missing repo"
grep_ok "repair git" "the operator is told what to fix"
grep_absent "falling back to the current checkout" \
  "no silent fallback to the cwd when git itself could not run"

# Negative control: exit 1 is still determinate, so it must STILL reach the
# historic fallback. Without this, refusing every non-zero code would pass the
# assertions above while breaking the case the split had to preserve.
export FAKE_REPO_ROOT_EXIT=1
run 1 --print --branch main
grep_ok "falling back to the current checkout" \
  "a determinate 'not a git repo' answer still takes the fallback chain"
grep_absent "could not run git at all" "exit 1 is never reported as a broken git"

unset FAKE_REPO_ROOT_EXIT
rm -f "$SCRIPTS/repo-root.sh"

# ============================================================================
# Regression (issue #1439): --repo-path did not override cwd repo detection.
# `gh repo view` ran ~60 lines BEFORE REPO_PATH was even computed, so a run from
# another repo's checkout resolved THAT repo and exited 3 ("PR not found in
# <wrong repo>") even though the flag named the right clone — observed live on
# PR #1423's Phase C. Every caller had to cd first, which the flag existed to
# avoid.
#
# GH_FAKE_REPO_BY_CWD makes the fake gh resolve owner/repo from its own cwd, so
# a cwd-scoped call FAILS the test instead of passing vacuously: reaching
# solo/repo from $OTHER is only possible by entering $CLONE. Placed after test
# 29's repo-root.sh fixture is removed, so path resolution here uses the same
# fallback chain as every other case.
# ============================================================================
printf 'solo/repo\n' > "$CLONE/.fake-repo-slug"
OTHER="$TMP/other-repo"; mkdir -p "$OTHER"; printf 'other/elsewhere\n' > "$OTHER/.fake-repo-slug"

# Compare directories by physical path — $TMP is under /var on macOS, which is a
# symlink to /private/var, so a literal string compare can differ spuriously.
same_dir() { [[ "$(cd "$1" 2>/dev/null && pwd -P)" == "$(cd "$2" 2>/dev/null && pwd -P)" ]]; }

# 30. --repo-path from an UNRELATED repo's cwd resolves the flagged repo.
new_log
GATE_PWD="$TMP/gate-pwd.log"; : > "$GATE_PWD"
OUT="$( cd "$OTHER" && GH_FAKE_REPO_BY_CWD=1 FAKE_GATE_PWD_LOG="$GATE_PWD" \
  FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' \
  "$SUT" 30 --print --repo-path "$CLONE" --branch main 2>&1 )"; RC=$?
expect_rc 0 "--repo-path resolves the flagged repo from an unrelated cwd (exit 0)"
grep_ok "repos/solo/repo/branches/main/protection/enforce_admins" \
  "cross-cwd run resolved the --repo-path repo (solo/repo)"
grep_absent "other/elsewhere" "cross-cwd run never resolved the invoker's cwd repo"
grep_ok "cd $CLONE && \\\\" "cross-cwd run still prints the portable cd prefix"
GATE_CWD="$(head -n 1 "$GATE_PWD" 2>/dev/null)"
if [[ -n "$GATE_CWD" ]] && same_dir "$GATE_CWD" "$CLONE"; then
  ok "the cwd-scoped merge-gate.sh pre-flight subprocess also ran inside the flagged clone"
else
  bad "merge-gate.sh ran in '${GATE_CWD:-<never invoked>}', not the --repo-path clone ($CLONE)"
fi

# 30b. Negative control: the SAME invocation WITHOUT --repo-path still resolves
#      the invoker's cwd repo and fails exactly as the ticket reported. Without
#      this, case 30 could pass against a fake gh that ignored cwd altogether —
#      and it pins that the cwd fallback is preserved when no flag is given.
new_log
OUT="$( cd "$OTHER" && GH_FAKE_REPO_BY_CWD=1 FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' \
  "$SUT" 30 --print --branch main 2>&1 )"; RC=$?
expect_rc 3 "without --repo-path the invoker's cwd repo is used (exit 3)"
grep_ok "not found in other/elsewhere" \
  "the cwd-scoped run fails with the ticket's wrong-repo error — the bug this fix removes"

# 30c. An explicit --repo-path that cannot be entered is a hard error in the
#      read-only mode too (exit 7), never a silent fall back to the cwd: the
#      alternative is printing a bypass for whatever repo the cwd happens to be.
new_log
OUT="$( cd "$OTHER" && GH_FAKE_REPO_BY_CWD=1 FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' \
  "$SUT" 30 --print --repo-path "$TMP/no-such-clone" --branch main 2>&1 )"; RC=$?
expect_rc 7 "an unusable explicit --repo-path refuses even in --print (exit 7)"
grep_ok "cannot cd into repo path" "the refusal names the unusable path"
grep_absent "other/elsewhere" "no fallback to the invoker's cwd repo on an unusable --repo-path"
log_absent "." "the repo-path refusal fires before any gh call"

# ============================================================================
# 31 (issue #1404): the exit-1 fallback `git rev-parse --show-toplevel` is
# bounded. PR #1386 refused rather than fall through on repo-root.sh's timeout,
# but left this call unbounded because it is a cheap single-file read — a claim
# about COST, not about stall risk. The #1363 filesystem stalls per file, so an
# unbounded call here re-creates the same no-output freeze one step further
# down, on the path whose next action is an irreversible merge.
#
# There is no repo-root.sh in $SCRIPTS (test 29 removed its fixture), so a run
# without --repo-path reaches this fallback directly.
# ============================================================================
GITSTUB="$TMP/gitstub"; mkdir -p "$GITSTUB"
REAL_GIT="$(command -v git)"
export REAL_GIT TICK_FILE="$TMP/t31-tick"
cat > "$GITSTUB/stub-sleeper" <<'EOF'
#!/usr/bin/env bash
# Self-limited (~10s) so a failing process-group kill cannot leak a sleeper.
for _ in $(seq 1 50); do
  printf 'tick\n' >> "$TICK_FILE"
  sleep 0.2
done
EOF
chmod +x "$GITSTUB/stub-sleeper"
cat > "$GITSTUB/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/t31-argv.log"
for a in "\$@"; do
  if [[ "\$a" == "--show-toplevel" ]]; then
    "$GITSTUB/stub-sleeper" &
    sleep 30
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GITSTUB/git"

# 31a. A wedged fallback refuses instead of hanging — and instead of guessing.
# A 3s bound, not 1s: the clock is whole-second, so a 1s bound can trip before
# the stub is even live.
new_log
: > "$TMP/t31-argv.log"
: > "$TICK_FILE"
T31_START="$(date +%s)"
OUT="$( cd "$OTHER" && PATH="$GITSTUB:$PATH" REPO_ROOT_TIMEOUT_SECS=3 \
  GH_FAKE_REPO_BY_CWD=1 FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' \
  "$SUT" 30 --print --branch main 2>&1 )"; RC=$?
T31_ELAPSED=$(( $(date +%s) - T31_START ))
expect_rc 4 "a wedged 'git rev-parse --show-toplevel' refuses the merge (exit 4)"
grep_ok "exceeded the 3s bound" "the refusal names the bound that tripped"
grep_ok "refusing to guess the repo path" "the refusal is explicit about not guessing"
grep_ok "pass --repo-path" "the operator is told what to do instead"
grep_absent "not found in other/elsewhere" \
  "no fall through to \$PWD — the cwd repo is never resolved on a killed call"
log_absent "." "the refusal fires before any gh call"
if (( T31_ELAPSED < 15 )); then
  ok "the bounded refusal returned in ${T31_ELAPSED}s (the stub sleeps 30s)"
else
  bad "the refusal took ${T31_ELAPSED}s — the bound did not hold"
fi
if grep -q -- '--show-toplevel' "$TMP/t31-argv.log"; then
  ok "control: the stalling call really was reached"
else
  bad "control: the stub never saw --show-toplevel, so nothing was bounded"
fi

# 31b. The library is what makes that bound possible, so its absence is a
#      refusal too — never a quiet fall back to the unbounded call.
new_log
rm -rf "${SCRIPTS:?}/lib"
OUT="$( cd "$OTHER" && GH_FAKE_REPO_BY_CWD=1 FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' \
  "$SUT" 30 --print --branch main 2>&1 )"; RC=$?
expect_rc 4 "a missing bounded-run library refuses rather than running unbounded (exit 4)"
grep_ok "bounded-run library not found" "the refusal names the missing library"
grep_absent "not found in other/elsewhere" "and still never guesses the repo path"
mkdir -p "$SCRIPTS/lib"
cp "$REPO_ROOT/.claude/scripts/lib/bounded-run.sh" "$SCRIPTS/lib/"

# 31c. Control: with nothing stalling, the same stub resolves as before. Without
#      it, 31a would also pass against a stub that broke every git call.
new_log
cat > "$GITSTUB/git" <<EOF
#!/usr/bin/env bash
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GITSTUB/git"
OUT="$( cd "$OTHER" && PATH="$GITSTUB:$PATH" REPO_ROOT_TIMEOUT_SECS=3 \
  GH_FAKE_REPO_BY_CWD=1 FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' \
  "$SUT" 30 --print --branch main 2>&1 )"; RC=$?
expect_rc 3 "control: a pass-through stub still resolves the cwd repo (exit 3, as in 30b)"
grep_absent "exceeded the 3s bound" "control: nothing is reported as timed out"
pkill -f "$GITSTUB/stub-sleeper" >/dev/null 2>&1 || true

echo "----------------------------------------"
echo "admin-merge.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
