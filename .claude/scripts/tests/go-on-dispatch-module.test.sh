#!/usr/bin/env bash
# catalog: tests — Checks /go-on incremental loading — path-only module resolution, per-stoppage-kind read traces, missing-module blocking, compaction re-dispatch, and verbatim parity with the pre-split file.
#
# Issue #2181. The traces are caller-boundary evidence: they record which module
# paths a caller following the entry's routing table resolves and reads. They do
# not observe the harness's private loader, runtime token use, or whether a
# model follows the routing; the same limit the /pm fixtures state in
# .claude/reference/incremental-skill-loading.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
skill="$root/.claude/skills/go-on"
entry="$skill/SKILL.md"
dispatcher="$skill/scripts/dispatch-module.sh"
source "$root/.claude/scripts/tests/lib/skill-bash.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/go-on-dispatch-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

kinds="planned-stop usage-limit-park token-exhaustion unplanned"
reviews="prepare publish respond merge"

# --- Every supported pair returns exactly its own readable module -----------
for phase in $kinds; do
  chosen=$("$BASH" "$dispatcher" kind "$phase")
  [[ "$chosen" == "$skill/modules/kinds/$phase.md" && -f "$chosen" ]] || fail "kind:$phase -> $chosen"
done
for phase in $reviews; do
  chosen=$("$BASH" "$dispatcher" review "$phase")
  [[ "$chosen" == "$skill/modules/review/$phase.md" && -f "$chosen" ]] || fail "review:$phase -> $chosen"
done
# No stray module the dispatcher cannot reach.
module_count=$(find "$skill/modules" -type f -name '*.md' | wc -l | tr -d ' ')
[[ "$module_count" == 8 ]] || fail "expected 8 modules, found $module_count"

# --- Invalid pairs exit 2 with nothing on stdout ----------------------------
for args in "kind ../unplanned" "review planned-stop" "kind" "merge review" "kind unplanned extra"; do
  status=0
  read -r -a argv <<< "$args"
  "$BASH" "$dispatcher" "${argv[@]}" > "$scratch/out" 2> "$scratch/error" || status=$?
  [[ "$status" == 2 && ! -s "$scratch/out" && -s "$scratch/error" ]] || fail "invalid pair '$args' exited $status"
done

# --- A missing, linked, or relocated module exits 3 and names the path ------
mkdir -p "$scratch/partial/scripts" "$scratch/partial/modules/kinds" "$scratch/partial/modules/review"
cp "$dispatcher" "$scratch/partial/scripts/"
partial_dispatch="$scratch/partial/scripts/dispatch-module.sh"
status=0
"$BASH" "$partial_dispatch" kind unplanned > "$scratch/out" 2> "$scratch/error" || status=$?
[[ "$status" == 3 && ! -s "$scratch/out" ]] || fail "missing module exited $status"
grep -Fq "required module unreadable: $(cd "$scratch/partial/modules/kinds" && pwd -P)/unplanned.md" "$scratch/error" \
  || fail "missing-module error does not name the path"

partial_merge="$scratch/partial/modules/review/merge.md"
for target in "$skill/modules/review/merge.md" "$scratch/nonexistent.md"; do
  ln -s "$target" "$partial_merge"
  status=0
  "$BASH" "$partial_dispatch" review merge > "$scratch/out" 2> "$scratch/error" || status=$?
  [[ "$status" == 3 && ! -s "$scratch/out" ]] || fail "linked module ($target) exited $status"
  grep -Fq 'required module unreadable:' "$scratch/error" || fail "linked module error text"
  rm "$partial_merge"
done
cp "$skill/modules/review/merge.md" "$partial_merge"
[[ "$("$BASH" "$partial_dispatch" review merge)" == "$(cd "$scratch/partial/modules/review" && pwd -P)/merge.md" ]] \
  || fail "copied install does not resolve its own module"
mv "$scratch/partial/modules/review" "$scratch/detached-review"
ln -s "$scratch/detached-review" "$scratch/partial/modules/review"
status=0
"$BASH" "$partial_dispatch" review merge > "$scratch/out" 2> "$scratch/error" || status=$?
[[ "$status" == 3 && ! -s "$scratch/out" ]] || fail "linked module directory exited $status"
rm "$scratch/partial/modules/review"
mv "$scratch/detached-review" "$scratch/partial/modules/review"

# Dispatch works from an unrelated working directory.
[[ "$(cd "$scratch" && "$BASH" "$dispatcher" kind planned-stop)" == "$skill/modules/kinds/planned-stop.md" ]] \
  || fail "dispatch from an unrelated directory"

# --- The entry's resolver: installed first, checkout only without HOME ------
resolver=$(extract_skill_bash "$entry" go-on-module-resolver)
mkdir -p "$scratch/home/.claude/skills-worktree/.claude/skills" "$scratch/project"
ln -s "$skill" "$scratch/home/.claude/skills-worktree/.claude/skills/go-on"
trace="$resolver"$'\nprintf "%s\\n" "$GO_ON_MODULE_DISPATCH"\n'
selected=$(cd "$scratch/project" && HOME="$scratch/home" "$BASH" -eu -c "$trace")
[[ "$selected" == "$scratch/home/.claude/skills-worktree/.claude/skills/go-on/scripts/dispatch-module.sh" ]] \
  || fail "resolver did not prefer the skills worktree: $selected"
[[ "$("$BASH" "$selected" kind unplanned)" == "$skill/modules/kinds/unplanned.md" ]] || fail "installed dispatch"
selected=$(cd "$root" && env -u HOME "$BASH" -eu -c "$trace")
[[ "$selected" == '.claude/skills/go-on/scripts/dispatch-module.sh' ]] || fail "unset-HOME fallback: $selected"
selected=$(cd "$scratch/project" && HOME="$scratch/empty-home" "$BASH" -eu -c "$trace")
[[ -z "$selected" ]] || fail "resolver invented a dispatcher: $selected"

# --- Traces: each stoppage kind reads only its own kind module --------------
# The routing table in the entry is the source; a trace is the selected paths.
table_pairs() { # table_pairs <class cell text>
  local row
  row=$(grep -F -- "| $1 |" "$entry") || fail "routing table has no row for $1"
  grep -oE '`(kind|review):[a-z-]+`' <<< "$row" | tr -d '`' || true
}
# Module holding a "## Step N:" heading, by dispatching every review phase.
module_with_step() {
  local step=$1 phase hit="" path
  for phase in $reviews; do
    path=$("$BASH" "$dispatcher" review "$phase")
    if grep -qE "^## Step ${step}:" "$path"; then
      [[ -z "$hit" ]] || fail "Step $step appears in more than one review module"
      hit=$phase
    fi
  done
  [[ -n "$hit" ]] || fail "no review module holds Step $step"
  printf '%s\n' "$hit"
}
# Review phases from one phase onward, in lane order.
from_phase() {
  local start=$1 phase on=""
  for phase in $reviews; do
    [[ "$phase" == "$start" ]] && on=1
    [[ -n "$on" ]] && printf '%s\n' "$phase"
  done
  return 0
}
trace_of() { # trace_of "<pair> <pair>..." -> module paths relative to the skill, space-joined
  local pair path out=""
  for pair in $1; do
    path=$("$BASH" "$dispatcher" "${pair%%:*}" "${pair#*:}")
    out="${out}${out:+ }${path#"$skill/"}"
  done
  printf '%s\n' "$out"
}

none_pairs=$(table_pairs '`none`, or unclassifiable')
[[ -z "$none_pairs" ]] || fail "classification-only route reads modules: $none_pairs"
[[ "$(table_pairs '`pause` / `end`')" == 'kind:planned-stop' ]] || fail "pause/end route"
[[ "$(table_pairs '`usage_limit_park`')" == 'kind:usage-limit-park' ]] || fail "park route"
[[ "$(table_pairs '`token_exhaustion`' | head -1)" == 'kind:token-exhaustion' ]] || fail "token route"
[[ "$(table_pairs '`token_exhaustion`' | sed -n 2p)" == 'review:prepare' ]] || fail "token route reads prepare first"
unplanned_route=$(table_pairs '`unplanned`' | tr '\n' ' ')
[[ "$unplanned_route" == 'kind:unplanned review:prepare review:publish review:respond review:merge ' ]] \
  || fail "unplanned route: $unplanned_route"

# token_exhaustion: the kind module names the step; the lane continues in order.
token_trace() { # token_trace <step from needs>
  local start pairs="kind:token-exhaustion review:prepare" phase
  start=$(module_with_step "$1")
  for phase in $(from_phase "$start"); do
    [[ "$phase" == prepare ]] || pairs="$pairs review:$phase"
  done
  trace_of "$pairs"
}
token_kind="$skill/modules/kinds/token-exhaustion.md"
grep -Fq '`continue_polling` → Step 6, `continue_fixes` → Step 7, unpushed fixes → Step 1b' "$token_kind" || fail "token needs mapping moved"
grep -Fq '`review:prepare` for Step 1b, `review:respond` for Step 6 and Step 7' "$token_kind" || fail "token module header"
# phase-a-fixer's token-exhaustion handoff writes needs: continue_fixes.
grep -Fq '"needs": "continue_fixes"' "$root/.claude/agents/phase-a-fixer.md" || fail "phase-a-fixer no longer writes continue_fixes"
[[ "$(token_trace 6)" == 'modules/kinds/token-exhaustion.md modules/review/prepare.md modules/review/respond.md modules/review/merge.md' ]] \
  || fail "continue_polling trace: $(token_trace 6)"
[[ "$(token_trace 7)" == 'modules/kinds/token-exhaustion.md modules/review/prepare.md modules/review/respond.md modules/review/merge.md' ]] \
  || fail "continue_fixes trace: $(token_trace 7)"
[[ "$(token_trace 1b)" == 'modules/kinds/token-exhaustion.md modules/review/prepare.md modules/review/publish.md modules/review/respond.md modules/review/merge.md' ]] \
  || fail "unpushed-fixes trace: $(token_trace 1b)"

for kind in $kinds; do
  case "$kind" in
    planned-stop) pairs=$(table_pairs '`pause` / `end`') ;;
    usage-limit-park) pairs=$(table_pairs '`usage_limit_park`') ;;
    token-exhaustion) pairs=$(table_pairs '`token_exhaustion`') ;;
    unplanned) pairs=$(table_pairs '`unplanned`') ;;
  esac
  kind_trace=$(trace_of "$pairs")
  for other in $kinds; do
    [[ "$other" == "$kind" ]] && continue
    [[ " $kind_trace " != *"modules/kinds/$other.md"* ]] || fail "$kind trace reads $other: $kind_trace"
  done
done
[[ "$(trace_of kind:planned-stop)" == 'modules/kinds/planned-stop.md' ]] || fail "pause/end trace"
[[ "$(trace_of kind:usage-limit-park)" == 'modules/kinds/usage-limit-park.md' ]] || fail "park trace"

# --- Compaction: re-dispatch only the persisted active kind and phase -------
# A recovery reloads the entry, then the active kind, review:prepare (helpers and
# the authorship and diff-survival guards a write needs), and the module holding
# the active step. Other phases stay unread.
for case_ in "unplanned 9a merge" "unplanned 7 respond" "token-exhaustion 6 respond" "unplanned 3 publish"; do
  read -r kind step want <<< "$case_"
  phase=$(module_with_step "$step")
  [[ "$phase" == "$want" ]] || fail "Step $step is in $phase, expected $want"
  [[ "$(trace_of "kind:$kind review:prepare review:$phase")" == "modules/kinds/$kind.md modules/review/prepare.md modules/review/$want.md" ]] \
    || fail "compaction trace for $case_"
done
grep -Fq 'For `token_exhaustion` and `unplanned`, read only the active kind module, `review:prepare`, and the active review module.' "$entry" || fail "compaction rule"
grep -Fq 'For `pause` / `end` and `usage_limit_park`, read only the active kind module.' "$entry" || fail "delegated-lane compaction rule"
grep -Fq 'a fresh `/go-on` invocation applies the full 0.4 precedence table again' "$entry" || fail "compaction keeps precedence"
grep -Fq "re-check Step 0b's authorship guard and Step 1's diff-survival guard" "$entry" || fail "compaction gates"
grep -Fq 'always re-runs Step 8 (read-only) before Step 9a or Step 10' "$entry" || fail "compaction re-derives CLEAN_BEHIND"
grep -Fq "Before Step 6 or Step 7, run that module's Step 5" "$token_kind" || fail "token resume reloads the sticky reviewer"
grep -Fq 'so a `continue_fixes` resume reaches Step 7 rather than waiting at Step 6' "$token_kind" || fail "continue_fixes overrides Step 5 exit 1"
grep -Fq '`continue_fixes` (Step 5, then Step 7, even when Step 5 exits `1`)' "$skill/modules/review/respond.md" || fail "respond header continue_fixes route"
grep -Fq 'to `/pause-resume` only, `--generation`' "$skill/modules/kinds/planned-stop.md" || fail "end-resume must not receive --generation"

# --- Preflight: a missing lane module blocks before any write ---------------
# Simulated caller: resolve every lane module, then write the receipt.
preflight_then_write() { # <dispatcher> <receipt file> <pair>...
  local d=$1 receipt=$2 pair
  shift 2
  for pair in "$@"; do
    "$BASH" "$d" "${pair%%:*}" "${pair#*:}" > /dev/null || return $?
  done
  : > "$receipt"
}
mkdir -p "$scratch/install"
cp -R "$skill/." "$scratch/install/"
rm "$scratch/install/modules/review/merge.md"
status=0
preflight_then_write "$scratch/install/scripts/dispatch-module.sh" "$scratch/receipt" \
  kind:unplanned review:prepare review:publish review:respond review:merge 2> "$scratch/error" || status=$?
[[ "$status" == 3 && ! -e "$scratch/receipt" ]] || fail "preflight did not stop before the receipt write ($status)"
grep -Fq 'modules/review/merge.md' "$scratch/error" || fail "preflight error does not name merge.md"
# A delegated lane does not depend on the review modules.
preflight_then_write "$scratch/install/scripts/dispatch-module.sh" "$scratch/receipt" kind:planned-stop \
  || fail "planned-stop preflight blocked on an unrelated module"
[[ -e "$scratch/receipt" ]] || fail "planned-stop preflight wrote nothing"
# A continue_polling token_exhaustion resume never reaches review:publish, so
# its preflight resolves only the modules token_trace 6 reads; a missing
# publish.md does not block it, while the Step 1b route still does.
cp "$skill/modules/review/merge.md" "$scratch/install/modules/review/merge.md"
rm "$scratch/install/modules/review/publish.md" "$scratch/receipt"
grep -Fq 'Step 6 or Step 7: `review:respond` and `review:merge`; Step 1b: all four' "$entry" || fail "token preflight scope"
token_preflight() { # <step>
  local pairs=(kind:token-exhaustion review:prepare) phase
  for phase in $(from_phase "$(module_with_step "$1")"); do
    [[ "$phase" == prepare ]] || pairs+=("review:$phase")
  done
  preflight_then_write "$scratch/install/scripts/dispatch-module.sh" "$scratch/receipt" "${pairs[@]}"
}
token_preflight 6 || fail "continue_polling preflight blocked on unreached publish.md"
[[ -e "$scratch/receipt" ]] || fail "continue_polling preflight wrote nothing"
rm "$scratch/receipt"
status=0
token_preflight 1b 2> /dev/null || status=$?
[[ "$status" == 3 && ! -e "$scratch/receipt" ]] || fail "unpushed-fixes preflight ignored missing publish.md ($status)"
grep -Fq '[BLOCKED] /go-on module unavailable: <operation:phase>' "$entry" || fail "blocker line"
grep -Fq 'Never fall back to another module' "$entry" || fail "no-fallback rule"
grep -Fq 'Write no receipt.' "$entry" || fail "missing module writes a receipt"
grep -Fq 'rerun `/go-on --again`' "$entry" || fail "post-receipt next step"

# --- Structure: headers, no imports, gates stay in the entry ----------------
while IFS= read -r module; do
  grep -Fxq '<!-- go-on-routing:begin -->' <<< "$(head -1 "$module")" || fail "$module lacks a routing header"
  header=$(sed -n '1,/<!-- go-on-routing:end -->/p' "$module")
  for field in 'Route `' '**Trigger:**' '**Prerequisites:**'; do
    grep -Fq "$field" <<< "$header" || fail "$module header lacks $field"
  done
done < <(find "$skill/modules" -type f -name '*.md' | sort)
if grep -nE '^[[:space:]]*@' "$entry"; then fail "entry has an @ import"; fi
for anchor in go-on-approved-quota-batch go-on-quota-resume-options go-on-limit-generation-gate \
    go-on-live-native-session-gate go-on-limit-park-probe go-on-module-resolver; do
  grep -Fq "<!-- test-anchor: $anchor -->" "$entry" || fail "entry lost anchor $anchor"
done
for heading in '### 0.1 Parse arguments' '### 0.2 Resolve the stop-state helpers' '### 0.2a Validate' \
    '### 0.3 Probe the evidence' '### 0.4 Precedence' '### 0.5 Resume receipt' '### 0.5a Log the stoppage' '### 0.6 Dispatch'; do
  grep -Fq "$heading" "$entry" || fail "entry lost $heading"
done
grep -Fq 'Never duplicate a live task or Monitor' "$entry" || fail "live-work check left the entry"
grep -Fq 'PM run mode reread' "$entry" || fail "run-mode reread left the entry"
if grep -qE '^## Step ([1-9]|0b)' "$entry"; then fail "a lane step remains in the entry"; fi

# Each test anchor and each lane step exists exactly once across the skill.
for anchor in $(grep -rohE --include='*.md' 'test-anchor: [a-z0-9-]+' "$skill" | sort -u | cut -d' ' -f2); do
  count=$(grep -rhF --include='*.md' "<!-- test-anchor: $anchor -->" "$skill" | wc -l | tr -d ' ')
  [[ "$count" == 1 ]] || fail "anchor $anchor appears $count times"
done
for step in 0b 1 1b 2 3 4 5 6 7 8 9 9a 10; do
  count=$(grep -rhE --include='*.md' "^## Step ${step}:" "$skill" | wc -l | tr -d ' ')
  [[ "$count" == 1 ]] || fail "Step $step appears $count times"
done

# --- Verbatim parity with the pre-split file --------------------------------
# Lines outside go-on-routing markers, ignoring blank lines and bare `---`
# separators, must equal the pre-split file's lines as a multiset. Runs while
# the comparison base still holds the monolithic skill; GO_ON_SPLIT_BASELINE
# pins a commit (the split was cut from e0a68ddf).
parity_base=${GO_ON_SPLIT_BASELINE:-}
if [[ -z "$parity_base" ]]; then
  for ref in origin/main main; do
    if base_commit=$(git -C "$root" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null); then
      parity_base=$(git -C "$root" merge-base HEAD "$base_commit" 2>/dev/null) || parity_base=""
      [[ -n "$parity_base" ]] && break
    fi
  done
fi
if [[ -z "$parity_base" ]]; then
  printf '%s\n' 'go-on split parity: SKIP — no comparison base in this checkout'
elif git -C "$root" cat-file -e "$parity_base:.claude/skills/go-on/modules" 2>/dev/null; then
  printf 'go-on split parity: SKIP — base %s already has the split layout\n' "$parity_base"
else
  git -C "$root" show "$parity_base:.claude/skills/go-on/SKILL.md" > "$scratch/baseline.md" \
    || fail "cannot read the baseline go-on skill at $parity_base"
  parity_files=("$scratch/baseline.md" "$entry")
  while IFS= read -r module; do parity_files+=("$module"); done < <(find "$skill/modules" -type f -name '*.md' | sort)
  python3 - "${parity_files[@]}" <<'PY' || exit 1
import sys
from collections import Counter

BEGIN, END = "<!-- go-on-routing:begin -->", "<!-- go-on-routing:end -->"

def lines(path, markers):
    out, inside = [], False
    with open(path, encoding="utf-8") as handle:
        for line in handle.read().split("\n"):
            if markers and line == BEGIN:
                if inside:
                    sys.exit(f"{path}: nested routing marker")
                inside = True
            elif markers and line == END:
                if not inside:
                    sys.exit(f"{path}: unmatched routing end marker")
                inside = False
            elif not inside and line.strip() and line != "---":
                out.append(line)
    if inside:
        sys.exit(f"{path}: unclosed routing marker")
    return out

before = Counter(lines(sys.argv[1], False))
after = Counter(line for path in sys.argv[2:] for line in lines(path, True))
# Deliberate deviations from the pre-split text, each counted exactly
# (PR #2533 review findings on pre-existing behaviour).
# 1. The BugBot branch of Step 6 read $SHA, assigned only in the CR branch;
#    review/respond.md now assigns it there too.
# 2. The token_exhaustion lane had no step for phase-a-fixer's
#    `needs: continue_fixes`; kinds/token-exhaustion.md maps it to Step 7.
# 3. The pause/end lane forwarded --generation to /end-resume, which declares
#    no such flag; kinds/planned-stop.md now forwards it to /pause-resume only.
REPLACED = [
    ("`continue_polling` → Step 6, unpushed fixes → Step 1b",
     "`continue_polling` → Step 6, `continue_fixes` → Step 7, unpushed fixes → Step 1b"),
    ("**and `--generation` when 0.2a validated one**. Forwarding it",
     "**and, to `/pause-resume` only, `--generation` when 0.2a validated one** (`/end-resume` declares no such flag). Forwarding it"),
]
for old, new in REPLACED:
    hits = [line for line in before if old in line]
    if len(hits) != 1 or before[hits[0]] != 1:
        sys.exit(f"go-on split parity: FAIL — deliberate replacement base not found once: {old[:60]}")
    before[hits[0].replace(old, new)] += before.pop(hits[0])
deliberate = Counter({
    "SHA=$(gh pr view $PR_NUM --json commits --jq '.commits[-1].oid')": 1,
})
absent = deliberate - (after - before)
for line, count in absent.items():
    print(f"deliberate deviation not present ({count}): {line[:120]}", file=sys.stderr)
if absent:
    sys.exit("go-on split parity: FAIL")
after -= deliberate
missing, extra = before - after, after - before
for label, counts in (("missing", missing), ("unmarked extra", extra)):
    for line, count in counts.items():
        print(f"{label} ({count}): {line[:120]}", file=sys.stderr)
if missing or extra:
    sys.exit("go-on split parity: FAIL")
print(f"go-on split parity: {sum(before.values())} instruction lines match the pre-split file")
PY
fi

printf '%s\n' 'go-on module routes: 8 kind/review pairs, per-kind traces, invalid/missing/linked guards, preflight, compaction, installed resolution'
