#!/usr/bin/env bash
# admin-merge.test.sh — Offline unit tests for admin-merge.sh (issue #451).
# Stubs `gh` and `merge-gate.sh` so no network / real repo is touched.
# Run from repo root: bash .claude/scripts/tests/admin-merge.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="$REPO_ROOT/.claude/scripts/admin-merge.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
BIN="$TMP/bin"; mkdir -p "$BIN"
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"
CLONE="$TMP/clone"; mkdir -p "$CLONE"

# admin-merge.sh resolves merge-gate.sh next to itself, so run a copy from $SCRIPTS.
cp "$SRC" "$SCRIPTS/admin-merge.sh"; chmod +x "$SCRIPTS/admin-merge.sh"
SUT="$SCRIPTS/admin-merge.sh"

# --- Fake merge-gate.sh: emits JSON; behaviour driven by env vars. ----------
cat > "$SCRIPTS/merge-gate.sh" <<'EOF'
#!/usr/bin/env bash
MISSING="${FAKE_GATE_MISSING:-[]}"
HUMAN="${FAKE_GATE_HUMAN:-[]}"
jq -cn --argjson m "$MISSING" --argjson h "$HUMAN" \
  '{met:false, missing:$m, human_changes_requested:$h}'
exit "${FAKE_GATE_EXIT:-1}"
EOF
chmod +x "$SCRIPTS/merge-gate.sh"

# --- Fake clean-behind-check.sh: exit code IS the safe_to_offer verdict -------
# (0 = safe to offer / clean BEHIND, 1 = not safe). Only consulted when the gate
# lists a BEHIND blocker (issue #631).
cat > "$SCRIPTS/clean-behind-check.sh" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_CBC_EXIT:-1}"
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
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "${FAKE_OWNER_REPO:-solo/repo}"; exit 0 ;;
  "pr view "*"--json number,state,baseRefName,headRefName")
    if [ -n "${FAKE_PR_JSON:-}" ]; then echo "$FAKE_PR_JSON"
    else echo '{"number":1,"state":"OPEN","baseRefName":"main","headRefName":"feat"}'; fi
    exit 0 ;;
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
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING='["branch protection reviewDecision is REVIEW_REQUIRED, not APPROVED, with CodeRabbit in CODEOWNERS — trigger @coderabbitai full review"]' \
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

# 9b. Static: execute mode cd's into the resolved repo path before the dance
# (so `gh pr merge` targets the right repo from any cwd — BugBot finding).
if awk '/MODE" == "execute"/{f=1} f && /cd "\$REPO_PATH"/{found=1} END{exit !found}' "$SRC"; then
  ok "execute mode cd's into repo path before the dance"
else
  bad "execute mode does not cd into \$REPO_PATH before running gh"
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

echo "----------------------------------------"
echo "admin-merge.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
