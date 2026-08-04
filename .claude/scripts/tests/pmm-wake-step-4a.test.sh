#!/usr/bin/env bash
# Regression test for `/pr-monitor-and-manage-wake` Step 4a — the `--auto-check`
# fleet scan (issues #871, #887, #888).
#
# WHAT IS UNDER TEST
#   The REAL fenced bash in
#   `.claude/skills/pr-monitor-and-manage-wake/SKILL.md`, pulled out at run time
#   by `lib/skill-bash.sh` through the `<!-- test-anchor: … -->` markers, then
#   executed against a stubbed `gh` and a real `session-state.sh` copy driven by
#   a temp `$HOME`. Nothing here is a transcription of the skill: edit the skill
#   and this suite runs the edit. Same idea as
#   `pr-state-classify.test.sh`, which executes the canonical
#   `lib/pr-state-classify.jq` file directly so "the two can never drift apart".
#
#   Step 4a is two adjacent fenced blocks (scan+guards, then compare). The suite
#   concatenates them in document order — that pair is the runnable unit.
#
# WHY (issue #871)
#   `--auto-check` compares the current fleet against `.pmm.fleet_at_pause` and
#   resumes a paused PR-fleet monitor when they differ. Pre-#887, any *failure*
#   in that comparison — `gh` erroring, empty or non-JSON output, an unreadable
#   or malformed saved snapshot — left one side empty, which read as "fleet
#   changed" and kicked off a full monitor run the user never asked for. The fix
#   is fail-closed: a scan that cannot PROVE a change keeps the pause marker and
#   the re-scan, and exits non-zero. That fix shipped in PR #887 with no
#   committed test, so a prose cleanup could silently re-open it. This is that
#   test.
#
# THE THREE OBSERVABLE OUTCOMES
#   scan failed → non-zero exit + "fleet scan failed" on stderr (pause and
#                 re-scan both kept; never reaches the comparison)
#   unchanged   → exit 0 + "[auto-check] Fleet unchanged — re-scan continues."
#                 (no-op; re-scan kept)
#   changed     → exit 0 with no "Fleet unchanged" line (falls through to
#                 Step 4b: cancel the re-scan and resume)
#
#   Every case additionally asserts that the saved state survived the block
#   byte-for-byte. "Pause marker and re-scan kept" is something the fail-closed
#   path *prints*; without reading the state file back, a Step 4a that cleared
#   `.pmm.paused_at` would print it just as convincingly. Clearing the marker is
#   Step 4b's job and Step 4b is outside these anchors, so the invariant holds
#   on the changed path too.
#
# DISCRIMINATION CONTROL (Bug6a/Bug6b convention, but executed rather than
# asserted in a comment)
#   A regression suite that passes against both the buggy and the fixed code is
#   rubber-stamping. So the same twelve scenarios are replayed against the
#   pre-#887 block, kept verbatim in
#   `fixtures/pmm-wake-step-4a-pre887.md` (frozen snapshot of commit `87c7434`),
#   and the suite FAILS unless at least 8 of the first 10 cases come out
#   differently there — the ratio PR #887 observed with its scratch harness. The
#   fixture is committed rather than read from `git show` because CI checks out
#   shallow. Its comparison half is held byte-identical to the live one (checked
#   below), so every recorded deviation is attributable to the missing guards.
#
# Requires: bash 3.2+ (macOS system bash — no mapfile/readarray, no associative
# arrays), jq, awk. Offline: no gh, no git, no network.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/scripts/tests/lib/skill-bash.sh
. "$TEST_DIR/lib/skill-bash.sh"

SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILL_MD="$SCRIPTS_DIR/../skills/pr-monitor-and-manage-wake/SKILL.md"
PRE887_MD="$TEST_DIR/fixtures/pmm-wake-step-4a-pre887.md"

PASS=0
FAIL=0
pass() { echo "ok   — $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL — $1" >&2; FAIL=$((FAIL + 1)); }

die() { echo "FATAL: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Extract the live Step 4a blocks. A failure here is fatal, not a soft failure:
# a suite that runs zero lines of skill bash must never report green.
# ---------------------------------------------------------------------------
LIVE_SCAN="$(extract_skill_bash "$SKILL_MD" pmm-wake-step-4a-scan)" \
  || die "could not extract pmm-wake-step-4a-scan from $SKILL_MD"
LIVE_COMPARE="$(extract_skill_bash "$SKILL_MD" pmm-wake-step-4a-compare)" \
  || die "could not extract pmm-wake-step-4a-compare from $SKILL_MD"
[ -n "$LIVE_SCAN" ] || die "extracted scan block is empty"
[ -n "$LIVE_COMPARE" ] || die "extracted compare block is empty"

PRE_SCAN="$(extract_skill_bash "$PRE887_MD" pmm-wake-step-4a-scan)" \
  || die "could not extract pmm-wake-step-4a-scan from $PRE887_MD"
PRE_COMPARE="$(extract_skill_bash "$PRE887_MD" pmm-wake-step-4a-compare)" \
  || die "could not extract pmm-wake-step-4a-compare from $PRE887_MD"

LIVE_BLOCK="$LIVE_SCAN
$LIVE_COMPARE"
PRE_BLOCK="$PRE_SCAN
$PRE_COMPARE"

# Sanity: we are running the real thing, not a stub that happens to parse.
case "$LIVE_SCAN" in
  *"gh pr list"*) : ;;
  *) die "extracted scan block does not contain a gh pr list call — anchor drifted?" ;;
esac
case "$LIVE_COMPARE" in
  *"CURRENT_FLEET"*) : ;;
  *) die "extracted compare block does not reference CURRENT_FLEET — anchor drifted?" ;;
esac

# ---------------------------------------------------------------------------
# Environment: one scratch dir, one temp HOME, one trap.
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  [ -n "${TMP_HOME:-}" ] && rm -rf "$TMP_HOME"
  return 0
}
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

# Real session-state.sh + its two dependencies, so `--get` semantics (exit 3 on
# a missing state file, exit 4 on malformed JSON) are the production ones.
STUB_SCRIPTS="$TMP/scripts"
mkdir -p "$STUB_SCRIPTS/lib"
cp "$SCRIPTS_DIR/session-state.sh" "$STUB_SCRIPTS/session-state.sh"
cp "$SCRIPTS_DIR/state-lock.sh" "$STUB_SCRIPTS/state-lock.sh"
cp "$SCRIPTS_DIR/lib/repo-normalizer.sh" "$STUB_SCRIPTS/lib/repo-normalizer.sh"
chmod +x "$STUB_SCRIPTS/session-state.sh" "$STUB_SCRIPTS/state-lock.sh"
# The skill resolves this once in its "Resolve the state helper" block; Step 4a
# only consumes it, so exporting it is a faithful stand-in.
export SESSION_STATE_SH="$STUB_SCRIPTS/session-state.sh"

# Offline `gh`. Payload comes from $GH_STUB_FIXTURE, exit code from the sibling
# "<fixture>.rc" file, both rewritten per scenario.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'GH_STUB'
#!/usr/bin/env bash
# Offline gh stub — see pmm-wake-step-4a.test.sh. Ignores its arguments: Step 4a
# issues exactly one `gh pr list --json …` call, so the payload alone drives the
# scenario.
fixture="${GH_STUB_FIXTURE:?GH_STUB_FIXTURE not set}"
rc=0
[ -f "$fixture.rc" ] && rc="$(cat "$fixture.rc")"
if [ "$rc" -ne 0 ]; then
  echo "gh: stubbed transport failure (exit $rc)" >&2
  exit "$rc"
fi
[ -f "$fixture" ] && cat "$fixture"
exit 0
GH_STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

GH_STUB_FIXTURE="$TMP/gh-pr-list.json"
export GH_STUB_FIXTURE
STDERR_FILE="$TMP/block.stderr"

# ---------------------------------------------------------------------------
# Fixtures and scenario plumbing
# ---------------------------------------------------------------------------
BASE_CONFIG='{"author":"@me","repo":"auerbachb/claude-code-config","cadence":"5m","max_parallel":3,"idle_pause_after":3,"auto_wake":true,"auto_wake_cadence":"60m","confirm_merges":false}'
NO_AUTHOR_CONFIG='{"repo":"auerbachb/claude-code-config","cadence":"5m","max_parallel":3,"idle_pause_after":3,"auto_wake":true,"auto_wake_cadence":"60m","confirm_merges":false}'
# Key order matches what /pr-monitor-and-manage persists at pause time
# (pmm-lifecycle.md): {pr, head_sha, state}.
BASE_FLEET='[{"pr":1,"head_sha":"aaa1111","state":"CLEAN"},{"pr":2,"head_sha":"bbb2222","state":"BLOCKED"}]'
BASE_GH='[{"number":1,"headRefOid":"aaa1111","mergeStateStatus":"CLEAN"},{"number":2,"headRefOid":"bbb2222","mergeStateStatus":"BLOCKED"}]'
# Same two PRs, PR 1 force-pushed to a new (hex-shaped) head.
MOVED_GH='[{"number":1,"headRefOid":"ccc3333","mergeStateStatus":"CLEAN"},{"number":2,"headRefOid":"bbb2222","mergeStateStatus":"BLOCKED"}]'

# write_state <config-json> <fleet-json>
write_state() {
  jq -n --argjson cfg "$1" --argjson fleet "$2" \
    '{schema_version: 2, pmm: {paused_at: "2026-08-01T00:00:00Z", config_at_pause: $cfg, fleet_at_pause: $fleet}}' \
    > "$HOME/.claude/session-state.json"
}

remove_state() { rm -f "$HOME/.claude/session-state.json"; }

# set_gh <exit-code> <stdout-payload>
set_gh() {
  printf '%s' "$1" > "$GH_STUB_FIXTURE.rc"
  printf '%s' "$2" > "$GH_STUB_FIXTURE"
}

RUN_OUT=""
RUN_ERR=""
RUN_RC=0
STATE_BEFORE=""
STATE_AFTER=""

STATE_FILE="$HOME/.claude/session-state.json"
ABSENT_SENTINEL="<no session-state.json>"

# read_state — current state file contents, or a sentinel when it is absent.
#   Case 7 deliberately runs with no state file at all, and "still absent" is
#   just as much a preserved state as "unchanged bytes".
read_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    printf '%s' "$ABSENT_SENTINEL"
  fi
}

# run_block <block-source>
#   A fresh `bash -c`, not a subshell: skill blocks are run by the agent in a
#   plain shell, and this one is written for that (it uses `|| RC=$?` guards and
#   an unquoted-safe empty array expansion that `set -eu` would break).
#
#   The state file is snapshotted around the run so `verdict` can assert Step 4a
#   left it alone (see the preservation check there). `session-state.sh --get`
#   migrates in memory only — "a read never rewrites the file" (its header) — so
#   a byte comparison is exact, not approximate.
run_block() {
  STATE_BEFORE="$(read_state)"
  RUN_OUT="$(bash -c "$1" 2>"$STDERR_FILE")"
  RUN_RC=$?
  RUN_ERR="$(cat "$STDERR_FILE")"
  STATE_AFTER="$(read_state)"
}

contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# Which block the current pass is exercising, and where its verdicts go.
MODE="assert"
CTRL_DEVIATIONS=0
CTRL_DEVIATIONS_FIRST10=0
CTRL_LOG=""

# verdict <case-no> <description> <expectation> [stderr-needle]
#   expectation: scan_failed | unchanged | changed
verdict() {
  local caseno desc want needle ok why
  caseno="$1"; desc="$2"; want="$3"; needle="${4:-}"
  ok=1
  why=""

  case "$want" in
    scan_failed)
      if [ "$RUN_RC" -eq 0 ]; then
        ok=0; why="expected non-zero exit (fail-closed), got 0"
      elif ! contains "fleet scan failed" "$RUN_ERR"; then
        ok=0; why="expected a 'fleet scan failed' diagnostic on stderr, got: ${RUN_ERR:-<empty>}"
      elif [ -n "$needle" ] && ! contains "$needle" "$RUN_ERR"; then
        ok=0; why="expected stderr to mention '$needle', got: $RUN_ERR"
      elif contains "Fleet unchanged" "$RUN_OUT"; then
        ok=0; why="reached the comparison despite a failed scan"
      fi
      ;;
    unchanged)
      if [ "$RUN_RC" -ne 0 ]; then
        ok=0; why="expected exit 0, got $RUN_RC (stderr: ${RUN_ERR:-<empty>})"
      elif ! contains "Fleet unchanged" "$RUN_OUT"; then
        ok=0; why="expected the '[auto-check] Fleet unchanged' no-op line, got: ${RUN_OUT:-<empty>}"
      fi
      ;;
    changed)
      if [ "$RUN_RC" -ne 0 ]; then
        ok=0; why="expected exit 0 (a real change is not a scan failure), got $RUN_RC (stderr: ${RUN_ERR:-<empty>})"
      elif contains "Fleet unchanged" "$RUN_OUT"; then
        ok=0; why="classified a changed fleet as unchanged"
      elif contains "fleet scan failed" "$RUN_ERR"; then
        ok=0; why="treated a valid scan result as a scan failure"
      fi
      ;;
    *)
      die "verdict: unknown expectation '$want'"
      ;;
  esac

  # Step 4a is a READ-ONLY block: it consumes `.pmm.*` through `--get` and never
  # writes. Exit codes and diagnostics cannot prove that on their own — the
  # fail-closed path *prints* "Pause marker and re-scan kept", and a Step 4a
  # that cleared `.pmm.paused_at` or `.pmm.fleet_at_pause` would still print
  # that line, still exit 1, and still pass every check above while dropping the
  # pause it just promised to keep. Same hole on the unchanged path, whose whole
  # contract is "no-op". So compare the state file itself rather than trusting
  # the block's own account of what it did.
  #
  # This holds for `changed` too: cancelling the re-scan and clearing the marker
  # is Step 3 / Step 4b's job, and neither is inside the extracted anchors.
  if [ "$ok" -eq 1 ] && [ "$STATE_AFTER" != "$STATE_BEFORE" ]; then
    ok=0
    why="Step 4a mutated the saved state — the pause marker and fleet snapshot must survive it (before: $STATE_BEFORE | after: $STATE_AFTER)"
  fi

  if [ "$MODE" = "assert" ]; then
    if [ "$ok" -eq 1 ]; then
      pass "Case $caseno: $desc"
    else
      fail "Case $caseno: $desc — $why"
    fi
  else
    if [ "$ok" -eq 1 ]; then
      CTRL_LOG="$CTRL_LOG
   same as fixed — case $caseno: $desc"
    else
      CTRL_DEVIATIONS=$((CTRL_DEVIATIONS + 1))
      [ "$caseno" -le 10 ] && CTRL_DEVIATIONS_FIRST10=$((CTRL_DEVIATIONS_FIRST10 + 1))
      CTRL_LOG="$CTRL_LOG
   DIVERGES  — case $caseno: $desc — $why"
    fi
  fi
}

# ---------------------------------------------------------------------------
# The twelve PR #887 scenarios, run against whichever block $BLOCK holds.
# ---------------------------------------------------------------------------
run_scenarios() {
  BLOCK="$1"

  # -- Case 1 ---------------------------------------------------------------
  # Input:    `gh pr list` exits non-zero (auth expired, transport error).
  # Pre-fix:  exit status unchecked, $CURRENT empty, jq fails, CURRENT_FLEET
  #           empty -> compares unequal -> "fleet changed" -> resume.
  # Expected: SCAN_RC captured -> fail closed, pause and re-scan kept.
  write_state "$BASE_CONFIG" "$BASE_FLEET"
  set_gh 1 ""
  run_block "$BLOCK"
  verdict 1 "gh pr list exits non-zero -> fail closed" scan_failed "exited 1"

  # -- Case 2 ---------------------------------------------------------------
  # Input:    `gh` exits 0 but prints nothing.
  # Pre-fix:  empty $CURRENT -> jq error -> empty CURRENT_FLEET -> "changed".
  # Expected: explicit empty-output guard -> fail closed.
  write_state "$BASE_CONFIG" "$BASE_FLEET"
  set_gh 0 ""
  run_block "$BLOCK"
  verdict 2 "gh pr list returns empty output -> fail closed" scan_failed "empty output"

  # -- Case 3 ---------------------------------------------------------------
  # Input:    `gh` prints non-JSON (an interstitial notice, an HTML error page).
  # Pre-fix:  jq parse error -> empty CURRENT_FLEET -> "changed".
  # Expected: `type == "array"` guard -> fail closed.
  write_state "$BASE_CONFIG" "$BASE_FLEET"
  set_gh 0 'error connecting to api.github.com'
  run_block "$BLOCK"
  verdict 3 "gh pr list returns non-JSON -> fail closed" scan_failed "not a JSON array"

  # -- Case 4 ---------------------------------------------------------------
  # Input:    valid JSON, wrong shape — an object instead of the PR array.
  # Pre-fix:  `.[]` iterates the object values, jq errors mid-pipe -> "changed".
  # Expected: `type == "array"` guard -> fail closed.
  write_state "$BASE_CONFIG" "$BASE_FLEET"
  set_gh 0 '{"message":"Not Found","documentation_url":"https://docs.github.com"}'
  run_block "$BLOCK"
  verdict 4 "gh pr list returns a JSON object, not an array -> fail closed" scan_failed "not a JSON array"

  # -- Case 5 ---------------------------------------------------------------
  # Input:    saved snapshot is null (never written, or half-cleared).
  # Pre-fix:  `|| echo '[]'` never fires (the read succeeds, the VALUE is null),
  #           `sort_by` on null errors, SAVED_FLEET empty -> "changed".
  # Expected: array guard on the saved half too -> fail closed.
  write_state "$BASE_CONFIG" 'null'
  set_gh 0 "$BASE_GH"
  run_block "$BLOCK"
  verdict 5 "saved snapshot is null -> fail closed" scan_failed "saved snapshot"

  # -- Case 6 ---------------------------------------------------------------
  # Input:    saved snapshot is garbage (a bare string, not an array).
  # Pre-fix:  same as case 5 — unusable snapshot silently reads as "changed".
  # Expected: array guard -> fail closed.
  write_state "$BASE_CONFIG" '"not-a-fleet"'
  set_gh 0 "$BASE_GH"
  run_block "$BLOCK"
  verdict 6 "saved snapshot is garbage -> fail closed" scan_failed "saved snapshot"

  # -- Case 7 ---------------------------------------------------------------
  # Input:    session-state.sh read failure — state file missing (its exit 3).
  # Pre-fix:  defaults to {} and [], so an unreadable state file becomes an
  #           "empty fleet at pause" and any live PR reads as "changed".
  # Expected: defaults to null -> no author -> fail closed.
  remove_state
  set_gh 0 "$BASE_GH"
  run_block "$BLOCK"
  verdict 7 "session-state.sh read failure -> fail closed" scan_failed "no author"

  # -- Case 8 ---------------------------------------------------------------
  # Input:    config present but carries no author.
  # Pre-fix:  scans with --author "" — a differently-scoped result compared
  #           against a snapshot taken for a specific author.
  # Expected: author guard -> fail closed before gh is called.
  write_state "$NO_AUTHOR_CONFIG" "$BASE_FLEET"
  set_gh 0 "$BASE_GH"
  run_block "$BLOCK"
  verdict 8 "config present but no author -> fail closed" scan_failed "no author"

  # -- Case 9 ---------------------------------------------------------------
  # Input:    healthy scan, fleet identical to the snapshot.
  # Expected (both pre- and post-fix): no-op, re-scan keeps running.
  write_state "$BASE_CONFIG" "$BASE_FLEET"
  set_gh 0 "$BASE_GH"
  run_block "$BLOCK"
  verdict 9 "unchanged fleet -> no-op, re-scan continues" unchanged

  # -- Case 10 --------------------------------------------------------------
  # Input:    same PRs, one head_sha moved.
  # Expected (both pre- and post-fix): genuine change -> resume path.
  write_state "$BASE_CONFIG" "$BASE_FLEET"
  set_gh 0 "$MOVED_GH"
  run_block "$BLOCK"
  verdict 10 "changed head_sha -> fleet changed, resume" changed

  # -- Case 11 --------------------------------------------------------------
  # Input:    every PR landed; gh returns [].
  # Expected: `[]` is a VALID drained fleet, never a scan failure — the one
  #           empty-ish value that must still be trusted. This is precisely why
  #           the guards default to `null` rather than `[]`.
  write_state "$BASE_CONFIG" "$BASE_FLEET"
  set_gh 0 '[]'
  run_block "$BLOCK"
  verdict 11 "empty fleet [] is a valid drained fleet, not a scan failure" changed

  # -- Case 12 --------------------------------------------------------------
  # Input:    already drained at pause time and still drained now.
  # Expected: [] vs [] compares equal -> unchanged (not "changed", and not a
  #           failure).
  write_state "$BASE_CONFIG" '[]'
  set_gh 0 '[]'
  run_block "$BLOCK"
  verdict 12 "[] versus [] -> unchanged" unchanged
}

echo "== Step 4a scenarios against the live SKILL.md block =="
MODE="assert"
run_scenarios "$LIVE_BLOCK"

# ---------------------------------------------------------------------------
# Discrimination control — the same twelve against the pre-#887 block.
# ---------------------------------------------------------------------------
echo ""
echo "== Discrimination control: same scenarios against the pre-#887 block =="

if [ "$LIVE_COMPARE" = "$PRE_COMPARE" ]; then
  pass "control: comparison half is byte-identical live vs pre-#887 (deviations isolate the guards)"
else
  fail "control: comparison half differs live vs pre-#887 — the control no longer isolates the missing guards"
fi

MODE="control"
run_scenarios "$PRE_BLOCK"
MODE="assert"

echo "   control results:$CTRL_LOG"
echo "   control totals: $CTRL_DEVIATIONS/12 diverge overall, $CTRL_DEVIATIONS_FIRST10/10 among the first ten"

# PR #887 measured 8 of the first 10 failing pre-fix (cases 9 and 10 are the
# happy paths the pre-fix block already got right). Fewer than 8 means the
# harness stopped discriminating: either the scenarios went slack or the stubs
# stopped reaching the guards.
if [ "$CTRL_DEVIATIONS_FIRST10" -ge 8 ]; then
  pass "control: $CTRL_DEVIATIONS_FIRST10/10 first-ten scenarios diverge on the pre-#887 block (expected >= 8)"
else
  fail "control: only $CTRL_DEVIATIONS_FIRST10/10 first-ten scenarios diverge on the pre-#887 block (expected >= 8) — this suite may be rubber-stamping"
fi

# ---------------------------------------------------------------------------
# Extractor contract — a silently-empty extraction is the false-clean
# lib/skill-bash.sh exists to prevent, so every failure mode must be loud.
# ---------------------------------------------------------------------------
echo ""
echo "== lib/skill-bash.sh fail-loud contract =="

FIXDIR="$TMP/md"
mkdir -p "$FIXDIR"

cat > "$FIXDIR/ok.md" <<'MD'
Some prose.

<!-- test-anchor: alpha -->
```bash
echo one
echo two
```

More prose, and a second block nobody anchored.

```bash
echo unrelated
```
MD

out="$(extract_skill_bash "$FIXDIR/ok.md" alpha)"; rc=$?
expected='echo one
echo two'
if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ]; then
  pass "extractor: happy path returns exactly the anchored block body"
else
  fail "extractor: happy path — rc=$rc, body=<$out>"
fi

out="$(extract_skill_bash "$FIXDIR/ok.md" nosuchanchor 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && contains "anchor not found" "$out"; then
  pass "extractor: missing anchor exits non-zero (rc=$rc) with a diagnostic"
else
  fail "extractor: missing anchor — expected non-zero + diagnostic, got rc=$rc: $out"
fi

cat > "$FIXDIR/dupe.md" <<'MD'
<!-- test-anchor: beta -->
```bash
echo first
```

<!-- test-anchor: beta -->
```bash
echo second
```
MD

out="$(extract_skill_bash "$FIXDIR/dupe.md" beta 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && contains "ambiguous anchor" "$out"; then
  pass "extractor: ambiguous (multi-match) anchor exits non-zero (rc=$rc) with a diagnostic"
else
  fail "extractor: ambiguous anchor — expected non-zero + diagnostic, got rc=$rc: $out"
fi

cat > "$FIXDIR/adrift.md" <<'MD'
<!-- test-anchor: gamma -->

A paragraph has drifted in between the anchor and the fence.

```bash
echo not-mine
```
MD

out="$(extract_skill_bash "$FIXDIR/adrift.md" gamma 2>&1)"; rc=$?
# The needle pins the diagnostic's wording, not just its exit code: it must name
# the *first non-blank line* as the thing that has to be a fence, so it can never
# drift back into implying that a blank line is what got rejected (issue #926).
if [ "$rc" -ne 0 ] && contains "first non-blank line after the anchor" "$out"; then
  pass "extractor: anchor separated from its fence exits non-zero (rc=$rc) rather than grabbing the next block"
else
  fail "extractor: drifted anchor — expected non-zero + diagnostic, got rc=$rc: $out"
fi

# The flip side of adrift.md: blank lines alone are tolerated, however many.
# Only a non-blank line between anchor and fence is an error, so an editorial
# double newline never turns into a red build (issue #926).
cat > "$FIXDIR/tolerant.md" <<'MD'
<!-- test-anchor: eta -->



```bash
echo tolerated one
echo tolerated two
```
MD

out="$(extract_skill_bash "$FIXDIR/tolerant.md" eta 2>&1)"; rc=$?
expected='echo tolerated one
echo tolerated two'
if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ]; then
  pass "extractor: multiple blank lines between anchor and fence are tolerated (rc 0)"
else
  fail "extractor: multi-blank tolerance — expected rc 0 and the block body, got rc=$rc, body=<$out>"
fi

cat > "$FIXDIR/unclosed.md" <<'MD'
<!-- test-anchor: delta -->
```bash
echo never closed
MD

out="$(extract_skill_bash "$FIXDIR/unclosed.md" delta 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && contains "never closed" "$out"; then
  pass "extractor: unclosed fence exits non-zero (rc=$rc) with a diagnostic"
else
  fail "extractor: unclosed fence — expected non-zero + diagnostic, got rc=$rc: $out"
fi

cat > "$FIXDIR/empty.md" <<'MD'
<!-- test-anchor: epsilon -->
```bash
```
MD

out="$(extract_skill_bash "$FIXDIR/empty.md" epsilon 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && contains "is empty" "$out"; then
  pass "extractor: empty block body exits non-zero (rc=$rc) instead of returning nothing quietly"
else
  fail "extractor: empty body — expected non-zero + diagnostic, got rc=$rc: $out"
fi

out="$(extract_skill_bash "$FIXDIR/no-such-file.md" alpha 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && contains "cannot read markdown file" "$out"; then
  pass "extractor: unreadable markdown file exits non-zero (rc=$rc) with a diagnostic"
else
  fail "extractor: unreadable file — expected non-zero + diagnostic, got rc=$rc: $out"
fi

# A longer anchor name must not be matched by a shorter prefix of it.
cat > "$FIXDIR/prefix.md" <<'MD'
<!-- test-anchor: zeta-long -->
```bash
echo long
```
MD

out="$(extract_skill_bash "$FIXDIR/prefix.md" zeta 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && contains "anchor not found" "$out"; then
  pass "extractor: anchor match is whole-line, so 'zeta' does not match 'zeta-long'"
else
  fail "extractor: prefix match — expected non-zero + diagnostic, got rc=$rc: $out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "OK: pmm-wake Step 4a fail-closed scan — 12/12 scenarios plus extractor contract (issues #871, #887, #888)"
