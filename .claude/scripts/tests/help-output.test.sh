#!/usr/bin/env bash
# --help contract coverage for every repo script (issues #1513, #1475).
# catalog: tests — `--help` contract for every repo script (#1513/#1475/#1528) — repo-wide smoke sweep (exit 0, non-empty, silent stderr, never ends on a bare section heading) plus heading **and** body-content assertions for the 12 scripts whose extraction was BSD-fatal or truncating, fixtures proving the checker rejects both pre-fix forms, and (Part 4) the empty-extraction guard: an extraction that yields nothing must exit non-zero and say so on stderr, asserted end-to-end and at the `END`-block level, with a pre-fix control that still exits 0
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
  if grep -qE '^[A-Z][A-Z0-9 /&_.:()#-]*$' <<<"$last"; then
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
  'awk '"'"'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }'"'"' "$0"'
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
echo "=== Part 4 — an extraction that yields nothing must FAIL loudly (issue #1528) ==="

# The portable awk form cannot be defeated by BSD/GNU divergence any more, but it
# could still yield nothing — a header block deleted, a blank line landing at
# line 2, an unreadable $0. Every call site used to be `awk …; exit 0`, so that
# case printed nothing and reported SUCCESS. Relying on `set -e` to catch it is
# unsound: 20 of the 47 sites do not set it. The guard is therefore explicit at
# the call site, and this part proves it fires.
#
# GUARDED_EXTRACTION is the exact production text, so a drift in the shipped
# idiom shows up here rather than being re-asserted against a stale copy.
GUARDED_EXTRACTION='awk '"'"'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }'"'"' "$0" ||
      { printf '"'"'%s: --help header extraction produced no output\n'"'"' "$0" >&2; exit 70; }'

# make_bodied_fixture <path> <header-block>
# Writes a fixture carrying the guarded production extraction, with an arbitrary
# header block spliced in after the shebang.
make_bodied_fixture() {
  local path="$1" header="$2"
  {
    printf '#!/usr/bin/env bash\n'
    [ -n "$header" ] && printf '%s\n' "$header"
    printf '\nset -euo pipefail\ncase "${1:-}" in\n  --help|-h)\n    %s\n    exit 0 ;;\nesac\n' \
      "$GUARDED_EXTRACTION"
  } > "$path"
}

# The shipped idiom must actually be the one under test.
if grep -qF 'END { exit(n ? 0 : 1) }' "$REPO_ROOT/.claude/scripts/overrun-check.sh"; then
  ok "the guarded awk form is what production ships"
else
  bad "production no longer ships the guarded awk form — Part 4 is testing a stale idiom"
fi

# Control (positive): a normal header still exits 0 and prints its body. Without
# this, a guard that rejected everything would look like a passing suite.
make_bodied_fixture "$TMP/guard-ok.sh" '# fixture.sh — guarded positive control
#
# PURPOSE
#   PURPOSE-BODY-MARKER stands in for real purpose prose.'
run_help "$TMP/guard-ok.sh"
check "guard(+): a well-formed header still exits 0" "$RC" "0"
check "guard(+): and still writes nothing to stderr" "$(wc -c < "$ERRF" | tr -d ' ')" "0"
if grep -qF -- "PURPOSE-BODY-MARKER" "$OUT"; then
  ok "guard(+): and still emits the header body"
else
  bad "guard(+): the guard suppressed a healthy header body"
fi

# Case 1 — header deleted, the blank separator remains at line 2. awk hits its
# terminator immediately and prints nothing.
make_bodied_fixture "$TMP/guard-blank.sh" ''
run_help "$TMP/guard-blank.sh"
check "guard(-): a header deleted down to a blank line 2 exits non-zero" \
  "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
# 70 = sysexits EX_SOFTWARE, "internal software error". The code is deliberately
# NOT 1: exit 1 is a documented IN-BAND result for some of these scripts —
# estimate-resolve.sh returns it for a tier-table fallback — so a caller that
# ran --help and branched on status could not tell a broken help from a real
# answer. That ambiguity is the one PR #1549 called out; 70 is unused repo-wide.
check "guard(-): the status is EX_SOFTWARE (70), never an in-band code" "$RC" "70"
check "guard(-): stdout is empty, as the broken case is" \
  "$(wc -c < "$OUT" | tr -d ' ')" "0"
if grep -qF -- "produced no output" "$ERRF"; then
  ok "guard(-): the failure is VISIBLE — it names itself on stderr"
else
  bad "guard(-): failed silently; stderr was '$(head -1 "$ERRF")'"
fi

# Case 2 — the END block, asserted directly on the awk program.
#
# Deleting a header outright is NOT an empty extraction: awk then simply prints
# the code that follows, which is a different (and louder) defect. The only
# shapes that yield nothing are the terminator landing at line 2 — case 1 — and
# awk reaching EOF having printed nothing, which through `$0` needs a one-line
# file and so cannot carry a --help arm at all. That case is therefore asserted
# against the program itself rather than through a fixture that cannot exist.
AWK_PROG='NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }'

printf '#!/usr/bin/env bash\n' > "$TMP/one-line.sh"
awk "$AWK_PROG" "$TMP/one-line.sh" >/dev/null 2>&1
check "END block: EOF with nothing printed exits 1" "$?" "1"

printf '#!/usr/bin/env bash\n\nset -euo pipefail\n' > "$TMP/blank-second.sh"
awk "$AWK_PROG" "$TMP/blank-second.sh" >/dev/null 2>&1
check "END block: terminator at line 2 exits 1" "$?" "1"

printf '#!/usr/bin/env bash\n# a real header line\n\nset -euo pipefail\n' > "$TMP/has-header.sh"
HDR=$(awk "$AWK_PROG" "$TMP/has-header.sh"); HDR_RC=$?
check "END block: a one-line header exits 0" "$HDR_RC" "0"
check "END block: …and prints the stripped header" "$HDR" "a real header line"

# Negative control on the guard itself: the PRE-fix shape (no END block, bare
# `exit 0`) must still report success on the very same broken input. Without
# this the two cases above could pass against a fixture that was never capable
# of the bug.
printf '#!/usr/bin/env bash\n\nset -euo pipefail\ncase "${1:-}" in\n  --help|-h)\n' \
  > "$TMP/guard-prefix.sh"
printf '    awk %s "$0"\n    exit 0 ;;\nesac\n' \
  "'NR == 1 { next } /^\$/ { exit } { sub(/^# ?/, \"\"); print }'" >> "$TMP/guard-prefix.sh"
run_help "$TMP/guard-prefix.sh"
check "guard control: the pre-fix shape still exits 0 on the same empty extraction" "$RC" "0"
check "guard control: …while printing nothing — the exact defect #1528 names" \
  "$(wc -c < "$OUT" | tr -d ' ')" "0"

# Every production site must carry the guard: a bare `awk …` help line with no
# `||` follow-up is the regression this whole part exists to prevent.
UNGUARDED=""
for f in .claude/scripts/*.sh .claude/hooks/*.sh .github/scripts/*.sh; do
  [ -f "$f" ] || continue
  case "$f" in */tests/*) continue ;; esac
  grep -q "awk 'NR == 1" "$f" || continue
  # The help line must end in `||`, handing off to the guard on the next line.
  if ! grep -q "awk 'NR == 1.*END { exit(n ? 0 : 1) }' \"\$0\" ||" "$f"; then
    UNGUARDED="${UNGUARDED}    $f"$'\n'
  fi
done
if [ -n "$UNGUARDED" ]; then
  bad "every awk --help site carries the empty-extraction guard; unguarded:"
  printf '%s' "$UNGUARDED"
else
  ok "every awk --help site carries the empty-extraction guard"
fi

# TERMINATOR INVARIANT.
#
# The extraction must stop at the first NON-COMMENT line, never at the first
# BLANK one. A blank-line terminator is only correct where a blank line
# separates the header from the code, and four scripts have no such separator:
# polling-state-gate.sh, run-hook-tests.sh, run-python-tests.sh and
# summarize-test-run.sh all run their header straight into `set -uo pipefail`.
# The last three were printing that line — and `shopt -s nullglob` — into their
# own --help. The comment-run terminator is correct everywhere (verified
# output-identical across all sites), so it is the single shipped form.
BLANKTERM=""
TERM_CHECKED=0
for f in .claude/scripts/*.sh .claude/hooks/*.sh .github/scripts/*.sh; do
  [ -f "$f" ] || continue
  case "$f" in */tests/*) continue ;; esac
  grep -q "awk 'NR == 1" "$f" || continue
  TERM_CHECKED=$((TERM_CHECKED + 1))
  if grep -q "awk 'NR == 1 { next } /\^\$/ { exit }" "$f"; then
    BLANKTERM="${BLANKTERM}    $f — uses the blank-line terminator; it emits code where no blank separator exists"$'\n'
  fi
done
if [ -n "$BLANKTERM" ]; then
  bad "every --help extraction stops at the first non-comment line; violations:"
  printf '%s' "$BLANKTERM"
else
  ok "every --help extraction stops at the first non-comment line ($TERM_CHECKED sites)"
fi
# Fail closed: the loop must have actually inspected the family.
if [ "$TERM_CHECKED" -ge 40 ]; then
  ok "terminator invariant inspected $TERM_CHECKED awk help sites (>= 40)"
else
  bad "terminator invariant inspected only $TERM_CHECKED sites — discovery is broken"
fi

# Behavioural half: the shipped terminator must actually refuse to print code.
# A fixture whose header runs straight into shell code — no blank separator —
# must yield only the header. This is the defect the three runners shipped.
cat > "$TMP/no-separator.sh" <<NOSEP_EOF
#!/usr/bin/env bash
# fixture.sh — header running straight into code, no blank separator
# HEADER-BODY-MARKER is the last line that belongs in --help.
set -uo pipefail
shopt -s nullglob
case "\${1:-}" in
  --help|-h)
    $GUARDED_EXTRACTION
    exit 0 ;;
esac
NOSEP_EOF
run_help "$TMP/no-separator.sh"
check "no-separator fixture: exits 0" "$RC" "0"
if grep -qF -- "HEADER-BODY-MARKER" "$OUT"; then
  ok "no-separator fixture: emits the header"
else
  bad "no-separator fixture: dropped the header"
fi
if grep -qE 'set -uo pipefail|shopt -s nullglob' "$OUT"; then
  bad "no-separator fixture: LEAKED shell code into --help"
else
  ok "no-separator fixture: never leaks shell code into --help"
fi

# Negative control: the blank-line terminator on the same fixture DOES leak, so
# the assertion above is load-bearing rather than vacuous.
make_bodied_leak() {
  cat > "$TMP/leaky.sh" <<LEAK_EOF
#!/usr/bin/env bash
# fixture.sh — header running straight into code, no blank separator
# HEADER-BODY-MARKER is the last line that belongs in --help.
set -uo pipefail
shopt -s nullglob
case "\${1:-}" in
  --help|-h)
    awk 'NR == 1 { next } /^\$/ { exit } { sub(/^# ?/, ""); print }' "\$0"
    exit 0 ;;
esac
LEAK_EOF
}
make_bodied_leak
run_help "$TMP/leaky.sh"
if grep -qE 'set -uo pipefail|shopt -s nullglob' "$OUT"; then
  ok "control(-): the blank-line terminator DOES leak code on that fixture"
else
  bad "control(-): the blank-line terminator did not leak — the fixture no longer reproduces the bug"
fi

echo
echo "-------------------------------------------"
echo "PASS: $PASS    FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
