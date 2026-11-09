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
# The stub lingers 30s in this mode, so the regression shows up as elapsed time.
# Asserting a ceiling well under that linger is what makes this discriminating:
# with the bound the run is a few seconds, without it the run inherits the 30.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
export STUB_CODEX_IGNORE_TERM=1
term_t0="$(date +%s)"
run --json
term_elapsed=$(( $(date +%s) - term_t0 ))
unset STUB_CODEX_IGNORE_TERM
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "a server that ignores SIGTERM still yields its answer"
if [[ "$term_elapsed" -lt 15 ]]; then
  ok "and cleanup is bounded — the run took ${term_elapsed}s, not the stub's 30s linger"
else
  bad "cleanup was not bounded: the run took ${term_elapsed}s, inheriting the stub's linger"
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

