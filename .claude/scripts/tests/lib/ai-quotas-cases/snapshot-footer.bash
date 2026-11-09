#!/usr/bin/env bash
# Source-only quota fixture group: snapshot-footer. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 17d. the LAST SNAPSHOT footer -------------------------------------------

overage_case 40 50
run
check_contains "$OUT" "LAST SNAPSHOT: none yet" \
  "with no scheduled snapshot the footer says none yet — manual lines do not count"
run --quiet
run
check_not_contains "$OUT" "none yet" "once the unattended job has run the footer names its time"
check_contains "$OUT" "LAST SNAPSHOT: Tue Sep 8" \
  "and names it in Eastern, like every other time in the table"
check_not_contains "$OUT" "stale" "a snapshot taken now is not stale"

overage_case 40 50
mkdir -p "$(dirname "$HISTORY")"
# A torn line FIRST, then the real one: a run killed mid-append leaves exactly
# this, and one unparseable line must not cost the footer the lines around it.
printf 'this line is not json\n' > "$HISTORY"
# And a line that PARSES but is not an object. `fromjson?` catches only the
# parse error, so a bare number reaches `.source` and aborts jq — which would
# take the good line below down with it.
printf '5\n' >> "$HISTORY"
jq -nc --arg ts "$(utc_iso $(( NOW - 3 * 86400 )))" \
  '{ts: $ts, provider: "codex", label: "codex-one@example.com", nickname: null,
    window: "7-day", used_pct: 10, resets_at_epoch: null, source: "scheduled"}' >> "$HISTORY"
run
check_contains "$OUT" "stale (>1 day)" "a scheduled snapshot older than a day reads as stale"
check_contains "$OUT" "LAST SNAPSHOT: Sat Sep 5" \
  "control(+): neither the torn line nor the non-object one stopped the good one being read"

# File order is append-COMPLETION order, and every row of a run carries the
# clock that run STARTED on — so a slow run finishing after a quick one leaves
# an older ts on the last line. Written in exactly that order here: the newer
# reading first, the older one appended after it.
overage_case 40 50
mkdir -p "$(dirname "$HISTORY")"
jq -nc --arg ts "$(utc_iso "$NOW")" \
  '{ts: $ts, provider: "codex", label: "codex-one@example.com", nickname: null,
    window: "7-day", used_pct: 10, resets_at_epoch: null, source: "scheduled"}' > "$HISTORY"
jq -nc --arg ts "$(utc_iso $(( NOW - 3 * 86400 )))" \
  '{ts: $ts, provider: "codex", label: "codex-one@example.com", nickname: null,
    window: "7-day", used_pct: 10, resets_at_epoch: null, source: "scheduled"}' >> "$HISTORY"
run
check_contains "$OUT" "LAST SNAPSHOT: Tue Sep 8" \
  "the footer names the NEWEST scheduled reading, not whichever line landed last"
check_not_contains "$OUT" "stale" \
  "so a fresh reading is not reported stale because an older one was appended after it"

