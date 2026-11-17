#!/usr/bin/env bash
# Offline tests: polling-state-gate.sh saves the merge-gate result it just
# produced for escalate-review.sh, without changing the verdict (issue #2442).
# catalog: tests — `polling-state-gate.sh` passes merge-gate stdout and exit code through unchanged and saves a met result for same-cycle reuse; a failed save changes nothing
#
# Runs a COPY of .claude/scripts with a stub merge-gate.sh, a temp HOME and a
# stub gh: no test calls GitHub.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$TEST_DIR" rev-parse --show-toplevel)"
# shellcheck source=lib/polling-state-gate-fixtures.sh
source "$TEST_DIR/lib/polling-state-gate-fixtures.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP" "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude/handoffs"
unset GH_TOKEN GITHUB_TOKEN

PASS=0; FAIL=0
check_eq() {
  if [[ "$3" == "$2" ]]; then PASS=$((PASS + 1)); echo "ok   — $1"
  else FAIL=$((FAIL + 1)); echo "FAIL — $1 (expected '$2', got '$3')"; fi
}

PROJ="$TMP/proj"
mkdir -p "$PROJ/.claude"
cp -R "$REPO_ROOT/.claude/scripts" "$PROJ/.claude/scripts"
cp -R "$REPO_ROOT/.claude/reference" "$PROJ/.claude/reference"
SCRIPT="$PROJ/.claude/scripts/polling-state-gate.sh"

HEAD40="aaaaaaaa0000000000000000000000000000aaaa"
BASE40="bbbbbbbb0000000000000000000000000000bbbb"
PR=84
export GATE_CACHE_DIR="$TMP/gate-cache"

REPO_A="$TMP/repo-a"
mk_repo "$REPO_A" "https://github.com/org/c.git"
STUB_BIN="$TMP/bin"
write_polling_gh_stub "$STUB_BIN"
# Wrapper: answer the head/base snapshot read, delegate everything else.
cat > "$STUB_BIN/gh-wrap" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" == "repos/{owner}/{repo}/pulls/84" && "$*" == *"--jq"* ]]; then
  [[ -n "${FAKE_SNAPSHOT_FAIL:-}" ]] && exit 1
  echo "org/c $HEAD40 $BASE40"; exit 0
fi
exec "$REAL_STUB_GH" "$@"
STUB
mv "$STUB_BIN/gh" "$STUB_BIN/gh.real"
mv "$STUB_BIN/gh-wrap" "$STUB_BIN/gh"
chmod +x "$STUB_BIN/gh"
export REAL_STUB_GH="$STUB_BIN/gh.real" HEAD40 BASE40

write_handoff "org/c" "$PR" "$HEAD40"
cycle() { # prints stdout to $TMP/out, stderr to $TMP/err, returns the script's rc
  ( cd "$REPO_A" && PATH="$STUB_BIN:$PATH" STUB_HEAD_SHA="$HEAD40" STUB_OWNER_REPO="org/c" \
      bash "$SCRIPT" "$PR" "$@" >"$TMP/out" 2>"$TMP/err" )
}
cycle --ensure-session; check_eq "enrolment succeeds" "0" "$?"
CACHE_FILE="$GATE_CACHE_DIR/org__c__pr$PR.json"

gate_stub() { # <met true|false> <exit code>
  cat > "$PROJ/.claude/scripts/merge-gate.sh" <<STUB
#!/usr/bin/env bash
echo "stub-gate-stderr" >&2
printf '{"pr_number":$PR,"owner_repo":"org/c","met":$1,"head_sha":"$HEAD40","missing":[]}\n'
exit $2
STUB
  chmod +x "$PROJ/.claude/scripts/merge-gate.sh"
}

echo "== (s1): met gate -> stdout, stderr and exit 0 pass through; the result is saved =="
rm -rf "$GATE_CACHE_DIR"; gate_stub true 0
cycle; rc=$?
check_eq "(s1) exit code is the gate's" "0" "$rc"
check_eq "(s1) stdout is exactly the gate's JSON" \
  "{\"pr_number\":$PR,\"owner_repo\":\"org/c\",\"met\":true,\"head_sha\":\"$HEAD40\",\"missing\":[]}" "$(cat "$TMP/out")"
check_eq "(s1) gate stderr still reaches stderr" "1" "$(grep -c stub-gate-stderr "$TMP/err" || true)"
check_eq "(s1) saved file exists" "1" "$([[ -f "$CACHE_FILE" ]] && echo 1 || echo 0)"
check_eq "(s1) saved key fields" "$HEAD40 $BASE40 false 0" \
  "$(jq -r '[.head_sha, .base_sha, (.allow_nonauthor|tostring), (.rc|tostring)] | join(" ")' "$CACHE_FILE")"
check_eq "(s1) saved file holds the gate result" "true" "$(jq -r '.gate.met|tostring' "$CACHE_FILE")"

echo "== (s2): not-met gate (exit 1) -> exit 1 passes through, nothing saved =="
rm -rf "$GATE_CACHE_DIR"; gate_stub false 1
cycle; rc=$?
check_eq "(s2) exit code is the gate's (1)" "1" "$rc"
check_eq "(s2) not-met result is not saved" "0" "$([[ -e "$CACHE_FILE" ]] && echo 1 || echo 0)"

echo "== (s3): gate exit 4 passes through =="
rm -rf "$GATE_CACHE_DIR"; gate_stub true 4
cycle; rc=$?
check_eq "(s3) exit code is the gate's (4)" "4" "$rc"
check_eq "(s3) nothing saved on a gate error" "0" "$([[ -e "$CACHE_FILE" ]] && echo 1 || echo 0)"

echo "== (s4): a failed save never changes the verdict or exit code =="
gate_stub true 0
rm -rf "$GATE_CACHE_DIR"; : > "$GATE_CACHE_DIR"   # a FILE where the directory must go: mkdir fails
cycle; rc=$?
check_eq "(s4) exit code still 0 with an unwritable cache location" "0" "$rc"
check_eq "(s4) stdout unchanged" "1" "$(jq -e '.met == true' "$TMP/out" >/dev/null 2>&1 && echo 1 || echo 0)"
rm -f "$GATE_CACHE_DIR"
FAKE_SNAPSHOT_FAIL=1 cycle; rc=$?
check_eq "(s4) exit code still 0 when the SHA snapshot read fails" "0" "$rc"
check_eq "(s4) ...and nothing is saved from it" "0" "$([[ -e "$CACHE_FILE" ]] && echo 1 || echo 0)"
rm -f "$PROJ/.claude/scripts/lib/gate-result-cache.sh"
cycle; rc=$?
check_eq "(s4) exit code still 0 when the cache library is missing" "0" "$rc"

echo "== (s5): a saved result whose gate head differs from the snapshot is refused =="
rm -rf "$GATE_CACHE_DIR"
cp "$REPO_ROOT/.claude/scripts/lib/gate-result-cache.sh" "$PROJ/.claude/scripts/lib/gate-result-cache.sh"
cat > "$PROJ/.claude/scripts/merge-gate.sh" <<STUB
#!/usr/bin/env bash
printf '{"pr_number":$PR,"owner_repo":"org/c","met":true,"head_sha":"cccccccc0000000000000000000000000000cccc","missing":[]}\n'
STUB
cycle; rc=$?
check_eq "(s5) exit code still the gate's" "0" "$rc"
check_eq "(s5) head mismatch -> nothing saved" "0" "$([[ -e "$CACHE_FILE" ]] && echo 1 || echo 0)"

echo "== polling-state-gate-gate-save: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
