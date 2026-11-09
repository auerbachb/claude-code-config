#!/usr/bin/env bash
# Source-only quota fixture group: cursor. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 13. the cursor IDE-token reader (#1703) ---------------------------------
#
# The reader borrows the token the Cursor IDE holds, derives the dashboard
# cookie in memory, and calls three endpoints. Everything below runs against a
# fixture SQLite state store and the fake curl; the real IDE store is never
# touched and no browser exists to launch.

# A pool field, addressed by pool rather than by window: a cursor account
# contributes TWO rows sharing one window, so field_of alone cannot tell
# `cursor-models` from `other-models` and would answer with whichever came
# first — a test that passes while reading the wrong pool.


CUR="$PROFILES/cursor-one@example.com/cursor"


# --- 13a. a signed-in IDE renders both pool rows -----------------------------

reset_state
seed_cursor_account
run --json
check_eq "$RC" "0" "a cursor account reads cleanly"
check_eq "$(cursor_field cursor-one@example.com cursor-models status)" "ok" \
  "the cursor-models pool reads ok"
check_eq "$(cursor_field cursor-one@example.com other-models status)" "ok" \
  "the other-models pool reads ok"
# 53.034333… rounds to one decimal with a bare .0 dropped, exactly as the
# retired helper rendered it — the display contract, unchanged by the transport.
check_eq "$(cursor_field cursor-one@example.com cursor-models used_pct)" "53" \
  "autoPercentUsed drives the cursor-models figure, rounded once"
check_eq "$(cursor_field cursor-one@example.com other-models used_pct)" "100" \
  "apiPercentUsed drives the other-models figure"
check_eq "$(cursor_field cursor-one@example.com cursor-models remaining_pct)" "47" \
  "remaining_pct comes off the same rounded number"
# Cents to dollars, on every dollar field.
check_eq "$(cursor_field cursor-one@example.com cursor-models plan_used_usd)" "2092.43" \
  "totalSpend is read as cents"
check_eq "$(cursor_field cursor-one@example.com cursor-models plan_included_usd)" "400" \
  "the plan limit is read as cents"
check_eq "$(cursor_field cursor-one@example.com other-models spend_limit_used_usd)" "1007.5" \
  "the on-demand block is read as cents, on both rows"
check_eq "$(cursor_field cursor-one@example.com other-models spend_limit_usd)" "1000" \
  "as is its limit"
# Milliseconds to epoch seconds, from get-monthly-billing-cycle.
check_eq "$(cursor_field cursor-one@example.com cursor-models resets_at_epoch)" "1790611774" \
  "the billing-cycle end is read as milliseconds and becomes the reset"
check_eq "$(cursor_field cursor-one@example.com cursor-models window_start_epoch)" "1787933374" \
  "and the cycle start becomes the window start"
check_eq "$(cursor_field cursor-one@example.com cursor-models plan)" "Ultra" \
  "get-plan-info supplies the plan name"
check_eq "$(cursor_field cursor-one@example.com cursor-models reported_email)" "$CURSOR_FIXTURE_EMAIL" \
  "the row is labelled with the IDE's cached email"
check_eq "$(cursor_field cursor-one@example.com cursor-models source)" "ide-token" \
  "and names the path it came from"

# The cookie's user id keeps the `google-oauth2|` prefix. Stripping to the
# segment after the final `|` is the plausible-looking mistake that answers 401
# against the real dashboard, so it is asserted rather than assumed.
check_eq "$(head -n 1 "$STUB_CURSOR_UID_LOG")" "$CURSOR_FIXTURE_SUB" \
  "the cookie carries the sub claim with only a leading auth0| removed"
check_eq "$(sort -u "$STUB_CURSOR_UID_LOG" | wc -l | tr -d ' ')" "1" \
  "and every one of the three calls carried the same user id"
check_eq "$(grep -c 'cursor.com/api/dashboard' "$STUB_CURL_LOG" | tr -d ' ')" "3" \
  "all three dashboard endpoints are called"

# --- 13b. the leak assertion (the ticket's own check) ------------------------
#
# `grep -iE 'WorkosCursorSessionToken=|eyJ'` over everything this run wrote
# must find nothing. The fixture token really is a JWT, so `eyJ` is a live
# tripwire here and not a formality.
check_not_contains "$OUT" "WorkosCursorSessionToken" "no cookie reaches stdout"
check_not_contains "$OUT" "eyJ" "no token reaches stdout"
check_not_contains "$ERR" "WorkosCursorSessionToken" "no cookie reaches stderr"
check_not_contains "$ERR" "eyJ" "no token reaches stderr"
check_not_contains "$(cat "$STUB_CURL_LOG")" "eyJ" "no token reaches the curl argv log"
LEAK_HIT="$(grep -icE 'WorkosCursorSessionToken=|eyJ' "$CASE_HOME/.claude/ai-quotas-history.jsonl" 2>/dev/null | tr -d ' ' || true)"
check_eq "${LEAK_HIT:-0}" "0" "no token or cookie reaches the history file"

# --- 13c. a rejected token says to sign in, in the IDE -----------------------

reset_state
seed_cursor_account
echo "unauth" > "$STUB_CURSOR_MODE"
run --json
check_eq "$RC" "0" "a rejected cursor token does not fail the run"
check_eq "$(rows_for cursor-one@example.com)" "needs-login" "HTTP 401 reads needs-login"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "open the Cursor IDE and sign in" \
  "and the note says to sign in IN THE IDE, not to run a command"
check_not_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "/quotas-setup relogin" \
  "the relogin command is NOT offered — it cannot create this credential"
check_eq "$(field_of cursor-one@example.com "billing-cycle" used_pct)" "null" \
  "and no figure is invented"
# The two enrichment calls are SKIPPED once the usage call has decided the row
# (CodeRabbit). Three 401s per account per read is latency spent on a row that
# will not render, against a provider that rate-limits.
check_eq "$(grep -c 'cursor.com/api/dashboard' "$STUB_CURL_LOG" | tr -d ' ')" "1" \
  "and the enrichment endpoints are not called after a rejected token"

# --- 13d. any other non-200 is unreachable, with the status ------------------

reset_state
seed_cursor_account
echo "server" > "$STUB_CURSOR_MODE"
run --json
check_eq "$(rows_for cursor-one@example.com)" "unreachable" "HTTP 500 reads unreachable"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "500" \
  "and the note carries the status code"
check_eq "$(grep -c 'cursor.com/api/dashboard' "$STUB_CURL_LOG" | tr -d ' ')" "1" \
  "and the enrichment endpoints are not called after a failed usage read"

# --- 13e. a signed-out IDE ---------------------------------------------------

reset_state
seed_cursor_account
CURSOR_DB_UNDER_TEST="$CURSOR_DB_SIGNED_OUT"
run --json
CURSOR_DB_UNDER_TEST=""
check_eq "$(rows_for cursor-one@example.com)" "needs-login" \
  "a state store with no access token reads needs-login"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "not signed in" \
  "and says the IDE is not signed in"
check_eq "$(grep -c 'cursor.com' "$STUB_CURL_LOG" | tr -d ' ')" "0" \
  "no dashboard call is made without a token"

# --- 13f. no state store at all ----------------------------------------------

reset_state
seed_cursor_account
CURSOR_DB_UNDER_TEST="$CURSOR_DB_MISSING"
run --json
CURSOR_DB_UNDER_TEST=""
check_eq "$(rows_for cursor-one@example.com)" "needs-login" \
  "a missing state store reads needs-login"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "open the Cursor IDE and sign in" \
  "with the same instruction"

# --- 13f2. no sqlite3 at all is unreachable, not needs-login -----------------
#
# Without sqlite3 this reader cannot see whether the IDE is signed in. Saying
# `needs-login` there would tell the user to sign in again over a missing tool,
# which is the one instruction that cannot help (CodeRabbit).

reset_state
seed_cursor_account
SQLITE3_BIN_UNDER_TEST="$TMP/no-such-sqlite3"
run --json
SQLITE3_BIN_UNDER_TEST=""
check_eq "$RC" "0" "a missing sqlite3 does not fail the run"
check_eq "$(rows_for cursor-one@example.com)" "unreachable" \
  "a missing sqlite3 reads unreachable, not needs-login"
check_contains "$(field_of cursor-one@example.com "billing-cycle" detail)" "sqlite3" \
  "and the note names the tool that is missing"
check_eq "$(grep -c 'cursor.com' "$STUB_CURL_LOG" | tr -d ' ')" "0" \
  "control(-): no request was made without a way to read the token"

# --- 13f3. the default store path follows PLATFORM ---------------------------
#
# The path was hardcoded to macOS, so a signed-in Linux user read `needs-login`
# — telling them to sign in again over a path this reader was looking for in
# the wrong place (CodeAnt). `run` always sets AI_QUOTAS_CURSOR_STATE_DB, which
# is precisely what hid it, so this case invokes the reader with that seam
# ABSENT and reads the path back out of the row's own detail note.



reset_state
seed_cursor_account
run_no_db_seam Linux --json
check_contains "$OUT" "/.config/Cursor/User/globalStorage/state.vscdb" \
  "a Linux platform looks for the documented Linux store path"
check_not_contains "$OUT" "Library/Application Support/Cursor" \
  "and not the macOS one"
reset_state
seed_cursor_account
run_no_db_seam Darwin --json
check_contains "$OUT" "Library/Application Support/Cursor/User/globalStorage/state.vscdb" \
  "control(+): Darwin still looks for the macOS store path"

