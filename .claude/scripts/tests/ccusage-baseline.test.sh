#!/usr/bin/env bash
# Offline tests for ccusage-baseline.sh (issue #781).
# catalog: tests — JSON shape, human-readable output, ccusage-absent exit 3, empty-blocks exit 1, usage errors, and --help for `ccusage-baseline.sh` (#781)
#
# Fully hermetic: stubs the `ccusage` binary on PATH; no network access, no
# real ccusage install required. Follows the *.test.sh stubbing pattern used
# by churn-hotspots.test.sh and companion tests in this directory.
#
# Run from repo root: bash .claude/scripts/tests/ccusage-baseline.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/ccusage-baseline.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

check_eq() {  # desc, expected, actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

check_jq() {  # desc, json, jq boolean expr
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then pass "$1"; else fail "$1 (jq: $3)"; fi
}

check_contains() {  # desc, haystack, needle
  if grep -qF "$3" <<<"$2"; then pass "$1"; else fail "$1 (missing '$3' in output)"; fi
}

# ---- ccusage stub -------------------------------------------------------------
# Minimal stub that honours:
#   --version              → print version line
#   blocks --json          → print BLOCKS_JSON fixture
#   blocks --json --recent → same fixture (recent flag is transparent in stub)
# Any other invocation exits 1 loudly.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

# Shared fixture: one active block + one completed block
FIXTURE_BLOCKS="$TMP/blocks.json"
cat > "$FIXTURE_BLOCKS" <<'EOF'
{
  "blocks": [
    {
      "id": "2026-08-09T21:00:00.000Z",
      "startTime": "2026-08-09T21:00:00.000Z",
      "endTime": "2026-08-10T02:00:00.000Z",
      "actualEndTime": "2026-08-10T01:45:00.000Z",
      "isActive": false,
      "isGap": false,
      "costUSD": 42.5,
      "totalTokens": 5000000,
      "entries": 120,
      "burnRate": null,
      "projection": null,
      "models": ["claude-sonnet-4-6", "claude-opus-5"],
      "tokenCounts": {
        "cacheCreationInputTokens": 100000,
        "cacheReadInputTokens": 4800000,
        "inputTokens": 1000,
        "outputTokens": 99000
      }
    },
    {
      "id": "2026-08-10T14:00:00.000Z",
      "startTime": "2026-08-10T14:00:00.000Z",
      "endTime": "2026-08-10T19:00:00.000Z",
      "actualEndTime": null,
      "isActive": true,
      "isGap": false,
      "costUSD": 18.25,
      "totalTokens": 2000000,
      "entries": 55,
      "burnRate": 12.5,
      "projection": 65.0,
      "models": ["claude-opus-5"],
      "tokenCounts": {
        "cacheCreationInputTokens": 50000,
        "cacheReadInputTokens": 1900000,
        "inputTokens": 500,
        "outputTokens": 49500
      }
    }
  ]
}
EOF

cat > "$STUB_BIN/ccusage" <<STUB
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--version"*)
    printf 'ccusage 20.0.19\n'
    ;;
  *"blocks --json"*)
    cat "$FIXTURE_BLOCKS"
    ;;
  *)
    printf 'ccusage stub: unhandled args: %s\n' "\$args" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$STUB_BIN/ccusage"
export PATH="$STUB_BIN:$PATH"

# Helper: run the script with given args; sets OUT and RC
run() {
  OUT=$(bash "$SCRIPT" "$@" 2>/dev/null)
  RC=$?
}

# =============================================================================
# Scenario 1 — JSON output: shape, fields, and values
# =============================================================================
run --json
check_eq "1a: exits 0 on success" "0" "$RC"
check_jq "1b: top-level key ccusage_version present" "$OUT" 'has("ccusage_version")'
check_jq "1c: generated_at is present" "$OUT" 'has("generated_at")'
check_jq "1d: active_block is present and non-null" "$OUT" '.active_block != null'
check_jq "1e: active_block.isActive is true" "$OUT" '.active_block.isActive == true'
check_jq "1f: recent_blocks is an array" "$OUT" '.recent_blocks | type == "array"'
check_jq "1g: recent_total_cost_usd is a number" "$OUT" '.recent_total_cost_usd | type == "number"'
check_jq "1h: recent_total_tokens is a number" "$OUT" '.recent_total_tokens | type == "number"'
check_jq "1i: total cost == sum of both blocks (42.5 + 18.25 = 60.75)" "$OUT" \
  '.recent_total_cost_usd == 60.75'
check_jq "1j: total tokens == sum (5000000 + 2000000 = 7000000)" "$OUT" \
  '.recent_total_tokens == 7000000'
check_jq "1k: recent_blocks contains the non-active block" "$OUT" \
  '[.recent_blocks[] | select(.isActive == false)] | length == 1'
check_jq "1l: ccusage_version is non-empty string" "$OUT" \
  '(.ccusage_version | type) == "string" and (.ccusage_version | length) > 0'

# =============================================================================
# Scenario 2 — Human-readable default output
# =============================================================================
run
check_eq "2a: exits 0 in human-readable mode" "0" "$RC"
check_contains "2b: output contains 'ccusage baseline' header" "$OUT" "ccusage baseline"
check_contains "2c: output contains billing block count" "$OUT" "Billing blocks found: 2"
check_contains "2d: output shows Active block section" "$OUT" "Active block"
check_contains "2e: output shows Window total section" "$OUT" "Window total"
check_contains "2f: output references the /context manual capture doc" "$OUT" "token-measurement-baseline-2026-08.md"

# =============================================================================
# Scenario 3 — --recent flag passes through without error
# =============================================================================
run --json --recent
check_eq "3a: --recent exits 0" "0" "$RC"
check_jq "3b: JSON shape is intact with --recent" "$OUT" 'has("ccusage_version") and has("active_block")'

# =============================================================================
# Scenario 4 — ccusage missing: graceful degradation with exit 3
# =============================================================================
# CCUSAGE_BIN="" explicitly marks ccusage as absent (bypasses all detection
# paths including hardcoded /opt/homebrew/bin/npx checks). This is the
# testability hook documented in the script header.
OUT_MISSING=$(CCUSAGE_BIN="" bash "$SCRIPT" --json 2>&1)
RC_MISSING=$?

check_eq "4a: exits 3 when CCUSAGE_BIN='' (absent)" "3" "$RC_MISSING"
check_contains "4b: error message mentions ccusage not installed" "$OUT_MISSING" "ccusage is not installed"
check_contains "4c: error message mentions manual capture doc" "$OUT_MISSING" "token-measurement-baseline-2026-08.md"

# =============================================================================
# Scenario 5 — empty blocks response: exit 1 (no data)
# =============================================================================
EMPTY_FIXTURE="$TMP/empty_blocks.json"
cat > "$EMPTY_FIXTURE" <<'EOF'
{"blocks":[]}
EOF
cat > "$STUB_BIN/ccusage" <<STUB
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--version"*) printf 'ccusage 20.0.19\n' ;;
  *"blocks --json"*) cat "$EMPTY_FIXTURE" ;;
  *) printf 'stub: unhandled: %s\n' "\$args" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/ccusage"

run --json
check_eq "5a: exits 1 when blocks array is empty" "1" "$RC"

# Restore full stub
cat > "$STUB_BIN/ccusage" <<STUB
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--version"*)     printf 'ccusage 20.0.19\n' ;;
  *"blocks --json"*) cat "$FIXTURE_BLOCKS" ;;
  *) printf 'stub: unhandled: %s\n' "\$args" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/ccusage"

# =============================================================================
# Scenario 6 — usage errors
# =============================================================================
OUT_ERR=$(bash "$SCRIPT" --bogus 2>&1); RC_ERR=$?
check_eq "6a: unknown flag exits 2" "2" "$RC_ERR"

OUT_CONFLICT=$(bash "$SCRIPT" --recent --since 20260801 2>&1); RC_CONFLICT=$?
check_eq "6b: --recent + --since exits 2 (mutually exclusive)" "2" "$RC_CONFLICT"

OUT_INJECT=$(bash "$SCRIPT" --since '20260801; rm -rf /' 2>&1); RC_INJECT=$?
check_eq "6c: --since with shell metacharacters exits 2 (injection guard)" "2" "$RC_INJECT"
check_contains "6d: injection guard error mentions YYYYMMDD format" "$OUT_INJECT" "YYYYMMDD"

# =============================================================================
# Scenario 7 — --help exits 0
# =============================================================================
OUT_HELP=$(bash "$SCRIPT" --help 2>&1); RC_HELP=$?
check_eq "7a: --help exits 0" "0" "$RC_HELP"
check_contains "7b: --help output contains USAGE" "$OUT_HELP" "USAGE"

# =============================================================================
echo
echo "ccusage-baseline.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
