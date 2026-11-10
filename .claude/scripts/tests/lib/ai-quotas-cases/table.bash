#!/usr/bin/env bash
# Source-only quota fixture group: table. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 17f. last_scheduled_snapshot_at is on every document --------------------

overage_case 40 50
run --json
check_eq "$(printf '%s' "$DOC" | jq -r 'has("last_scheduled_snapshot_at") | tostring')" "true" \
  "--json declares last_scheduled_snapshot_at"
check_eq "$(printf '%s' "$DOC" | jq -r '.last_scheduled_snapshot_at | tostring')" "null" \
  "null before the unattended job has ever run"
run --quiet
run --json
check_eq "$(printf '%s' "$DOC" | jq -r '.last_scheduled_snapshot_at')" "2026-09-08T20:00:00Z" \
  "and the instant of the last scheduled snapshot once it has"

reset_state
write_config
run --json
check_eq "$(printf '%s' "$DOC" | jq -r 'has("last_scheduled_snapshot_at") | tostring')" "true" \
  "the no-accounts document has the same shape — nothing for a consumer to special-case"

# --- 17g. the compact table fits five accounts in 100 columns ----------------

# One claude and four codex accounts, each reporting its OWN address, so no row
# carries a `registered as` note that a real five-account registry would not
# have. Only one claude account: the anthropic stub answers from a single
# shared body, so a second one would report the first account address and
# reintroduce exactly the artificial note this fixture exists to avoid.
#
# The nicknames are the length nicknames actually are — the owner uses `GPT LM`
# and `GPT Personal` — because the ACCOUNT column is sized by the longest one,
# and a fixture with 30-character nicknames would be measuring the fixture.
reset_state
FIVE_SNAP="$(codex_snapshot_primary_weekly)"
C_A="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
X_A="$(seed_codex_profile codex-one@example.com "$FIVE_SNAP" codex-one@example.com)"
X_B="$(seed_codex_profile codex-two@example.com "$FIVE_SNAP" codex-two@example.com)"
X_C="$(seed_codex_profile codex-three@example.com "$FIVE_SNAP" codex-three@example.com)"
X_D="$(seed_codex_profile codex-four@example.com "$FIVE_SNAP" codex-four@example.com)"
write_config \
  "$(account_json claude claude-one@example.com "$C_A" "Claude Code-credentials-AAA" | jq '. + {nickname: "Claude Work"}')" \
  "$(account_json codex codex-one@example.com "$X_A" | jq '. + {nickname: "GPT LM"}')" \
  "$(account_json codex codex-two@example.com "$X_B" | jq '. + {nickname: "GPT Personal"}')" \
  "$(account_json codex codex-three@example.com "$X_C" | jq '. + {nickname: "GPT Spare"}')" \
  "$(account_json codex codex-four@example.com "$X_D" | jq '. + {nickname: "GPT Extra"}')"
run
check_eq "$RC" "0" "a five-account table exits 0"
check_not_contains "$OUT" "REMAIN" "the compact table has no REMAIN column"
check_contains "$OUT" "USED" "and still has USED"
FIVE_TABLE="$(table_only "$OUT")"
# The control comes FIRST: a width measured over a table that never rendered
# would pass for the emptiest possible reason.
check_eq "$(printf '%s\n' "$FIVE_TABLE" | grep -c '7-day' || true)" "5" \
  "control(+): all five accounts really are in the measured table"
# Second control: the measured table must be the CLEAN five-account case. A
# `registered as` note is a fixture artifact here (the stub bodies are shared),
# and if one crept back it would widen the table for a reason no real registry
# has — the width assertion below would then be failing, or passing, on the
# strength of a fake note.
check_not_contains "$FIVE_TABLE" "registered as" \
  "control(-): no row is decorated with a mislabelled-account note"
FIVE_WIDTH="$(widest_line "$FIVE_TABLE")"
if [[ "$FIVE_WIDTH" -le 100 && "$FIVE_WIDTH" -gt 0 ]]; then
  ok "the five-account table fits in 100 columns (widest line: ${FIVE_WIDTH})"
else
  bad "the five-account table does not fit in 100 columns (widest line: ${FIVE_WIDTH})"
fi
check_eq "$(history_count)" "5" "and every one of the five rows was recorded"

