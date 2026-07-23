#!/usr/bin/env bash
# Offline unit tests for pr-authorship.sh (issue #733 — hard authorship guard).
# Stubs `gh` on PATH so no network/auth is needed. The script has no sibling-script
# dependencies, so it runs in place from the repo with a temp HOME. Requires jq.
# Run from repo root:
#   bash .claude/scripts/tests/pr-authorship.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/pr-authorship.sh"

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

# ---- stub gh on PATH ---------------------------------------------------------
# Behavior is driven entirely by env vars the scenarios set:
#   FAKE_VIEWER    login returned by `gh api user`; "__FAIL__" => gh exits 1.
#   FAKE_PR_MODE   json (default) | 404 | error  — how `gh api repos/.../pulls/N` behaves.
#   FAKE_PR_JSON   raw PR JSON body printed in the `json` mode.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "unexpected gh call: $*" >&2; exit 99; }
shift
endpoint="${1:-}"   # this script always passes the endpoint first
case "$endpoint" in
  user)
    if [[ "${FAKE_VIEWER:-}" == "__FAIL__" ]]; then
      echo "gh: could not authenticate to github.com" >&2
      exit 1
    fi
    printf '%s\n' "${FAKE_VIEWER:-}"
    ;;
  repos/*/pulls/*)
    case "${FAKE_PR_MODE:-json}" in
      404)   echo "gh: HTTP 404: Not Found (https://api.github.com/$endpoint)" >&2; exit 1 ;;
      error) echo "gh: HTTP 500: internal server error" >&2; exit 1 ;;
      *)     printf '%s' "${FAKE_PR_JSON:-}" ;;
    esac
    ;;
  *)
    echo "unexpected endpoint: $endpoint" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# author JSON body helper: $1 = login, $2 = type (User/Bot/...)
pr_body() {
  jq -cn --arg login "$1" --arg type "$2" '{number: 5, user: {login: $login, type: $type}}'
}

run() {
  # run <pr-arg...> ; sets global OUT (stdout) and RC (exit code)
  OUT="$(bash "$SCRIPT" "$@" 2>/dev/null)"; RC=$?
}

############################################################################
echo "== (1) mine: viewer == author -> verdict mine, exit 0 =="
export FAKE_VIEWER="alice"; export FAKE_PR_MODE="json"; export FAKE_PR_JSON="$(pr_body alice User)"
run 730
check_eq "stdout mine" "mine" "$OUT"
check_eq "exit 0" 0 "$RC"

############################################################################
echo "== (2) not_mine: collaborator author -> verdict not_mine, exit 1 =="
export FAKE_VIEWER="alice"; export FAKE_PR_JSON="$(pr_body bob User)"
run 42
check_eq "stdout not_mine" "not_mine" "$OUT"
check_eq "exit 1" 1 "$RC"

############################################################################
echo "== (3) not_mine: bot author (dependabot) -> verdict not_mine, exit 1 =="
export FAKE_VIEWER="alice"; export FAKE_PR_JSON="$(pr_body 'dependabot[bot]' Bot)"
run 43
check_eq "stdout not_mine" "not_mine" "$OUT"
check_eq "exit 1 (bots are not mine)" 1 "$RC"

############################################################################
echo "== (4) fail-closed: PR API error -> verdict unknown, exit 4 =="
export FAKE_VIEWER="alice"; export FAKE_PR_MODE="error"
run 44
check_eq "stdout unknown" "unknown" "$OUT"
check_eq "exit 4 (fail-closed)" 4 "$RC"

############################################################################
echo "== (5) fail-closed: empty author in PR body -> verdict unknown, exit 4 =="
export FAKE_VIEWER="alice"; export FAKE_PR_MODE="json"; export FAKE_PR_JSON='{"number":5}'
run 45
check_eq "stdout unknown" "unknown" "$OUT"
check_eq "exit 4 (fail-closed)" 4 "$RC"

############################################################################
echo "== (6) fail-closed: viewer login unresolvable -> verdict unknown, exit 4 =="
export FAKE_VIEWER="__FAIL__"; export FAKE_PR_MODE="json"; export FAKE_PR_JSON="$(pr_body alice User)"
run 46
check_eq "stdout unknown" "unknown" "$OUT"
check_eq "exit 4 (fail-closed on viewer)" 4 "$RC"

############################################################################
echo "== (7) not found: 404 -> verdict unknown, exit 3 =="
export FAKE_VIEWER="alice"; export FAKE_PR_MODE="404"
run 9999
check_eq "stdout unknown" "unknown" "$OUT"
check_eq "exit 3 (not found)" 3 "$RC"

############################################################################
echo "== (8) usage: non-numeric PR -> exit 2 =="
export FAKE_VIEWER="alice"; export FAKE_PR_MODE="json"
run abc
check_eq "exit 2 (usage)" 2 "$RC"

############################################################################
echo "== (9) usage: missing PR arg -> exit 2 =="
run
check_eq "exit 2 (usage)" 2 "$RC"

############################################################################
echo "== (10) --json: not_mine object shape (verdict + author fields) =="
export FAKE_VIEWER="alice"; export FAKE_PR_MODE="json"; export FAKE_PR_JSON="$(pr_body bob User)"
run 47 --json
check_eq "exit 1" 1 "$RC"
check_eq "json verdict" "not_mine" "$(jq -r '.verdict' <<<"$OUT")"
check_eq "json author" "bob" "$(jq -r '.author' <<<"$OUT")"
check_eq "json viewer" "alice" "$(jq -r '.viewer' <<<"$OUT")"

############################################################################
echo "== (11) --repo passthrough: mine in a named repo -> exit 0 =="
export FAKE_VIEWER="alice"; export FAKE_PR_JSON="$(pr_body alice User)"
run 5 --repo other/repo
check_eq "stdout mine" "mine" "$OUT"
check_eq "exit 0" 0 "$RC"

############################################################################
echo "== (12) --repo validation: malformed value -> exit 2 =="
run 5 --repo not-a-repo
check_eq "exit 2 (bad --repo)" 2 "$RC"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: pr-authorship.sh tests passed"
