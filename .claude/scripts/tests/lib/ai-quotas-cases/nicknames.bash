#!/usr/bin/env bash
# Source-only quota fixture group: nicknames. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 17e. nicknames ----------------------------------------------------------

overage_case 40 50
NICKED="$TMP/nicked.json"
jq '.accounts = [.accounts[] | if .provider == "codex" then . + {nickname: "GPT LM"} else . end]' \
  "$CONFIG" > "$NICKED" && mv "$NICKED" "$CONFIG"
run
check_contains "$OUT" "GPT LM" "the table shows the nickname"
check_not_contains "$OUT" "codex-one@example.com" "in place of the address it replaces"
check_contains "$OUT" "claude-one@example.com" \
  "control(+): an account with no nickname still shows its address"
run --json
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "codex") | .nickname')" "GPT LM" \
  "--json carries the nickname on the row"
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "claude") | .nickname')" "null" \
  "and null — not a missing key — on a row without one"
check_eq "$(history_lines | jq -r 'select(.provider == "codex") | .nickname' | tail -n 1)" "GPT LM" \
  "the snapshot records the nickname alongside the label"

# `nick` refuses control characters, but this reader accepts any compatible
# 1.x registry — a hand-edited one, or one a future sibling wrote — and the
# value goes straight into a terminal table. A tab splits the columns, a
# newline forges a row, and an escape sequence is executed rather than shown.
overage_case 40 50
NICK_HOSTILE="$TMP/hostile-nick.json"
jq '.accounts = [.accounts[]
      | if .provider == "codex" then . + {nickname: "col\tsplit"} else . end]' \
  "$CONFIG" > "$NICK_HOSTILE" && mv "$NICK_HOSTILE" "$CONFIG"
# The fixture builds its own premise: a nickname that did not actually contain
# a tab would pass every assertion below for the wrong reason.
check_eq "$(jq -r '[.accounts[].nickname // empty | explode[] | select(. == 9)] | length' "$CONFIG")" "1" \
  "premise: the registry really does hold a nickname with a tab in it"
run
check_eq "$RC" "0" "a registry nickname holding a control character does not fail the run"
check_not_contains "$OUT" "col	split" "the raw value never reaches the table"
check_contains "$OUT" "codex-one@example.com" \
  "which falls back to the label, exactly as an absent nickname does"
run --json
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "codex") | .nickname')" "null" \
  "control(+): --json carries it as null, the same shape an account with no nickname has"

overage_case 40 50
NICK_ESC="$TMP/esc-nick.json"
jq '.accounts = [.accounts[]
      | if .provider == "codex" then . + {nickname: "esc[2Jhere"} else . end]' \
  "$CONFIG" > "$NICK_ESC" && mv "$NICK_ESC" "$CONFIG"
check_eq "$(jq -r '[.accounts[].nickname // empty | explode[] | select(. == 27)] | length' "$CONFIG")" "1" \
  "premise: and one holding a real escape character"
run
check_not_contains "$OUT" "esc" "an escape sequence is dropped rather than handed to the terminal"
check_contains "$OUT" "codex-one@example.com" "control(+): that row fell back to its label too"

