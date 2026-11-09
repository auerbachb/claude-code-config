#!/usr/bin/env bash
# Source-only quota fixture group: codex-cleanup. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 14d. cleanup is bounded when the server outlives SIGTERM ---------------
# SIGTERM is a request the real `codex app-server` may decline. An unconditional
# `wait` after it blocks until the process feels like exiting — at CLEANUP,
# after the answer is already in hand — so a report whose whole contract is that
# it comes back would hang holding the result. Cleanup must escalate to SIGKILL
# and give up on the status rather than on the report.
#
# Check the stub itself: a skipped cleanup leaves it running, and an unbounded
# wait lets it reach its natural exit. Other quota work can take any amount of
# time without affecting these checks.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
if ! term_tmp="$(mktemp -d "$TMP/codex-cleanup.XXXXXXXX")" || ! mkfifo "$term_tmp/linger"; then
  bad "could not create the SIGTERM-resistant fixture's private FIFO"
  return 1
fi
export STUB_CODEX_IGNORE_TERM=1 STUB_CODEX_PID_FILE="$term_tmp/pid"
export STUB_CODEX_LINGER_FIFO="$term_tmp/linger" STUB_CODEX_LINGER_EXPIRED="$term_tmp/expired"
run --json
unset STUB_CODEX_IGNORE_TERM STUB_CODEX_PID_FILE STUB_CODEX_LINGER_FIFO STUB_CODEX_LINGER_EXPIRED
term_pid=
if [[ -s "$term_tmp/pid" ]]; then
  IFS= read -r term_pid < "$term_tmp/pid"
fi
if [[ ! "$term_pid" =~ ^[1-9][0-9]*$ ]]; then
  bad "the SIGTERM-resistant fixture did not record its PID"
elif ! kill -0 "$term_pid" 2>/dev/null ||
  [[ "$(ps -o stat= -p "$term_pid" 2>/dev/null)" =~ ^[[:space:]]*Z ]] ||
  ! kill -0 "$term_pid" 2>/dev/null; then
  ok "the SIGTERM-resistant fixture is no longer running when cleanup returns"
else
  bad "the SIGTERM-resistant fixture is still running after cleanup (PID $term_pid)"
fi
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "a server that ignores SIGTERM still yields its answer"
if [[ -e "$term_tmp/expired" ]]; then
  bad "cleanup returned only after the fixture reached its natural linger timeout"
else
  ok "cleanup did not wait for the fixture's natural linger timeout"
fi

# --- 14c. an unusable timeout is refused, not used --------------------------
# `[[ -lt ]]` is arithmetic: `abc` evaluates to 0, so the app-server loop makes
# ZERO passes and the row degrades to the HTTP fallback reporting "did not
# answer within abcs" — a silent fallback wearing a timeout's clothes. `08` is
# arithmetically invalid (8 is not an octal digit) and bash says so on stderr.
# Neither is a timeout, so the reader must refuse the value and keep its
# default rather than bounding anything with it.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
jq -n --argjson week "$WEEK_RESET" \
  '{rate_limits: {planType: "pro",
                  primary: {usedPercent: 11, windowDurationMins: 10080, resetsAt: $week},
                  secondary: null}}' > "$STUB_CHATGPT_BODY"
for bad_timeout in abc 08 0; do
  # Exported, not prefixed: a `VAR=x func` prefix leaks past the call in bash,
  # so the next case would inherit it and stop testing what it names.
  export AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE="$bad_timeout"
  run --json
  unset AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE
  check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
    "AI_QUOTAS_CODEX_TIMEOUT='$bad_timeout' is refused, so app-server is still waited for"
  check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "71" \
    "control(+): and the figures are still the app-server fixture's, not the HTTP body's"
  check_contains "$ERR" "not a positive integer" \
    "and the refusal is stated on stderr rather than applied silently"
done
# A usable override is still honoured — or the checks above would pass on a
# reader that ignored the variable altogether.
export AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE="7"
run --json
unset AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "control(+): a valid timeout is accepted"
check_not_contains "$ERR" "not a positive integer" \
  "control(-): and a valid timeout draws no refusal"
# An EMPTY value is not a wrong value: `${VAR:-20}` cannot tell it from unset,
# and "you left it unset" is not something to warn about. It takes the default
# silently, and the refusal above stays reserved for values someone meant.
export AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE=""
run --json
unset AI_QUOTAS_CODEX_TIMEOUT_OVERRIDE
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "an empty timeout takes the default"
check_not_contains "$ERR" "not a positive integer" \
  "control(-): and is not refused — empty is indistinguishable from unset"

# --- 14b. --five-hour must not mask an unreadable codex payload -------------
# A payload with no windows at all is an unrecognised SHAPE. Rendering "this
# plan reports no short window" for it would state a fact about the plan
# nobody established, and would mark the read successful — so the flag would
# SUPPRESS the unreachable row the same payload produces without it.

# This case is about the HTTP payload, so it has to be the HTTP path that runs.
# Removing the fixture here rather than inheriting test 14's removal is what
# keeps the premise the case's own: with app-server answering, the reader never
# reaches the body below and all three checks pass on the wrong path.
rm -f "$X1/rate-limits.json"
jq -n '{something_else: {}, other: 1}' > "$STUB_CHATGPT_BODY"
run --json --five-hour
check_eq "$(rows_for codex-one@example.com)" "unreachable" \
  "an unreadable payload is unreachable even under --five-hour"
check_contains "$(field_of codex-one@example.com "7-day" detail)" "something_else, other" \
  "and the note still prints the keys it saw"
run --json
check_eq "$(rows_for codex-one@example.com)" "unreachable" \
  "control(+): the same payload is unreachable without the flag too"

