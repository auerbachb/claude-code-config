#!/usr/bin/env bash
# Guards the >=420s bound floor for checkpoint-handoff.test.sh (issue #1505).
#
# THE FAILURE THIS PREVENTS
#   checkpoint-handoff.test.sh builds a throwaway git repository per case, so it
#   runs ~71s idle and ~202s under concurrent subagents. On 2026-08-31 a ~240s
#   alarm on a loaded machine reported it as HANGING, and real, already-correct
#   work was parked on the strength of that report (it merged unchanged as
#   rounds 3-5 of PR #1423). The suite was never hanging; the bound was too
#   tight to tell the difference between slow and stuck.
#
#   Two things keep that from recurring, and both are one careless edit from
#   disappearing silently — which is what this suite exists to notice:
#     1. the suite announces its runtime BEFORE the silence starts, and
#     2. nothing applies a bound under 420s that would cover it.
#
# WHY T1 RUNS THE REAL SUITE INSTEAD OF GREPPING IT
#   The property is not "an echo exists somewhere in the file" — it is "the
#   reader sees it before the wait". A grep passes just as happily when the
#   banner has drifted below the fixture building it is supposed to precede, so
#   the assertion has to observe real output ordering. The suite is started for
#   real and killed as soon as its fixture work has announced itself; TMPDIR
#   points at this suite's own scratch directory, so the fixtures orphaned by
#   that kill (the EXIT trap does not run on a signal) are contained and
#   removed here.
#
#   "First line printed" is not enough on its own, because the fixture work is
#   SILENT: a banner moved below the harness build is still the first line, and
#   the wait it explains now happens before it. So a `mktemp` stub makes the
#   fixture work announce itself onto the same stream, and the assertion is an
#   ordering between the two.
#
#   The wait is adaptive — poll until that marker appears — rather than a fixed
#   alarm. A suite whose whole subject is "tight bounds manufacture phantom
#   hangs" must not itself fail because a loaded runner was slow to fork. The
#   60s ceiling below is a genuine-breakage backstop, not a timing assertion.
#
# Requires git. Run from repo root:
#   bash .claude/scripts/tests/checkpoint-handoff-slow-bound.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
# Said plainly here rather than surfacing three lines later as a puzzling
# "/.claude/scripts/... not readable": every path below is built on this, so an
# empty value must stop the run, not quietly root it at /.
if [[ -z "$REPO_ROOT" ]]; then
  echo "FAIL — not inside a git work tree; run this suite from the repo root" >&2
  exit 1
fi
SUITE_REL=".claude/scripts/tests/checkpoint-handoff.test.sh"
SUITE="$REPO_ROOT/$SUITE_REL"
RUNNER="$REPO_ROOT/.github/scripts/run-hook-tests.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/hook-scripts.yml"
BOUNDED_RUN="$REPO_ROOT/.claude/scripts/lib/bounded-run.sh"

# The floor itself, in seconds. Every assertion below reads this rather than a
# literal, so raising the floor is one edit.
FLOOR_SECS=420

# How long a probe waits for a suite to say anything at all before giving up.
# Declared here, beside FLOOR_SECS, rather than next to its first use: probe_suite
# reads it under `set -u`, so a caller added above that assignment would abort on
# an unbound variable instead of running.
WAIT_CEILING=60

SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

# kill_child gives us the process-group kill, so the suite's own children
# (git, the hook under test) die with it instead of outliving the wrapper.
# shellcheck source=/dev/null
if [[ -r "$BOUNDED_RUN" ]]; then
  source "$BOUNDED_RUN"
else
  echo "FAIL — lib/bounded-run.sh not readable at $BOUNDED_RUN" >&2
  exit 1
fi

[[ -r "$SUITE" ]] || { echo "FAIL — $SUITE_REL not readable" >&2; exit 1; }

# ---------------------------------------------------------------------------
# T1/T2 — the banner is emitted before any fixture work, and names the floor
# ---------------------------------------------------------------------------
# "First line of output" alone would NOT prove the banner precedes the fixture
# work, because that work is silent: move the banner below the harness build and
# the banner is still the first thing printed, while the wait it explains now
# happens before it. So the fixture work is made to announce itself too.
#
# A `mktemp` stub earlier on PATH writes a marker and then execs the real binary
# (resolved here, before the stub dir is prepended — a stub that forwarded via
# `command -v` would find itself). `mktemp -d` is the suite's first fixture act
# and the gateway to every `git init` after it, so its first call is the moment
# the silence starts.
#
# Both streams are redirected into ONE file, so ordering between the banner
# (stdout) and the marker (stderr) is a real ordering rather than a race: `>f
# 2>&1` gives both descriptors the same open file description, hence a shared
# append offset.
STUB_BIN="$SCRATCH/stub-bin"
FIXTURE_MARKER="CHECKPOINT-FIXTURE-WORK-BEGINS"
mkdir -p "$STUB_BIN"

REAL_MKTEMP="$(command -v mktemp 2>/dev/null || true)"
if [[ -z "$REAL_MKTEMP" ]]; then
  echo "FAIL — mktemp not on PATH; cannot instrument fixture start" >&2
  exit 1
fi
cat >"$STUB_BIN/mktemp" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$FIXTURE_MARKER" >&2
exec "$REAL_MKTEMP" "\$@"
STUB
chmod +x "$STUB_BIN/mktemp"

# Starts a suite, waits until its fixture work has announced itself, kills it,
# and reports what the combined stream saw. Sets PROBE_FIRST_LINE,
# PROBE_BANNER_LINE and PROBE_MARKER_LINE. Written as a function so the
# ordering assertion can be run against a deliberately broken copy too — a
# check that only ever sees correct input is a check nobody has tested.
probe_suite() { # suite_path, tag
  local suite="$1" tag="$2" out tmpdir pid wait_start wait_now
  out="$SCRATCH/probe-$tag.out"
  tmpdir="$SCRATCH/probe-$tag-tmp"
  mkdir -p "$tmpdir"
  : >"$out"

  # Job control puts the suite in its own process group for the group kill.
  set -m 2>/dev/null || true
  ( cd "$REPO_ROOT" && TMPDIR="$tmpdir" PATH="$STUB_BIN:$PATH" bash "$suite" ) \
    >"$out" 2>&1 </dev/null &
  pid=$!
  set +m 2>/dev/null || true

  # Adaptive wait: stop as soon as the fixture work announces itself, which
  # normally takes milliseconds. The ceiling only trips when the suite produced
  # nothing at all — the breakage being tested for — so it is deliberately far
  # larger than an echo plus one mktemp could ever need, and is never itself
  # the thing under test.
  #
  # The clock is read every pass rather than counting iterations: `sleep 0.1`
  # falls back to `sleep 1` where fractional sleep is unsupported, and an
  # iteration count calibrated for the fast path would silently become a
  # 10-minute ceiling there. Counting ticks to bound wall-clock time is the
  # same mistake this whole suite exists to prevent.
  # BOTH tokens, not just the marker. The stub writes the marker BEFORE exec-ing
  # the real mktemp, so on a suite whose banner sits after that first `mktemp -d`
  # returns — which is exactly the mutated copy NC5 builds — stopping at the
  # marker can read and kill before the banner is ever written. The banner then
  # looks absent and NC5 fails, most often when mktemp is slow: the same load
  # this suite exists to tolerate. The ordering in the file is truthful whenever
  # it is read; the only requirement is not to stop reading too early.
  #
  # Every bail-out below still applies, so a suite that genuinely never prints
  # one of the two ends the wait on process exit or the ceiling and is reported
  # by the both-observations guard rather than waited on forever.
  wait_start="$(date -u +%s 2>/dev/null || true)"
  while ! { grep -qF "$FIXTURE_MARKER" "$out" 2>/dev/null && grep -q 'SLOW SUITE' "$out" 2>/dev/null; }; do
    kill -0 "$pid" 2>/dev/null || break
    wait_now="$(date -u +%s 2>/dev/null || true)"
    # An unreadable clock must not mean "wait forever"; stop and let the
    # assertions report on whatever was written.
    case "${wait_start}:${wait_now}" in
      *[!0-9:]*|:*|*:) break ;;
    esac
    (( wait_now - wait_start >= WAIT_CEILING )) && break
    sleep 0.1 2>/dev/null || sleep 1
  done

  PROBE_FIRST_LINE="$(head -n 1 "$out" 2>/dev/null || true)"
  # Line numbers on the single shared stream, so these are a real ordering.
  PROBE_BANNER_LINE="$(grep -n 'SLOW SUITE' "$out" 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
  PROBE_MARKER_LINE="$(grep -nF "$FIXTURE_MARKER" "$out" 2>/dev/null | head -n 1 | cut -d: -f1 || true)"

  kill_child TERM "$pid"
  for _ in 1 2; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill_child KILL "$pid"
  wait "$pid" 2>/dev/null || true
  return 0
}

# banner_precedes_fixtures → 0 when the last probe saw the banner before the
# first fixture act. Both line numbers must exist: a missing marker means the
# probe never observed fixture work and the comparison would be meaningless.
banner_precedes_fixtures() {
  [[ "$PROBE_BANNER_LINE" =~ ^[0-9]+$ ]] || return 1
  [[ "$PROBE_MARKER_LINE" =~ ^[0-9]+$ ]] || return 1
  (( PROBE_BANNER_LINE < PROBE_MARKER_LINE ))
}

PROBE_FIRST_LINE=""
PROBE_BANNER_LINE=""
PROBE_MARKER_LINE=""

probe_suite "$SUITE" real
FIRST_LINE="$PROBE_FIRST_LINE"
REAL_BANNER_LINE="$PROBE_BANNER_LINE"
REAL_MARKER_LINE="$PROBE_MARKER_LINE"

if [[ -n "$FIRST_LINE" ]]; then
  pass "T1 the suite writes output before its fixture work completes"
else
  fail "T1 the suite produced no output within ${WAIT_CEILING}s — a watcher sees only silence"
fi

if [[ "$FIRST_LINE" == "$SUITE_REL:"* || "$FIRST_LINE" == "checkpoint-handoff.test.sh:"* ]] \
   && [[ "$FIRST_LINE" == *SLOW* ]]; then
  pass "T1 first line is the slow-suite banner, not a test result"
else
  fail "T1 first line is not the slow-suite banner (got: '$FIRST_LINE')"
fi

# The assertion the "first line" check cannot make on its own: fixture work is
# SILENT, so a banner moved below the harness build is still the first line
# printed while no longer preceding the wait it exists to explain.
if banner_precedes_fixtures; then
  pass "T1 banner (line $REAL_BANNER_LINE) precedes the first fixture act (line $REAL_MARKER_LINE)"
else
  fail "T1 banner does not precede fixture work (banner line: '${REAL_BANNER_LINE:-none}', first fixture act: '${REAL_MARKER_LINE:-none}')"
fi

# T2 — the banner carries the number, so a reader deciding on a bound reads it
# off the terminal instead of guessing. Parsed, never string-compared: the
# wording is free to change, the floor is not.
# Both spellings of the comparison, and any unit starting with "s" — `>= 420s`,
# `≥420 seconds`, `>=420 sec` all parse. Pinning one exact spelling would make a
# harmless rewording of the banner fail a test that is supposed to care only
# about the number.
BANNER_BOUND="$(printf '%s' "$FIRST_LINE" | grep -Eo '(>=|≥)[[:space:]]*[0-9]+[[:space:]]*s' | grep -Eo '[0-9]+' | head -n 1 || true)"
if [[ -n "$BANNER_BOUND" ]] && (( BANNER_BOUND >= FLOOR_SECS )); then
  pass "T2 banner names a bound floor >= ${FLOOR_SECS}s (found ${BANNER_BOUND}s)"
else
  fail "T2 banner does not name a bound floor >= ${FLOOR_SECS}s (found: '${BANNER_BOUND:-none}')"
fi

# ---------------------------------------------------------------------------
# Detectors — shared by the repo scan and by its negative controls
# ---------------------------------------------------------------------------
# Only EXECUTABLE bound applications count: `timeout 240`, `run_bounded 240`,
# `--timeout=240`, `timeout-minutes: 4`. Prose such as "any bound must be >=
# 420s" or "a ~240s alarm" is deliberately unmatched — this guard is about what
# runs, and matching English would make every doc that explains the floor trip
# the guard that enforces it.
#
# Tokenised rather than pattern-matched, because the two shapes a regex gets
# wrong are the ones that matter most:
#   * `timeout --foreground 240 …` / `timeout -k 10s 240 …` — the duration is
#     not adjacent to the command, so "number right after timeout" MISSES a
#     real violation. Option words are skipped, and the four that take a
#     separate argument consume it (so `-k 10s` is not mistaken for the bound).
#   * `timeout 10m …` — 600s, compliant, but read as a bare integer it is "10"
#     and gets reported as a violation. Suffixes are converted, so a guard
#     against tight bounds cannot itself block a generous one.
second_bounds() { # file → one integer per bound application, normalised to seconds
  awk '
    function dur2sec(t,   u, v) {
      if (t !~ /^[0-9]+(\.[0-9]+)?[smhd]?$/) return -1
      u = ""
      if (t ~ /[smhd]$/) { u = substr(t, length(t), 1); t = substr(t, 1, length(t) - 1) }
      v = t + 0
      if (u == "m") v *= 60
      else if (u == "h") v *= 3600
      else if (u == "d") v *= 86400
      return int(v)
    }
    {
      n = split($0, tok, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        w = tok[i]
        sub(/^[^A-Za-z0-9_-]+/, "", w)   # strip leading ( ; && " etc
        # Compared on the BASENAME: `/usr/bin/timeout 240` and
        # `/opt/homebrew/bin/gtimeout 240` are bounds like any other, and this
        # repo tells its agents to invoke CLIs by absolute path precisely because
        # a minimal PATH makes a bare name unreliable — so the path-qualified
        # form is the one likely to be written here. Only a trailing component
        # named exactly timeout/gtimeout counts, so `my_timeout 240` (no slash,
        # different command) still does not match.
        b = w
        sub(/^.*\//, "", b)
        s = -1
        bt = ""
        if (b == "timeout" || b == "gtimeout") {
          j = i + 1
          while (j <= n && substr(tok[j], 1, 1) == "-") {
            if (tok[j] == "-k" || tok[j] == "--kill-after" || tok[j] == "-s" || tok[j] == "--signal") j++
            j++
          }
          if (j <= n) { bt = tok[j]; s = dur2sec(bt) }
        }
        else if (w ~ /^g?timeout=/)  { bt = substr(w, index(w, "=") + 1); s = dur2sec(bt) }
        else if (w == "run_bounded") { if (i + 1 <= n) { bt = tok[i + 1]; s = dur2sec(bt) } }
        else if (w == "--timeout")   { if (i + 1 <= n) { bt = tok[i + 1]; s = dur2sec(bt) } }
        else if (w ~ /^--timeout=/)  { bt = substr(w, index(w, "=") + 1); s = dur2sec(bt) }
        if (s >= 0) print s
        # A bound whose duration is a shell variable cannot be shown to clear the
        # floor, and dropping it silently is the one failure this guard must not
        # have: `run_bounded "$BOUND"` is the dominant idiom in this repo, so the
        # hole would sit exactly where a real bound would be written. Reported as
        # unverifiable, matching how the chain-readability check treats a link it
        # cannot read. The `$` test is what keeps prose out: `Any timeout must be
        # >= 420s.` also fails to parse as a duration, and flagging every
        # unparseable word would make the docs that explain the floor trip it.
        else if (bt ~ /\$/) print "U:" bt
      }
    }
  ' "$1" 2>/dev/null || true
}

# True when the file stores the suite path in a shell variable, which is enough
# to make every bound in it suspect (see the T3 loop for why this is a file-level
# heuristic rather than variable resolution).
#
# The declaration keywords are part of the pattern, not decoration: anchoring
# straight to `NAME=` reads `local suite=…/checkpoint-handoff.test.sh` as a
# non-assignment, leaves the file at suite-lines scope, and lets a later
# `timeout 240 bash "$suite"` — a line that never names the suite — walk past T3.
# `local` is the ordinary form here (`offenders_in` above opens with one), so the
# hole is on the path a real caller would take, not a hypothetical one.
# The trailing flag group covers `declare -r` / `local -r -i` and friends.
assigns_suite() { # file
  grep -Eq '^[[:space:]]*((local|export|declare|readonly|typeset)[[:space:]]+(-[-A-Za-z]+[[:space:]]+)*)*[A-Za-z_][A-Za-z0-9_]*=.*checkpoint-handoff\.test\.sh' "$1" 2>/dev/null
}

minute_bounds() { # file → one integer per `timeout-minutes:` value
  grep -Eho 'timeout-minutes:[[:space:]]*[0-9]+' "$1" 2>/dev/null \
    | grep -Eo '[0-9]+$' || true
}

# Offending bounds in a file, as human-readable strings. `scope` is either
# `suite-lines` (only lines naming the suite count — a file may legitimately
# bound something else) or `whole-file` (a blanket bound covering every suite).
offenders_in() { # file, scope → offending descriptions, one per line
  # Two statements, not one `local`: every word on a `local` line is expanded
  # in the CALLER's scope before the builtin runs, so `target="$file"` there
  # reads an unset outer `file` and dies under `set -u`.
  local file="$1" scope="$2" v target
  target="$file"
  [[ -r "$file" ]] || return 0
  if [[ "$scope" == "suite-lines" ]]; then
    target="$SCRATCH/suite-lines.$$"
    grep -F 'checkpoint-handoff.test.sh' "$file" >"$target" 2>/dev/null || true
    [[ -s "$target" ]] || return 0
  fi
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if [[ "$v" == U:* ]]; then
      printf '%s: unverifiable bound %s (shell variable — cannot be shown >= %ss)\n' \
        "$file" "${v#U:}" "$FLOOR_SECS"
    elif (( v < FLOOR_SECS )); then
      printf '%s: %ss bound\n' "$file" "$v"
    fi
  done <<<"$(second_bounds "$target")"
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    (( v * 60 < FLOOR_SECS )) && printf '%s: timeout-minutes %s (%ss)\n' "$file" "$v" "$((v * 60))"
  done <<<"$(minute_bounds "$target")"
  return 0
}

# ---------------------------------------------------------------------------
# T3 — no bound under the floor covers this suite
# ---------------------------------------------------------------------------
# Scanned: every tracked executable-ish file. NOT .md — prose about the floor
# names numbers on both sides of it, and documentation is not an orchestration
# path. This file is excluded from its own scan: it carries sub-floor values on
# purpose, as the negative-control fixtures below.
# Derived, never hardcoded: a renamed file with a stale literal here would scan
# ITSELF, and its negative-control fixtures are deliberately sub-floor bounds on
# lines naming the suite — the guard would fail on its own test data.
SELF_ABS="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_REL="${SELF_ABS#"$REPO_ROOT/"}"
FOUND=""
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  # Two forms of the same exclusion. The string compare is the ordinary path;
  # `-ef` (same device+inode) is the backstop for when it cannot match — this
  # repo is routinely reached through a symlinked worktree, where SELF_ABS keeps
  # the symlinked prefix, the REPO_ROOT strip leaves SELF_REL absolute, and the
  # suite would scan ITSELF. Its own negative-control fixtures are sub-floor
  # bounds on lines naming the suite, so that reads as a real violation.
  [[ "$rel" == "$SELF_REL" ]] && continue
  [[ "$REPO_ROOT/$rel" -ef "$SELF_ABS" ]] && continue
  # A file that parks the suite path in a variable can bound it on a line that
  # never names it — `s=…/checkpoint-handoff.test.sh` … `timeout 240 bash "$s"`
  # — and line-scoped matching walks straight past that. Resolving shell
  # variables properly is a linter project, not a test; this is the bounded
  # version. If a file assigns the path at all, EVERY bound in it is treated as
  # covering the suite. That errs toward flagging rather than missing, and the
  # report names the offending value either way.
  scope="suite-lines"
  assigns_suite "$REPO_ROOT/$rel" && scope="whole-file"
  out="$(offenders_in "$REPO_ROOT/$rel" "$scope")"
  [[ -n "$out" ]] && FOUND+="$out"$'\n'
done <<<"$(cd "$REPO_ROOT" && git ls-files -- '*.sh' '*.yml' '*.yaml' '*.py' 2>/dev/null || true)"

# A blanket bound anywhere in the invocation chain covers this suite without
# ever naming it, so the whole chain is scanned whole rather than by line: the
# discovery runner, the CI wrapper that calls it, and the workflow that calls
# that. Listed explicitly instead of derived from a call graph — the chain is
# three files, and a deriver would be more machinery than the thing it guards.
# A new link in that chain adds a line here.
#
# Readability is asserted rather than assumed: offenders_in returns nothing for
# a file it cannot read, so a renamed link would make this scan report "clean"
# precisely because it never looked. Unverifiable is recorded as a failure, not
# as a pass.
# The workflow is scanned whole rather than per-job. A `timeout-minutes` on
# hook-tests-py39 (which runs no bash suite) would be flagged even though it
# cannot affect this one — accepted deliberately: the alternative is parsing
# YAML into job blocks, and the cost of being wrong here is a loud, specific
# message a reader can dismiss in seconds, not a silently missed bound.
SUMMARIZE="$REPO_ROOT/.github/scripts/summarize-test-run.sh"
for f in "$RUNNER" "$SUMMARIZE" "$WORKFLOW"; do
  if [[ ! -r "$f" ]]; then
    FOUND+="$f: not readable — the blanket-bound scan could not run"$'\n'
    continue
  fi
  out="$(offenders_in "$f" whole-file)"
  [[ -n "$out" ]] && FOUND+="$out"$'\n'
done

if [[ -z "${FOUND//[$'\n' ]/}" ]]; then
  pass "T3 no bound under ${FLOOR_SECS}s applies to $SUITE_REL"
else
  fail "T3 bound-floor scan for $SUITE_REL reported:"$'\n'"$FOUND"
fi

# ---------------------------------------------------------------------------
# Negative controls — prove each detector FIRES, so T3 cannot pass by not
# running. A clean repo makes T3 green whether the scan works or is broken;
# these fixtures are the only thing separating those two outcomes.
# ---------------------------------------------------------------------------
NC1="$SCRATCH/nc-suite-line.sh"
cat >"$NC1" <<'FIXTURE'
#!/usr/bin/env bash
run_bounded 240 bash .claude/scripts/tests/checkpoint-handoff.test.sh
FIXTURE
if [[ -n "$(offenders_in "$NC1" suite-lines)" ]]; then
  pass "NC1 detector fires on a 240s bound applied to the suite by name"
else
  fail "NC1 detector missed a 240s run_bounded on the suite — T3 passes vacuously"
fi

NC2="$SCRATCH/nc-blanket-runner.sh"
cat >"$NC2" <<'FIXTURE'
#!/usr/bin/env bash
for t in $TESTS; do timeout 300 bash "$t"; done
FIXTURE
if [[ -n "$(offenders_in "$NC2" whole-file)" ]]; then
  pass "NC2 detector fires on a blanket 300s bound naming no suite"
else
  fail "NC2 detector missed a blanket 300s timeout — T3 passes vacuously"
fi

NC3="$SCRATCH/nc-workflow.yml"
cat >"$NC3" <<'FIXTURE'
jobs:
  hook-tests:
    timeout-minutes: 5
FIXTURE
if [[ -n "$(offenders_in "$NC3" whole-file)" ]]; then
  pass "NC3 detector fires on timeout-minutes: 5 (300s)"
else
  fail "NC3 detector missed timeout-minutes: 5 — T3 passes vacuously"
fi

# The inverse control: a bound AT the floor must NOT be reported, or the guard
# would block the very fix the issue asks for.
NC4="$SCRATCH/nc-at-floor.sh"
cat >"$NC4" <<'FIXTURE'
#!/usr/bin/env bash
timeout 420 bash .claude/scripts/tests/checkpoint-handoff.test.sh
gtimeout 600 bash .claude/scripts/tests/checkpoint-handoff.test.sh
FIXTURE
if [[ -z "$(offenders_in "$NC4" suite-lines)" ]]; then
  pass "NC4 a bound at or above the floor is not reported"
else
  fail "NC4 detector flagged a compliant >= ${FLOOR_SECS}s bound"
fi

# GNU timeout puts its options before the duration, so a "number adjacent to
# the command" reading misses these entirely — a violation that looks compliant
# is worse than no guard at all.
NC4B="$SCRATCH/nc-timeout-options.sh"
cat >"$NC4B" <<'FIXTURE'
#!/usr/bin/env bash
timeout --foreground 240 bash .claude/scripts/tests/checkpoint-handoff.test.sh
timeout -k 10s 300 bash .claude/scripts/tests/checkpoint-handoff.test.sh
FIXTURE
NC4B_HITS="$(offenders_in "$NC4B" suite-lines | wc -l | tr -d '[:space:]')"
if [[ "$NC4B_HITS" == "2" ]]; then
  pass "NC4b detector fires on both option-carrying forms (--foreground 240, -k 10s 300)"
else
  fail "NC4b expected 2 option-carrying violations, detected $NC4B_HITS (a -k argument read as the bound would give a wrong count)"
fi

# The suffix control: `timeout 10m` is 600s and compliant. Read as a bare
# integer it is "10" and the guard would block the very bound the issue asks
# for — a false positive here is how a guard gets deleted.
NC4C="$SCRATCH/nc-suffix.sh"
cat >"$NC4C" <<'FIXTURE'
#!/usr/bin/env bash
timeout 10m bash .claude/scripts/tests/checkpoint-handoff.test.sh
timeout 1h bash .claude/scripts/tests/checkpoint-handoff.test.sh
FIXTURE
if [[ -z "$(offenders_in "$NC4C" suite-lines)" ]]; then
  pass "NC4c minute/hour suffixes are converted, not read as bare seconds"
else
  fail "NC4c flagged a compliant suffixed bound (10m/1h) as under ${FLOOR_SECS}s"
fi

# ...and the same suffix handling must still catch a genuinely tight one.
NC4D="$SCRATCH/nc-suffix-tight.sh"
cat >"$NC4D" <<'FIXTURE'
#!/usr/bin/env bash
timeout 4m bash .claude/scripts/tests/checkpoint-handoff.test.sh
FIXTURE
if [[ -n "$(offenders_in "$NC4D" suite-lines)" ]]; then
  pass "NC4d a suffixed but tight bound (4m = 240s) is still reported"
else
  fail "NC4d missed timeout 4m (240s) — suffix handling swallowed a real violation"
fi

# The indirection control: the bound and the suite name never share a line.
NC4E="$SCRATCH/nc-indirect.sh"
cat >"$NC4E" <<'FIXTURE'
#!/usr/bin/env bash
suite=.claude/scripts/tests/checkpoint-handoff.test.sh
timeout 240 bash "$suite"
FIXTURE
if assigns_suite "$NC4E" && [[ -n "$(offenders_in "$NC4E" whole-file)" ]]; then
  pass "NC4e a bound reached through a variable is still detected"
else
  fail "NC4e missed a 240s bound applied via a suite-path variable"
fi

# ...and the escalation must be conditional, or every file in the repo would be
# scanned as if it bounded this suite.
NC4F="$SCRATCH/nc-no-assignment.sh"
cat >"$NC4F" <<'FIXTURE'
#!/usr/bin/env bash
other=.claude/scripts/tests/ac-gate.test.sh
timeout 30 bash "$other"
FIXTURE
if ! assigns_suite "$NC4F" && [[ -z "$(offenders_in "$NC4F" suite-lines)" ]]; then
  pass "NC4f a tight bound on an unrelated suite is not attributed to this one"
else
  fail "NC4f flagged a bound belonging to a different suite"
fi

# ...and the indirection control again, with the assignment written the way this
# repo actually writes one. NC4e uses a bare `suite=`; a detector anchored to
# `NAME=` passes NC4e while missing every declared form, so the bare case alone
# cannot prove the escalation works. Each keyword is asserted separately: a loop
# that stopped early would otherwise report the whole set as covered.
NC4G="$SCRATCH/nc-indirect-declared.sh"
for kw in local export declare readonly typeset "declare -r" "local -r"; do
  cat >"$NC4G" <<FIXTURE
#!/usr/bin/env bash
$kw suite=.claude/scripts/tests/checkpoint-handoff.test.sh
timeout 240 bash "\$suite"
FIXTURE
  if assigns_suite "$NC4G" && [[ -n "$(offenders_in "$NC4G" whole-file)" ]]; then
    pass "NC4g a bound reached through a '$kw' declaration is still detected"
  else
    fail "NC4g missed a 240s bound applied via a '$kw' suite-path declaration"
  fi
done

# A bound whose DURATION is a variable. Its value is unknowable from the file, so
# the only two options are report it or drop it; dropping it is a silent miss on
# the repo-dominant `run_bounded "$BOUND"` form, which is the failure this guard
# exists to prevent. Each spelling is asserted separately — a quoted "$B" and a
# bare ${B} reach the tokeniser differently.
NC4H="$SCRATCH/nc-variable-bound.sh"
for bound in 'run_bounded "$BOUND"' 'timeout "$BOUND"' 'timeout ${BOUND}' 'run_bounded $BOUND'; do
  cat >"$NC4H" <<FIXTURE
#!/usr/bin/env bash
$bound bash .claude/scripts/tests/checkpoint-handoff.test.sh
FIXTURE
  if [[ "$(offenders_in "$NC4H" suite-lines)" == *"unverifiable bound"* ]]; then
    pass "NC4h a variable bound ($bound) is reported as unverifiable, not dropped"
  else
    fail "NC4h silently dropped a variable bound ($bound) — a sub-floor value would pass unseen"
  fi
done

# ...and the discriminator has to be the variable, not "did not parse as a
# duration". Prose fails to parse too, and flagging it would trip every doc that
# explains the floor. This is NC6 from the other side: same unparseable token,
# opposite verdict, so a widened detector cannot quietly swallow the prose case.
NC4I="$SCRATCH/nc-unparseable-prose.sh"
cat >"$NC4I" <<'FIXTURE'
#!/usr/bin/env bash
# checkpoint-handoff.test.sh: any timeout must be >= 420s, never a 240s alarm.
FIXTURE
if [[ -z "$(offenders_in "$NC4I" suite-lines)" ]]; then
  pass "NC4i an unparseable NON-variable token (prose) is still not a bound"
else
  fail "NC4i flagged prose as an unverifiable bound — docs explaining the floor would trip it"
fi

# Path-qualified bounds. CONTRIBUTING tells agents to invoke CLIs by absolute
# path because a minimal PATH makes a bare name unreliable, and gtimeout is a
# Homebrew binary, so the path-qualified spelling is the likely one here.
NC4J="$SCRATCH/nc-path-qualified.sh"
for cmd in /usr/bin/timeout /opt/homebrew/bin/gtimeout ./bin/timeout; do
  cat >"$NC4J" <<FIXTURE
#!/usr/bin/env bash
$cmd 240 bash .claude/scripts/tests/checkpoint-handoff.test.sh
FIXTURE
  if [[ -n "$(offenders_in "$NC4J" suite-lines)" ]]; then
    pass "NC4j a path-qualified bound ($cmd 240) is detected"
  else
    fail "NC4j missed a 240s bound written as $cmd — a real bound escaped T3"
  fi
done

# ...matching the basename must not turn every name ENDING in timeout into one.
# `my_timeout` is a different command, and flagging it would attribute a bound to
# code that never applied one.
NC4K="$SCRATCH/nc-basename-lookalike.sh"
cat >"$NC4K" <<'FIXTURE'
#!/usr/bin/env bash
my_timeout 240 bash .claude/scripts/tests/checkpoint-handoff.test.sh
FIXTURE
if [[ -z "$(offenders_in "$NC4K" suite-lines)" ]]; then
  pass "NC4k a command merely ending in timeout (my_timeout) is not a bound"
else
  fail "NC4k attributed a bound to my_timeout — basename match is too loose"
fi

# The ordering control (NC5). A real copy of the suite with the banner relocated below
# its first `mktemp -d` — the exact drift the first-line check cannot see, since
# the banner is still the first thing PRINTED. awk carries the banner line
# across rather than the shell, so no quoting in it can break the mutation.
MUTATED="$SCRATCH/mutated-suite.sh"
awk '
  /SLOW SUITE/ && !seen { banner = $0; seen = 1; next }
  { print }
  /mktemp -d/ && seen && !placed { print banner; placed = 1 }
' "$SUITE" >"$MUTATED"

if grep -q 'SLOW SUITE' "$MUTATED" && ! diff -q "$SUITE" "$MUTATED" >/dev/null 2>&1; then
  probe_suite "$MUTATED" mutated
  # Both observations must exist. `banner_precedes_fixtures` also returns
  # non-zero when a line number is MISSING, so a probe that produced nothing at
  # all would look exactly like a correctly-detected violation and this control
  # would pass for the wrong reason — the very failure mode it guards against.
  if [[ ! "$PROBE_MARKER_LINE" =~ ^[0-9]+$ || ! "$PROBE_BANNER_LINE" =~ ^[0-9]+$ ]]; then
    fail "NC5 mutated probe observed no ordering (banner: '${PROBE_BANNER_LINE:-none}', fixture: '${PROBE_MARKER_LINE:-none}') — the check is unproven, not proven"
  elif (( PROBE_BANNER_LINE > PROBE_MARKER_LINE )); then
    pass "NC5 ordering check fires when the banner is moved below the first fixture act"
  else
    fail "NC5 ordering check passed a suite whose banner sits BELOW its fixture work — T1 ordering is vacuous"
  fi
else
  fail "NC5 could not build the mutated fixture — the ordering check is unproven"
fi

# The prose control: the documentation that EXPLAINS the floor names numbers on
# both sides of it. If the detector matched English, every such doc would trip
# the guard enforcing it.
NC6="$SCRATCH/nc-prose.sh"
cat >"$NC6" <<'FIXTURE'
#!/usr/bin/env bash
# checkpoint-handoff.test.sh is slow: ~202s loaded. A ~240s alarm reported a
# phantom hang. Any timeout must be >= 420s.
FIXTURE
if [[ -z "$(offenders_in "$NC6" suite-lines)" ]]; then
  pass "NC6 prose naming 202s/240s is not mistaken for a bound application"
else
  fail "NC6 detector flagged prose — docs explaining the floor would trip it"
fi

# The probe's own race, made deterministic (NC7). A suite that emits the banner
# only after a SLOW first fixture act is the shape NC5 constructs, and a probe
# that stopped at the fixture marker would read and kill before the banner was
# written — reporting "no ordering observed" on a suite that does emit one. The
# sleep turns a load-dependent race into a fixed delay, so this fails reliably
# rather than occasionally if the wait ever stops requiring both tokens again.
NC7="$SCRATCH/nc-slow-banner.sh"
cat >"$NC7" <<'FIXTURE'
#!/usr/bin/env bash
d="$(mktemp -d)"
sleep 2
echo "nc7 fixture: SLOW SUITE — banner emitted after the first fixture act"
sleep 5
FIXTURE
probe_suite "$NC7" slow-banner
if [[ "$PROBE_BANNER_LINE" =~ ^[0-9]+$ && "$PROBE_MARKER_LINE" =~ ^[0-9]+$ ]]; then
  if ! banner_precedes_fixtures; then
    pass "NC7 a banner emitted after a slow fixture act is still observed, and ordered after it"
  else
    fail "NC7 read the banner as preceding fixture work that provably ran first"
  fi
else
  fail "NC7 probe returned before the banner was written (banner: '${PROBE_BANNER_LINE:-none}', fixture: '${PROBE_MARKER_LINE:-none}') — the wait stops too early, so NC5 can fail under load"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
