#!/usr/bin/env bash
# catalog: tests — Test PM step receipts, invocation modes, state guards and skill blocks.
set -euo pipefail
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$(cd "$test_dir/.." && pwd)"
skill="$scripts/../skills/pm/SKILL.md"
source "$test_dir/lib/skill-bash.sh"

scratch="$(mktemp -d)"
trap 'rm -r -- "$scratch"' EXIT
export HOME="$scratch/home" CLAUDE_SESSION_ID=alpha CLAUDE_SESSION_REPO=demo/repo
mkdir -p "$HOME/.claude"
receipt="$scripts/pm-run-receipt.sh"
state="$scripts/session-state.sh"

expect_exit() {
  local expected="$1" status=0
  shift
  "$@" >"$scratch/stdout" 2>"$scratch/stderr" || status=$?
  if [[ "$status" != "$expected" ]]; then
    printf 'Expected exit %s, got %s from %s\n' "$expected" "$status" "$*" >&2
    cat "$scratch/stderr" >&2
    exit 1
  fi
}

run=$("$receipt" --start --mode cold)
for step in 0 0a 0b 1B 1C 1D 2 3.1 3.2 3.4; do
  "$receipt" --mark "$step" ran --run "$run"
done
all=$("$receipt" --render --run "$run")
[[ "$(grep -c ' ran$' <<<"$all")" == 10 ]]
[[ "$(wc -l <<<"$all" | tr -d ' ')" == 11 ]]
[[ "$all" != *'not recorded'* ]]

run=$("$receipt" --start --mode cold)
"$receipt" --mark 1C skipped --why --no-clean --run "$run"
partial=$(PM_RUN_ID="$run" "$receipt" --render)
grep -Fxq '1C skipped (--no-clean)' <<<"$partial"
grep -Fxq '3.4 not recorded ⚠' <<<"$partial"
expect_exit 2 "$receipt" --mark 1A ran --run "$run"
expect_exit 2 "$receipt" --mark 1B unknown --run "$run"
expect_exit 2 "$receipt" --mark 1B failed --why ' ' --run "$run"
[[ "$partial" == "$("$receipt" --render --run "$run")" ]]
"$receipt" --mark 1B failed --why $'first\nsecond\tthird' --run "$run"
grep -Fxq '1B failed (first second third)' <<<"$("$receipt" --render --run "$run")"

resume=$("$receipt" --start --mode resume)
"$receipt" --mark 3.1 skipped --why 'resume existing work' --run "$resume"
resume_output=$("$receipt" --render --run "$resume")
grep -Fxq '1A not recorded ⚠' <<<"$resume_output"
grep -Fxq '3.1 skipped (resume existing work)' <<<"$resume_output"
[[ "$resume_output" != *'1B '* ]]
expect_exit 3 "$receipt" --mark 1B ran --run "$run"
expect_exit 3 "$receipt" --render --run "$run"
grep -Fxq 'PM receipt unavailable for this run.' "$scratch/stdout"

day=$(CLAUDE_SESSION_ID=beta "$receipt" --start --mode cold --day)
day_output=$(CLAUDE_SESSION_ID=beta "$receipt" --render --run "$day")
grep -Fxq 'PM receipt · demo/repo · cold day' <<<"$day_output"
grep -Fxq '2D not recorded ⚠' <<<"$day_output"
if grep -Fxq '2 not recorded ⚠' <<<"$day_output"; then
  echo 'Day receipt must show 2D in place of 2' >&2
  exit 1
fi
[[ "$resume_output" == "$("$receipt" --render --run "$resume")" ]]
expect_exit 3 "$receipt" --render --repo demo/foreign --run "$resume"

punctuated=$(CLAUDE_SESSION_ID=local.dispatch:one "$receipt" --start --mode resume)
CLAUDE_SESSION_ID=local.dispatch:one "$receipt" --mark 1A ran --run "$punctuated"
grep -Fxq '1A ran' <<<"$(CLAUDE_SESSION_ID=local.dispatch:one "$receipt" --render --run "$punctuated")"
expect_exit 3 "$receipt" --render --run "$punctuated"

"$receipt" --mark 0 ran --run "$resume" &
mark_a=$!
"$receipt" --mark 0a ran --run "$resume" &
mark_b=$!
wait "$mark_a"
wait "$mark_b"
both=$("$receipt" --render --run "$resume")
grep -Fxq '0 ran' <<<"$both"
grep -Fxq '0a ran' <<<"$both"

first=$(CLAUDE_SESSION_ID= "$receipt" --start --mode cold 2>"$scratch/no-session")
grep -Fq 'scoping receipt to the run ID' "$scratch/no-session"
second=$(CLAUDE_SESSION_ID= "$receipt" --start --mode cold 2>"$scratch/no-session")
CLAUDE_SESSION_ID= "$receipt" --mark 0 ran --run "$first"
grep -Fxq '0 ran' <<<"$(CLAUDE_SESSION_ID= "$receipt" --render --run "$first")"
grep -Fxq '0 not recorded ⚠' <<<"$(CLAUDE_SESSION_ID= "$receipt" --render --run "$second")"

start_block=$(extract_skill_bash "$skill" pm-run-receipt-start)
mark_block=$(extract_skill_bash "$skill" pm-run-receipt-mark)
render_block=$(extract_skill_bash "$skill" pm-run-receipt-render)
export PM_RECEIPT_SH="$receipt" SESSION_STATE_SH="$state" PM_ENTRY_MODE=resume DAY_MODE=true
combined=$(printf '%s\n' "$start_block" 'PM_STEP=0 PM_OUTCOME=ran PM_REASON=""' "$mark_block" "$render_block")
wired=$(CLAUDE_SESSION_ID=wiring /bin/bash -eu -c "$combined
[[ -z \"\${PM_RUN_ID:-}\" ]]
PM_STEP=3.1 PM_OUTCOME=ran PM_REASON=\"\"
$mark_block
$render_block")
grep -Fxq 'PM receipt · demo/repo · resume day' <<<"$wired"
grep -Fxq '0 ran' <<<"$wired"
grep -Fxq '2D not recorded ⚠' <<<"$wired"
wire_path='.repos["demo/repo"].pm_receipts["wiring"]'
wire_state=$("$state" --get-json "$wire_path")
wire_run=$(jq -r '.run_id' <<<"$wire_state")
jq -e '.finished_at != null and .steps["3.1"] == null' <<<"$wire_state" >/dev/null
expect_exit 3 env CLAUDE_SESSION_ID=wiring "$receipt" --mark 3.1 ran --run "$wire_run"
[[ "$wire_state" == "$("$state" --get-json "$wire_path")" ]]
[[ "$wired" == "$(CLAUDE_SESSION_ID=wiring "$receipt" --render --run "$wire_run")" ]]

# A finish published after the marker's initial read must still win the CAS.
race_run=$(CLAUDE_SESSION_ID=race "$receipt" --start --mode cold)
mkdir "$scratch/race"
cp "$receipt" "$scratch/race/pm-run-receipt.sh"
cat > "$scratch/race/session-state.sh" <<'RACE'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == --set ]]; then
    "$PM_TEST_REAL_STATE" --repo demo/repo --set \
      '.repos["demo/repo"].pm_receipts["race"].finished_at="2026-11-11T12:45:00Z"' || exit 1
    break
  fi
done
exec "$PM_TEST_REAL_STATE" "$@"
RACE
chmod +x "$scratch/race/session-state.sh"
expect_exit 3 env CLAUDE_SESSION_ID=race PM_TEST_REAL_STATE="$state" \
  "$scratch/race/pm-run-receipt.sh" --mark 3.1 ran --run "$race_run"
race_state=$("$state" --get-json '.repos["demo/repo"].pm_receipts["race"]')
jq -e '.finished_at != null and .steps["3.1"] == null' <<<"$race_state" >/dev/null

before=$("$state" --get-json '.repos["demo/repo"].pm_receipts')
[[ -z "$(DAY_TICK=true /bin/bash -eu -c "$combined")" ]]
[[ -z "$(DAY_PROBE_WAKE=true /bin/bash -eu -c "$combined")" ]]
[[ "$before" == "$("$state" --get-json '.repos["demo/repo"].pm_receipts')" ]]
[[ "$(PM_RECEIPT_SH= /bin/bash -eu -c "$combined")" == 'PM receipt unavailable for this run.' ]]

map=$(jq -cn '
  [range(1;21) | {key:("older-" + tostring),
    value:{started_at:("2026-01-01T00:00:" + (100 + . | tostring | .[1:]) + "Z")}}]
  | from_entries')
"$state" --repo demo/retention --set ".repos[\"demo/retention\"].pm_receipts=$map"
new=$("$receipt" --start --mode cold --repo demo/retention)
saved=$("$state" --repo demo/retention --get-json '.repos["demo/retention"].pm_receipts')
jq -e --arg run "$new" '
  length == 20 and .alpha.run_id == $run and (has("older-1") | not)
' <<<"$saved" >/dev/null
[[ "$before" == "$("$state" --get-json '.repos["demo/repo"].pm_receipts')" ]]

echo 'PM run receipt checks passed'
