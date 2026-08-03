#!/usr/bin/env bash
# Tests for babysit-tick-watchdog.sh (issue #914).
#
# The hook warns when an armed /babysit-pr watcher has produced no tick within
# 2 x cadence_effective_minutes. Coverage is deliberately weighted toward the
# NEGATIVE controls: a watchdog that warns on everything is indistinguishable
# from one that works, and both pass a naive "did it warn?" suite
# (memory: guards-that-pass-by-not-running / restructure-silently-disables-other-guards).
# Never touches real session state.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/babysit-tick-watchdog.sh"

TMP_DIR="$(mktemp -d)"
export HOME="$TMP_DIR"
export CLAUDE_SESSION_REPO="test/repo"
export CLAUDE_BABYSIT_WATCHDOG_MARKER_DIR="$TMP_DIR/markers"
mkdir -p "$TMP_DIR/.claude" "$TMP_DIR/markers"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   — $*"; }

context_of() { jq -r '.hookSpecificOutput.additionalContext // ""'; }

# UTC ISO-8601 timestamp N minutes in the past (negative N = the future).
# Naive negation ("-${mins}" with mins=-60) yields "--60 minutes", which BOTH
# date implementations reject — so the sign is normalised explicitly.
ago() {
  local mins="$1" sign="-" abs="$1"
  if [[ "$mins" == -* ]]; then sign="+"; abs="${mins#-}"; fi
  date -u -d "${sign}${abs} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  date -u -v"${sign}${abs}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  return 1
}

# Fail closed: if offset arithmetic is unavailable, every timestamp below would
# be empty and the whole suite would pass vacuously by never warning.
_probe_past="$(ago 17)"   || fail "no usable date implementation for past offsets"
_probe_future="$(ago -60)" || fail "no usable date implementation for future offsets"
[[ "$_probe_past"   =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || fail "past-offset probe produced a malformed timestamp: '$_probe_past'"
[[ "$_probe_future" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || fail "future-offset probe produced a malformed timestamp: '$_probe_future'"

# $1 = PR number, $2 = JSON object for that PR's fields.
write_state() {
  jq -n --arg repo "$CLAUDE_SESSION_REPO" --arg pr "$1" --argjson body "$2" \
    '{repos: {($repo): {prs: {($pr): $body}}}}' > "$TMP_DIR/.claude/session-state.json"
}

# Raw multi-PR fixture.
write_state_raw() {
  jq -n --arg repo "$CLAUDE_SESSION_REPO" --argjson prs "$1" \
    '{repos: {($repo): {prs: $prs}}}' > "$TMP_DIR/.claude/session-state.json"
}

run_hook() {
  jq -cn --arg sid "test-session" '{session_id: $sid, tool_name: "Read"}' | bash "$HOOK"
}

reset_markers() { rm -rf "$TMP_DIR/markers"; mkdir -p "$TMP_DIR/markers"; }

PR="908"

# ── 1. Stalled watcher warns (the core case) ────────────────────────────────
write_state "$PR" "$(jq -n --arg t "$(ago 17)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
ctx="$(run_hook | context_of)"
[[ -n "$ctx" ]] || fail "expected a warning for a 17m-stale 5m watcher"
grep -q "NOT TICKING" <<<"$ctx" || fail "expected NOT TICKING banner, got: $ctx"
grep -q "#${PR}" <<<"$ctx" || fail "expected PR number in message, got: $ctx"
ok "17m-stale watcher at 5m cadence warns (2x threshold = 10m)"

# ── 2. NEGATIVE CONTROL: fresh tick must stay silent ────────────────────────
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 3)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
ctx="$(run_hook | context_of)"
[[ -z "$ctx" ]] || fail "fresh 3m tick must NOT warn, got: $ctx"
ok "negative control — fresh tick is silent"

# ── 3. Boundary: just under 2x is silent, at 2x warns ───────────────────────
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 9)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
[[ -z "$(run_hook | context_of)" ]] || fail "9m < 2x5m must be silent"
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 11)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
[[ -n "$(run_hook | context_of)" ]] || fail "11m >= 2x5m must warn"
ok "boundary — silent at 9m, warns at 11m (2x5m window)"

# ── 4. Window tracks cadence, not a hard-coded 10m ──────────────────────────
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 17)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:15}}')"
[[ -z "$(run_hook | context_of)" ]] || fail "17m must be silent at 15m cadence (2x=30m)"
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 31)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:15}}')"
ctx="$(run_hook | context_of)"
[[ -n "$ctx" ]] || fail "31m must warn at 15m cadence"
grep -q "warn at 30m" <<<"$ctx" || fail "expected the 30m window named, got: $ctx"
ok "window is 2x cadence, not a constant (silent 17m / warns 31m at 15m base)"

# ── 5. NEGATIVE CONTROL: inactive and stopped watchers stay silent ──────────
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 99)" \
  '{babysit:{active:false,last_tick_at:$t,cadence_effective_minutes:5}}')"
[[ -z "$(run_hook | context_of)" ]] || fail "active:false must never warn"
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 99)" \
  '{babysit:{active:true,stop_requested:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
[[ -z "$(run_hook | context_of)" ]] || fail "stop_requested:true must never warn"
ok "negative control — inactive and stop_requested watchers are silent"

# ── 6. Dedupe: same dead stretch warns once, a real tick re-arms it ─────────
reset_markers
STALE="$(ago 40)"
write_state "$PR" "$(jq -n --arg t "$STALE" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
[[ -n "$(run_hook | context_of)" ]] || fail "first warning expected"
[[ -z "$(run_hook | context_of)" ]] || fail "second call on the SAME last_tick_at must dedupe"
write_state "$PR" "$(jq -n --arg t "$(ago 30)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
[[ -n "$(run_hook | context_of)" ]] || fail "a new last_tick_at must re-arm the warning"
ok "dedupe holds per dead stretch, and a moved last_tick_at re-arms"

# ── 7. NEGATIVE CONTROL: malformed / missing inputs never nag ───────────────
reset_markers
write_state "$PR" '{"babysit":{"active":true,"last_tick_at":"not-a-timestamp","cadence_effective_minutes":5}}'
[[ -z "$(run_hook | context_of)" ]] || fail "unparseable last_tick_at must be silent, not a false alarm"
reset_markers
write_state "$PR" '{"babysit":{"active":true,"cadence_effective_minutes":5}}'
[[ -z "$(run_hook | context_of)" ]] || fail "absent last_tick_at must be silent"
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago -60)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
[[ -z "$(run_hook | context_of)" ]] || fail "future-dated tick (clock skew) must be silent"
reset_markers
write_state "$PR" '{"reviewer":"cr"}'
[[ -z "$(run_hook | context_of)" ]] || fail "PR with no babysit object must be silent"
reset_markers
rm -f "$TMP_DIR/.claude/session-state.json"
[[ -z "$(run_hook | context_of)" ]] || fail "missing state file must be silent"
ok "negative control — malformed, absent, skewed and stateless inputs stay silent"

# ── 8. Cadence fallbacks ────────────────────────────────────────────────────
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 25)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_base_minutes:10}}')"
ctx="$(run_hook | context_of)"
grep -q "warn at 20m" <<<"$ctx" || fail "expected fallback to cadence_base_minutes (20m), got: $ctx"
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 25)" '{babysit:{active:true,last_tick_at:$t}}')"
ctx="$(run_hook | context_of)"
grep -q "warn at 10m" <<<"$ctx" || fail "expected default 5m cadence -> 10m window, got: $ctx"
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 25)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:0}}')"
ctx="$(run_hook | context_of)"
grep -q "warn at 10m" <<<"$ctx" || fail "cadence 0 must fall back to 5m, not divide-by-zero, got: $ctx"
ok "cadence fallbacks — effective, then base, then 5m default; 0 is rejected"

# ── 9. Multiple stalled watchers are reported in one advisory ───────────────
reset_markers
write_state_raw "$(jq -n --arg a "$(ago 40)" --arg b "$(ago 40)" --arg c "$(ago 1)" '{
  "901": {babysit:{active:true,last_tick_at:$a,cadence_effective_minutes:5}},
  "902": {babysit:{active:true,last_tick_at:$b,cadence_effective_minutes:5}},
  "903": {babysit:{active:true,last_tick_at:$c,cadence_effective_minutes:5}}
}')"
ctx="$(run_hook | context_of)"
grep -q "#901" <<<"$ctx" || fail "expected #901 in combined advisory, got: $ctx"
grep -q "#902" <<<"$ctx" || fail "expected #902 in combined advisory, got: $ctx"
# `grep -q … && fail` would abort the suite under `set -e` on the SUCCESS path
# (grep exits 1 when absent, which is what we want), so branch explicitly.
if grep -q "#903" <<<"$ctx"; then fail "fresh #903 must NOT appear, got: $ctx"; fi
ok "multiple stalled watchers combine into one advisory; fresh ones excluded"

# ── 10. Output is always valid JSON or empty, and never blocks ──────────────
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 40)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
out="$(run_hook)"; rc=$?
[[ "$rc" -eq 0 ]] || fail "hook must exit 0, got $rc"
jq -e . >/dev/null <<<"$out" || fail "hook emitted invalid JSON: $out"
# `.decision // empty` yields NO output when the key is absent, which makes
# `jq -e` exit 4 — i.e. the assertion failed on the very case it should pass.
jq -e 'has("decision") | not' >/dev/null <<<"$out" \
  || fail "advisory hook must never emit a blocking decision: $out"
ok "exit 0, valid JSON, no blocking decision"

# ── 11. A PR key containing path separators still dedupes ───────────────────
# State keys are normally bare numbers. A corrupted key with slashes cannot
# escape the marker dir (the "claude-babysit-tickwarn-<sid>-" prefix means any
# ".." lands on a non-directory), but WITHOUT sanitization the marker write
# fails silently — so nothing is recorded and the advisory re-fires on every
# single tool call. Dedupe, not traversal, is the property under test; asserting
# traversal here passed against a deliberately unsanitized hook (vacuous).
reset_markers
write_state_raw "$(jq -n --arg t "$(ago 40)" '{
  "../../evil/908": {babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}
}')"
[[ -n "$(run_hook | context_of)" ]] || fail "expected a warning for the stale odd-keyed watcher"
[[ -z "$(run_hook | context_of)" ]] \
  || fail "odd PR key must still dedupe — an unwritable marker nags on every tool call"
stray="$(find "$TMP_DIR" -name 'claude-babysit-tickwarn-*' \
         -not -path "$CLAUDE_BABYSIT_WATCHDOG_MARKER_DIR/*" 2>/dev/null | head -1)"
[[ -z "$stray" ]] || fail "marker written outside the marker dir: $stray"
ok "odd PR key is sanitized — marker stays in-dir and dedupe still holds"

# ── 12. Recovery advice must be actionable in this window (CodeAnt, PR #922) ─
# The warning fires at 2 x cadence, but /babysit-pr A2 refuses a duplicate until
# max(3 x cadence, 30m). Between those two windows a bare "re-arm it" silently
# no-ops, so the message MUST name /babysit-pr-stop first. Regression pin.
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 12)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
ctx="$(run_hook | context_of)"
[[ -n "$ctx" ]] || fail "expected a warning at 12m / 5m cadence"
grep -q '/babysit-pr-stop' <<<"$ctx" || fail "recovery must name /babysit-pr-stop, got: $ctx"
# Ordering matters: stop BEFORE re-arm, or the advice is the no-op CodeAnt found.
stop_pos=$(awk '{print index($0, "/babysit-pr-stop")}' <<<"$ctx")
rearm_pos=$(awk '{print index($0, "then /babysit-pr <PR>")}' <<<"$ctx")
[[ "$rearm_pos" -gt 0 ]] || fail "recovery must name the re-arm step, got: $ctx"
[[ "$stop_pos" -lt "$rearm_pos" ]] \
  || fail "stop must be instructed BEFORE re-arm (stop@$stop_pos, rearm@$rearm_pos)"
grep -q 'persistent Monitor task ID' <<<"$ctx" \
  || fail "recovery must name the replacement persistent Monitor task ID, got: $ctx"
grep -q 'never substitute CronCreate, either /loop mode' <<<"$ctx" \
  || fail "recovery must reject every unreliable recurring primitive, got: $ctx"
ok "recovery advice is actionable inside the 2x..3x window (stop, then re-arm)"

# ── 13. Unwritable marker dir must not spam (BugBot, PR #922) ───────────────
# With no marker to suppress the repeat, emitting anyway replays the advisory on
# every PostToolUse call for as long as the poll stays dead. Suppress instead,
# and say so on stderr so the condition is visible rather than silent.
reset_markers
write_state "$PR" "$(jq -n --arg t "$(ago 40)" \
  '{babysit:{active:true,last_tick_at:$t,cadence_effective_minutes:5}}')"
RO_DIR="$TMP_DIR/readonly-markers"; mkdir -p "$RO_DIR"; chmod 500 "$RO_DIR"
run_ro() {
  jq -cn --arg sid "test-session" '{session_id: $sid, tool_name: "Read"}' \
    | CLAUDE_BABYSIT_WATCHDOG_MARKER_DIR="$RO_DIR" bash "$HOOK" 2>"$TMP_DIR/ro.err"
}
for attempt in 1 2 3; do
  [[ -z "$(run_ro | context_of)" ]] \
    || fail "unwritable marker dir must suppress the advisory (attempt $attempt), not repeat it"
done
grep -q 'cannot write' "$TMP_DIR/ro.err" \
  || fail "suppression must be surfaced on stderr, got: $(cat "$TMP_DIR/ro.err")"
chmod 700 "$RO_DIR"
ok "unwritable marker dir suppresses (3 calls, 0 advisories) and reports on stderr"

echo "All babysit-tick-watchdog tests passed."
