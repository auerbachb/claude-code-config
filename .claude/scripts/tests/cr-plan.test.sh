#!/usr/bin/env bash
# Offline integration tests for cr-plan.sh (issue #541 — enrichment false positive).
# catalog: tests — Tests for `cr-plan.sh`
# Stubs `gh` so nothing touches the network or the real ~/.claude; exercises the
# exit-code wiring around cr-plan-filter.py (filter semantics themselves are
# unit-tested in tests/test_cr_plan_filter.py). Requires python3.
# Run from repo root: bash .claude/scripts/tests/cr-plan.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/cr-plan.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

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
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (output does not contain '$needle')"
  fi
}

# ---- stub gh ----------------------------------------------------------------
# cr-plan.sh makes two kinds of calls:
#   gh issue view N --json state,createdAt --jq '"\(.state)\t\(.createdAt)"'
#   gh issue view N --json comments
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
case "$args" in
  *state,createdAt*)
    if [[ "${GH_ISSUE_MISSING:-0}" == "1" ]]; then
      echo "GraphQL: Could not resolve to an issue or pull request" >&2
      exit 1
    fi
    printf '%s\t%s\n' "${GH_ISSUE_STATE:-OPEN}" "2026-07-15T00:00:00Z"
    ;;
  *comments*)
    if [[ "${GH_COMMENTS_FAIL:-0}" == "1" ]]; then
      echo "gh: HTTP 500 from api.github.com" >&2
      exit 1
    fi
    cat "$GH_COMMENTS_JSON"
    ;;
  *)
    echo "stub gh: unexpected args: $args" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# ---- fixtures ---------------------------------------------------------------
# Compact synthetic bodies: the bash layer only needs "boilerplate rejected /
# plan accepted"; verbatim-fixture coverage lives in the Python unit tests.
python3 - "$TMP" <<'PY'
import json, pathlib, sys

tmp = pathlib.Path(sys.argv[1])
enrich = (
    "<!-- This is an auto-generated issue plan by CodeRabbit -->\n"
    "<details>\n<summary>🔗 Related PRs</summary>\n\n"
    + "owner/repo#1 - some previously merged change [merged]\n" * 8
    + "</details>\n\n---\n<details>\n<summary>📝 Issue Planner</summary>\n\n"
    "<sub>Check the box below or use the `@coderabbitai plan` command.</sub>\n\n"
    "- [ ] Create Plan\n</details>\n\n"
    "💬 Have feedback or questions? Drop into our discord!"
)
plan = (
    "<!-- This is an auto-generated reply by CodeRabbit -->\n"
    "## Coding Plan\n\n### Summary\n\n"
    + "1. A concrete implementation step with enough detail to act on.\n" * 10
)

def cr(body):
    return {"author": {"login": "coderabbitai"}, "body": body}

(tmp / "comments-enrichment.json").write_text(
    json.dumps({"comments": [cr(enrich)]}), encoding="utf-8")
(tmp / "comments-plan.json").write_text(
    json.dumps({"comments": [cr(enrich), cr(plan)]}), encoding="utf-8")
(tmp / "comments-empty.json").write_text(
    json.dumps({"comments": []}), encoding="utf-8")
(tmp / "comments-malformed.json").write_text("{not json", encoding="utf-8")
PY

run_script() {
  # run_script <command...> — captures stdout in OUT and exit code in RC.
  OUT="$("$@" 2>"$TMP/stderr")"
  RC=$?
}

# 1. usage error: no args
run_script env GH_COMMENTS_JSON=/dev/null bash "$SCRIPT" || true
check_eq "no args exits 2" "2" "$RC"

# 2. usage error: non-numeric issue number
run_script env GH_COMMENTS_JSON=/dev/null bash "$SCRIPT" abc || true
check_eq "non-numeric issue exits 2" "2" "$RC"

# 3. enrichment-only comments → no plan (the #540/#541 false positive, fixed)
run_script env GH_COMMENTS_JSON="$TMP/comments-enrichment.json" bash "$SCRIPT" 540 || true
check_eq "enrichment-only exits 1" "1" "$RC"
check_eq "enrichment-only prints nothing" "" "$OUT"

# 4. enrichment + real plan → plan wins
run_script env GH_COMMENTS_JSON="$TMP/comments-plan.json" bash "$SCRIPT" 541 || true
check_eq "enrichment+plan exits 0" "0" "$RC"
check_contains "enrichment+plan prints the plan" "## Coding Plan" "$OUT"

# 5. no comments at all → no plan
run_script env GH_COMMENTS_JSON="$TMP/comments-empty.json" bash "$SCRIPT" 7 || true
check_eq "no comments exits 1" "1" "$RC"

# 6. closed issue → 3
run_script env GH_ISSUE_STATE=CLOSED GH_COMMENTS_JSON="$TMP/comments-plan.json" bash "$SCRIPT" 452 || true
check_eq "closed issue exits 3" "3" "$RC"

# 7. missing issue → 3
run_script env GH_ISSUE_MISSING=1 GH_COMMENTS_JSON="$TMP/comments-plan.json" bash "$SCRIPT" 9999 || true
check_eq "missing issue exits 3" "3" "$RC"

# 8. gh failure on the comments fetch → 4
run_script env GH_COMMENTS_FAIL=1 GH_COMMENTS_JSON="$TMP/comments-plan.json" bash "$SCRIPT" 541 || true
check_eq "gh comments failure exits 4" "4" "$RC"

# 9. filter failure (malformed JSON reaches the helper) → 4
run_script env GH_COMMENTS_JSON="$TMP/comments-malformed.json" bash "$SCRIPT" 541 || true
check_eq "filter failure exits 4" "4" "$RC"

echo
echo "cr-plan.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
