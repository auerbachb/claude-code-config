#!/usr/bin/env bash
# Offline tests for model-fleet.sh (issue #770).
# catalog: tests — Tests for `model-fleet.sh`
#
# Fully hermetic: every case points the resolver at a temp fixture via --file,
# so nothing here depends on what .claude/model-fleet.json currently says. The
# one exception is the "real repo file resolves" case at the end, which is the
# point: the committed fleet file must actually be valid.
#
# The fleet-change simulation is the load-bearing case (issue #770 Test Plan
# item 5): swapping top_tier in a single file must change what every consumer
# resolves, with no other edit anywhere.
#
# Run from repo root: bash .claude/scripts/tests/model-fleet.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/model-fleet.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
# Keep the usage-log append out of the real ~/.claude.
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

check_eq() {  # desc, expected, actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# desc, expected_rc, expected_stderr_regex, args...
check_fails() {
  local desc="$1" want_rc="$2" want_re="$3"; shift 3
  local out rc=0
  out=$(bash "$SCRIPT" "$@" 2>&1) || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    fail "$desc (expected rc $want_rc, got $rc)"
    return
  fi
  # `--` before the pattern: several expected messages start with `--flag`,
  # which grep would otherwise parse as its own option.
  if ! printf '%s' "$out" | grep -qE -- "$want_re"; then
    fail "$desc (rc $rc as expected, but message did not match /$want_re/)"
    return
  fi
  pass "$desc"
}

write_fixture() {  # path, json
  printf '%s\n' "$2" > "$1"
}

# ---- fixtures ---------------------------------------------------------------

GOOD="$TMP/good.json"
write_fixture "$GOOD" '{
  "verified": "2026-07-28",
  "top_tier": "model-a",
  "fleet": [
    {"id": "model-a", "display": "Model A", "alias": null},
    {"id": "model-b", "display": "Model B", "alias": "b"}
  ]
}'

# Same shape, different top tier — the simulated fleet change.
CHANGED="$TMP/changed.json"
write_fixture "$CHANGED" '{
  "verified": "2026-09-01",
  "top_tier": "model-z",
  "fleet": [
    {"id": "model-z", "display": "Model Z", "alias": null},
    {"id": "model-a", "display": "Model A", "alias": null}
  ]
}'

write_fixture "$TMP/malformed.json" '{ "top_tier": "model-a", '
write_fixture "$TMP/no-top.json"    '{"fleet":[{"id":"model-a","display":"A"}]}'
write_fixture "$TMP/empty-top.json" '{"top_tier":"   ","fleet":[{"id":"model-a","display":"A"}]}'
write_fixture "$TMP/orphan-top.json" '{"top_tier":"model-q","fleet":[{"id":"model-a","display":"A"}]}'
write_fixture "$TMP/no-fleet.json"  '{"top_tier":"model-a"}'
write_fixture "$TMP/empty-fleet.json" '{"top_tier":"model-a","fleet":[]}'
write_fixture "$TMP/no-id.json"     '{"top_tier":"model-a","fleet":[{"display":"A"}]}'
write_fixture "$TMP/not-object.json" '["model-a"]'
# Non-string values must be rejected, not coerced: str(True) is "True", which
# would sail through every downstream check as a plausible model name.
write_fixture "$TMP/bool-id.json"      '{"top_tier":"model-a","fleet":[{"id":true,"display":"A"}]}'
write_fixture "$TMP/bool-top.json"     '{"top_tier":true,"fleet":[{"id":"model-a","display":"A"}]}'
write_fixture "$TMP/num-id.json"       '{"top_tier":"model-a","fleet":[{"id":5,"display":"A"}]}'
write_fixture "$TMP/list-display.json" '{"top_tier":"model-a","fleet":[{"id":"model-a","display":["A"]}]}'
# Internal-consistency fixtures: a duplicated id, and a top_tier that is not the
# strongest-first head of fleet[].
write_fixture "$TMP/dup-id.json" '{"top_tier":"model-a","fleet":[{"id":"model-a","display":"A"},{"id":"model-a","display":"A2"}]}'
write_fixture "$TMP/top-not-first.json" '{"top_tier":"model-b","fleet":[{"id":"model-a","display":"A"},{"id":"model-b","display":"B"}]}'
# display omitted — the id is the documented fallback label.
write_fixture "$TMP/no-display.json" '{"top_tier":"model-a","fleet":[{"id":"model-a"}]}'

# ---- happy path -------------------------------------------------------------

check_eq "--top-tier returns the top tier id" \
  "model-a" "$(bash "$SCRIPT" --file "$GOOD" --top-tier)"

check_eq "no mode flag defaults to --top-tier" \
  "model-a" "$(bash "$SCRIPT" --file "$GOOD")"

check_eq "--top-tier-display returns the human label" \
  "Model A" "$(bash "$SCRIPT" --file "$GOOD" --top-tier-display)"

check_eq "--list emits every entry, strongest first" \
  "model-a	Model A
model-b	Model B" "$(bash "$SCRIPT" --file "$GOOD" --list)"

check_eq "--json round-trips the document" \
  "model-a" "$(bash "$SCRIPT" --file "$GOOD" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["top_tier"])')"

check_eq "--file= form is accepted" \
  "model-a" "$(bash "$SCRIPT" "--file=$GOOD")"

check_eq "CLAUDE_MODEL_FLEET_FILE env var is honored" \
  "model-a" "$(CLAUDE_MODEL_FLEET_FILE="$GOOD" bash "$SCRIPT" --top-tier)"

check_eq "--file flag wins over the env var" \
  "model-z" "$(CLAUDE_MODEL_FLEET_FILE="$GOOD" bash "$SCRIPT" --file "$CHANGED" --top-tier)"

check_eq "missing display falls back to the id" \
  "model-a" "$(bash "$SCRIPT" --file "$TMP/no-display.json" --top-tier-display)"

check_eq "--help exits 0" \
  "0" "$(bash "$SCRIPT" --help >/dev/null 2>&1; echo $?)"

# Exit code alone would accept a help block that printed nothing useful, so
# assert the documented flags actually appear. The header uses `#` continuation
# lines throughout, so the awk extractor (which stops at the first *empty* line)
# reaches the end of the block -- this test is what keeps that true if the
# header ever gains a real blank line.
HELP_OUT="$(bash "$SCRIPT" --help 2>/dev/null)"
for flag in --top-tier --top-tier-display --list --json --file; do
  case "$HELP_OUT" in
    *"$flag"*) pass "--help documents $flag" ;;
    *)         fail "--help does not mention $flag" ;;
  esac
done
case "$HELP_OUT" in
  *"EXIT STATUS"*) pass "--help includes the EXIT STATUS section (block not truncated early)" ;;
  *)               fail "--help truncated before EXIT STATUS" ;;
esac

# ---- fleet-change simulation (Test Plan item 5) -----------------------------
# The whole contract in one assertion: one file changed, every consumer moves.
# Nothing else in the repo is touched between these two calls.

BEFORE_ID="$(bash "$SCRIPT" --file "$GOOD" --top-tier)"
BEFORE_DISPLAY="$(bash "$SCRIPT" --file "$GOOD" --top-tier-display)"
AFTER_ID="$(bash "$SCRIPT" --file "$CHANGED" --top-tier)"
AFTER_DISPLAY="$(bash "$SCRIPT" --file "$CHANGED" --top-tier-display)"

check_eq "fleet change: id before"      "model-a" "$BEFORE_ID"
check_eq "fleet change: id after"       "model-z" "$AFTER_ID"
check_eq "fleet change: display before" "Model A" "$BEFORE_DISPLAY"
check_eq "fleet change: display after"  "Model Z" "$AFTER_DISPLAY"

# In-place edit of one file (rather than two fixtures) — closest to what a real
# fleet change looks like.
INPLACE="$TMP/inplace.json"
cp "$GOOD" "$INPLACE"
check_eq "in-place fleet edit: before" "model-a" "$(bash "$SCRIPT" --file "$INPLACE")"
cp "$CHANGED" "$INPLACE"
check_eq "in-place fleet edit: after"  "model-z" "$(bash "$SCRIPT" --file "$INPLACE")"

# ---- fail-closed data errors (exit 1, never a fallback model) ---------------

check_fails "missing file exits 1" 1 \
  "fleet file not found" --file "$TMP/does-not-exist.json"

check_fails "malformed JSON exits 1" 1 \
  "not valid JSON" --file "$TMP/malformed.json"

check_fails "missing top_tier exits 1" 1 \
  "missing or empty 'top_tier'" --file "$TMP/no-top.json"

check_fails "whitespace-only top_tier exits 1" 1 \
  "missing or empty 'top_tier'" --file "$TMP/empty-top.json"

check_fails "top_tier absent from fleet exits 1" 1 \
  "not a member of fleet" --file "$TMP/orphan-top.json"

check_fails "missing fleet array exits 1" 1 \
  "missing or empty 'fleet'" --file "$TMP/no-fleet.json"

check_fails "empty fleet array exits 1" 1 \
  "missing or empty 'fleet'" --file "$TMP/empty-fleet.json"

check_fails "fleet entry without id exits 1" 1 \
  "missing 'id'" --file "$TMP/no-id.json"

check_fails "top-level non-object exits 1" 1 \
  "must contain a JSON object" --file "$TMP/not-object.json"

check_fails "boolean id is rejected, not coerced" 1 \
  "fleet\[0\].id must be a string, got bool" --file "$TMP/bool-id.json"

check_fails "boolean top_tier is rejected, not coerced" 1 \
  "top_tier must be a string, got bool" --file "$TMP/bool-top.json"

check_fails "numeric id is rejected, not coerced" 1 \
  "fleet\[0\].id must be a string, got int" --file "$TMP/num-id.json"

check_fails "non-string display is rejected" 1 \
  "fleet\[0\].display must be a string, got list" --file "$TMP/list-display.json"

check_fails "duplicate fleet id exits 1" 1 \
  "duplicates an earlier id" --file "$TMP/dup-id.json"

check_fails "top_tier not first in fleet exits 1" 1 \
  "not the first fleet\[\] entry" --file "$TMP/top-not-first.json"

# The committed file must satisfy the ordering invariant too, not just parse.
check_eq "committed fleet lists top_tier first" \
  "$(bash "$SCRIPT" --top-tier)" \
  "$(bash "$SCRIPT" --list | head -1 | cut -f1)"

# No failure path may ever print a model name on stdout — a caller reading
# stdout must get nothing rather than a stale guess.
for bad in malformed.json no-top.json orphan-top.json no-fleet.json; do
  STDOUT_ONLY="$(bash "$SCRIPT" --file "$TMP/$bad" 2>/dev/null)"
  check_eq "no stdout leakage on failure ($bad)" "" "$STDOUT_ONLY"
done

# ---- usage errors (exit 2) --------------------------------------------------

check_fails "unknown flag exits 2" 2 "unknown flag" --nope
check_fails "positional arg exits 2" 2 "unexpected positional argument" stray
check_fails "--file without a value exits 2" 2 "--file requires a value" --file
check_fails "conflicting mode flags exit 2" 2 "conflicting mode flags" --list --json --file "$GOOD"

# ---- the committed fleet file must itself be valid --------------------------

REAL_TOP="$(bash "$SCRIPT" --top-tier 2>/dev/null)"
if [ -n "$REAL_TOP" ]; then
  pass "committed .claude/model-fleet.json resolves (top_tier=$REAL_TOP)"
else
  fail "committed .claude/model-fleet.json does not resolve"
fi

REAL_DISPLAY="$(bash "$SCRIPT" --top-tier-display 2>/dev/null)"
if [ -n "$REAL_DISPLAY" ]; then
  pass "committed fleet file has a display name (top_tier_display=$REAL_DISPLAY)"
else
  fail "committed fleet file has no display name for top_tier"
fi

# Resolution must not depend on the caller's cwd — consumers run from
# worktrees and subdirectories.
CWD_TOP="$(cd "$TMP" && bash "$SCRIPT" --top-tier 2>/dev/null)"
check_eq "resolves the same from an unrelated cwd" "$REAL_TOP" "$CWD_TOP"

echo "---"
echo "model-fleet.test: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
