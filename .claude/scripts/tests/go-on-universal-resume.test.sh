#!/usr/bin/env bash
# Contract tests for /go-on as the universal resume front door (issue #1397).
#
# Guards the invariants that make one command safe to reach for after ANY
# stoppage: every class is detected, precedence is explicit and machine-checked,
# the refill gate is never re-enabled silently, and the dedicated resume
# commands keep working while pointing at /go-on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GO_ON="$ROOT/.claude/skills/go-on/SKILL.md"
PAUSE="$ROOT/.claude/skills/pause/SKILL.md"
PAUSE_RESUME="$ROOT/.claude/skills/pause-resume/SKILL.md"
END="$ROOT/.claude/skills/end/SKILL.md"
END_RESUME="$ROOT/.claude/skills/end-resume/SKILL.md"
LADDER="$ROOT/.claude/reference/universal-resume.md"
SCHEMA="$ROOT/.claude/reference/session-state-schema.json"
REF_README="$ROOT/.claude/reference/README.md"
HANDOFF_TEMPLATE="$ROOT/.claude/skills/end/references/portable-handoff-template.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -Eq -- "$2" "$1" || fail "$(basename "$1") missing: $2"; }
hasnt() {
  if grep -Eq -- "$2" "$1"; then fail "$(basename "$1") must not contain: $2"; fi
}

# Negative control: a guard that cannot fail is not a guard (issue #1397 review).
# Prove has/hasnt actually fire before relying on either below.
CONTROL=$(mktemp) || fail "could not stage the guard control fixture"
trap 'rm -f "$CONTROL"' EXIT
printf 'refill={"paused":false}\n' >"$CONTROL"
( has "$CONTROL" 'no-such-string-anywhere' ) 2>/dev/null \
  && fail "has() passed on a string that is absent"
( hasnt "$CONTROL" 'refill=\{' ) 2>/dev/null \
  && fail "hasnt() passed on a string that is present"

# --- The four resume companions all still exist -----------------------------
for f in "$GO_ON" "$PAUSE" "$PAUSE_RESUME" "$END" "$END_RESUME" "$LADDER"; do
  [[ -f "$f" ]] || fail "missing file: $f"
done
has "$PAUSE_RESUME" '^name: pause-resume$'
has "$END_RESUME" '^name: end-resume$'

# --- /go-on classifies every known stoppage class ---------------------------
has "$GO_ON" '^## Step 0: Classify the stoppage'
has "$GO_ON" 'execution_pauses'                  # planned-stop gate probe
has "$GO_ON" '\.repos\[.*\]\.pauses'             # parked /pause records probe (#1576)
has "$GO_ON" '\.repos\[.*\]\.pause`? / `?\.suspend|legacy singletons'  # legacy union members
has "$GO_ON" 'union'                             # probe B reads a set, not a slot
has "$GO_ON" 'portable-handoff-<owner>-<repo>'   # /end canonical note probe
has "$GO_ON" 'handoff_reason == "token_exhaustion"'
has "$GO_ON" 'unplanned'
has "$GO_ON" 'nothing to resume'
has "$GO_ON" 'unclassifiable'
# The interrupted-workflow lane it routes to is preserved, not replaced.
has "$GO_ON" '^## Step 0b: Identify context'
for step in 'Step 1: Check for an inherited rebase' 'Step 2: Run local CR review' \
            'Step 6: Check for review response' 'Step 8: Check merge gate' \
            'Step 9: Verify acceptance criteria'; do
  has "$GO_ON" "$step"
done

# --- Precedence is explicit, and parked state outranks stall detection ------
has "$GO_ON" 'Precedence — first match wins'
has "$GO_ON" 'Explicit parked state outranks generic stall detection'
has "$GO_ON" 'newest wins'
has "$LADDER" 'Explicit parked state outranks generic stall detection'

# Structural, not textual: the rank table itself must carry all four classes in
# rank order. Dropping or reordering a dispatch row fails here even though every
# one of those words still appears in the surrounding prose.
RANK_ROWS=$(awk -F'|' '
  /^\| Rank \| Class \|/     { flag = 1; next }
  flag && $0 !~ /^\|/        { exit }
  flag && $2 ~ /^ *[0-9]+ *$/ { gsub(/[ `]/, "", $2); gsub(/[ `]/, "", $3)
                                print $2 ":" $3 }
' "$GO_ON")
[[ -n "$RANK_ROWS" ]] || fail "could not extract the precedence table from go-on"
EXPECTED_RANKS='1:pause/end
2:token_exhaustion
3:unplanned
4:none'
[[ "$RANK_ROWS" == "$EXPECTED_RANKS" ]] \
  || fail "precedence table drifted (got: $(tr '\n' ' ' <<<"$RANK_ROWS"))"

# An unreadable planned-stop gate must bar every resuming rank, not only the
# two that mention it in prose. Rank 2 continues a recorded phase, which is a
# resume like any other: a token-exhaustion handoff says a phase ran out of
# budget, never that no pause/end gate is armed (issue #1397 Greptile P1).
# Assert the readability condition on the rank rows themselves, so dropping it
# from a "Fires on" cell fails here.
fires_on() {
  awk -F'|' -v want="$1" '
    /^\| Rank \| Class \|/     { flag = 1; next }
    flag && $0 !~ /^\|/        { exit }
    flag && $2 ~ /^ *[0-9]+ *$/ { r = $2; gsub(/ /, "", r)
                                  if (r == want) { print $4; exit } }
  ' "$GO_ON"
}
for guarded_rank in 2 3 4; do
  cell=$(fires_on "$guarded_rank")
  [[ -n "$cell" ]] || fail "precedence table has no rank $guarded_rank row"
  grep -Eq 'readable' <<<"$cell" \
    || fail "rank $guarded_rank must require a readable planned-stop probe (got:$cell)"
done
# And the prose that names which ranks an unreadable gate bars must agree.
has "$GO_ON" 'blocks ranks 2, 3, and 4 outright'
has "$GO_ON" 'ranks 2, 3, and 4 are all barred'
has "$LADDER" 'bars ranks 2, 3, and 4 outright'

# --- The refill gate is never re-enabled silently ---------------------------
has "$GO_ON" '\-\-resume-refill'
has "$GO_ON" 'never writes `refill.paused`'
# A direct refill write from /go-on would bypass the delegated command's contract.
hasnt "$GO_ON" 'refill=\{'
hasnt "$GO_ON" 'refill\.paused='
# Mechanism, not spelling: reject any state-WRITE invocation that mentions
# refill at all, so a jq-built object or a differently-spelled assignment path
# reaches this guard too. Reads (--get) stay allowed; probe C reads the refill
# record as corroborating evidence.
if grep -nE -- '--set[[:alnum:]-]*.*refill' "$GO_ON"; then
  fail "go-on must not write refill state — the delegated resume command owns it"
fi
has "$PAUSE_RESUME" 'only with --resume-refill'
has "$END_RESUME" 'unless --resume-refill'

# --- No duplicate live tasks or Monitors ------------------------------------
has "$GO_ON" 'Never duplicate a live task or Monitor'
has "$GO_ON" '\-\-list --live'
has "$GO_ON" 'babysit.active'
has "$GO_ON" 'resume receipt|Resume receipt'
has "$GO_ON" 'evidence_digest'
has "$GO_ON" '\-\-again'
has "$SCHEMA" '_resume_comment'
has "$SCHEMA" 'evidence_digest'

# --- Monitor re-arming stays with the owning skills -------------------------
has "$GO_ON" 'owning skills'
has "$LADDER" 'Monitors and watches: owned elsewhere'

# --- "Could not look" is never "nothing there" ------------------------------
has "$GO_ON" 'never reads as "no evidence"'
has "$GO_ON" 'checked both installed paths'
# A failed/malformed read must stay "unknown", never collapse to "no gate".
has "$GO_ON" 'GATE_STATE=unreadable'
has "$GO_ON" 'never default to absent'
has "$LADDER" 'tri-state'
has "$LADDER" 'could not look'

# Structural: check WHERE `absent` can be reached, not just that the token
# exists. A regression that treats an unreadable planned-stop record as absent
# unbars ranks 3 and 4 while a stop may still be armed — the exact safety
# inversion the ladder exists to prevent — so pin both absent-producing paths.
PROBE_A=$(awk '
  index($0, "GATE_STATE=unreadable") && !flag { flag = 1 }
  flag                                        { print }
  flag && /^GATE_CLASS=/                      { exit }
' "$GO_ON")
[[ -n "$PROBE_A" ]] || fail "could not extract the planned-stop probe from go-on"
ABSENT_LINES=$(grep -c 'GATE_STATE=absent' <<<"$PROBE_A" || true)
[[ "$ABSENT_LINES" == "2" ]] || fail \
  "probe A reaches GATE_STATE=absent on $ABSENT_LINES lines (expected 2: exit 3, validated empty map)"
grep -Eq 'READ_RC == 3 \)\)' <<<"$PROBE_A" \
  || fail "probe A no longer isolates exit 3 as the only no-state-file case"
# The failed-read branch must land on unreadable on its very next line.
grep -A1 -E 'READ_RC != 0 \)\)' <<<"$PROBE_A" | grep -q 'GATE_STATE=unreadable' \
  || fail "a failed read (READ_RC != 0) must set GATE_STATE=unreadable, not absent"
# So must the malformed-map fallback (the else arm of the jq validation).
grep -A1 -E '^[[:space:]]*else[[:space:]]*$' <<<"$PROBE_A" | grep -q 'GATE_STATE=unreadable' \
  || fail "a malformed gate map must set GATE_STATE=unreadable, not absent"

# --- Stop-state helpers resolve from installed locations only ---------------
RESOLVER=$(awk '/^resolve_installed\(\) \{/{flag=1} flag{print} /^\}$/{if(flag)exit}' "$GO_ON")
[[ -n "$RESOLVER" ]] || fail "go-on has no resolve_installed() candidate list"
grep -q 'skills-worktree/.claude/scripts' <<<"$RESOLVER" \
  || fail "stop-state candidate list omits the skills-worktree entry"
grep -q '"\$HOME/.claude/scripts' <<<"$RESOLVER" \
  || fail "stop-state candidate list omits the \$HOME install entry"
# Inspect every candidate rather than matching one source spelling: a
# checkout-relative fallback written as "./.claude/scripts/…", "$PWD/…", or via
# any other expansion is caught by requiring each candidate to be $HOME-rooted.
CANDIDATES=$(grep -F '.claude/scripts' <<<"$RESOLVER")
[[ -n "$CANDIDATES" ]] || fail "resolve_installed() lists no .claude/scripts candidates"
while IFS= read -r cand_line; do
  grep -q '\$HOME/' <<<"$cand_line" \
    || fail "stop-state candidate is not \$HOME-rooted (untrusted checkout):$cand_line"
done <<<"$CANDIDATES"

# --- The dedicated commands keep working and point at /go-on ---------------
has "$PAUSE_RESUME" '/go-on. is the primary entry point'
has "$END_RESUME" '/go-on. is the primary entry point'
has "$PAUSE_RESUME" 'keeps working unchanged'
has "$END_RESUME" 'keeps working unchanged'
has "$PAUSE" '/go-on'
has "$END" '/go-on'
# The portable handoff document has a reader outside this harness; its
# Resume command: field is lint-restricted to /end-resume.
[[ -f "$HANDOFF_TEMPLATE" ]] || fail "missing portable handoff template"
hasnt "$HANDOFF_TEMPLATE" '/go-on'

# --- The ladder is catalogued -----------------------------------------------
has "$REF_README" 'universal-resume\.md'
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SCHEMA" \
  || fail "session-state-schema.json is not valid JSON"
python3 - "$SCHEMA" <<'PY' || exit 1
import json, sys
repo = json.load(open(sys.argv[1]))["repos"]["org/repo"]
FIELDS = ("class", "evidence_digest", "at", "session_id", "dispatched_to")

# Issue #1576: receipts are keyed per session. The legacy singleton stays
# documented as a READ-ONLY fallback, so both shapes must be present.
resumes = repo.get("resumes")
assert isinstance(resumes, dict) and resumes, \
    "repos[].resumes is not documented as a session-keyed map"
for key, receipt in resumes.items():
    assert isinstance(receipt, dict), f"resumes[{key}] is not an object"
    for field in FIELDS:
        assert field in receipt, f"resumes[{key}] is missing {field}"
    assert receipt.get("session_id") == key, \
        f"resumes[{key}] must be self-describing (session_id != key)"

legacy = repo.get("resume")
assert isinstance(legacy, dict), "legacy repos[].resume must stay documented"
for field in FIELDS:
    assert field in legacy, f"legacy resume receipt is missing {field}"
assert "LEGACY READ-ONLY" in repo["_resume_comment"], \
    "the singleton resume slot must be annotated as legacy read-only"

# The pause side is keyed the same way, with the same legacy annotation.
pauses = repo.get("pauses")
assert isinstance(pauses, dict) and pauses, \
    "repos[].pauses is not documented as a session-keyed map"
for key, record in pauses.items():
    assert record.get("session_id") == key, \
        f"pauses[{key}] must be self-describing (session_id != key)"
    assert "active" in record and "paused_at" in record and "marker_path" in record, \
        f"pauses[{key}] is missing a required pause-board field"
assert isinstance(repo.get("pause"), dict), "legacy repos[].pause must stay documented"
assert "LEGACY READ-ONLY" in repo["_pause_comment"], \
    "the singleton pause slot must be annotated as legacy read-only"
PY

# --- Behavioral: the documented newest-wins filter, run on real fixtures ----
# Extract the jq program /go-on documents rather than restating it, so the test
# fails when the skill's own filter drifts.
FILTER=$(awk '
  index($0, "GATE_JSON=$(jq -c") { flag = 1; next }
  flag && index($0, "<<<")       { flag = 0 }
  flag                           { print }
' "$GO_ON")
[[ -n "$FILTER" ]] || fail "could not extract the planned-stop gate filter from go-on"

gate_class() { jq -r "$FILTER" <<<"$1" | jq -r '.class // ""'; }

PAUSE_OLDER='{"s1":{"active":true,"command":"pause","at":"2026-08-22T22:10:00Z","cleared_at":null},
              "s2":{"active":true,"command":"end","at":"2026-08-23T09:00:00Z","cleared_at":null}}'
END_OLDER='{"s1":{"active":true,"command":"pause","at":"2026-08-23T09:00:00Z","cleared_at":null},
            "s2":{"active":true,"command":"end","at":"2026-08-22T22:10:00Z","cleared_at":null}}'
END_CLEARED='{"s1":{"active":true,"command":"pause","at":"2026-08-22T22:10:00Z","cleared_at":null},
              "s2":{"active":false,"command":"end","at":"2026-08-23T09:00:00Z","cleared_at":"2026-08-23T09:30:00Z"}}'

[[ "$(gate_class "$PAUSE_OLDER")" == "end" ]] \
  || fail "newest-wins picked the older pause over the newer end"
[[ "$(gate_class "$END_OLDER")" == "pause" ]] \
  || fail "newest-wins picked the older end over the newer pause"
[[ "$(gate_class "$END_CLEARED")" == "pause" ]] \
  || fail "a cleared gate must not classify the stoppage"
[[ -z "$(gate_class '{}')" ]] \
  || fail "an empty gate map must yield no class (nothing to resume)"
[[ -z "$(gate_class 'null')" ]] \
  || fail "an absent gate map must yield no class (nothing to resume)"

# Unorderable or unrecognized evidence must fail the filter (-> unclassifiable),
# never sort into a confident answer.
BAD_STAMP='{"s1":{"active":true,"command":"pause","at":"2026-08-22T22:10:00-04:00","cleared_at":null}}'
BAD_COMMAND='{"s1":{"active":true,"command":"halt","at":"2026-08-22T22:10:00Z","cleared_at":null}}'
MALFORMED='["not-a-map"]'
if jq -ce "$FILTER" <<<"$BAD_STAMP" >/dev/null 2>&1; then
  fail "a non-UTC-Z stamp must not classify the stoppage"
fi
if jq -ce "$FILTER" <<<"$BAD_COMMAND" >/dev/null 2>&1; then
  fail "an unknown gate command must not classify the stoppage"
fi
if jq -ce "$FILTER" <<<"$MALFORMED" >/dev/null 2>&1; then
  fail "a malformed gate map must not classify the stoppage"
fi
# Control: the same invocation shape succeeds on a valid map, so the three
# assertions above are failing on the fixture, not on the invocation.
jq -ce "$FILTER" <<<"$PAUSE_OLDER" >/dev/null 2>&1 \
  || fail "the gate filter rejected a valid map — the negative cases prove nothing"

# /go-on branches on this exit code to tell "read and validated, but empty"
# (absent) from "could not read" (unreadable). An empty result must still exit 0,
# or a repo that never stopped would classify as unclassifiable forever.
ALL_CLEARED='{"s1":{"active":false,"command":"end","at":"2026-08-23T09:00:00Z","cleared_at":"2026-08-23T09:30:00Z"}}'
for empty_fixture in '{}' 'null' "$ALL_CLEARED"; do
  EMPTY_OUT=$(jq -ce "$FILTER" <<<"$empty_fixture") \
    || fail "an empty-but-valid gate map must exit 0, else absent reads as unreadable"
  [[ "$EMPTY_OUT" == '{}' ]] \
    || fail "an empty-but-valid gate map must yield {} (got: $EMPTY_OUT)"
done

echo "OK: /go-on universal resume contract tests passed"
