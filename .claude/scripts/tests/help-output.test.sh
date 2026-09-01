#!/usr/bin/env bash
# --help contract coverage for every repo script (issues #1513, #1475).
#
# WHY THIS SUITE EXISTS
#
# `<script> --help` is this repo's DESIGNATED contract surface — handoff-files.md,
# cr-merge-gate.md, main-hygiene.md, repo-bootstrap.md and .claude/scripts/docs/
# all send readers there. Nothing tested it. Twelve scripts were shipping a
# defective one, in two families:
#
#   Family A — dead on macOS (6 scripts). A nested `sed -n '2,/^set -/{ /^#/{
#     …; p }; … }'` block is rejected by BSD sed ("extra characters at the end
#     of p command"): sed error on stderr, EMPTY stdout, and — under
#     `set -euo pipefail` — exit 1 instead of the `exit 0` on the next line.
#     For estimate-resolve.sh that wrong status is actively dangerous: exit 1 is
#     a documented in-band result (tier-table fallback), so broken help
#     masqueraded as success.
#
#   Family B — silently truncated (6 scripts). A `sed` range STOPS AT its
#     terminator, so `/^# EXAMPLES$/` and `/^# DEPENDENCIES$/` as terminators
#     emitted the heading and swallowed everything under it. Exit 0, no error,
#     content simply gone.
#
# Both families were invisible to CI because six of seven workflows run on
# ubuntu-latest, where GNU sed accepts the nested block — the bug fired only on
# the macOS machines the repo is developed on. This suite lives in the
# auto-discovered .claude/scripts/tests/ directory, so run-hook-tests.sh runs it
# in BOTH the `hook-tests` (ubuntu) and `hook-tests-macos` jobs with no workflow
# edit. The macOS job is what closes family A.
#
# WHAT IS ASSERTED
#
#   Part 1 — repo-wide smoke sweep. EVERY .sh in .claude/scripts/, .claude/hooks/
#     and .github/scripts/ that advertises `--help` must: exit 0, print a
#     non-trivial stdout, write NOTHING to stderr, and not end on a bare section
#     heading. That last check is family B's exact signature, and it is what
#     makes the sweep catch a defect introduced by an implementation nobody has
#     written yet — it tests the OUTPUT, not the extraction idiom.
#
#   Part 2 — content assertions for the 12 fixed scripts: every section HEADING
#     plus at least one known BODY line from each section. Headings alone are
#     vacuous — family B printed every heading it had and still dropped the
#     content. Body needles are content substrings, not line counts, so they
#     survive header reflow.
#
#   Part 3 — controls. The checker is run against purpose-built fixtures that
#     reproduce each pre-fix form, and must REJECT both; and against the
#     canonical form, which it must ACCEPT. Without the positive control a
#     checker that rejects everything would look like a passing suite.
#
# Run from anywhere: bash .claude/scripts/tests/help-output.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "cannot resolve repo root" >&2; exit 1; }
cd "$REPO_ROOT" || { echo "cannot cd to repo root" >&2; exit 1; }

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
# Scripts append one telemetry line to $HOME/.claude/script-usage.log on entry.
# Redirect HOME so probing 100+ helps never touches the developer's real state.
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

OUT="$TMP/help.out"
ERRF="$TMP/help.err"
RC=0

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   — $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# ---------------------------------------------------------------------------
# run_help <script-path>
#
# Runs `<script> --help` with a 10s wall-clock bound, leaving stdout in $OUT,
# stderr in $ERRF and the status in $RC. Stock macOS ships no timeout(1), so the
# bound is built here: background the child, poll, kill on expiry. A `--help`
# that hangs is itself a defect and must fail loudly rather than stall CI.
# ---------------------------------------------------------------------------
run_help() {
  local script="$1" pid waited=0
  : > "$OUT"; : > "$ERRF"
  bash "$script" --help >"$OUT" 2>"$ERRF" </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    RC=124
  else
    wait "$pid"
    RC=$?
  fi
}

# ---------------------------------------------------------------------------
# smoke_verdict
#
# Reads $RC/$OUT/$ERRF from the last run_help and prints a space-separated list
# of violation tags, or "clean". ONE definition, used by the repo-wide sweep AND
# by the controls in Part 3 — so the controls exercise the real checker rather
# than a copy of it that could drift.
#
#   rc<N>      — non-zero exit (family A's signature, with empty stdout)
#   empty      — stdout under 20 bytes
#   stderr     — anything on stderr (a sed/awk diagnostic, or any other noise)
#   bare-head  — last non-blank stdout line is a bare section heading, i.e. a
#                section was announced and its body dropped (family B)
# ---------------------------------------------------------------------------
smoke_verdict() {
  local tags="" last bytes
  bytes=$(wc -c < "$OUT" | tr -d ' ')
  last=$(grep -v '^[[:space:]]*$' "$OUT" | tail -1)

  [ "$RC" -ne 0 ] && tags="$tags rc$RC"
  [ "$bytes" -lt 20 ] && tags="$tags empty"
  [ -s "$ERRF" ] && tags="$tags stderr"
  # A heading is a line at column 0 in caps — body lines are always indented,
  # and prose sentences carry lowercase.
  if printf '%s\n' "$last" | grep -qE '^[A-Z][A-Z0-9 /&_.:()#-]*$'; then
    tags="$tags bare-head"
  fi

  if [ -z "$tags" ]; then printf 'clean\n'; else printf '%s\n' "${tags# }"; fi
}

echo "=== Part 1 — repo-wide --help smoke sweep ==="

PROBED=0
SWEEP_FAILURES=""
for f in .claude/scripts/*.sh .claude/hooks/*.sh .github/scripts/*.sh; do
  [ -f "$f" ] || continue
  # Only scripts that advertise the flag. state-lock.sh, for instance, is a
  # library that prints its header and exits 2 for ANY execution; it never
  # claims to support --help and is correctly not held to this contract.
  grep -q -e '--help' "$f" || continue
  PROBED=$((PROBED + 1))
  run_help "$f"
  verdict="$(smoke_verdict)"
  if [ "$verdict" != "clean" ]; then
    SWEEP_FAILURES="${SWEEP_FAILURES}    $f — $verdict"$'\n'
  fi
done

if [ -n "$SWEEP_FAILURES" ]; then
  bad "every advertised --help is well-formed; violations:"
  printf '%s' "$SWEEP_FAILURES"
else
  ok "every advertised --help is well-formed ($PROBED scripts probed)"
fi

# Fail closed on broken discovery — a sweep that probed nothing must never pass
# green as "all helps are fine" (precedent: run-hook-tests.sh exit 3, issue #681).
if [ "$PROBED" -ge 60 ]; then
  ok "sweep discovery found $PROBED scripts advertising --help (>= 60)"
else
  bad "sweep discovery found only $PROBED scripts advertising --help — a glob is broken"
fi

echo
echo "=== Part 2 — section headings AND body content for the 12 fixed scripts ==="

# script :: kind :: expected substring
#
# `kind` is documentation for the failure message; both kinds are checked the
# same way (fixed-string containment). Every section of every fixed script gets
# a heading needle AND a body needle — the truncation family proved a heading
# needle alone passes on output whose content is gone.
CONTENT_TABLE="$(cat <<'CONTENT_EOF'
audit-skill-usage.sh :: head :: PURPOSE:
audit-skill-usage.sh :: body :: Reads .claude/data/skill-usage.json and reports skills
audit-skill-usage.sh :: head :: USAGE:
audit-skill-usage.sh :: body :: bash .claude/scripts/audit-skill-usage.sh [--help]
audit-skill-usage.sh :: head :: DEPENDENCIES:
audit-skill-usage.sh :: body :: - jq  (available at /usr/bin/jq
audit-skill-usage.sh :: head :: DATA SOURCE:
audit-skill-usage.sh :: body :: The file is initialized automatically on first run
audit-skill-usage.sh :: head :: EXIT STATUS:
audit-skill-usage.sh :: body :: 1 — at least one skill is recommended for removal
estimate-resolve.sh :: head :: PURPOSE
estimate-resolve.sh :: body :: Used by dispatch/makespan helpers
estimate-resolve.sh :: head :: USAGE
estimate-resolve.sh :: body :: estimate-resolve.sh <issue_number> [--repo owner/repo]
estimate-resolve.sh :: head :: STDOUT (one line)
estimate-resolve.sh :: body :: from ## Estimate section (exit
estimate-resolve.sh :: head :: EXIT CODES
estimate-resolve.sh :: body :: 0  resolved from ## Estimate section in issue body
estimate-resolve.sh :: head :: PARSE PATTERN (from time-estimates.md)
estimate-resolve.sh :: body :: plan\s+on\s+
estimate-resolve.sh :: head :: TIER TABLE (from time-estimates.md)
estimate-resolve.sh :: body :: Est: 15
estimate-resolve.sh :: head :: DEPENDENCIES
estimate-resolve.sh :: body :: - gh (authenticated)
makespan.sh :: head :: PURPOSE
makespan.sh :: body :: Compute the projected finish time for a batch of issues
makespan.sh :: head :: USAGE
makespan.sh :: body :: makespan.sh --json '<JSON>' [--ceiling N]
makespan.sh :: head :: JSON INPUT SCHEMA
makespan.sh :: body :: { "issues": [
makespan.sh :: head :: OPTIONS
makespan.sh :: body :: --ceiling N     Concurrency ceiling (default: 4
makespan.sh :: head :: STDOUT (one line)
makespan.sh :: body :: binding: <bound>
makespan.sh :: head :: EXIT CODES
makespan.sh :: body :: 0  success
makespan.sh :: head :: DEPENDENCIES
makespan.sh :: body :: - jq >= 1.5
overrun-check.sh :: head :: PURPOSE
overrun-check.sh :: body :: Called once per poll cycle per active PR pipeline
overrun-check.sh :: head :: USAGE
overrun-check.sh :: body :: overrun-check.sh --pr N --bound-min M --started-at ISO8601
overrun-check.sh :: head :: OUTPUT
overrun-check.sh :: body :: exit 2: already alerted
overrun-check.sh :: head :: READOUT MODE (--readout)
overrun-check.sh :: body :: Computes and prints the progress readout line to stdout
overrun-check.sh :: head :: CELL MODE (--readout-cells)
overrun-check.sh :: body :: Same inputs and same pace model as --readout
overrun-check.sh :: head :: ALERT LINE FORMAT (stdout, only on exit 1)
overrun-check.sh :: body :: h elapsed vs
overrun-check.sh :: head :: SESSION-STATE MARKER
overrun-check.sh :: body :: Writes via session-state.sh:
overrun-check.sh :: head :: DEPENDENCIES
overrun-check.sh :: body :: - session-state.sh (resolved via candidate order)
skill-conventions-audit.sh :: head :: USAGE:
skill-conventions-audit.sh :: body :: bash .claude/scripts/skill-conventions-audit.sh [--strict] [--help]
skill-conventions-audit.sh :: head :: EXIT STATUS:
skill-conventions-audit.sh :: body :: 1 — at least one ERROR (or any finding when --strict)
window-plan.sh :: head :: PURPOSE
window-plan.sh :: body :: Converts a human-readable planning window
window-plan.sh :: head :: USAGE
window-plan.sh :: body :: window-plan.sh --window "until 5:00 PM"
window-plan.sh :: head :: OUTPUT (stdout, one line)
window-plan.sh :: body :: window_minutes=N stall_margin_min=M
window-plan.sh :: head :: WINDOW FORMATS ACCEPTED
window-plan.sh :: body :: End clock time today in ET
window-plan.sh :: head :: STALL MARGIN
window-plan.sh :: body :: For overnight or end-clock-time windows
window-plan.sh :: head :: EXIT CODES
window-plan.sh :: body :: 4  system date error
repo-root.sh :: head :: PURPOSE
repo-root.sh :: body :: pattern used across
repo-root.sh :: head :: USAGE
repo-root.sh :: body :: repo-root.sh [path]
repo-root.sh :: head :: ENVIRONMENT
repo-root.sh :: body :: REPO_ROOT_TIMEOUT_SECS   Wall-clock bound
repo-root.sh :: head :: OUTPUT
repo-root.sh :: body :: stdout: absolute path of the main-worktree root
repo-root.sh :: head :: EXIT STATUS
repo-root.sh :: body :: 0  Success — path printed on stdout.
repo-root.sh :: head :: REQUIREMENTS
repo-root.sh :: body :: Besides git, this script REQUIRES mktemp, awk, head
repo-root.sh :: head :: EXAMPLES
repo-root.sh :: body :: ROOT_REPO=$(.claude/scripts/repo-root.sh)
greptile-budget.sh :: head :: PURPOSE
greptile-budget.sh :: body :: Single source of truth for the Greptile daily-budget contract
greptile-budget.sh :: head :: USAGE
greptile-budget.sh :: body :: greptile-budget.sh --check  [--budget N]
greptile-budget.sh :: head :: MODES
greptile-budget.sh :: body :: --check     Read current state; print JSON
greptile-budget.sh :: head :: FLAGS
greptile-budget.sh :: body :: --budget N  Override the default budget of 40 reviews/day
greptile-budget.sh :: head :: OUTPUT
greptile-budget.sh :: body :: stdout: single-line JSON object
greptile-budget.sh :: head :: EXIT STATUS
greptile-budget.sh :: body :: 1  Budget exhausted
greptile-budget.sh :: head :: ATOMICITY
greptile-budget.sh :: body :: All writes go through
greptile-budget.sh :: head :: DEPENDENCIES
greptile-budget.sh :: body :: - .claude/scripts/state-lock.sh (sibling library
greptile-budget.sh :: head :: EXAMPLES
greptile-budget.sh :: body :: if ! greptile-budget.sh --consume >/dev/null; then
cr-review-hourly.sh :: head :: PURPOSE
cr-review-hourly.sh :: body :: Tracks consumption against CodeRabbit
cr-review-hourly.sh :: head :: USAGE
cr-review-hourly.sh :: body :: cr-review-hourly.sh --check
cr-review-hourly.sh :: head :: MODES
cr-review-hourly.sh :: body :: Prune events older than 1 hour
cr-review-hourly.sh :: head :: FLAGS
cr-review-hourly.sh :: body :: default budget 8; env CR_HOURLY_BUDGET
cr-review-hourly.sh :: head :: OUTPUT
cr-review-hourly.sh :: body :: stdout: single-line JSON.
cr-review-hourly.sh :: head :: EXIT STATUS
cr-review-hourly.sh :: body :: 0  Success.
cr-review-hourly.sh :: head :: LOCKING (issue #639)
cr-review-hourly.sh :: body :: Every write path serializes on the shared session-state lock
cr-review-hourly.sh :: head :: DEPENDENCIES
cr-review-hourly.sh :: body :: jq, date (UTC ISO), mktemp, mv; .claude/scripts/state-lock.sh
credit-budget.sh :: head :: PURPOSE
credit-budget.sh :: body :: Evaluate the daily autonomous-dispatch credit budget
credit-budget.sh :: head :: USAGE
credit-budget.sh :: body :: credit-budget.sh --check  [--budget N]
credit-budget.sh :: head :: MODES
credit-budget.sh :: body :: --check    Probe authoritative signals
credit-budget.sh :: head :: FLAGS
credit-budget.sh :: body :: --budget N  Override daily_credit_budget_usd
credit-budget.sh :: head :: OUTPUT
credit-budget.sh :: body :: stdout: single-line JSON
credit-budget.sh :: head :: EXIT STATUS (the dispatch gate; unreadable state is never permission)
credit-budget.sh :: body :: no authoritative overage signal today
credit-budget.sh :: head :: AUTHORITATIVE PROBE (Probe 1 only — see budget-source-probe.md)
credit-budget.sh :: body :: Reads ~/.claude/usage-limit-events.jsonl
credit-budget.sh :: head :: ATOMICITY
credit-budget.sh :: body :: All writes use jq + temp-file + mv, serialized through state-lock.sh.
credit-budget.sh :: head :: DEPENDENCIES
credit-budget.sh :: body :: - state-lock.sh (sibling library)
pr-preflight.sh :: head :: PURPOSE
pr-preflight.sh :: body :: Single source of truth for the per-PR pre-flight run by /fixpr
pr-preflight.sh :: head :: HEAD-SHA FRESHNESS (issue #576)
pr-preflight.sh :: body :: Presence used to be PR-wide
pr-preflight.sh :: head :: API COST (issue #590)
pr-preflight.sh :: body :: One additional paginated call
pr-preflight.sh :: head :: USAGE
pr-preflight.sh :: body :: pr-preflight.sh <pr_number> [--json] [--dry-run]
pr-preflight.sh :: head :: FLAGS
pr-preflight.sh :: body :: --json     Emit only a single-line JSON summary
pr-preflight.sh :: head :: OUTPUT
pr-preflight.sh :: body :: Default mode: one timestamped action line per action taken
pr-preflight.sh :: head :: EXIT STATUS
pr-preflight.sh :: body :: 3  PR not found / closed / inaccessible.
pr-preflight.sh :: head :: SAFETY (safety.md — absolute)
pr-preflight.sh :: body :: Never modifies branch protection
pr-preflight.sh :: head :: DEPENDENCIES
pr-preflight.sh :: body :: gh, jq. Optionally cr-review-hourly.sh
pr-preflight.sh :: head :: PER-SHA TRIGGER DEDUPE (issue #576)
pr-preflight.sh :: body :: preflight_trigger_head_sha
usage-horizon.sh :: head :: PURPOSE
usage-horizon.sh :: body :: Turn the harness-injected in-context remaining-token counter
usage-horizon.sh :: head :: USAGE
usage-horizon.sh :: body :: usage-horizon.sh --observe <remaining> [--limit <total>]
usage-horizon.sh :: head :: MODES
usage-horizon.sh :: body :: --observe <remaining>
usage-horizon.sh :: head :: FLAGS
usage-horizon.sh :: body :: --limit <total>   Window total for the reading
usage-horizon.sh :: head :: OUTPUT
usage-horizon.sh :: body :: stdout: exactly two lines
usage-horizon.sh :: head :: EXIT STATUS (the gate; unknown is NEVER read as clear)
usage-horizon.sh :: body :: runway above the approaching threshold
usage-horizon.sh :: head :: HYSTERESIS
usage-horizon.sh :: body :: Worsening is immediate; improving must clear the threshold
usage-horizon.sh :: head :: CONCURRENT SESSIONS (known limitation, deliberately not papered over)
usage-horizon.sh :: body :: is a SINGLE slot in a machine-wide state file
usage-horizon.sh :: head :: DEGRADATION CONTRACT (fail closed — mirrors credit-budget.sh)
usage-horizon.sh :: body :: produces STATUS=unknown and exit 3
usage-horizon.sh :: head :: FILES
usage-horizon.sh :: body :: observation log, mode 600
usage-horizon.sh :: head :: DEPENDENCIES
usage-horizon.sh :: body :: - shasum or sha256sum
CONTENT_EOF
)"

# Cache each script's --help once; the table walks it many times.
CURRENT=""
TABLE_ROWS=0
MISSING=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  TABLE_ROWS=$((TABLE_ROWS + 1))
  script="${row%% :: *}"
  rest="${row#* :: }"
  kind="${rest%% :: *}"
  needle="${rest#* :: }"

  if [ "$script" != "$CURRENT" ]; then
    run_help ".claude/scripts/$script"
    CURRENT="$script"
    if [ "$RC" -ne 0 ]; then
      bad "$script --help exits 0 (got $RC; stderr: $(head -1 "$ERRF"))"
    fi
    cp "$OUT" "$TMP/cached-$script.out"
  fi

  if grep -qF -- "$needle" "$TMP/cached-$script.out"; then
    :
  else
    MISSING="${MISSING}    $script [$kind] missing: $needle"$'\n'
  fi
done <<< "$CONTENT_TABLE"

if [ -n "$MISSING" ]; then
  bad "all $TABLE_ROWS heading/body needles present; missing:"
  printf '%s' "$MISSING"
else
  ok "all $TABLE_ROWS heading/body needles present across the 12 fixed scripts"
fi

# The table must actually cover all 12 scripts — a typo'd name would silently
# shrink coverage while the assertion above still reported success.
COVERED=$(printf '%s\n' "$CONTENT_TABLE" | sed 's/ :: .*//' | sort -u | wc -l | tr -d ' ')
check "content table covers all 12 fixed scripts" "$COVERED" "12"

echo
echo "=== Part 3 — controls (the checker must reject the pre-fix forms) ==="

# A fixture header shaped exactly like a real script's: title, two sections with
# marked bodies, terminated by the blank line before `set -euo pipefail`.
make_fixture() {
  local path="$1" extraction="$2"
  cat > "$path" <<FIXTURE_EOF
#!/usr/bin/env bash
# fixture.sh — negative-control fixture for help-output.test.sh
#
# PURPOSE
#   PURPOSE-BODY-MARKER stands in for real purpose prose.
#
# DEPENDENCIES
#   DEPS-BODY-MARKER stands in for the last section's body.

set -euo pipefail
case "\${1:-}" in
  --help|-h)
    $extraction
    exit 0 ;;
esac
FIXTURE_EOF
}

# Control 1 (positive) — the canonical form this PR adopts must be ACCEPTED,
# and must emit both section bodies. Without this, a checker that rejected
# everything would produce a green suite in the two negative controls below.
make_fixture "$TMP/canonical.sh" \
  'awk '"'"'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }'"'"' "$0"'
run_help "$TMP/canonical.sh"
check "control(+): canonical awk form passes the smoke checker" "$(smoke_verdict)" "clean"
if grep -qF -- "DEPS-BODY-MARKER" "$OUT" && grep -qF -- "PURPOSE-BODY-MARKER" "$OUT"; then
  ok "control(+): canonical awk form emits BOTH section bodies"
else
  bad "control(+): canonical awk form dropped a section body"
fi

# Control 2 (negative, family B) — the heading-range form. Portable: the range
# ends AT the terminator on BOTH BSD and GNU sed, so this control is decisive on
# every platform.
make_fixture "$TMP/family-b.sh" \
  "sed -n '/^# PURPOSE\$/,/^# DEPENDENCIES\$/p' \"\$0\" | sed 's/^# \\{0,1\\}//'"
run_help "$TMP/family-b.sh"
FAMILY_B_VERDICT="$(smoke_verdict)"
case "$FAMILY_B_VERDICT" in
  *bare-head*) ok "control(-): family-B heading-range form is REJECTED (bare-head)" ;;
  *) bad "control(-): family-B heading-range form was NOT rejected (verdict: $FAMILY_B_VERDICT)" ;;
esac
if grep -qF -- "DEPS-BODY-MARKER" "$OUT"; then
  bad "control(-): family-B fixture unexpectedly emitted its last section body — fixture is wrong"
else
  ok "control(-): family-B fixture drops its last section body, as the bug did"
fi

# Control 3 (negative, family A) — the nested-block form. BSD sed rejects it;
# GNU sed accepts it. Probe the BEHAVIOR rather than the platform name, and make
# the complementary assertion where the abort is not reproducible, so the
# ubuntu job is never vacuous either.
make_fixture "$TMP/family-a.sh" \
  "sed -n '2,/^set -/{ /^#/{ s/^# \\?//; p }; /^set -/q }' \"\$0\""
run_help "$TMP/family-a.sh"
FAMILY_A_VERDICT="$(smoke_verdict)"
if printf 'x\n' | sed -n '2,/^set -/{ /^#/{ p }; /^set -/q }' >/dev/null 2>&1; then
  # GNU sed (Linux CI): the nested block runs, so assert the STRUCTURAL fact
  # instead — no help site in the repo still carries the BSD-fatal shape.
  ok "control(-): this sed ACCEPTS nested blocks (GNU) — behavioral half not reproducible here"
  STILL_NESTED=$(grep -rl "sed -n '2,/\^set -/{" .claude/scripts .claude/hooks .github/scripts 2>/dev/null \
    | grep -v '/tests/' | wc -l | tr -d ' ')
  check "control(-): no production help site still uses the BSD-fatal nested form" "$STILL_NESTED" "0"
else
  # BSD sed (macOS, the platform where the bug fired): the fixture must die.
  case "$FAMILY_A_VERDICT" in
    *rc*) ok "control(-): family-A nested-block form is REJECTED on BSD sed ($FAMILY_A_VERDICT)" ;;
    *) bad "control(-): family-A nested-block form was NOT rejected (verdict: $FAMILY_A_VERDICT)" ;;
  esac
  check "control(-): family-A fixture prints nothing on stdout" "$(wc -c < "$OUT" | tr -d ' ')" "0"
fi

echo
echo "-------------------------------------------"
echo "PASS: $PASS    FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
