#!/usr/bin/env bash
# Source-only quota fixture group: history-errors. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 17h. history never changes the exit status ------------------------------
#
# The history path is made unwritable by occupying it with a DIRECTORY rather
# than by permissions: this suite may run as a user for whom a mode-000 file is
# still writable, and the assertion would then pass without ever reaching the
# failure it claims to test.

overage_case 40 50
rm -rf "$HISTORY"
mkdir -p "$HISTORY"
BLOCKED_MODE_BEFORE="$(ls -ld "$HISTORY" | cut -c1-10)"
run
check_eq "$RC" "0" "an unwritable history file does not fail the report"
check_contains "$OUT" "OVERAGE" "and the table still renders in full"
check_contains "$ERR" "$HISTORY" "the failure is named on stderr rather than swallowed"
# `chmod 600` on a directory SUCCEEDS and strips its execute bit, making it
# unusable. A display tool must not mutate a path it merely failed to write to,
# so the mode is asserted unchanged rather than assumed.
check_eq "$(ls -ld "$HISTORY" | cut -c1-10)" "$BLOCKED_MODE_BEFORE" \
  "and the directory occupying that path is left exactly as it was"
rm -rf "$HISTORY"

