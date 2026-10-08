#!/usr/bin/env bash
# Offline tests for bugbot-tier-excluded.sh (issue #1728).
# catalog: tests — Tests the gate-to-exit-code contract of `bugbot-tier-excluded.sh`
#
# WHAT IS UNDER TEST
#   The one shared answer every `@cursor review` path and escalate-review.sh
#   ask: does this PR's review tier exclude BugBot? Exit 0 + gate for ci-only
#   and ci+codeant-one-round; exit 1 + gate for full and legacy; exit 2 with
#   nothing on stdout for a usage error or any resolver failure — which every
#   caller treats as "post" (fail-open). Since issue #1807 a resolved
#   `"escalation":"off"` also gives exit 0 + gate on any gate, with one stderr
#   line; any other escalation value keeps the gate's own answer.
#
# HOW IT IS OBSERVED
#   The helper is copied beside a stub review-tier.sh that prints
#   FIXTURE_TIER_OUT, exits FIXTURE_TIER_RC, and logs the arguments it received,
#   so the forwarding of --repo/--base is asserted rather than assumed.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
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

DIR="$TMP/scripts"
mkdir -p "$DIR"
HELPER="$DIR/bugbot-tier-excluded.sh"
cp "$REPO_ROOT/.claude/scripts/bugbot-tier-excluded.sh" "$HELPER"
chmod +x "$HELPER"
cat > "$DIR/review-tier.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TIER_CALLS"
if [[ -n "${FIXTURE_TIER_OUT:-}" ]]; then printf '%s\n' "$FIXTURE_TIER_OUT"; fi
exit "${FIXTURE_TIER_RC:-0}"
STUB
export TIER_CALLS="$TMP/tier-calls"

tier_json() { printf '{"policy":"present","gate":"%s","tier":"t","source":"base:main","error":null,"matches":[]}' "$1"; }

STDOUT=""; STDERR=""; RC=0
run() { # <resolver stdout> <resolver rc> -- <helper args...>
  export FIXTURE_TIER_OUT="$1" FIXTURE_TIER_RC="$2"
  shift 2
  : > "$TIER_CALLS"
  STDOUT="$(bash "$HELPER" "$@" 2>"$TMP/err")"; RC=$?
  STDERR="$(cat "$TMP/err")"
}

for gate in ci-only ci+codeant-one-round; do
  echo "== gate $gate -> exit 0, gate on stdout (skip BugBot) =="
  run "$(tier_json "$gate")" 0 42
  check_eq "exit 0" "0" "$RC"
  check_eq "stdout is the gate" "$gate" "$STDOUT"
  check_eq "stderr silent" "" "$STDERR"
done

for gate in full legacy; do
  echo "== gate $gate -> exit 1, gate on stdout (post) =="
  run "$(tier_json "$gate")" 0 42
  check_eq "exit 1" "1" "$RC"
  check_eq "stdout is the gate" "$gate" "$STDOUT"
done

echo "== an absent policy (legacy) as review-tier.sh really prints it -> exit 1 =="
run '{"policy":"absent","gate":"legacy","tier":null,"source":"base:main","error":null,"matches":[]}' 0 42
check_eq "exit 1" "1" "$RC"

# REVIEW_ESCALATION (issue #1807): review-tier.sh appends "escalation".
tier_json_esc() { printf '{"policy":"present","gate":"%s","tier":"t","source":"base:main","error":null,"matches":[],"escalation":%s}' "$1" "$2"; }

for gate in full legacy ci-only ci+codeant-one-round; do
  echo "== gate $gate + escalation off -> exit 0, gate on stdout, one stderr line =="
  run "$(tier_json_esc "$gate" '"off"')" 0 42
  check_eq "exit 0 (skip BugBot)" "0" "$RC"
  check_eq "stdout stays the gate" "$gate" "$STDOUT"
  check_eq "exactly one stderr line" "1" "$(grep -c . <<<"$STDERR" | tr -d ' ')"
  check_eq "…naming escalation off as the reason" "1" "$(grep -c 'escalation off' <<<"$STDERR" | tr -d ' ')"
done

echo "== an ini-only section as review-tier.sh really prints it (legacy + off) -> exit 0 =="
run '{"policy":"absent","gate":"legacy","tier":null,"source":"base:main","error":null,"matches":[],"escalation":"off"}' 0 42
check_eq "exit 0" "0" "$RC"
check_eq "stdout legacy" "legacy" "$STDOUT"

for gate in full legacy; do
  echo "== gate $gate + escalation on -> exit 1 exactly as before =="
  run "$(tier_json_esc "$gate" '"on"')" 0 42
  check_eq "exit 1" "1" "$RC"
  check_eq "stdout is the gate" "$gate" "$STDOUT"
  check_eq "stderr silent" "" "$STDERR"
done

echo "== ci-only + escalation on -> exit 0, stderr silent (the gate alone excludes) =="
run "$(tier_json_esc ci-only '"on"')" 0 42
check_eq "exit 0" "0" "$RC"
check_eq "stderr silent" "" "$STDERR"

echo "== FAILS OPEN — only a literal \"off\" on a resolved answer skips =="
for esc in '"OFF"' '"maybe"' '""' 'null' 'false' '0'; do
  run "$(tier_json_esc full "$esc")" 0 42
  check_eq "full + escalation $esc -> exit 1" "1" "$RC"
done
run "$(tier_json_esc lenient '"off"')" 0 42
check_eq "unrecognised gate + escalation off -> exit 2 (unresolved)" "2" "$RC"
check_eq "unrecognised gate + escalation off -> empty stdout" "" "$STDOUT"
run "$(tier_json_esc full '"off"')" 4 42
check_eq "escalation off printed but resolver exit 4 -> exit 2, not a skip" "2" "$RC"

echo "== forwarding: PR, --repo and --base reach the resolver, plus --json =="
run "$(tier_json full)" 0 42 --repo acme/widgets --base develop
check_eq "resolver arguments" "42 --repo acme/widgets --base develop --json" "$(cat "$TIER_CALLS")"
run "$(tier_json full)" 0 42
check_eq "no --repo/--base when none were given" "42 --json" "$(cat "$TIER_CALLS")"

echo "== FAILS OPEN — every unresolvable answer is exit 2 with nothing on stdout =="
run "" 4 42
check_eq "resolver exit 4 -> exit 2" "2" "$RC"
check_eq "resolver exit 4 -> empty stdout" "" "$STDOUT"
check_eq "resolver exit 4 -> one stderr line" "1" "$(grep -c . <<<"$STDERR" | tr -d ' ')"
run "" 3 42
check_eq "resolver exit 3 (PR not found) -> exit 2" "2" "$RC"
# A resolver that answered on stdout and then exited non-zero is still a failure.
run "$(tier_json ci-only)" 4 42
check_eq "ci-only printed but resolver exit 4 -> exit 2, not a skip" "2" "$RC"
for junk in "" "not json" '["ci-only"]' '{"gate":"lenient"}' '{"gate":null}' '"ci-only"'; do
  run "$junk" 0 42
  check_eq "resolver output '$junk' -> exit 2" "2" "$RC"
  check_eq "resolver output '$junk' -> empty stdout" "" "$STDOUT"
done

echo "== FAILS OPEN — review-tier.sh missing -> exit 2 =="
mv "$DIR/review-tier.sh" "$TMP/review-tier.bak"
run "$(tier_json ci-only)" 0 42
mv "$TMP/review-tier.bak" "$DIR/review-tier.sh"
check_eq "exit 2" "2" "$RC"
check_eq "empty stdout" "" "$STDOUT"

echo "== usage errors -> exit 2, resolver never called =="
# `|`-separated so each case is an explicit argument list, empty included.
for spec in "" "0" "abc" "-1" "42|43" "42|--repo" "42|--base" "42|--bogus"; do
  ARGS=()
  [[ -n "$spec" ]] && IFS='|' read -r -a ARGS <<<"$spec"
  run "$(tier_json ci-only)" 0 ${ARGS[@]+"${ARGS[@]}"}
  check_eq "args '$spec' -> exit 2" "2" "$RC"
  check_eq "args '$spec' -> resolver not called" "" "$(cat "$TIER_CALLS")"
done

echo "== --help =="
HELP_OUT="$(bash "$HELPER" --help 2>"$TMP/help-err")"; RC=$?
check_eq "--help exits 0" "0" "$RC"
check_eq "--help stderr silent" "" "$(cat "$TMP/help-err")"
check_eq "--help documents exit 0" "1" "$(grep -c '^  0  The gate is ci-only' <<<"$HELP_OUT" | tr -d ' ')"
check_eq "--help documents the escalation switch" "1" "$(grep -c 'escalation off (`"escalation":"off"`) on any recognised gate' <<<"$HELP_OUT" | tr -d ' ')"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: bugbot-tier-excluded.sh tests passed"
