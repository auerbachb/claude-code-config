#!/usr/bin/env bash
# Unit tests for chip-model-guard-lint.sh (issue #731)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/.github/scripts/chip-model-guard-lint.sh"

TMP_ROOT=$(mktemp -d -t chip-model-guard-lint.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0

# Canonical emitters, split by class (issue #770). Literal emitters name the
# model; resolver emitters look it up via model-fleet.sh and must contain no
# model literal at all.
LITERAL_EMITTERS=(pm prompt start-issue issue-maker wave)
RESOLVER_EMITTERS=(harness-audit)
ALL_EMITTERS=("${LITERAL_EMITTERS[@]}" "${RESOLVER_EMITTERS[@]}")

make_fixture() {
  local dir="$1" skill
  mkdir -p "$dir/.claude/reference" "$dir/.claude/rules"
  for skill in "${ALL_EMITTERS[@]}"; do
    mkdir -p "$dir/.claude/skills/${skill}"
  done
  cp "$REPO_ROOT/.claude/reference/chip-launching.md" "$dir/.claude/reference/"
  cp "$REPO_ROOT/.claude/reference/chip-model-guard-decision.md" "$dir/.claude/reference/"
  cp "$REPO_ROOT/.claude/rules/chip-spawn.md" "$dir/.claude/rules/"
  cp "$REPO_ROOT/CLAUDE.md" "$dir/CLAUDE.md"
  for skill in "${ALL_EMITTERS[@]}"; do
    cp "$REPO_ROOT/.claude/skills/${skill}/SKILL.md" "$dir/.claude/skills/${skill}/"
  done
}

expect() {
  local name="$1" want="$2" want_re="$3"; shift 3
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"
  if ! ( cd "$dir" && "$@" ); then
    echo "FAIL — ${name}: fixture mutation failed (see error above)"
    failures=$((failures + 1))
    return
  fi

  local out got
  out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?

  if (( got != want )); then
    echo "FAIL — ${name}: expected exit ${want}, got ${got}"
    echo "$out" | sed 's/^/       /'
    failures=$((failures + 1))
    return
  fi

  if ! grep -qE "$want_re" <<< "$out"; then
    echo "FAIL — ${name}: exit ${got} as expected, but output did not match /${want_re}/"
    echo "$out" | sed 's/^/       /'
    failures=$((failures + 1))
    return
  fi

  echo "ok   — ${name}"
}

noop() { :; }

# A sed mutation whose pattern silently stops matching — a reworded heading, a
# renamed section — leaves the fixture pristine, so the lint passes for the
# ordinary reason and the case "succeeds" without testing anything. #791 hit
# exactly that while authoring these fixtures. `mutate` makes a no-op loud.
mutate() {  # mutate <file> <sed-expression>
  local file="$1" expr="$2" before after
  before=$(cksum < "$file")
  sed -i.bak "$expr" "$file"
  after=$(cksum < "$file")
  if [[ "$before" == "$after" ]]; then
    echo "       FIXTURE ERROR — no-op mutation on ${file}: ${expr}" >&2
    return 90
  fi
}

# Appends cannot no-op, so they need no such guard.
append_line() { printf '\n%s\n' "$2" >> "$1"; }

expect "well-formed repo passes" 0 'chip-model-guard-lint: OK' noop

expect "missing MODEL GUARD in chip-launching fails" 1 \
  'Missing required MODEL GUARD preamble marker' \
  mutate .claude/reference/chip-launching.md '/MODEL GUARD:/d'

expect "missing /pm emitter in chip-launching fails" 1 \
  'chip-launching /pm emitter reference' \
  mutate .claude/reference/chip-launching.md '/\/pm/d'

expect "missing Fable guidance in chip-launching fails" 1 \
  'Fable pre-click warning guidance' \
  mutate .claude/reference/chip-launching.md '/Fable parent/d'

expect "missing model-guard in pm skill fails" 1 \
  'pm model-guard requirement' \
  mutate .claude/skills/pm/SKILL.md '/model-guard preamble/d'

# After the co-occurrence tightening (#802) wave has TWO lines that satisfy the
# check: the "Chip model + effort contract" line (has "MUST open" + **Model:**)
# and the prompt-description line (`**Model:**` line first).  Removing only the
# first still leaves the second, so both must be cleared to prove the check fires.
decouple_wave_placement() {
  mutate .claude/skills/wave/SKILL.md '/Chip model + effort contract/d'
  mutate .claude/skills/wave/SKILL.md 's/`\*\*Model:\*\*` line first,/the Model line first,/'
}

expect "missing first-line placement in wave skill fails" 1 \
  'wave first-line \*\*Model:\*\* placement' \
  decouple_wave_placement

expect "missing Fable warning in start-issue skill fails" 1 \
  'start-issue Fable pre-click warning requirement' \
  mutate .claude/skills/start-issue/SKILL.md '/Fable/d'

expect "missing chip-spawn rule index fails" 1 \
  'CLAUDE.md chip-spawn rule index entry' \
  mutate CLAUDE.md '/chip-spawn\.md/d'

# --- #791: the effort line and the versionless rule ------------------------

# Functions rather than inline commands: `expect` runs "$@" in a subshell of
# this shell, so shell functions resolve there just like `noop` above.
drop_effort_from_prompt() { mutate .claude/skills/prompt/SKILL.md '/\*\*Effort:\*\*/d'; }
drop_effort_from_contract() { mutate .claude/reference/chip-launching.md '/\*\*Effort:\*\*/d'; }
drop_effort_from_rule() { mutate .claude/rules/chip-spawn.md '/\*\*Effort:\*\*/d'; }
reintroduce_versioned_name() { append_line .claude/rules/chip-spawn.md 'Historical aside: Opus 5 was once the picker default.'; }
reintroduce_versioned_name_in_skill() { append_line .claude/skills/wave/SKILL.md 'Step up to Sonnet 4.6 for cheap work.'; }
drop_model_effort_section() { mutate .claude/reference/chip-launching.md '/Model and effort lines/d'; }
drop_ultra_code_guidance() { mutate .claude/reference/chip-launching.md '/Ultra code/d'; }
# A bare "Fable" mention must not satisfy the pre-click-warning check: the
# rename from "Fable 5" to "Fable" would otherwise have weakened it into a
# match on any passing mention of the model. The replacement text deliberately
# still says "Fable" — otherwise a loose /Fable/ check would fail here too and
# the case would pass whether or not the check is strict, proving nothing.
weaken_fable_warning() { mutate .claude/skills/wave/SKILL.md 's/parent thread is on Fable/chip may recommend Fable/'; }

expect "missing Effort line in prompt skill fails" 1 \
  'prompt \*\*Effort:\*\* requirement' \
  drop_effort_from_prompt

expect "missing Effort line in chip-launching fails" 1 \
  'Missing required Effort line contract' \
  drop_effort_from_contract

expect "missing Effort line in chip-spawn rule fails" 1 \
  'chip-spawn.md Effort line rule' \
  drop_effort_from_rule

expect "reintroduced versioned model name in a rule file fails" 1 \
  'Versioned model name' \
  reintroduce_versioned_name

expect "reintroduced versioned model name in a skill file fails" 1 \
  'Versioned model name' \
  reintroduce_versioned_name_in_skill

expect "missing model+effort placement section in chip-launching fails" 1 \
  'model\+effort placement section' \
  drop_model_effort_section

expect "missing Ultra-code guidance in chip-launching fails" 1 \
  'Ultra-code-is-not-a-level guidance' \
  drop_ultra_code_guidance

expect "bare Fable mention does not satisfy the pre-click warning check" 1 \
  'wave Fable pre-click warning requirement' \
  weaken_fable_warning

# Tool-consumed model IDs must NOT trip the versioned-name scan: they are
# lowercase and hyphenated, so "Family<space>digit" cannot match them. Without
# this case, tightening the regex could silently start failing every explicit
# `claude-opus-5` in the repo.
add_explicit_model_ids() { append_line .claude/rules/chip-spawn.md 'Config value the CLI parses: `claude-opus-5`, `claude-haiku-4-5-20251001`.'; }

expect "explicit tool-consumed model IDs still pass" 0 \
  'chip-model-guard-lint: OK' \
  add_explicit_model_ids

# Dated .claude/reference/ audit records are point-in-time history and keep
# their versioned model names by design (.claude/reference/README.md, "Audits
# and research"). The scan names its two living-contract files explicitly
# rather than scanning the directory, so an audit file must not trip it —
# this case is what stops a future "just scan .claude/reference" from
# quietly rewriting history to make the lint pass.
add_dated_audit_record() {
  append_line .claude/reference/harness-model-audit-2026-06.md \
    'As of this audit the picker default was Opus 5 and Haiku 4.5 was the cheap tier.'
}

expect "dated reference audit records are exempt from the versioned-name scan" 0 \
  'chip-model-guard-lint: OK' \
  add_dated_audit_record

# --- sixth emitter + resolver class (issue #770) -----------------------------

expect "missing /harness-audit emitter in chip-launching fails" 1 \
  'chip-launching /harness-audit emitter reference' \
  sed -i.bak '/harness-audit/d' .claude/reference/chip-launching.md

expect "missing /harness-audit in decision record fails" 1 \
  'decision record /harness-audit reference' \
  sed -i.bak '/harness-audit/d' .claude/reference/chip-model-guard-decision.md

expect "deleted harness-audit skill fails" 1 \
  'canonical chip emitter missing' \
  rm -f .claude/skills/harness-audit/SKILL.md

# The resolver emitter is checked on the resolver reference, NOT on a model
# literal — dropping model-fleet.sh means it can no longer resolve a tier.
expect "resolver emitter without model-fleet.sh fails" 1 \
  'harness-audit model-fleet.sh resolver reference' \
  sed -i.bak '/model-fleet\.sh/d' .claude/skills/harness-audit/SKILL.md

expect "resolver emitter without pre-click warning fails" 1 \
  'harness-audit pre-click warning requirement' \
  sed -i.bak '/pre-click/d' .claude/skills/harness-audit/SKILL.md

# The inverted check: a hardcoded model name in a resolver emitter is an error,
# because it reintroduces exactly the drift the resolver removes (#749).
plant_model_literal() {
  printf '\nRecommend Opus 5 for this pass.\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "model literal planted in resolver emitter fails" 1 \
  'must not hardcode a model name' \
  plant_model_literal

plant_api_id_literal() {
  printf '\nUse claude-fable-5 for the judgment pass.\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "api-id model literal in resolver emitter fails" 1 \
  'must not hardcode a model name' \
  plant_api_id_literal

# Bare aliases are caught only in a model-value position, so both field spellings
# must trip the check.
plant_alias_model_field() {
  printf '\nmodel: opus\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "bare alias in a model: field fails" 1 \
  'must not hardcode a bare model alias' \
  plant_alias_model_field

plant_capitalized_alias() {
  printf '\nmodel: Opus\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "capitalized alias in a model: field fails" 1 \
  'must not hardcode a bare model alias' \
  plant_capitalized_alias

plant_uppercase_literal() {
  printf '\nUse CLAUDE-OPUS-5 for this pass.\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "uppercase api-id literal fails" 1 \
  'must not hardcode a model name' \
  plant_uppercase_literal

plant_alias_chip_line() {
  printf '\n**Model:** sonnet — cheap pass\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "bare alias on a **Model:** line fails" 1 \
  'must not hardcode a bare model alias' \
  plant_alias_chip_line

# ...and prose that merely contains the word must NOT trip it, or the check is
# unusable in any document that discusses model tiers.
plant_alias_in_prose() {
  printf '\nThe fleet spans fable, opus, sonnet, and haiku tiers.\n' >> .claude/skills/harness-audit/SKILL.md
}
expect "bare alias in ordinary prose still passes" 0 \
  'chip-model-guard-lint: OK' \
  plant_alias_in_prose

# A literal emitter must NOT be subject to the inverted rule — naming the model
# is the whole point there. This guards against the classes being swapped.
# The literal is a bare family name: since #791 a *versioned* one fails
# everywhere, so this case would otherwise pass for the wrong reason and stop
# testing the class split at all (the next case pins that half).
plant_literal_in_pm() {
  printf '\nFable remains the top tier for this pass.\n' >> .claude/skills/pm/SKILL.md
}
expect "model literal in a literal emitter still passes" 0 \
  'chip-model-guard-lint: OK' \
  plant_literal_in_pm

# ...but a versioned literal fails even in a literal emitter (#791). Together
# with the case above this pins both halves: family names are fine in a literal
# emitter, version numbers are fine nowhere.
plant_versioned_literal_in_pm() {
  printf '\nFable 5 remains the top tier for this pass.\n' >> .claude/skills/pm/SKILL.md
}
expect "versioned literal fails even in a literal emitter" 1 \
  'Versioned model name' \
  plant_versioned_literal_in_pm

# --- #802: co-occurrence check (placement phrase must be *about* **Model:**) ---

# The too-loose direction: a placement phrase on a line that does NOT also carry
# **Model:**.  The issue body calls out "MUST open with the task description" as
# the canonical example of a claim that the old loose alternation accepted (it
# matched "MUST open") but the new co-occurrence check rejects.  The mutation
# replaces issue-maker's real placement claim ("MUST open with the `**Model:**`
# line") with that exact example text so the replacement deliberately keeps the
# phrase — otherwise a loose /MUST open/ check would still fail here and the
# case would not distinguish strict from loose.
must_open_task_description() {
  mutate .claude/skills/issue-maker/SKILL.md \
    's/MUST open with the `\*\*Model:\*\*` line from/MUST open with the task description from/'
}

expect "placement phrase without **Model:** co-occurrence fails (Issue #802 example)" 1 \
  'issue-maker first-line \*\*Model:\*\* placement' \
  must_open_task_description

# The too-brittle direction: PR #799 proposed rewording "the **Model:** line
# first" — more direct than "as the first line of the prompt" but broke the old
# loose check because bare "first" was not in its vocabulary. The new
# co-occurrence check must accept it because **Model:** and "first" appear on
# the same line. The replacement deliberately retains both so the case proves
# co-occurrence strictness, not mere phrase-absence.
rewording_pr799() {
  mutate .claude/skills/pm/SKILL.md \
    's/ as the \*\*first line\*\* of the / **first** in the chip /'
}

expect "PR#799 rewording (**Model:** line first in chip prompt) still passes" 0 \
  'chip-model-guard-lint: OK' \
  rewording_pr799

# The right-side over-match: bare `\bfirst\b` before **Model:** on the same line
# was accepted even in non-contractual prose such as "the first time we reference
# **Model:**".  The fix removes `\bfirst\b` from the right-side alternation, so
# only the specific placement phrases (first line, first content, MUST open, …)
# satisfy the check when the phrase precedes **Model:** on the same line.  Bare
# "first" that precedes **Model:** is now correctly rejected as insufficient.
# (Bare "first" that FOLLOWS **Model:** on the same line still satisfies the
# left-side alternation — preserving the PR #799 rewording above.)
noncontractual_first_before_model() {
  mutate .claude/skills/issue-maker/SKILL.md \
    's/MUST open with the `\*\*Model:\*\*` line from/the first time we reference `\*\*Model:\*\*` is from/'
}

expect "non-contractual 'first' before **Model:** does not satisfy placement (#802 fix)" 1 \
  'issue-maker first-line \*\*Model:\*\* placement' \
  noncontractual_first_before_model

# --- #837: the guard compares families, not strings --------------------------

# Three preamble sentences carry the family-level semantics, and each can be
# reverted independently — so each gets its own revert-fails case. A suite that
# only covered one would leave the other two free to regress silently.
# None of these mutations touch an em dash: BSD sed's handling of multibyte
# patterns is locale-dependent, and a pattern that quietly stops matching would
# be caught by `mutate`'s no-op guard but only after wasting a debugging round.
drop_family_comparison() {
  mutate .claude/reference/chip-launching.md '/Compare families only/d'
}

expect "missing family-comparison rule in chip-launching fails" 1 \
  'Missing required family-level comparison rule' \
  drop_family_comparison

drop_version_qualifier_rule() {
  mutate .claude/reference/chip-launching.md '/old-style version qualifier/d'
}

expect "missing version-qualifier rule in chip-launching fails" 1 \
  'version-qualifier-is-noise rule' \
  drop_version_qualifier_rule

# The literal pre-#837 regression: the match branch echoing whatever string it
# read ({MODEL}) instead of naming the family it is running ({FAMILY}).
revert_family_self_report() {
  mutate .claude/reference/chip-launching.md 's/Running on {FAMILY}/Running on {MODEL}/'
}

expect "match branch reporting {MODEL} instead of {FAMILY} fails" 1 \
  'family self-report in match branch' \
  revert_family_self_report

# A bare mention of "families" must not satisfy the comparison check — the
# assertion has to bind to the contractual instruction, not to the word. The
# replacement deliberately keeps "families" AND states the string-equality rule
# this ticket removed, so the case proves strictness in both directions at once:
# a loose /families/ check would pass here, and only the phrase check fails it.
weaken_family_comparison() {
  mutate .claude/reference/chip-launching.md \
    's/Compare families only/Compare the exact strings; the families are listed as/'
}

expect "bare 'families' mention does not satisfy the family-comparison check" 1 \
  'family-level comparison rule' \
  weaken_family_comparison

# Semantic inversion, not deletion: a reword that keeps every keyword but
# reverses the rule is the failure mode a keyword-presence check cannot see.
# Both cases below deliberately leave the vocabulary intact, so a looser
# pattern would pass them and the case would prove nothing.

# "old-style version qualifier" survives verbatim; only the instruction flips.
invert_version_qualifier_rule() {
  mutate .claude/reference/chip-launching.md \
    's/qualifier: ignore it on either side/qualifier: honor it on both sides/'
}

expect "inverted version-qualifier rule (keyword intact) fails" 1 \
  'version-qualifier-is-noise rule' \
  invert_version_qualifier_rule

# "Running on {FAMILY}" survives in the document but leaves the Match branch,
# so the branch that must report a family no longer does.
unbind_family_report_from_match_branch() {
  mutate .claude/reference/chip-launching.md \
    's/Match (same family): state "Running on {FAMILY} as recommended."/Match: say you are proceeding. (Docs elsewhere use "Running on {FAMILY}".)/'
}

expect "{FAMILY} outside the Match branch does not satisfy the self-report check" 1 \
  'family self-report in match branch' \
  unbind_family_report_from_match_branch

# The third inversion: "Compare families only" survives as an exact substring
# while the sentence goes on to re-require string equality — the precise reword
# this ticket exists to prevent. Only the em-dash anchor rejects it; a bare
# substring check would pass it, which is why the anchor is not cosmetic.
readd_string_equality_after_family_rule() {
  mutate .claude/reference/chip-launching.md \
    's/Compare families only/Compare families only, and the exact model strings must match,/'
}

expect "family rule re-requiring exact strings (substring intact) fails" 1 \
  'family-level comparison rule' \
  readd_string_equality_after_family_rule

# --- #1398: the mismatch branch is a menu -----------------------------------
# Every case below degrades the menu contract while LEAVING ITS VOCABULARY IN
# PLACE, so a looser keyword check would pass each one and prove nothing. That
# is the same discipline the family-comparison cases above follow.

# The tool name survives in the sentence; only the instruction to use it goes.
revert_menu_to_typed_reply() {
  mutate .claude/reference/chip-launching.md \
    's/Surface the choice with AskUserQuestion/Report both models and wait for a typed reply (AskUserQuestion optional)/'
}

expect "mismatch branch reverted to a typed reply fails" 1 \
  'mismatch-branch AskUserQuestion vehicle' \
  revert_menu_to_typed_reply

# Both options survive, but neither is marked recommended — the menu still
# renders and the user loses the steer ask-menu.md requires.
drop_recommended_suffix() {
  mutate .claude/reference/chip-launching.md \
    's/ — continue (Recommended)"/ — continue"/'
}

expect "switched-confirm option without the (Recommended) suffix fails" 1 \
  'switched-confirm option, recommended-first suffix' \
  drop_recommended_suffix

# A one-option menu is not a choice: without the proceed-on-current path the
# only way past the guard is to claim a switch that may not have happened.
drop_proceed_option() {
  mutate .claude/reference/chip-launching.md '/"Continue on {RUNNING_FAMILY} anyway"/d'
}

expect "menu missing the proceed-on-current-model option fails" 1 \
  'proceed-on-current-model option' \
  drop_proceed_option

# The label substitutes the full model string instead of the family, which the
# decision record rules out for labels (the QUESTION text carries full names).
substitute_full_model_in_label() {
  mutate .claude/reference/chip-launching.md \
    's/"Switched to {RECOMMENDED_FAMILY} — continue/"Switched to {RECOMMENDED_MODEL} — continue/'
}

expect "option label substituting a full model instead of a family fails" 1 \
  'switched-confirm option, recommended-first suffix' \
  substitute_full_model_in_label

# Trusting the click is the failure this loop exists to prevent: a click cannot
# switch the model, so an unverified confirm is an unchecked override.
trust_the_click() {
  mutate .claude/reference/chip-launching.md \
    's/re-check the family you are running: if it now matches, state/take the user at their word and state/'
}

expect "confirm answer trusted without re-verification fails" 1 \
  'confirm-answer re-verification' \
  trust_the_click

# The prose branch survives verbatim, but its trigger stops being "the tool is
# unavailable" and becomes discretionary — which makes the menu skippable.
make_fallback_discretionary() {
  mutate .claude/reference/chip-launching.md \
    's/Fallback, when AskUserQuestion is unavailable (headless runs): report, in one/Alternatively, if you would rather not ask: report, in one/'
}

expect "prose fallback made discretionary rather than headless-only fails" 1 \
  'headless prose fallback for the mismatch branch' \
  make_fallback_discretionary

# Wholesale deletion of the mismatch branch, with every explanatory paragraph
# left standing. Measured: the pre-#1398 whole-file lint also catches this one
# (5 errors), because these anchors are quoted labels and imperative sentences
# that appear nowhere in the prose. It is kept as a plain regression test, and
# the block-scoping claim is carried by the NEXT case, which the whole-file
# lint provably does not catch.
delete_mismatch_branch_keep_prose() {
  mutate .claude/reference/chip-launching.md \
    '/^- Mismatch (different family)/,/is the recommended path instead\./d'
}

expect "mismatch branch deleted while its prose survives fails" 1 \
  'mismatch-branch AskUserQuestion vehicle' \
  delete_mismatch_branch_keep_prose

# The discriminating case for block scoping: the instruction leaves the fence
# and reappears as commentary underneath it, so the bytes a chip actually ships
# no longer carry it while the phrase is still somewhere in the file. Verified
# against the pre-#1398 script: whole-file greps report OK here (exit 0), and
# only the block-scoped check fails it. That delta is the whole reason
# require_guard_pattern exists.
move_menu_instruction_out_of_fence() {
  mutate .claude/reference/chip-launching.md \
    's/^  STOP\. Do no other work\. Surface the choice with AskUserQuestion — one$/  STOP. Do no other work. Report both models and wait. (Threads should/'
  append_line .claude/reference/chip-launching.md \
    'Commentary: Surface the choice with AskUserQuestion — one question naming both.'
}

expect "menu instruction moved out of the fence into prose fails" 1 \
  'mismatch-branch AskUserQuestion vehicle' \
  move_menu_instruction_out_of_fence

# A check that cannot run must never report OK (the silent-pass shape): with no
# fenced preamble at all, every block-scoped assertion has to fail loudly.
strip_preamble_fence() {
  mutate .claude/reference/chip-launching.md '/^```text$/,/^```$/{ /MODEL GUARD/!d; }'
}

expect "unextractable preamble block fails loudly rather than passing" 1 \
  'MODEL GUARD preamble block not found or empty|Missing required' \
  strip_preamble_fence

# A second marker-bearing fence makes "the block" ambiguous: the extractor takes
# the first, so a well-formed example could vouch for a rotted original.
add_second_guard_block() {
  append_line .claude/reference/chip-launching.md \
    '```text
MODEL GUARD: Your very first action — illustrative copy for documentation.
```'
}

expect "a second MODEL GUARD fenced block fails" 1 \
  'Expected exactly one fenced MODEL GUARD block, found 2' \
  add_second_guard_block

# "exactly these two options" is a contract a presence check cannot enforce:
# every asserted phrase survives while the menu grows a path nobody reasoned
# about.
add_third_menu_option() {
  mutate .claude/reference/chip-launching.md \
    's/^    2\. "Continue on {RUNNING_FAMILY} anyway" — proceed on the current model\.$/    2. "Continue on {RUNNING_FAMILY} anyway" — proceed on the current model.\
    3. "Relaunch this thread on {RECOMMENDED_FAMILY}" — start over./'
}

expect "a third menu option fails even with every phrase intact" 1 \
  'must offer exactly two numbered options, found 3' \
  add_third_menu_option

# The stop failing open: any typed reply becomes permission to resume.
let_free_text_resume_work() {
  mutate .claude/reference/chip-launching.md \
    's/and if it does not resolve the mismatch the STOP still stands, so ask again/and treat it as permission to resume work, so continue/'
}

expect "free-text escape treated as permission to resume fails" 1 \
  'free-text-escape answer keeps the stop' \
  let_free_text_resume_work

# The block that counts is the one under "## Model-guard preamble". Relocating
# it verbatim to another section leaves the marker in the file — and the
# whole-file count still sees exactly one — but the canonical section no longer
# carries the preamble a reader is sent to.
relocate_guard_block_out_of_section() {
  mutate .claude/reference/chip-launching.md '/^## Model-guard preamble$/s/.*/## Model-guard notes/'
}

expect "guard block outside its canonical section fails" 1 \
  'block not found or empty under the "## Model-guard preamble" section' \
  relocate_guard_block_out_of_section

# A heading that merely STARTS with the canonical text is a different section:
# under a prefix match it would open the real one and hand the checks whatever
# block it contains.
suffix_the_section_heading() {
  mutate .claude/reference/chip-launching.md \
    '/^## Model-guard preamble$/s/.*/## Model-guard preamble — example/'
}

expect "section heading with a suffix does not open the canonical section" 1 \
  'block not found or empty under the "## Model-guard preamble" section' \
  suffix_the_section_heading

if (cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1); then
  echo "ok   — real repo conformance is intact"
else
  echo "FAIL — lint does not pass against the real repo"
  (cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /') || true
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "chip-model-guard-lint.test: ${failures} failure(s)"
  exit 1
fi

echo "OK: chip-model-guard-lint tests passed (${case_num} fixtures)"
