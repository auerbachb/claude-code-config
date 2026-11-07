#!/usr/bin/env bash
# clean-behind-check.test.sh — Offline unit tests for clean-behind-check.sh (issues #631, #667).
# catalog: tests — Tests for `clean-behind-check.sh`
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

# --- Fake merge-gate.sh: emits {met, missing, authorship}; env-var driven. ----
# FAKE_GATE_LOG (issue #1257) — when set, every invocation's raw argv ("$*") is
#   appended as a line, so a test can assert --allow-nonauthor actually reached
#   this nested call rather than merely being accepted by the arg parser.
# FAKE_GATE_AUTHORSHIP_BLOCK (issue #1257) — when 1, models merge-gate.sh's own
#   INDEPENDENT issue #733 check: authorship is "not_mine" and the non-author
#   blocker is appended to missing[] unless --allow-nonauthor is present in argv.
# FAKE_GATE_OMIT_AUTHORSHIP — when 1, omit the `authorship` key entirely, to
#   model an older merge-gate.sh that predates the field.
cat > "$SCRIPTS/merge-gate.sh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_GATE_LOG:-}" ]; then printf '%s\n' "$*" >> "$FAKE_GATE_LOG"; fi
MISSING="${FAKE_GATE_MISSING:-[\"branch is BEHIND base — rebase + force-push before merging\"]}"
AUTHORSHIP="${FAKE_GATE_AUTHORSHIP:-mine}"
if [ "${FAKE_GATE_AUTHORSHIP_BLOCK:-0}" = "1" ]; then
  AUTHORSHIP="not_mine"
  SAW_ALLOW_NONAUTHOR=0
  for a in "$@"; do
    if [ "$a" = "--allow-nonauthor" ]; then SAW_ALLOW_NONAUTHOR=1; fi
  done
  if [ "$SAW_ALLOW_NONAUTHOR" -eq 0 ]; then
    MISSING="$(printf '%s' "$MISSING" | jq -c '. + ["PR #1 is authored by other (not you, solouser) — automated merge is blocked by the authorship guard (.claude/rules/safety.md); pass --allow-nonauthor only under an explicit per-PR user override"]')"
  fi
fi
if [ "${FAKE_GATE_OMIT_AUTHORSHIP:-0}" = "1" ]; then
  jq -cn \
    --argjson met "${FAKE_GATE_MET:-false}" \
    --argjson missing "$MISSING" \
    '{met:$met, missing:$missing}'
else
  jq -cn \
    --argjson met "${FAKE_GATE_MET:-false}" \
    --argjson missing "$MISSING" \
    --arg authorship "$AUTHORSHIP" \
    '{met:$met, missing:$missing, authorship:$authorship}'
fi
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
    if grep -q 'baseRefOid' <<<"$ARGS"; then
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
  *"/pulls/"*"--jq .head.sha"*)
    # Post-fetch head re-read; FAKE_HEAD_AFTER simulates a concurrent push,
    # FAKE_HEAD_AFTER_FAIL=1 an unreadable head.
    if [[ "${FAKE_HEAD_AFTER_FAIL:-0}" == "1" ]]; then
      echo "ERROR: failed to read PR head" >&2; exit 1
    fi
    echo "${FAKE_HEAD_AFTER:-deadbeefcafedeadbeefcafedeadbeefcafedead}"
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
  if grep -q "$1" <<<"$OUT"; then ok "$2"; else bad "$2 (output: $OUT)"; fi
}
grep_absent() {  # grep_absent <pattern> <desc> — asserts pattern is NOT in $OUT
  if grep -q "$1" <<<"$OUT"; then bad "$2 (pattern '$1' found but should be absent; output: $OUT)"; else ok "$2"; fi
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

# ============================================================================
# Regression (issue #1257): this script had NO --allow-nonauthor concept — the
# arg parser rejected it (exit 2) and its NESTED merge-gate.sh call could never
# receive an authorship override. For a BEHIND + non-author PR the nested gate
# therefore re-added the issue #733 blocker into missing[]; it is not the BEHIND
# message, so it landed in residual_blockers, held gate_green_except_behind
# false, and made admin-merge.sh refuse with a misleading "not safe to skip a
# rebase". Each test below fails against the pre-fix script.
# ============================================================================

# 33. The flag is accepted at all (pre-fix: "unknown flag" usage error, exit 2).
run 0 --allow-nonauthor
expect_rc 0 "--allow-nonauthor is accepted, not rejected as an unknown flag"

# 34. The flag literally reaches the nested merge-gate.sh invocation. Parser
#     acceptance alone would leave the real bug in place, so assert on argv.
GATE_LOG="$TMP/gatecalls.log"; : > "$GATE_LOG"
FAKE_GATE_LOG="$GATE_LOG" run 0 --allow-nonauthor
if grep -q -- "--allow-nonauthor" "$GATE_LOG"; then
  ok "--allow-nonauthor literally appears in the nested merge-gate.sh invocation"
else
  bad "--allow-nonauthor was NOT forwarded to merge-gate.sh (logged calls: $(cat "$GATE_LOG"))"
fi

# 35. Negative control: the flag is never fabricated when it was not passed.
GATE_LOG2="$TMP/gatecalls2.log"; : > "$GATE_LOG2"
FAKE_GATE_LOG="$GATE_LOG2" run 0
if grep -q -- "--allow-nonauthor" "$GATE_LOG2"; then
  bad "--allow-nonauthor unexpectedly forwarded when not passed (logged: $(cat "$GATE_LOG2"))"
else
  ok "no --allow-nonauthor forwarded when the flag was not passed"
fi

# 36. End-to-end: BEHIND + non-author + --allow-nonauthor → the authorship
#     blocker never enters residual_blockers, so the clean-BEHIND verdict is
#     reachable (exit 0). This is the state admin-merge.sh needs to reach the
#     plain-shape bypass instead of the misleading rebase refusal.
FAKE_GATE_AUTHORSHIP_BLOCK=1 run 0 --allow-nonauthor
expect_rc 0 "BEHIND + non-author + --allow-nonauthor → safe_to_offer (exit 0)"
expect_field '.safe_to_offer' 'true' "override lets safe_to_offer become true for a non-author PR"
expect_field '.residual_blockers | length' '0' "authorship blocker absent from residual_blockers under override"
expect_field '.gate_green_except_behind' 'true' "gate_green_except_behind true under the override"

# 37. Negative control — the fail-closed default is PROVABLY unchanged: the same
#     non-author PR WITHOUT the flag still keeps the authorship blocker, still
#     reports not-safe, and still exits 1. (Also proves test 36 is not a
#     tautology: the fixture really does model the blocking behavior.)
FAKE_GATE_AUTHORSHIP_BLOCK=1 run 1
expect_rc 1 "BEHIND + non-author WITHOUT the flag still refuses (exit 1)"
expect_field '.safe_to_offer' 'false' "no override → safe_to_offer stays false"
expect_field '.gate_green_except_behind' 'false' "no override → gate_green_except_behind stays false"
expect_field '[.residual_blockers[] | select(test("authorship guard"))] | length' '1' \
  "no override → authorship blocker retained in residual_blockers"
expect_field '[.reasons_not_safe[] | select(test("authorship guard"))] | length' '1' \
  "no override → authorship blocker surfaced in reasons_not_safe"

# 38. The override is never silent: `authorship` mirrors merge-gate.sh's verdict
#     even when the blocker is suppressed, and `authorship_overridden` records
#     that a bypass was in effect. A bypass that left no trace in the evidence
#     JSON is exactly what these fields exist to prevent.
FAKE_GATE_AUTHORSHIP_BLOCK=1 run 0 --allow-nonauthor
expect_field '.authorship' 'not_mine' "bypassed non-author PR is still legible as authorship=not_mine"
expect_field '.authorship_overridden' 'true' "authorship_overridden true when --allow-nonauthor is passed"

run 0
expect_field '.authorship' 'mine' "authorship mirrored from merge-gate.sh on a normal run"
expect_field '.authorship_overridden' 'false' "authorship_overridden false by default (opt-in only)"

# 39. Forward compatibility: an older merge-gate.sh with no `authorship` key
#     degrades to "unknown" rather than reporting a false "mine".
FAKE_GATE_OMIT_AUTHORSHIP=1 run 0
expect_field '.authorship' 'unknown' "missing merge-gate authorship field degrades to unknown"

# ============================================================================
# Issue #1859: zero-context changed-line ranges. GitHub patches carry 3 lines of
# context, and the pre-fix parser intersected the context-inclusive header
# spans, so two edits up to ~6 lines apart read as overlapping even when git
# merges them cleanly. Cases 40, 41 and 45 fail against the pre-fix script
# (false overlap / insertion-only fallback); 44 and 46 fail there because the
# insertion-only side fell back instead of producing a real range; 49 and 50
# fail there because the old header-only parser trusted a malformed patch and
# called it disjoint (fail-open). The rest are negative controls proving that
# touching or overlapping edits still block.
# ============================================================================

# hunk_case <base-patch> <pr-patch> — run the SUT with one shared file whose
# base-delta and PR patches are the given unified-diff bodies (real newlines).
hunk_case() {
  local bp pp
  bp="$(jq -cn --arg p "$1" '{"shared.md": $p}')"
  pp="$(jq -cn --arg p "$2" '{"shared.md": $p}')"
  FAKE_PR_FILES='["shared.md","mine.sh"]' \
    FAKE_BASE_DELTA_FILES='["shared.md"]' \
    FAKE_BASE_DELTA_PATCHES="$bp" \
    FAKE_PR_FILE_PATCHES="$pp" \
    run 1
}
expect_disjoint() {  # expect_disjoint <desc>
  expect_rc 0 "$1 → exit 0 (safe to offer)"
  expect_field '.safe_to_offer' 'true' "$1: safe_to_offer true"
  expect_field '.file_overlap.count' '0' "$1: overlap count 0"
  expect_field '.file_overlap.granularity' 'hunk' "$1: granularity hunk"
  expect_field '.file_overlap.fallback_files | length' '0' "$1: no fallback files"
}
expect_overlap() {  # expect_overlap <desc>
  expect_rc 1 "$1 → exit 1 (not safe)"
  expect_field '.safe_to_offer' 'false' "$1: safe_to_offer false"
  expect_field '.file_overlap.count' '1' "$1: overlap count 1"
  expect_field '.file_overlap.granularity' 'hunk' "$1: granularity hunk"
  expect_field '.file_overlap.fallback_files | length' '0' "$1: a real overlap, not a fallback"
}

# 40. PR #925 shape (auerbachb/still-point, ios/PARITY_CHECKLIST.md): main
#     changed lines 3, 14 and 33 and deleted line 42; the PR changed only line
#     44. Line 43 is untouched by both sides. The -39,7 and -41,7 hunks overlap
#     on context alone; the changed lines do not.
PR925_BASE="$(printf '%s\n' \
  '@@ -1,6 +1,6 @@' ' l1' ' l2' '-l3' '+L3' ' l4' ' l5' ' l6' \
  '@@ -11,7 +11,7 @@' ' l11' ' l12' ' l13' '-l14' '+L14' ' l15' ' l16' ' l17' \
  '@@ -30,7 +30,7 @@' ' l30' ' l31' ' l32' '-l33' '+L33' ' l34' ' l35' ' l36' \
  '@@ -39,7 +39,6 @@ ## Parity' ' l39' ' l40' ' l41' '-l42' ' l43' ' l44' ' l45')"
PR925_PR="$(printf '%s\n' \
  '@@ -41,7 +41,7 @@ ## Parity' ' l41' ' l42' ' l43' '-l44' '+L44' ' l45' ' l46' ' l47')"
hunk_case "$PR925_BASE" "$PR925_PR"
expect_disjoint "#1859 PR #925 shape (context-padded hunks, disjoint changed lines)"

# 41. Line-separated insertion: base inserts after line 42, PR changes line 44.
hunk_case "$(printf '%s\n' '@@ -40,3 +40,4 @@' ' l40' ' l41' ' l42' '+new')" \
  "$(printf '%s\n' '@@ -41,7 +41,7 @@' ' l41' ' l42' ' l43' '-l44' '+L44' ' l45' ' l46' ' l47')"
expect_disjoint "#1859 insertion after 42 vs change on 44 (line 43 separates)"

# 42. Negative control: adjacent edits (base line 42, PR line 43) still overlap.
hunk_case "$(printf '%s\n' '@@ -39,7 +39,7 @@' ' l39' ' l40' ' l41' '-l42' '+L42' ' l43' ' l44' ' l45')" \
  "$(printf '%s\n' '@@ -40,7 +40,7 @@' ' l40' ' l41' ' l42' '-l43' '+L43' ' l44' ' l45' ' l46')"
expect_overlap "#1859 adjacent edits (42 vs 43)"

# 43. Negative control: both sides change the same line.
hunk_case "$(printf '%s\n' '@@ -41,3 +41,3 @@' ' l41' '-l42' '+A42' ' l43')" \
  "$(printf '%s\n' '@@ -41,3 +41,3 @@' ' l41' '-l42' '+B42' ' l43')"
expect_overlap "#1859 same-line edits"

# 44. Insertion after line 5 (-5,0) vs a PR change on line 6 → touching.
INS5="$(printf '%s\n' '@@ -5,0 +6,2 @@' '+n1' '+n2')"
hunk_case "$INS5" "$(printf '%s\n' '@@ -6 +6 @@' '-l6' '+L6')"
expect_overlap "#1859 insertion after 5 vs change on 6"

# 45. The same insertion vs a PR change on line 7 → line 6 separates them.
hunk_case "$INS5" "$(printf '%s\n' '@@ -7 +7 @@' '-l7' '+L7')"
expect_disjoint "#1859 insertion after 5 vs change on 7"

# 46. Insertion vs insertion at the same point → overlap.
hunk_case "$INS5" "$(printf '%s\n' '@@ -5,0 +6 @@' '+other')"
expect_overlap "#1859 same-point insertions"

# 47. Omitted-count header (@@ -5 +5 @@) vs a PR change on line 5 → overlap.
hunk_case "$(printf '%s\n' '@@ -5 +5 @@' '-l5' '+A5')" \
  "$(printf '%s\n' '@@ -4,3 +4,3 @@' ' l4' '-l5' '+B5' ' l6')"
expect_overlap "#1859 omitted-count header vs change on the same line"

# 48. Multiple hunks; only the second one touches the PR edit → overlap.
hunk_case "$(printf '%s\n' '@@ -1,3 +1,3 @@' ' l1' '-l2' '+L2' ' l3' '@@ -20,3 +20,3 @@' ' l20' '-l21' '+L21' ' l22')" \
  "$(printf '%s\n' '@@ -19,3 +19,3 @@' ' l19' '-l20' '+L20' ' l21')"
expect_overlap "#1859 second base hunk touches the PR edit"

# 49. Malformed patch (header count disagrees with the body) → fail closed:
#     fallback to file level, unsafe, with a malformed reason in the note. The
#     ranges would be disjoint if the patch were trusted, so this discriminates.
hunk_case "$(printf '%s\n' '@@ -1,5 +1,5 @@' ' l1' '-l2' '+L2' ' l3')" \
  "$(printf '%s\n' '@@ -40,3 +40,3 @@' ' l40' '-l41' '+L41' ' l42')"
expect_rc 1 "#1859 malformed patch → exit 1 (not safe)"
expect_field '.safe_to_offer' 'false' "#1859 malformed patch: safe_to_offer false"
expect_field '.file_overlap.count' '1' "#1859 malformed patch: counted as overlapping"
expect_field '.file_overlap.fallback_files | length' '1' "#1859 malformed patch: one fallback file"
grep_ok "malformed" "#1859 malformed patch: note names the malformed reason"

# 50. Malformed: text before the first hunk header → fail closed.
hunk_case "$(printf '%s\n' 'garbage' '@@ -1,3 +1,3 @@' ' l1' '-l2' '+L2' ' l3')" \
  "$(printf '%s\n' '@@ -40,3 +40,3 @@' ' l40' '-l41' '+L41' ' l42')"
expect_rc 1 "#1859 text before first header → exit 1 (not safe)"
expect_field '.file_overlap.fallback_files | length' '1' "#1859 text before first header: one fallback file"

# 51. "\ No newline at end of file" is neutral, and a patch without a trailing
#     newline parses the same as one with it.
hunk_case "$(printf '%s\n%s\n%s\n%s\n%s' '@@ -9,2 +9,2 @@' ' l9' '-l10' '+L10' '\ No newline at end of file')" \
  "$(printf '%s\n' '@@ -6,3 +6,3 @@' ' l6' '-l7' '+L7' ' l8')"
expect_disjoint "#1859 no-newline marker is neutral"

# 52. Any other backslash-prefixed line is malformed → fail closed. The ranges
#     would be disjoint if the patch were trusted, so this discriminates.
hunk_case "$(printf '%s\n' '@@ -9,2 +9,2 @@' ' l9' '-l10' '\ something else' '+L10')" \
  "$(printf '%s\n' '@@ -6,3 +6,3 @@' ' l6' '-l7' '+L7' ' l8')"
expect_rc 1 "#1859 non-marker backslash line → exit 1 (not safe)"
expect_field '.file_overlap.fallback_files | length' '1' "#1859 non-marker backslash line: one fallback file"

# 53. PR head moves between the compare and the PR-files fetch → fail closed:
#     the patches would be in different coordinate spaces. Disjoint ranges, so
#     trusting them would wrongly report safe — this discriminates.
DISJ_B="$(printf '%s\n' '@@ -1,3 +1,3 @@' ' l1' '-l2' '+L2' ' l3')"
DISJ_P="$(printf '%s\n' '@@ -40,3 +40,3 @@' ' l40' '-l41' '+L41' ' l42')"
FAKE_HEAD_AFTER=0000000000000000000000000000000000000000 hunk_case "$DISJ_B" "$DISJ_P"
expect_rc 1 "PR head moved after patch fetch → exit 1 (not safe)"
expect_field '.safe_to_offer' 'false' "PR head moved: safe_to_offer false"
grep_ok "PR head changed" "PR head moved: note names the reason"

# 54. PR head unreadable after the fetch → fail closed the same way.
FAKE_HEAD_AFTER_FAIL=1 hunk_case "$DISJ_B" "$DISJ_P"
expect_rc 1 "PR head unreadable after patch fetch → exit 1 (not safe)"
expect_field '.safe_to_offer' 'false' "PR head unreadable: safe_to_offer false"

# 55. Control: same patches with the head unchanged → disjoint (safe).
hunk_case "$DISJ_B" "$DISJ_P"
expect_disjoint "head unchanged control"

echo "----------------------------------------"
echo "clean-behind-check.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
