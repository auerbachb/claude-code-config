#!/usr/bin/env bash
# catalog: tests — Checks path-only PM module resolution and installed-first discovery.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
skill="$root/.claude/skills/pm"
dispatcher="$skill/scripts/dispatch-module.sh"
source "$root/.claude/scripts/tests/lib/skill-bash.sh"
resolver=$(extract_skill_bash "$skill/SKILL.md" pm-module-resolver)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pm-day-module-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

for phase in preconditions arm tick teardown recovery park-reactive park-preemptive probe-wake; do
  expected=$phase
  [[ "$phase" != probe-wake ]] || expected=park-preemptive
  chosen=$("$BASH" "$dispatcher" day "$phase")
  [[ "$chosen" == "$skill/modules/day-$expected.md" && -f "$chosen" ]]
done

for pair in resume:load resume:fetch resume:present rank:load rank:fetch rank:score \
    rank:present shared:priority shared:window-fit shared:ownership flow:cleanup flow:forgotten-prs \
    flow:monitor flow:launch flow:track flow:progress flow:refill flow:handoff; do
  operation=${pair%:*}
  phase=${pair#*:}
  chosen=$("$BASH" "$dispatcher" "$operation" "$phase")
  [[ "$chosen" == "$skill/modules/$operation/$phase.md" && -f "$chosen" ]]
done

status=0
"$BASH" "$dispatcher" day '../tick' > "$scratch/out" 2> "$scratch/error" || status=$?
[[ "$status" == 2 && ! -s "$scratch/out" && -s "$scratch/error" ]]

mkdir -p "$scratch/partial/scripts" "$scratch/partial/modules"
cp "$dispatcher" "$scratch/partial/scripts/"
status=0
"$BASH" "$scratch/partial/scripts/dispatch-module.sh" day tick > "$scratch/out" 2> "$scratch/error" || status=$?
[[ "$status" == 3 && ! -s "$scratch/out" ]]
grep -Fq 'required module unreadable:' "$scratch/error"

# A linked module can point outside the portability lint's scanned tree.
partial_dispatch="$scratch/partial/scripts/dispatch-module.sh"
partial_tick="$scratch/partial/modules/day-tick.md"
for target in "$skill/modules/day-tick.md" "$scratch/nonexistent.md"; do
  ln -s "$target" "$partial_tick"
  status=0
  "$BASH" "$partial_dispatch" day tick > "$scratch/out" 2> "$scratch/error" || status=$?
  [[ "$status" == 3 && ! -s "$scratch/out" ]]
  grep -Fq 'required module unreadable:' "$scratch/error"
  rm "$partial_tick"
done
cp "$skill/modules/day-tick.md" "$partial_tick"
[[ "$("$BASH" "$partial_dispatch" day tick)" == "$(cd "$scratch/partial/modules" && pwd -P)/day-tick.md" ]]
mv "$scratch/partial/modules" "$scratch/real-modules"
ln -s "$scratch/real-modules" "$scratch/partial/modules"
status=0
"$BASH" "$partial_dispatch" day tick > "$scratch/out" 2> "$scratch/error" || status=$?
[[ "$status" == 3 && ! -s "$scratch/out" ]]
grep -Fq 'required module unreadable:' "$scratch/error"

rm "$scratch/partial/modules"
mv "$scratch/real-modules" "$scratch/partial/modules"
mkdir -p "$scratch/detached-rank"
cp "$skill/modules/rank/fetch.md" "$scratch/detached-rank/fetch.md"
ln -s "$scratch/detached-rank" "$scratch/partial/modules/rank"
status=0
"$BASH" "$partial_dispatch" rank fetch > "$scratch/out" 2> "$scratch/error" || status=$?
[[ "$status" == 3 && ! -s "$scratch/out" ]]
grep -Fq 'required module unreadable:' "$scratch/error"

mkdir -p "$scratch/home/.claude/skills-worktree/.claude/skills" "$scratch/project"
ln -s "$skill" "$scratch/home/.claude/skills-worktree/.claude/skills/pm"
trace="$resolver"$'\nprintf "%s\\n" "$PM_MODULE_DISPATCH"\n'
selected=$(cd "$scratch/project" && HOME="$scratch/home" "$BASH" -eu -c "$trace")
[[ "$selected" == "$scratch/home/.claude/skills-worktree/.claude/skills/pm/scripts/dispatch-module.sh" ]]
[[ "$("$BASH" "$selected" day tick)" == "$skill/modules/day-tick.md" ]]
selected=$(cd "$root" && env -u HOME "$BASH" -eu -c "$trace")
[[ "$selected" == '.claude/skills/pm/scripts/dispatch-module.sh' ]]

# Resolve the routes as declared in the entry. A trace is the selected paths,
# without executing any skill procedure or reading bodies of sibling modules.
trace_route() {
  local label=$1 row pair module selected=""
  row=$(grep -F -- "| $label |" "$skill/SKILL.md") || return
  while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    pair=${pair#\`}; pair=${pair%\`}
    module=$("$BASH" "$dispatcher" "${pair%:*}" "${pair#*:}") || return
    selected="${selected}${selected:+ }${module#"$skill/modules/"}"
  done <<< "$(grep -oE '`(resume|rank|shared|day|flow):[a-z-]+`' <<< "$row" || true)"
  printf '%s\n' "$selected"
}

[[ "$(trace_route 'Resume existing work')" == 'resume/load.md resume/fetch.md resume/present.md' ]]
[[ "$(trace_route 'Cold start or explicit ranking')" == 'rank/load.md rank/fetch.md rank/score.md rank/present.md' ]]
[[ "$(trace_route 'Existing Step 1C cleanup gate')" == 'flow/cleanup.md' ]]
[[ "$(trace_route 'Existing Step 1D forgotten-PR gate')" == 'flow/forgotten-prs.md' ]]
[[ "$(trace_route 'Selected eligible dispatch')" == 'flow/launch.md' ]]
[[ "$(trace_route 'Available-capacity evaluation')" == 'flow/refill.md' ]]
[[ "$(trace_route 'Status, due progress, or board report')" == 'flow/progress.md' ]]
status_trace=$(trace_route 'Passive status')
[[ -z "$status_trace" ]]
[[ "$(trace_route 'Saved queue, operator order, or current evidence refill')" == 'shared/priority.md shared/ownership.md shared/window-fit.md' ]]
[[ "$(trace_route 'Bounded backlog rescan')" == 'rank/fetch.md rank/score.md' ]]
rank_score="$skill/modules/rank/score.md"
restore_okr=$(grep -nF 'restore the current OKRs and `OKR_MODE` before scoring' "$rank_score" | cut -d: -f1)
score_start=$(grep -nF '### 1B.3:' "$rank_score" | cut -d: -f1)
[[ "$restore_okr" -lt "$score_start" ]]
grep -Fq 'Resolve `rank:load` for the read-only config and OKR rule in 1B.1.' "$rank_score"
grep -Fq 'At this gate, read `shared:priority`' "$skill/modules/rank/load.md"
grep -Fq 'Step 0b parsed it successfully, read `shared:window-fit`' "$skill/modules/rank/present.md"
grep -Fq 'At this gate, read `shared:ownership`' "$skill/modules/rank/present.md"
rank_present="$skill/modules/rank/present.md"
ownership_read=$(grep -nF 'Resolve `shared:ownership` when the initial selection' "$rank_present" | cut -d: -f1)
batch_select=$(grep -nF '**Select the initial batch and standing queue' "$rank_present" | cut -d: -f1)
[[ "$ownership_read" -lt "$batch_select" ]]

grep -Fq 'Ordinary cold start and resume without day state read no day modules.' "$skill/SKILL.md"
if grep -qE '^### 2D\.[1-7]:' "$skill/SKILL.md"; then
  printf '%s\n' 'FAIL: inline day procedures remain in SKILL.md' >&2
  exit 1
fi
tick="$skill/modules/day-tick.md"
resume_route=$(grep -nF 'successful-resume condition, resolve `day:park-reactive` before D5' "$tick" | cut -d: -f1)
d5=$(grep -nF '**D5 — Persist status' "$tick" | cut -d: -f1)
[[ "$resume_route" -lt "$d5" ]]
grep -Fq 'use only its **On a successful resume** cleanup' "$tick"
grep -Fq '<!-- test-anchor: pm-day-d5-resume-clear -->' "$skill/modules/day-park-reactive.md"
arm="$skill/modules/day-arm.md"
generation_binding=$(extract_skill_bash "$arm" pm-day-arm-immediate-generation)
[[ "$(DAY_GENERATION=published-generation "$BASH" -u -c "$generation_binding"$'\nprintf "%s\\n" "$TICK_GENERATION"')" == published-generation ]]
publish_line=$(grep -nF "Check that write's exit code" "$arm" | cut -d: -f1)
bind_line=$(grep -nF 'pm-day-arm-immediate-generation' "$arm" | cut -d: -f1)
immediate_line=$(grep -nF 'Then **run one tick immediately**' "$arm" | cut -d: -f1)
[[ "$publish_line" -lt "$bind_line" && "$bind_line" -lt "$immediate_line" ]]

probe="$skill/modules/day-park-preemptive.md"
probe_horizon=$(grep -nF 'For a probe fire, resolve `day:tick` and run only its `pm-day-d2-horizon-branch`' "$probe" | cut -d: -f1)
probe_fire=$(grep -nF '<!-- test-anchor: pm-day-2d7-probe-fire -->' "$probe" | cut -d: -f1)
[[ "$probe_horizon" -lt "$probe_fire" ]]
extract_skill_bash "$tick" pm-day-d2-horizon-branch > "$scratch/probe-horizon"
[[ -s "$scratch/probe-horizon" ]]
launch="$skill/modules/flow/launch.md"
budget=$(extract_skill_bash "$launch" pm-initial-launch-credit-budget)
budget_dir="$scratch/budget-project"
mkdir -p "$budget_dir/.claude/scripts"
budget_check="$budget_dir/.claude/scripts/credit-budget.sh"
cat > "$budget_check" <<'BUDGET'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = --check ] || exit 3
printf '%s\n' checked > "$FIXTURE_BUDGET_CALL"
[ -z "$FIXTURE_BUDGET_STATUS" ] || printf '{"status":"%s"}\n' "$FIXTURE_BUDGET_STATUS"
exit "$FIXTURE_BUDGET_RC"
BUDGET
chmod +x "$budget_check"
check_budget() {
  local rc="$1" status="$2" explicit="$3" expected="$4" day_mode="${5:-true}"
  [[ "$(cd "$budget_dir" && env -u HOME FIXTURE_BUDGET_RC="$rc" FIXTURE_BUDGET_STATUS="$status" \
    DAY_MODE="$day_mode" FIXTURE_BUDGET_CALL="$scratch/budget-call" \
    PM_INITIAL_USER_DIRECTED="$explicit" "$BASH" -u -c "$budget" 2>/dev/null)" == "PM_INITIAL_BUDGET=$expected" ]]
}
check_budget 0 ok false ok
check_budget 1 reached false reached
check_budget 2 unknown false unknown
check_budget 3 '' false unknown
check_budget 1 reached true explicit-override
check_budget 1 '' false unknown
check_budget 0 reached false unknown
[[ -s "$scratch/budget-call" ]]
rm "$scratch/budget-call"
check_budget 1 reached false not-applicable false
[[ ! -e "$scratch/budget-call" ]]
rm -f "$budget_check"
ln -s "$root/.claude/scripts/credit-budget.sh" "$budget_check"
check_budget 0 '' false unknown
rm -f "$budget_check"
check_budget 0 '' false unknown
grep -Fq 'Day-mode initial 1B.5 dispatch checks the credit budget in flow:launch' "$skill/SKILL.md"

printf '%s\n' 'PM module routes: 26 operation/phase pairs, invalid/missing guards, installed symlink and unset-HOME fallback'
