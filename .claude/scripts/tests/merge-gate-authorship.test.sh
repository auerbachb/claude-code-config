#!/usr/bin/env bash
# merge-gate-authorship.test.sh — the issue #733 authorship guard in merge-gate.sh.
# Runs the REAL merge-gate.sh (+ real ci-status.sh / check-runs-dedup.sh /
# session-state.sh siblings); only `gh` is stubbed on PATH. Requires jq.
# Run from repo root: bash .claude/scripts/tests/merge-gate-authorship.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Overridable so this suite can be pointed at another checkout's merge-gate.sh
# (issue #1485); the guard stops a mistyped path from reading as a real result.
# Named MERGE_GATE here, not SUT, as it has been since this suite was written.
MERGE_GATE="${MERGE_GATE:-$REPO_ROOT/.claude/scripts/merge-gate.sh}"
[[ -f "$MERGE_GATE" && -x "$MERGE_GATE" ]] || { echo "FAIL — MERGE_GATE is not an executable file: $MERGE_GATE" >&2; exit 1; }

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"; mkdir -p "$HOME/.claude"

PASS=0; FAIL=0
check_eq() { # <label> <expected> <actual>
  if [[ "$3" == "$2" ]]; then PASS=$((PASS+1)); echo "ok   — $1"
  else FAIL=$((FAIL+1)); echo "FAIL — $1 (expected '$2', got '$3')"; fi
}

# ---- stub gh: a clean baseline (CI green, CR APPROVED on HEAD, no threads) so
#      authorship is the only variable. Behaviour driven by env vars:
#        FAKE_VIEWER       login from `gh api user` (default alice)
#        FAKE_VIEWER_FAIL  when set, `gh api user` exits 1 (viewer unresolved)
#        FAKE_PR_AUTHOR    PR author login (default alice)
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "solo/repo"; exit 0 ;;
  "api user --jq .login")
    if [ -n "${FAKE_VIEWER_FAIL:-}" ]; then echo "gh: auth error" >&2; exit 1; fi
    echo "${FAKE_VIEWER:-alice}"; exit 0 ;;
  *"pr view "*)
    jq -cn --arg author "${FAKE_PR_AUTHOR:-alice}" \
      '{number:1, state:"OPEN", headRefOid:"deadbeef", baseRefName:"main",
        mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", reviewDecision:"APPROVED",
        author:{login:$author, type:"User"}}'
    exit 0 ;;
  *check-runs*)
    jq -cn '{check_runs:[{id:1,name:"ci",status:"completed",conclusion:"success",
              check_suite:{id:1},app:{slug:"gha",id:1}}]}'; exit 0 ;;
  *git/commits/*)
    jq -cn '{committer:{date:"2026-07-23T12:00:00Z"}}'; exit 0 ;;
  *pulls/*/reviews*)
    # body is substantive on purpose (issue #875): the gate discounts an approval
    # with no evidence anything read the commit, and this fixture stands in for a
    # genuine review so the authorship logic stays the only thing under test.
    jq -cn '[{user:{login:"coderabbitai[bot]",type:"Bot"},commit_id:"deadbeef",
              body:"Actionable comments posted: 0. Reviewed the changed files; no issues found.",
              state:"APPROVED",submitted_at:"2026-07-23T13:00:00Z"}]'; exit 0 ;;
  *pulls/*/comments*)  echo "[]"; exit 0 ;;
  *issues/*/comments*) echo "[]"; exit 0 ;;
  *graphql*)
    jq -cn '{data:{repository:{pullRequest:{reviewThreads:{nodes:[]}}}}}'; exit 0 ;;
  *"/branches/"*"/protection/required_status_checks"*)
    # Branch-protection required contexts (issue #1361). Default is a 404, which
    # combined with the unprotected branch object below resolves to "no required
    # status checks" — so every pre-#1361 expectation in this file is unchanged.
    # FAKE_REQUIRED_STATUS_CHECKS supplies the endpoint payload;
    # FAKE_BRANCH_PROTECTED=true marks the base branch protected.
    if [[ -n "${FAKE_REQUIRED_STATUS_CHECKS:-}" ]]; then
      printf '%s' "${FAKE_REQUIRED_STATUS_CHECKS}"; exit 0
    fi
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"/branches/"*)
    if [[ -n "${FAKE_BRANCH_JSON:-}" ]]; then
      printf '%s' "${FAKE_BRANCH_JSON}"; exit 0
    fi
    jq -cn --arg p "${FAKE_BRANCH_PROTECTED:-false}" \
      '{name:"main", protected:($p == "true"),
        protection:{required_status_checks:{contexts:[]}}}'
    exit 0 ;;
  *contents/*) echo "Not Found" >&2; exit 1 ;;
esac
echo "unexpected gh call: $ARGS" >&2
exit 1
GHEOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

run_gate() { OUT="$("$@" "$MERGE_GATE" 1 2>/dev/null)"; RC=$?; }
authorship()  { echo "$OUT" | jq -r '.authorship'; }
guard_in_missing() { echo "$OUT" | jq -e '[.missing[]? | select(contains("authorship guard"))] | length > 0' >/dev/null && echo yes || echo no; }

echo "== (1) mine: author == viewer -> authorship=mine, no block, gate met =="
run_gate env FAKE_VIEWER=alice FAKE_PR_AUTHOR=alice
check_eq "authorship == mine" "mine" "$(authorship)"
check_eq "no authorship entry in missing" "no" "$(guard_in_missing)"
check_eq "gate met (clean baseline, own PR) -> exit 0" "0" "$RC"

echo "== (2) not_mine: author != viewer -> authorship=not_mine, blocks, exit 1 =="
run_gate env FAKE_VIEWER=alice FAKE_PR_AUTHOR=bob
check_eq "authorship == not_mine" "not_mine" "$(authorship)"
check_eq "authorship entry present in missing" "yes" "$(guard_in_missing)"
check_eq "gate not met -> exit 1" "1" "$RC"

echo "== (3) not_mine + --allow-nonauthor -> field still not_mine, no block =="
OUT="$(env FAKE_VIEWER=alice FAKE_PR_AUTHOR=bob "$MERGE_GATE" 1 --allow-nonauthor 2>/dev/null)"; RC=$?
check_eq "authorship field still reflects reality (not_mine)" "not_mine" "$(authorship)"
check_eq "override suppresses the authorship block" "no" "$(guard_in_missing)"
check_eq "override lets the gate pass -> exit 0" "0" "$RC"

echo "== (4) unknown (viewer unresolved) -> authorship=unknown, does NOT block =="
run_gate env FAKE_VIEWER_FAIL=1 FAKE_PR_AUTHOR=bob
check_eq "authorship == unknown" "unknown" "$(authorship)"
check_eq "unknown does not add an authorship block (fail-closed lives upstream)" "no" "$(guard_in_missing)"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: merge-gate authorship tests passed"
