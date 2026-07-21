#!/usr/bin/env bash
# clean-behind-check.test.sh — Offline unit tests for clean-behind-check.sh (issue #631).
# Stubs `gh`, `merge-gate.sh`, and `ac-checkboxes.sh` so no network / real repo is
# touched. Run from repo root: bash .claude/scripts/tests/clean-behind-check.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="$REPO_ROOT/.claude/scripts/clean-behind-check.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
BIN="$TMP/bin"; mkdir -p "$BIN"
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"

# clean-behind-check.sh resolves merge-gate.sh + ac-checkboxes.sh next to itself,
# so run a copy from $SCRIPTS alongside the fakes.
cp "$SRC" "$SCRIPTS/clean-behind-check.sh"; chmod +x "$SCRIPTS/clean-behind-check.sh"
SUT="$SCRIPTS/clean-behind-check.sh"

# --- Fake merge-gate.sh: emits {met, missing}; behaviour driven by env vars. --
cat > "$SCRIPTS/merge-gate.sh" <<'EOF'
#!/usr/bin/env bash
jq -cn \
  --argjson met "${FAKE_GATE_MET:-false}" \
  --argjson missing "${FAKE_GATE_MISSING:-[\"branch is BEHIND base — rebase + force-push before merging\"]}" \
  '{met:$met, missing:$missing}'
exit "${FAKE_GATE_EXIT:-1}"
EOF
chmod +x "$SCRIPTS/merge-gate.sh"

# --- Fake ac-checkboxes.sh: emits the --extract JSON array. -------------------
# NOTE: the default JSON is set via a plain assignment, NOT a ${VAR:-default}
# fallback — bash parameter-expansion defaults terminate at the first literal
# `}`, which would truncate a brace-containing JSON default into garbage.
cat > "$SCRIPTS/ac-checkboxes.sh" <<'EOF'
#!/usr/bin/env bash
AC="${FAKE_AC_JSON:-}"
if [ -z "$AC" ]; then
  AC='[{"index":0,"checked":true,"text":"a"},{"index":1,"checked":true,"text":"b"}]'
fi
echo "$AC"
exit "${FAKE_AC_EXIT:-0}"
EOF
chmod +x "$SCRIPTS/ac-checkboxes.sh"

# --- Fake gh (safe defaults describe a green, clean-BEHIND, no-overlap PR). ---
# Emulates gh 2.48.0: rejects any `pr view` field list containing `baseRefOid`.
# FAKE_PRVIEW_ERR: if set, `pr view` prints this to stderr and exits 1 (error injection).
# FAKE_BASEREF_FAIL: if set to 1, the git/ref/heads call exits 1 (fallback test).
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "${FAKE_OWNER_REPO:-solo/repo}"; exit 0 ;;
  *"pr view "*"headRefOid"*)
    # Reject baseRefOid in the field list (gh 2.48.0 does not support it)
    if echo "$ARGS" | grep -q 'baseRefOid'; then
      echo 'Unknown JSON field: "baseRefOid"' >&2; exit 1
    fi
    # Allow injecting a gh error for error-classification tests
    if [[ -n "${FAKE_PRVIEW_ERR:-}" ]]; then
      echo "$FAKE_PRVIEW_ERR" >&2; exit 1
    fi
    jq -cn \
      --arg ms "${FAKE_MERGESTATE:-BEHIND}" \
      --arg mg "${FAKE_MERGEABLE:-MERGEABLE}" \
      --argjson files "${FAKE_PR_FILES:-[\"mine.txt\"]}" \
      '{number:1,state:"OPEN",headRefOid:"deadbeefcafedeadbeefcafedeadbeefcafedead",baseRefName:"main",mergeStateStatus:$ms,mergeable:$mg,files:($files|map({path:.}))}'
    exit 0 ;;
  *"git/ref/heads/"*)
    # Best-effort base-SHA resolution; simulate failure via FAKE_BASEREF_FAIL=1
    if [[ "${FAKE_BASEREF_FAIL:-0}" == "1" ]]; then
      echo "ERROR: failed to resolve ref" >&2; exit 1
    fi
    jq -cn --arg sha "${FAKE_BASE_SHA:-ba5eba5eba5eba5eba5eba5eba5eba5eba5eba5e}" \
      '{"object":{"sha":$sha}}'
    exit 0 ;;
  *compare/*)
    jq -cn \
      --argjson files "${FAKE_BASE_DELTA_FILES:-[\"other.txt\"]}" \
      --argjson ahead "${FAKE_AHEAD_BY:-2}" \
      --arg newest "${FAKE_NEWEST_BASE_AT:-2026-07-21T18:00:00Z}" \
      '{ahead_by:$ahead, files:($files|map({filename:.})), commits:[{commit:{committer:{date:$newest}}}]}'
    exit 0 ;;
  *commits/*)
    echo "${FAKE_HEAD_AT:-2026-07-21T12:00:00Z}"; exit 0 ;;
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
json_field() {  # json_field <jq-filter> — echoes the value from the last $OUT
  jq -r "$1" <<<"$OUT" 2>/dev/null
}
expect_field() {  # expect_field <jq-filter> <want> <desc>
  local got; got="$(json_field "$1")"
  if [[ "$got" == "$2" ]]; then ok "$3"; else bad "$3 (field $1 = '$got', want '$2'; out: $OUT)"; fi
}
grep_ok() {    # grep_ok <pattern> <desc>
  if printf '%s\n' "$OUT" | grep -q "$1"; then ok "$2"; else bad "$2 (output: $OUT)"; fi
}
grep_absent() {  # grep_absent <pattern> <desc> — asserts pattern is NOT in $OUT
  if printf '%s\n' "$OUT" | grep -q "$1"; then bad "$2 (pattern '$1' found but should be absent; output: $OUT)"; else ok "$2"; fi
}

# 1. Green PR, clean BEHIND, base delta does NOT touch PR files → safe (exit 0),
#    and the churn advisory fires (main newer than PR head, ahead_by>=1). [#621 replay]
run 1
expect_rc 0 "clean BEHIND, no overlap → exit 0 (safe to offer)"
expect_field '.safe_to_offer' 'true' "safe_to_offer is true"
expect_field '.reasons_not_safe | length' '0' "no reasons_not_safe when safe"
expect_field '.merge_state' 'BEHIND' "merge_state reported as BEHIND"
expect_field '.file_overlap.count' '0' "zero file overlap"
expect_field '.churn.advisory' 'true' "churn advisory fires on rapid-main replay"
expect_field '.churn.base_ahead_by' '2' "churn reports base_ahead_by"
if jq -e . >/dev/null 2>&1 <<<"$OUT"; then ok "stdout is valid JSON"; else bad "stdout not valid JSON: $OUT"; fi

# 2. Green PR, BEHIND, base delta TOUCHES the PR's files → not safe (rebase).
FAKE_PR_FILES='["shared.txt","mine.txt"]' FAKE_BASE_DELTA_FILES='["shared.txt"]' run 1
expect_rc 1 "file overlap → exit 1 (not safe)"
expect_field '.safe_to_offer' 'false' "safe_to_offer false on overlap"
expect_field '.file_overlap.count' '1' "overlap count is 1"
grep_ok "base delta overlaps PR files" "reason names the file overlap"

# 3. BEHIND but a residual merge-gate blocker (unresolved thread) → not safe.
FAKE_GATE_MISSING='["branch is BEHIND base — rebase + force-push before merging","1 unresolved review thread(s) — resolve via GraphQL before merge"]' \
  run 1
expect_rc 1 "residual gate blocker → exit 1 (not safe)"
expect_field '.gate_green_except_behind' 'false' "gate not green when a non-BEHIND blocker remains"
expect_field '.residual_blockers | length' '1' "residual_blockers lists the unresolved thread"
grep_ok "merge gate blocker" "reason surfaces the residual blocker"

# 4. mergeable CONFLICTING → not safe, conflict path.
FAKE_MERGEABLE='CONFLICTING' run 1
expect_rc 1 "CONFLICTING → exit 1 (not safe)"
expect_field '.safe_to_offer' 'false' "safe_to_offer false when CONFLICTING"
grep_ok "CONFLICTING" "reason names the conflict"

# 4b. mergeable UNKNOWN (GitHub still computing) → not safe (premature to offer).
FAKE_MERGEABLE='UNKNOWN' run 1
expect_rc 1 "UNKNOWN mergeability → exit 1 (not safe)"
expect_field '.safe_to_offer' 'false' "safe_to_offer false when mergeable UNKNOWN"
grep_ok "still computing mergeability" "reason names the UNKNOWN mergeability state"

# 5. Not BEHIND (already CLEAN, gate fully met) → no offer.
FAKE_MERGESTATE='CLEAN' FAKE_GATE_MET='true' FAKE_GATE_MISSING='[]' run 1
expect_rc 1 "CLEAN (not BEHIND) → exit 1 (nothing to offer)"
grep_ok "not BEHIND" "reason explains there is no clean-behind bypass to offer"

# 6. AC not fully verified (one unchecked Test Plan box) → not safe.
FAKE_AC_JSON='[{"index":0,"checked":true,"text":"a"},{"index":1,"checked":false,"text":"b"}]' run 1
expect_rc 1 "unchecked AC box → exit 1 (not safe)"
expect_field '.ac.all_checked' 'false' "ac.all_checked false with an unchecked box"
grep_ok "acceptance criteria not fully verified" "reason names the AC gap"

# 7. No churn: main did NOT advance past PR head → advisory false, still safe.
FAKE_AHEAD_BY='0' FAKE_NEWEST_BASE_AT='2026-07-20T00:00:00Z' run 1
expect_rc 0 "clean BEHIND with no churn is still safe (exit 0)"
expect_field '.churn.advisory' 'false' "churn advisory false when main has not advanced"

# 8. Static: the helper NEVER merges or touches branch protection (offer-only).
if grep -qE 'gh pr merge|--admin|enforce_admins|-X[[:space:]]+(DELETE|POST|PUT)|--method[[:space:]]+(DELETE|POST|PUT)' "$SRC"; then
  bad "helper must never merge or modify protection (found a forbidden call)"
else
  ok "helper never merges or modifies branch protection (offer-only)"
fi

# 9. Usage errors.
run
expect_rc 2 "missing PR number → exit 2"
run 1 --reviewer bogus
expect_rc 2 "invalid --reviewer value → exit 2"

# 10. gh 2.48.0 regression: open PR still resolves without baseRefOid in field list.
#     The stub now rejects baseRefOid, so the happy-path tests above already cover
#     this implicitly; this is an explicit regression assertion.
run 1
expect_rc 0 "open PR resolves correctly with baseRefOid absent from field list (gh 2.48.0 regression)"
expect_field '.safe_to_offer' 'true' "safe_to_offer true when baseRefOid absent"

# 11. Genuine not-found: gh error text matches not-found phrases → exit 3.
FAKE_PRVIEW_ERR='GraphQL: Could not resolve to a PullRequest with the number of 999. (repository.pullRequest)' run 999
expect_rc 3 "genuine not-found gh error → exit 3"
grep_ok "not found" "not-found message surfaced on exit 3"

# 12. Other gh error (unknown field, rate-limit, network): → exit 4, no not-found message.
FAKE_PRVIEW_ERR='Unknown JSON field: "wat"' run 1
expect_rc 4 "other gh error (unknown field) → exit 4"
grep_absent "not found in" "exit-4 path must NOT print the not-found message"
grep_ok 'Unknown JSON field' "exit-4 path surfaces the real gh error text"

# 15. Repo-level gh error must NOT be mis-classified as PR not found → exit 4 (not exit 3).
FAKE_PRVIEW_ERR='GraphQL: Could not resolve to a Repository with the login of "solo" and the name "repo". (organization)' run 999
expect_rc 4 "repo-level not-found routes to exit 4 (not misclassified as PR missing)"
grep_absent "not found in" "repo-level error must NOT print the PR-not-found message"

# 16. Generic HTTP 404 error must NOT be mis-classified as PR not found → exit 4.
FAKE_PRVIEW_ERR='HTTP 404 Not Found' run 999
expect_rc 4 "HTTP 404 not-found routes to exit 4 (not misclassified as PR missing)"
grep_absent "not found in" "HTTP 404 error must NOT print the PR-not-found message"

# 13. Base-SHA-fetch failure: git/ref/heads call fails → ref-name fallback, still exit 0.
FAKE_BASEREF_FAIL=1 run 1
expect_rc 0 "base-SHA fetch failure → ref-name fallback, still safe to offer (exit 0)"
expect_field '.safe_to_offer' 'true' "safe_to_offer true even when BASE_SHA not resolved"

# 14. Static: ensure `pr view` never requests `baseRefOid` in actual code (regression guard).
#     Exclude comment lines (# ...) — the script documents the removed field in comments.
if grep -E 'pr view.*baseRefOid' "$SRC" | grep -v '^[[:space:]]*#' >/dev/null 2>&1; then
  bad "source must not request baseRefOid via 'pr view' in code (gh 2.48.0 compat)"
else
  ok "source does not request baseRefOid via 'pr view' in code (gh 2.48.0 compat)"
fi

echo "----------------------------------------"
echo "clean-behind-check.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
