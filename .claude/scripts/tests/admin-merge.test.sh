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

# --- Fake gh (safe defaults: no brace-heavy ${VAR:-...} expansions) ----------
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "${FAKE_OWNER_REPO:-solo/repo}"; exit 0 ;;
  "pr view "*"--json number,state,baseRefName,headRefName,merged")
    if [ -n "${FAKE_PR_JSON:-}" ]; then echo "$FAKE_PR_JSON"
    else echo '{"number":1,"state":"OPEN","baseRefName":"main","headRefName":"feat","merged":false}'; fi
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
ok()   { echo "ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

run() { OUT="$("$SUT" "$@" 2>&1)"; RC=$?; }

# 1. Happy path: solo + enforce_admins + clean gate → print exact command.
FAKE_GATE_EXIT=0 FAKE_GATE_MISSING='[]' run 1 --print --repo-path "$CLONE" --branch main
[[ $RC -eq 0 ]] && ok "print exits 0 on merge-ready solo repo" || bad "print exit ($RC): $OUT"
echo "$OUT" | grep -q "cd $CLONE && \\\\" && ok "command has cd-prefix" || bad "missing cd-prefix: $OUT"
echo "$OUT" | grep -q "gh api -X DELETE repos/solo/repo/branches/main/protection/enforce_admins" \
  && ok "DELETE enforce_admins present" || bad "missing DELETE: $OUT"
echo "$OUT" | grep -q "gh pr merge 1 --squash --admin" && ok "merge --admin present" || bad "missing merge: $OUT"
POST_LINE=$(echo "$OUT" | grep "gh api -X POST repos/solo/repo/branches/main/protection/enforce_admins")
[[ -n "$POST_LINE" ]] && ok "re-enable POST present" || bad "missing POST: $OUT"
if echo "$POST_LINE" | grep -qiE -- '-f |--field|enabled='; then
  bad "POST must have NO body (found a field flag): $POST_LINE"
else
  ok "POST sent with no body (no -f/--field/enabled=)"
fi

# 2. Hard blocker (unresolved thread) → refuse, exit 1, no bypass printed.
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING='["1 unresolved review thread(s) — resolve via GraphQL before merge"]' \
  run 1 --print --repo-path "$CLONE" --branch main
[[ $RC -eq 1 ]] && ok "refuses on hard blocker (exit 1)" || bad "expected exit 1, got $RC: $OUT"
echo "$OUT" | grep -q "enforce_admins" && bad "should NOT print bypass on hard blocker" || ok "no bypass printed on hard blocker"

# 3. Only a code-owner reviewDecision blocker → bypassable, still prints.
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING='["branch protection reviewDecision is REVIEW_REQUIRED, not APPROVED, with CodeRabbit in CODEOWNERS — trigger @coderabbitai full review"]' \
  run 1 --print --repo-path "$CLONE" --branch main
[[ $RC -eq 0 ]] && ok "reviewDecision-only blocker is bypassable (exit 0)" || bad "expected exit 0, got $RC: $OUT"

# 4. Human change request → refuse even if everything else clean.
FAKE_GATE_EXIT=1 FAKE_GATE_MISSING='[]' FAKE_GATE_HUMAN='["alice"]' \
  run 1 --print --repo-path "$CLONE" --branch main
[[ $RC -eq 1 ]] && ok "refuses on human CHANGES_REQUESTED (exit 1)" || bad "expected exit 1, got $RC: $OUT"

# 5. Not solo-owned (two human admins) → refuse, exit 5.
FAKE_GATE_EXIT=0 FAKE_ADMINS="solouser otheruser" \
  run 1 --print --repo-path "$CLONE" --branch main
[[ $RC -eq 5 ]] && ok "refuses non-solo repo (exit 5)" || bad "expected exit 5, got $RC: $OUT"

# 6. --force-solo bypasses the solo heuristic.
FAKE_GATE_EXIT=0 FAKE_ADMINS="solouser otheruser" \
  run 1 --print --force-solo --repo-path "$CLONE" --branch main
[[ $RC -eq 0 ]] && ok "--force-solo overrides solo heuristic (exit 0)" || bad "expected exit 0, got $RC: $OUT"

# 7. enforce_admins not enabled → refuse, exit 6.
FAKE_GATE_EXIT=0 FAKE_PROTECTION='{"enforce_admins":{"enabled":false}}' \
  run 1 --print --repo-path "$CLONE" --branch main
[[ $RC -eq 6 ]] && ok "refuses when enforce_admins off (exit 6)" || bad "expected exit 6, got $RC: $OUT"

# 8. --launch-terminal on non-macOS falls back to inline print (exit 0).
if [[ "$(uname)" != "Darwin" ]]; then
  FAKE_GATE_EXIT=0 run 1 --launch-terminal --repo-path "$CLONE" --branch main
  [[ $RC -eq 0 ]] && ok "launch-terminal falls back on non-macOS (exit 0)" || bad "expected exit 0, got $RC: $OUT"
  echo "$OUT" | grep -qi "macOS-only" && ok "launch-terminal prints macOS-only note" || bad "missing macOS-only note: $OUT"
fi

# 9. Static: execute mode has a trap that re-enables protection.
grep -q "trap reenable_protection EXIT" "$SRC" && ok "execute mode installs re-enable trap" || bad "missing trap in execute mode"

# 10. Mutually exclusive modes.
run 1 --print --execute --repo-path "$CLONE" --branch main
[[ $RC -eq 2 ]] && ok "mutually exclusive modes rejected (exit 2)" || bad "expected exit 2, got $RC"

echo "----------------------------------------"
echo "admin-merge.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
