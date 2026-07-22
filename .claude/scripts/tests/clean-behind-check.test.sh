#!/usr/bin/env bash
# clean-behind-check.test.sh — Offline unit tests for clean-behind-check.sh (issues #631, #667).
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
# FAKE_BASE_DELTA_PATCHES: JSON object {filename: patchtext} for compare response.
# FAKE_PR_FILE_PATCHES: JSON object {filename: patchtext} for pulls/{N}/files response.
# FAKE_PR_PATCHES_FAIL: if set to 1, pulls/{N}/files call exits 1 (API failure test).
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
  *"pulls/"*"files"*)
    # PR file patches endpoint (pulls/{N}/files --paginate)
    if [[ "${FAKE_PR_PATCHES_FAIL:-0}" == "1" ]]; then
      echo "ERROR: failed to fetch PR files" >&2; exit 1
    fi
    PATCHES="${FAKE_PR_FILE_PATCHES:-null}"
    PR_FILES="${FAKE_PR_FILES:-[\"mine.txt\"]}"
    jq -cn \
      --argjson pr_files "$PR_FILES" \
      --argjson patches "$PATCHES" \
      '[$pr_files[] | {filename: ., patch: (if $patches != null then ($patches[.] // null) else null end), status: "modified"}]'
    exit 0 ;;
  *compare/*)
    PATCHES="${FAKE_BASE_DELTA_PATCHES:-null}"
    jq -cn \
      --argjson files "${FAKE_BASE_DELTA_FILES:-[\"other.txt\"]}" \
      --argjson patches "$PATCHES" \
      --argjson ahead "${FAKE_AHEAD_BY:-2}" \
      --arg newest "${FAKE_NEWEST_BASE_AT:-2026-07-21T18:00:00Z}" \
      '{
        ahead_by: $ahead,
        files: ($files | map({filename: ., patch: (if $patches != null then ($patches[.] // null) else null end)})),
        commits: [{commit:{committer:{date:$newest}}}]
      }'
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
expect_field '.churn.threshold' '1' "churn.threshold is 1 (default)"
if jq -e . >/dev/null 2>&1 <<<"$OUT"; then ok "stdout is valid JSON"; else bad "stdout not valid JSON: $OUT"; fi

# 2. Green PR, BEHIND, base delta TOUCHES the PR's files → not safe (rebase).
#    With no patch data, hunk analysis falls back to file-level (conservative).
FAKE_PR_FILES='["shared.txt","mine.txt"]' FAKE_BASE_DELTA_FILES='["shared.txt"]' run 1
expect_rc 1 "file overlap (no patch data → file-level fallback) → exit 1 (not safe)"
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

# ============================================================
# Issue #667: hunk-level overlap + tunable churn threshold
# ============================================================

# Patch fixtures — unified diff hunk strings (JSON-safe, actual newline via $'...' not needed
# since we pass them as JSON string values through jq).
# Disjoint: base modifies lines 1-3, PR modifies lines 10-12 → no intersection.
DISJOINT_BASE_PATCHES='{"shared.sh":"@@ -1,3 +1,3 @@\n context\n-old\n+new\n context2"}'
DISJOINT_PR_PATCHES='{"shared.sh":"@@ -10,3 +10,3 @@\n context8\n-old10\n+new10\n context12"}'

# Overlapping: base modifies lines 5-9, PR modifies lines 7-9 → intersect at 7-9.
OVERLAPPING_BASE_PATCHES='{"shared.sh":"@@ -5,5 +5,5 @@\n c5\n-o6\n+n6\n c7\n-o8\n+n8\n c9"}'
OVERLAPPING_PR_PATCHES='{"shared.sh":"@@ -7,3 +7,3 @@\n c7\n-o8\n+n8\n c9"}'

# 17. Hunk-level: same file but DISJOINT hunks → hunk analysis says safe_to_offer=true.
#     This is the key regression the issue exists to fix: file-level would have said unsafe.
FAKE_PR_FILES='["shared.sh","mine.sh"]' \
  FAKE_BASE_DELTA_FILES='["shared.sh"]' \
  FAKE_BASE_DELTA_PATCHES="$DISJOINT_BASE_PATCHES" \
  FAKE_PR_FILE_PATCHES="$DISJOINT_PR_PATCHES" \
  run 1
expect_rc 0 "hunk: same-file disjoint hunks → exit 0 (safe to offer — false positive eliminated)"
expect_field '.safe_to_offer' 'true' "safe_to_offer true when hunks are disjoint"
expect_field '.file_overlap.count' '0' "overlap count 0 after hunk analysis shows disjoint"
expect_field '.file_overlap.granularity' 'hunk' "granularity is hunk when analysis ran"
expect_field '.file_overlap.hunk_overlapping_files | length' '0' "hunk_overlapping_files empty for disjoint"
expect_field '.file_overlap.fallback_files | length' '0' "no fallback files for disjoint case"

# 18. Hunk-level: same file with OVERLAPPING hunks → unsafe.
FAKE_PR_FILES='["shared.sh","mine.sh"]' \
  FAKE_BASE_DELTA_FILES='["shared.sh"]' \
  FAKE_BASE_DELTA_PATCHES="$OVERLAPPING_BASE_PATCHES" \
  FAKE_PR_FILE_PATCHES="$OVERLAPPING_PR_PATCHES" \
  run 1
expect_rc 1 "hunk: same-file overlapping hunks → exit 1 (not safe)"
expect_field '.safe_to_offer' 'false' "safe_to_offer false when hunks overlap"
expect_field '.file_overlap.count' '1' "overlap count 1 for overlapping hunks"
expect_field '.file_overlap.granularity' 'hunk' "granularity is hunk"
expect_field '.file_overlap.hunk_overlapping_files | length' '1' "hunk_overlapping_files has the shared file"
grep_ok "base delta overlaps PR files" "reason names the overlapping file"

# 19. Hunk-level: missing patch (binary file or no patch field) → conservative fallback → unsafe.
FAKE_PR_FILES='["binary.bin","mine.txt"]' \
  FAKE_BASE_DELTA_FILES='["binary.bin"]' \
  FAKE_BASE_DELTA_PATCHES='{}' \
  FAKE_PR_FILE_PATCHES='{}' \
  run 1
expect_rc 1 "hunk: missing patch (binary/truncated) → conservative fallback → exit 1 (not safe)"
expect_field '.safe_to_offer' 'false' "safe_to_offer false on conservative fallback"
expect_field '.file_overlap.granularity' 'hunk' "granularity is hunk even when falling back"
expect_field '.file_overlap.fallback_files | length' '1' "fallback_files lists the binary file"
expect_field '.file_overlap.hunk_overlapping_files | length' '1' "hunk_overlapping_files includes fallback file"
grep_ok "fell back to file-level" "note documents the fallback"

# 20. Hunk-level: PR files API failure → keep file-level verdict (conservative).
FAKE_PR_FILES='["shared.txt","mine.txt"]' \
  FAKE_BASE_DELTA_FILES='["shared.txt"]' \
  FAKE_PR_PATCHES_FAIL=1 \
  run 1
expect_rc 1 "hunk: PR files API failure → file-level result kept → exit 1 (not safe)"
expect_field '.safe_to_offer' 'false' "safe_to_offer false when hunk analysis unavailable"
expect_field '.file_overlap.granularity' 'file' "granularity is file when hunk analysis fails"
grep_ok "hunk analysis unavailable" "note documents API failure"

# 21. New JSON fields exist and are valid on a standard safe run.
run 1
expect_field '.file_overlap.granularity' 'file' "granularity is file when no file-level overlap (no hunk analysis needed)"
expect_field '.file_overlap.hunk_overlapping_files | length' '0' "hunk_overlapping_files empty when no overlap"
expect_field '.file_overlap.fallback_files | length' '0' "fallback_files empty when no overlap"
expect_field '.churn.threshold' '1' "churn.threshold present in output"

# ============================================================
# Churn threshold tuning (issue #667)
# ============================================================

# 22. Default threshold=1: ahead_by=1 fires advisory (existing behavior preserved).
FAKE_AHEAD_BY=1 run 1
expect_field '.churn.advisory' 'true' "threshold=1 default: ahead_by=1 fires advisory"
expect_field '.churn.threshold' '1' "churn.threshold=1 in output"

# 23. Custom threshold via env var: ahead_by < threshold → advisory false.
FAKE_AHEAD_BY=2 CHURN_THRESHOLD=3 run 1
expect_field '.churn.advisory' 'false' "CHURN_THRESHOLD=3: ahead_by=2 does not fire advisory"
expect_field '.churn.threshold' '3' "churn.threshold reflects env var value"

# 24. Custom threshold via env var: ahead_by >= threshold → advisory true.
FAKE_AHEAD_BY=3 CHURN_THRESHOLD=3 run 1
expect_field '.churn.advisory' 'true' "CHURN_THRESHOLD=3: ahead_by=3 fires advisory"

# 25. --churn-threshold flag: ahead_by < threshold → advisory false.
FAKE_AHEAD_BY=1 run 1 --churn-threshold 5
expect_field '.churn.advisory' 'false' "--churn-threshold 5: ahead_by=1 does not fire advisory"
expect_field '.churn.threshold' '5' "churn.threshold reflects flag value"

# 26. --churn-threshold flag: ahead_by >= threshold → advisory true.
FAKE_AHEAD_BY=5 run 1 --churn-threshold 5
expect_field '.churn.advisory' 'true' "--churn-threshold 5: ahead_by=5 fires advisory"
expect_rc 0 "--churn-threshold 5 with safe PR still exits 0 (churn is advisory only)"

# 27. --churn-threshold flag overrides env var (flag wins).
FAKE_AHEAD_BY=2 CHURN_THRESHOLD=1 run 1 --churn-threshold 5
expect_field '.churn.advisory' 'false' "flag overrides env var: threshold=5, ahead_by=2 → advisory false"
expect_field '.churn.threshold' '5' "flag threshold value wins over env var"

# 28. Churn advisory never gates safe_to_offer.
FAKE_AHEAD_BY=100 CHURN_THRESHOLD=1 run 1
expect_rc 0 "churn advisory never gates safe_to_offer — high churn still safe (exit 0)"
expect_field '.churn.advisory' 'true' "advisory fires with high churn"
expect_field '.safe_to_offer' 'true' "safe_to_offer true regardless of churn"

# 29. Usage: invalid --churn-threshold value → exit 2.
run 1 --churn-threshold bad
expect_rc 2 "invalid --churn-threshold value → exit 2"

# 30. Usage: --churn-threshold with no value → exit 2.
run 1 --churn-threshold
expect_rc 2 "--churn-threshold with no value → exit 2"

# 31. Threshold=0: when ahead_by=0 but base commit is NOT newer than PR HEAD → advisory false.
#     With threshold=0, `0 >= 0` passes the numeric check, so the timestamp comparison
#     is the deciding factor. Use a base timestamp older than the PR HEAD to confirm
#     the timestamp gate still applies.
FAKE_AHEAD_BY=0 FAKE_NEWEST_BASE_AT='2026-07-21T10:00:00Z' run 1 --churn-threshold 0
expect_field '.churn.advisory' 'false' "threshold=0 + ahead_by=0 + base not newer: advisory false (timestamp gating)"
expect_field '.churn.threshold' '0' "threshold=0 present in output"

# 32. Hunk-level: non-empty but oversized patch (>= 20,000 chars, potentially
#     truncated) → conservative fallback → exit 1 (not safe).
#     The DISJOINT_PR_PATCHES fixture would produce safe_to_offer=true if the
#     large base patch were parsed as-is (disjoint ranges). The truncation guard
#     must kick in before range parsing and force the conservative fallback.
OVERSIZED_PATCH="$(printf '@@ -1,1 +1,1 @@\n-old\n+new\n'; printf 'x%.0s' {1..20000})"
OVERSIZED_BASE_PATCHES="$(jq -cn --arg p "$OVERSIZED_PATCH" '{"shared.sh": $p}')"
FAKE_PR_FILES='["shared.sh","mine.sh"]' \
  FAKE_BASE_DELTA_FILES='["shared.sh"]' \
  FAKE_BASE_DELTA_PATCHES="$OVERSIZED_BASE_PATCHES" \
  FAKE_PR_FILE_PATCHES="$DISJOINT_PR_PATCHES" \
  run 1
expect_rc 1 "hunk: oversized base patch (>= 20000 chars) → conservative fallback → exit 1"
expect_field '.safe_to_offer' 'false' "safe_to_offer false for oversized base patch"
expect_field '.file_overlap.granularity' 'hunk' "granularity is hunk even with oversized patch"
expect_field '.file_overlap.fallback_files | length' '1' "oversized patch triggers fallback_files"
expect_field '.file_overlap.hunk_overlapping_files | length' '1' "hunk_overlapping_files includes fallback file"

echo "----------------------------------------"
echo "clean-behind-check.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
