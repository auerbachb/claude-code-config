#!/usr/bin/env bash
# Offline tests for split-thresholds.sh (issue #1680).
# catalog: tests — Tests for `split-thresholds.sh`: the env → pm-config.md → default cascade per knob, reject-and-fall-back (never clamp) on out-of-range and non-integer values, the incoherent-pair rule that resets BOTH knobs, exact-key config matching, and the output modes
#
# The script is run against a SANDBOX repo — a temp directory carrying its own
# .claude/pm-config.md, with stub repo-root.sh and the real pm-config-get.sh
# beside a copy of the script under test. That is what makes the config tier
# reachable at all: the production repo-root.sh always resolves the MAIN
# worktree, so a test running from a git worktree would otherwise only ever
# exercise the env and default tiers and would pass without the config branch
# existing.
#
# Run from anywhere: bash .claude/scripts/tests/split-thresholds.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "cannot resolve repo root" >&2; exit 1; }
SRC="$REPO_ROOT/.claude/scripts/split-thresholds.sh"
PM_CONFIG_GET="$REPO_ROOT/.claude/scripts/pm-config-get.sh"

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

# ---- sandbox ----------------------------------------------------------------
SANDBOX="$TMP/sandbox"
BIN="$SANDBOX/.claude/scripts"
mkdir -p "$BIN"
cp "$SRC" "$BIN/split-thresholds.sh"
cp "$PM_CONFIG_GET" "$BIN/pm-config-get.sh"
chmod +x "$BIN/split-thresholds.sh" "$BIN/pm-config-get.sh"
# Stub repo-root.sh: points at the sandbox so the config tier reads the fixture
# below rather than this checkout's own pm-config.md.
cat > "$BIN/repo-root.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$SANDBOX"
STUB
chmod +x "$BIN/repo-root.sh"

SUT="$BIN/split-thresholds.sh"

write_config() {  # write_config <ini body lines...>
  mkdir -p "$SANDBOX/.claude"
  {
    printf '# Sandbox PM config\n\n## Budget\n\n```ini\n'
    printf '%s\n' "$@"
    printf '```\n\n## Team\n\nnobody\n'
  } > "$SANDBOX/.claude/pm-config.md"
}

run_sut() {  # run_sut <args...> — stdout in OUT, stderr in ERR, status in RC
  OUT="$("$SUT" "$@" 2>"$TMP/stderr")"
  RC=$?
  ERR="$(cat "$TMP/stderr")"
}

# =============================================================================
# 1. No config, no env — the shipped defaults, and every output mode.
# =============================================================================
rm -f "$SANDBOX/.claude/pm-config.md"
run_sut
check_eq "1 no config exits 0" "0" "$RC"
check_eq "1 plain mode prints both knobs" "SPLIT_OVER_MIN=180 INCREMENT_BOUND_MIN=120" "$OUT"
check_eq "1 no stderr when nothing is misconfigured" "" "$ERR"

run_sut --split-over
check_eq "1 --split-over prints only the threshold" "180" "$OUT"
run_sut --increment-bound
check_eq "1 --increment-bound prints only the bound" "120" "$OUT"
run_sut --json
check_eq "1 --json reports both sources as default" \
  "default default" \
  "$(printf '%s' "$OUT" | jq -r '"\(.split_over_source) \(.increment_bound_source)"')"

# =============================================================================
# 2. The config tier — and that it is genuinely reached.
#
# Case 2a uses values NO other tier would produce, so a pass cannot come from
# the defaults leaking through: 240/60 is neither knob's default.
# =============================================================================
write_config 'SPLIT_OVER_MIN = 240' 'INCREMENT_BOUND_MIN = 60'
run_sut --json
check_eq "2a config values are read" "240 60" \
  "$(printf '%s' "$OUT" | jq -r '"\(.split_over_min) \(.increment_bound_min)"')"
check_eq "2a both sources report config" "config config" \
  "$(printf '%s' "$OUT" | jq -r '"\(.split_over_source) \(.increment_bound_source)"')"

# 2b. Exact-key matching: a longer key that merely CONTAINS the knob name must
# not be read as the knob. This is what an interpolated-regex match would get
# wrong. The value has to be DISCRIMINATING: 300 is inside [30, 960] and is not
# the default, so a substring match would resolve to 300 and fail this case. An
# out-of-range value (999) would be rejected on its way through and land on 180
# anyway — the assertion would pass without the exact-key rule existing at all.
write_config 'MY_SPLIT_OVER_MIN = 300' 'INCREMENT_BOUND_MIN = 60'
run_sut --json
check_eq "2b a key containing the knob name is not the knob" "180" \
  "$(printf '%s' "$OUT" | jq -r '.split_over_min')"
check_eq "2b that knob falls back to default" "default" \
  "$(printf '%s' "$OUT" | jq -r '.split_over_source')"

# 2c. A commented-out placeholder is not an active setting.
write_config '# SPLIT_OVER_MIN = 600' 'INCREMENT_BOUND_MIN = 60'
run_sut --json
check_eq "2c commented knob is ignored" "180" \
  "$(printf '%s' "$OUT" | jq -r '.split_over_min')"

# 2d. An assignment with an EMPTY value is a misconfiguration to report, not an
# absent knob to skip silently.
write_config 'SPLIT_OVER_MIN =' 'INCREMENT_BOUND_MIN = 60'
run_sut --json
check_eq "2d empty value falls back to default" "180" \
  "$(printf '%s' "$OUT" | jq -r '.split_over_min')"
check_contains "2d empty value is reported on stderr" "not a positive integer" "$ERR"

# =============================================================================
# 3. Reject and fall back — never clamp.
#
# Each case uses a value whose CLAMPED result differs from the default, so a
# clamping implementation fails here instead of passing by coincidence:
# 10 clamps to the 30 minimum, 5000 clamps to the 960 maximum; the contract
# says both resolve to 180.
# =============================================================================
rm -f "$SANDBOX/.claude/pm-config.md"
CLAUDE_SPLIT_OVER_MIN=10 run_sut --split-over
check_eq "3 below-range env value falls back to the DEFAULT, not the minimum" "180" "$OUT"
check_contains "3 below-range value names the range" "outside [30, 960]" "$ERR"

CLAUDE_SPLIT_OVER_MIN=5000 run_sut --split-over
check_eq "3 above-range env value falls back to the DEFAULT, not the maximum" "180" "$OUT"

CLAUDE_SPLIT_OVER_MIN=abc run_sut --split-over
check_eq "3 non-integer env value falls back to the default" "180" "$OUT"
check_contains "3 non-integer value is reported" "not a positive integer" "$ERR"

CLAUDE_SPLIT_OVER_MIN=0240 run_sut --split-over
check_eq "3 leading-zero value is decimal, never octal" "240" "$OUT"

# An overlong digit string must be turned away BEFORE the arithmetic. It is all
# digits, so the "not a positive integer" branch does not catch it, and bash
# arithmetic on it is a fatal error — the resolution would abort rather than
# decline, which is the one outcome this cascade must never produce.
CLAUDE_SPLIT_OVER_MIN=1234567890123 run_sut --split-over
check_eq "3 overlong digit string exits 0 rather than aborting" "0" "$RC"
check_eq "3 overlong digit string falls back to the default" "180" "$OUT"
check_contains "3 overlong digit string is reported as such" "too many digits" "$ERR"

# env beats config
write_config 'SPLIT_OVER_MIN = 240'
CLAUDE_SPLIT_OVER_MIN=300 run_sut --json
check_eq "3 env wins over config" "300 env" \
  "$(printf '%s' "$OUT" | jq -r '"\(.split_over_min) \(.split_over_source)"')"

# A rejected env override falls back to the DEFAULT, never onward to config —
# a typo must not silently resolve to some other configured value. 240 is what
# a fall-through would produce, and 180 is the contract.
CLAUDE_SPLIT_OVER_MIN=nonsense run_sut --split-over
check_eq "3 rejected env does not fall through to config" "180" "$OUT"

# =============================================================================
# 4. The incoherent pair resets BOTH knobs.
#
# An increment bound at or above the split line makes every slice its own split
# trigger. 200 >= 180 is the equality-adjacent case; 180 == 180 is the exact
# boundary, which must also be rejected (the slice bound must be strictly below).
# =============================================================================
rm -f "$SANDBOX/.claude/pm-config.md"
CLAUDE_INCREMENT_BOUND_MIN=200 run_sut --json
check_eq "4 an over-threshold slice bound resets both knobs" "180 120" \
  "$(printf '%s' "$OUT" | jq -r '"\(.split_over_min) \(.increment_bound_min)"')"
check_eq "4 both sources report default after the reset" "default default" \
  "$(printf '%s' "$OUT" | jq -r '"\(.split_over_source) \(.increment_bound_source)"')"
check_contains "4 the incoherent pair is reported" "must be below SPLIT_OVER_MIN" "$ERR"

CLAUDE_INCREMENT_BOUND_MIN=180 run_sut --increment-bound
check_eq "4 a slice bound EQUAL to the split line is also incoherent" "120" "$OUT"

# A coherent custom pair survives untouched — without this the case above could
# pass for a checker that resets on every override.
CLAUDE_SPLIT_OVER_MIN=300 CLAUDE_INCREMENT_BOUND_MIN=200 run_sut --json
check_eq "4 a coherent custom pair is preserved" "300 200" \
  "$(printf '%s' "$OUT" | jq -r '"\(.split_over_min) \(.increment_bound_min)"')"

# =============================================================================
# 5. Usage contract.
# =============================================================================
run_sut --bogus
check_eq "5 unknown flag exits 2" "2" "$RC"
check_contains "5 unknown flag names itself" "--bogus" "$ERR"

run_sut --split-over --json
check_eq "5 conflicting output modes exit 2" "2" "$RC"

run_sut --path
check_eq "5 --path with no value exits 2" "2" "$RC"

# Positive --path coverage: a SECOND repo, with values neither the defaults nor
# the first sandbox's, reached only by passing its path through. The stub above
# ignores its argument, so this case gets one that honours it — otherwise the
# assertion would prove only that the flag parses. The directory name carries a
# SPACE deliberately: an unquoted argument expansion word-splits there and
# resolves the wrong root.
OTHER="$TMP/other repo"
mkdir -p "$OTHER/.claude"
{
  printf '# Other repo\n\n## Budget\n\n```ini\n'
  printf 'SPLIT_OVER_MIN = 420\nINCREMENT_BOUND_MIN = 210\n'
  printf '```\n'
} > "$OTHER/.claude/pm-config.md"
# Unquoted heredoc so $SANDBOX is baked in at write time. The no-argument
# fallback stays the SANDBOX, NOT $PWD: this stub outlives the --path cases and
# is what Sections 5 and 6 resolve through, so a $PWD fallback would silently
# point them at the caller's own checkout — where a repo that had retuned
# SPLIT_OVER_MIN would make "HOME-less run still resolves the default" fail, and
# a repo sitting at 180 would make it pass for the wrong reason.
cat > "$BIN/repo-root.sh" <<STUB
#!/usr/bin/env bash
# Honours its argument, the way the real repo-root.sh honours a starting path.
if [[ \$# -ge 1 && -n "\$1" ]]; then printf '%s\n' "\$1"; else printf '%s\n' "$SANDBOX"; fi
STUB
chmod +x "$BIN/repo-root.sh"
run_sut --json --path "$OTHER"
check_eq "5 --path reads the named repo's knobs" "420 210" \
  "$(printf '%s' "$OUT" | jq -r '"\(.split_over_min) \(.increment_bound_min)"')"
check_eq "5 --path values are sourced from that config" "config config" \
  "$(printf '%s' "$OUT" | jq -r '"\(.split_over_source) \(.increment_bound_source)"')"

run_sut --help
check_eq "5 --help exits 0" "0" "$RC"
check_eq "5 --help writes nothing to stderr" "" "$ERR"
check_contains "5 --help carries the cascade" "RESOLUTION CASCADE" "$OUT"

# =============================================================================
# 6. The unset-HOME contract (issue #1434).
#
# This script needs no home directory for any of its work, so a HOME-less run
# must answer normally rather than aborting on the telemetry append's ${HOME}
# expansion under `set -u`. Asserting the STDERR is empty is what makes this
# discriminating: an unguarded expansion aborts with an "unbound variable"
# trace, which a status-only check on a defaulting shell could miss.
# =============================================================================
OUT="$(env -u HOME "$SUT" --split-over 2>"$TMP/stderr")"; RC=$?; ERR="$(cat "$TMP/stderr")"
check_eq "6 HOME-less run exits 0" "0" "$RC"
check_eq "6 HOME-less run still resolves the default" "180" "$OUT"
check_eq "6 HOME-less run writes nothing to stderr" "" "$ERR"

OUT="$(env -u HOME "$SUT" --help 2>"$TMP/stderr")"; RC=$?; ERR="$(cat "$TMP/stderr")"
check_eq "6 HOME-less --help exits 0" "0" "$RC"
check_eq "6 HOME-less --help writes nothing to stderr" "" "$ERR"

echo
echo "split-thresholds.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
