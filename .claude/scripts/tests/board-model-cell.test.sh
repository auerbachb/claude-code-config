#!/usr/bin/env bash
# catalog: tests — Fixture tests for the /board Model cell extracted from board/SKILL.md: malformed records stop the merged walk at an em dash, a PR-backed row never falls back to session state, and each row and retry reads its own routed model
# Fixture tests for the /board Model cell (time-estimates.md §"Model cell"). The functions
# under test are extracted from the real .claude/skills/board/SKILL.md block, so the spec
# and the code cannot drift apart silently. Session and handoff state are fixture JSON.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$REPO_ROOT/.claude/skills/board/SKILL.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-model-cell.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAILS=0
PASSES=0

# Extract model_raw, model_family and the top-level CELL_MODEL case block.
awk '/^model_raw\(\) \{/{p=1} p{print} p && /^esac$/{exit}' "$SKILL" > "$WORK/cell.sh"
if ! grep -q '^model_raw() {' "$WORK/cell.sh" || ! grep -q '^esac$' "$WORK/cell.sh"; then
  echo "FAIL: could not extract the Model cell block from $SKILL" >&2
  exit 1
fi

# Fixture stand-ins for the real helpers. sget mirrors the real contract: it returns the value
# at a jq path, or nothing when the path is absent or null.
SESSION_FILE="$WORK/session.json"
sget() {
  local v
  v=$(jq -c "$1" "$SESSION_FILE" 2>/dev/null) || return 0
  [[ "$v" == "null" ]] && return 0
  printf '%s' "$v"
}
# handoff-state.sh --path stand-in: prints the fixture handoff path, or a missing path.
HANDOFF_FILE="$WORK/handoff.json"
cat > "$WORK/fake-handoff-state" <<EOF
#!/usr/bin/env bash
echo "\$HANDOFF_FIXTURE_PATH"
EOF
chmod +x "$WORK/fake-handoff-state"
HANDOFF_STATE_SH="$WORK/fake-handoff-state"

ROW_REPO="owner/repo"; ROW_STATUS=""; ROW_PR=""; ROW_ISSUE=""
# shellcheck disable=SC1090
source "$WORK/cell.sh"

# run_cell <name> <expected> <status> <pr> <issue> <session-json> <handoff-json|MISSING>
run_cell() {
  local name="$1" want="$2" status="$3" pr="$4" issue="$5" session="$6" handoff="$7"
  ROW_STATUS="$status"; ROW_PR="$pr"; ROW_ISSUE="$issue"
  printf '%s' "$session" > "$SESSION_FILE"
  if [[ "$handoff" == MISSING ]]; then
    export HANDOFF_FIXTURE_PATH="$WORK/does-not-exist.json"
  else
    printf '%s' "$handoff" > "$HANDOFF_FILE"
    export HANDOFF_FIXTURE_PATH="$HANDOFF_FILE"
  fi
  CELL_MODEL="—"
  case "$ROW_STATUS" in
    queued) ;;
    merged)
      for MP in C B A; do
        MRAW=$(model_raw "$MP")
        if [[ -n "$MRAW" ]]; then CELL_MODEL=$(model_family "$MRAW"); break; fi
      done ;;
    Phase?*) CELL_MODEL=$(model_family "$(model_raw "${ROW_STATUS:6:1}")") ;;
  esac
  if [[ "$CELL_MODEL" == "$want" ]]; then
    PASSES=$((PASSES + 1))
  else
    FAILS=$((FAILS + 1))
    echo "FAIL: $name: want [$want] got [$CELL_MODEL]" >&2
  fi
}

SESS_A_HAIKU='{"repos":{"owner/repo":{"tasks":{"issue-7":{"model_routing":{"A":{"decision":{"model":"haiku"}}}}}}}}'
SESS_NONE='{}'

# Fixture 1: a malformed record in a later phase stops the walk at that record.
run_cell "merged, malformed C string stops walk" "—" merged 2397 7 "$SESS_NONE" \
  '{"model_routing":{"issue-7":{"C":"bad","B":{"decision":{"model":"sonnet"}}}}}'
run_cell "merged, C with null decision stops walk" "—" merged 2397 7 "$SESS_NONE" \
  '{"model_routing":{"issue-7":{"C":{"decision":null},"B":{"decision":{"model":"sonnet"}}}}}'
run_cell "merged, malformed container stays unrecognised-free" "Sonnet" merged 2397 7 "$SESS_NONE" \
  '{"model_routing":{"issue-7":{"B":{"decision":{"model":"sonnet"}}}}}'
run_cell "phase row, malformed record renders dash" "—" "Phase B" 2397 7 "$SESS_NONE" \
  '{"model_routing":{"issue-7":{"B":"bad"}}}'

# Fixture 2: after a PR exists, a missing or unreadable handoff never falls back to session state.
run_cell "post-PR, handoff missing, session Phase A haiku renders dash" "—" "Phase A" 2397 7 \
  "$SESS_A_HAIKU" MISSING
run_cell "post-PR, handoff lacks phase record, session haiku renders dash" "—" "Phase A" 2397 7 \
  "$SESS_A_HAIKU" '{"model_routing":{"issue-7":{}}}'
run_cell "merged, handoff gone, session Phase A only renders dash" "—" merged 2397 7 \
  "$SESS_A_HAIKU" MISSING
run_cell "pre-PR Phase A reads session record" "Haiku" "Phase A" "" 7 "$SESS_A_HAIKU" MISSING
run_cell "queued row renders dash" "—" queued "" 7 "$SESS_A_HAIKU" MISSING

# Unknown alias renders dash, never a guessed family.
run_cell "unknown alias renders dash" "—" "Phase A" 2397 7 "$SESS_NONE" \
  '{"model_routing":{"issue-7":{"A":{"decision":{"model":"gpt-x"}}}}}'

# Fixture 4: each row reads its own record. Two issues with different models must not share one
# value, and a retry that re-routes the same phase shows on the next read.
SESS_TWO='{"repos":{"owner/repo":{"tasks":{"issue-7":{"model_routing":{"A":{"decision":{"model":"opus"}}}},"issue-8":{"model_routing":{"A":{"decision":{"model":"haiku"}}}}}}}}'
run_cell "row issue-7 reads its own opus record" "Opus" "Phase A" "" 7 "$SESS_TWO" MISSING
run_cell "row issue-8 reads its own haiku record" "Haiku" "Phase A" "" 8 "$SESS_TWO" MISSING

# Fixture 5: retry within phase B changes the model, and the next read shows it.
run_cell "phase B routed sonnet" "Sonnet" "Phase B" 2397 7 "$SESS_NONE" \
  '{"model_routing":{"issue-7":{"B":{"decision":{"model":"sonnet"}}}}}'
run_cell "phase B retried to opus shows opus on next read" "Opus" "Phase B" 2397 7 "$SESS_NONE" \
  '{"model_routing":{"issue-7":{"B":{"decision":{"model":"opus"}}}}}'

echo "board-model-cell: $PASSES passed, $FAILS failed"
[[ "$FAILS" -eq 0 ]]
