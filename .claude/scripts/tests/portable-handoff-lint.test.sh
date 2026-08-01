#!/usr/bin/env bash
# Tests for portable-handoff-lint.sh — the enforceable half of issue #901.
#
# The issue's requirement is that portability be "testable, not aspirational",
# so these tests do two jobs:
#
#   1. Prove the checker catches each violation class. A lint nobody has seen
#      fail is indistinguishable from a lint that always passes.
#   2. Prove it does NOT fire on the things a genuinely useful handoff must
#      contain — absolute paths, GitHub URLs, ordinary git and gh commands.
#      An over-strict checker gets worked around, and a worked-around checker
#      enforces nothing.
#
# Also guards the issue's standing constraint: nothing shipped for #901 may
# compute or consult a local token/spend estimate, and safety.md's quota
# prohibition must survive unamended.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="$REPO_ROOT/.claude/scripts/portable-handoff-lint.sh"
SKILL="$REPO_ROOT/.claude/skills/pause/SKILL.md"
TEMPLATE="$REPO_ROOT/.claude/skills/pause/references/portable-handoff-template.md"
SAFETY_RULE="$REPO_ROOT/.claude/rules/safety.md"
RECORDER="$REPO_ROOT/.claude/hooks/usage-limit-record.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

[[ -x "$LINT" ]] || fail "portable-handoff-lint.sh is not executable"
[[ -f "$SKILL" ]] || fail "pause/SKILL.md is missing"
[[ -f "$TEMPLATE" ]] || fail "portable-handoff-template.md is missing"

GOLDEN="$TMP_DIR/golden.md"
cat >"$GOLDEN" <<'EOF'
# Session handoff — auerbachb/claude-code-config — 2026-08-01 11:50 ET

Written when the session was paused. Everything below reflects that moment;
check the current state of anything you are about to change before changing it.

## Start here

Read the two unresolved review comments on pull request 903, then fix them on
the branch already checked out at
/Users/b/Develop/claude-code-config/.claude/worktrees/issue-901-clean-pause.

## What we're working on

Adding a command that produces a handoff document any agent can act on, so a
session ending on a usage limit does not lose where the work stood.

## Open work

- **Pull request 903 — add the pause command**
  https://github.com/auerbachb/claude-code-config/pull/903
  Waiting on: the automated reviewer to re-run after the last push.
  What is left: answer whatever it raises, then merge once checks are green.

## Decisions made this session

- Reused the existing stop flag instead of adding a second one — both mean "do
  not start new work until a person says otherwise", and a second flag would
  need handling in every reader forever.

## Local state on this machine

Branch: issue-901-clean-pause
Working directory: /Users/b/Develop/claude-code-config/.claude/worktrees/issue-901-clean-pause
Uncommitted changes: none
Unpushed commits: none — run `git status` and `gh pr view 903` to confirm.
EOF

run_lint() { "$LINT" --repo-root "$REPO_ROOT" "$@"; }

# --- 1. The golden document passes ---------------------------------------
# It carries every required section, an absolute working-directory path, a full
# GitHub URL, and real shell commands. All of that must be allowed.
run_lint "$GOLDEN" >/dev/null 2>&1 || {
  run_lint "$GOLDEN" >&2
  fail "the golden portable handoff does not pass its own lint"
}

# --- 2. Every violation class is caught ----------------------------------
# Each fixture is the golden document plus ONE bad line, so a failure here is
# unambiguously about that line.
assert_catches() { # rule, appended-line
  local rule="$1" line="$2" out rc f="$TMP_DIR/bad.md"
  cp "$GOLDEN" "$f"
  printf '%s\n' "$line" >>"$f"
  out=$(run_lint "$f" 2>&1); rc=$?
  [[ "$rc" -eq 1 ]] || fail "expected exit 1 for [$rule], got $rc — line: $line"
  printf '%s' "$out" | grep -q "\[$rule\]" \
    || fail "expected rule [$rule] to fire on: $line"$'\n'"got: $out"
}

assert_catches harness-path           "Run .claude/scripts/merge-gate.sh 903 first."
assert_catches harness-path           "Config lives in .claude/rules/safety.md there."
assert_catches phase-vocabulary       "Pick it up again at Phase B."
assert_catches phase-vocabulary       "The pipeline reached merge_ready last night."
assert_catches phase-vocabulary       "A phase-a-fixer subagent was running."
# A capital letter cannot be what decides whether the jargon ships.
assert_catches phase-vocabulary       "Pick it up again at phase b."
assert_catches phase-vocabulary       "It was at Phase c last night."
assert_catches phase-vocabulary       "The pipeline hit Merge_Ready earlier."
assert_catches state-file             "The tracked list is in session-state.json."
assert_catches state-file             "Read handoff-state.sh for the rest."
assert_catches state-file             "See pr-903-handoff.json for findings."
assert_catches skill-invocation       "Run /wrap when the checks go green."
assert_catches skill-invocation       "Then /fixpr to clear the comments."
assert_catches unrendered-placeholder "Objective: {CURRENT_OBJECTIVE}"

# A `#`-prefixed line is still text the reader sees. Exempting headings from the
# CONTENT tally is right; exempting them from the RULES would let a shell
# comment in a fenced block smuggle a harness path straight through.
assert_catches harness-path      "# Run .claude/scripts/merge-gate.sh first"
assert_catches harness-path      "### See .claude/rules/safety.md for detail"
assert_catches skill-invocation  "# then /wrap it up"
assert_catches phase-vocabulary  "## Phase B notes"

# --- 3. The worktree exemption is exactly as narrow as advertised ---------
# Absolute + /worktrees/ is an address the reader can resolve. Everything else
# under .claude/ is a pointer only this checkout understands.
assert_catches harness-path "Uncommitted work is in .claude/worktrees/issue-901-x."
assert_catches harness-path "Helper at /Users/b/repo/.claude/scripts/merge-gate.sh."

# The masking must key on the TOKEN being absolute, not on the substring
# "/.claude/worktrees/" appearing anywhere — a repo-relative path contains that
# substring too and is exactly what harness-path is for.
assert_catches harness-path "Second copy is at repo/.claude/worktrees/issue-42-other now."
# An unrelated absolute path earlier in the same sentence must not vouch for a
# relative harness path later in it.
assert_catches harness-path "See /tmp/build, then repo/.claude/worktrees/issue-42-other."
assert_catches harness-path "Logs in /var/log; also ./.claude/worktrees/issue-42-other."
assert_catches harness-path "Or at ./.claude/worktrees/issue-42-other instead."
assert_catches harness-path "Try ../other/.claude/worktrees/issue-42-other too."

ALLOWED="$TMP_DIR/allowed.md"
cp "$GOLDEN" "$ALLOWED"
printf '%s\n' "Also check /Users/b/repo/.claude/worktrees/issue-42-other for a second branch." >>"$ALLOWED"
printf '%s\n' "Quoted: \`/Users/b/repo/.claude/worktrees/issue-43-x\` is fine too." >>"$ALLOWED"
# A URL is an address any reader can open, so a repository link that happens to
# point at a harness file is a portable reference, unlike a local path.
printf '%s\n' "Background: https://github.com/auerbachb/claude-code-config/blob/main/.claude/rules/safety.md" >>"$ALLOWED"
# Markdown emphasis around a path must not make it read as relative — a
# one-character delimiter strip leaves the second asterisk in front of the slash.
printf '%s\n' "Bold: **/Users/b/repo/.claude/worktrees/issue-45-bold**" >>"$ALLOWED"
printf '%s\n' "Quoted URL: **https://github.com/auerbachb/claude-code-config/blob/main/.claude/rules/safety.md**" >>"$ALLOWED"
run_lint "$ALLOWED" >/dev/null 2>&1 \
  || fail "an absolute /.claude/worktrees/ path must be allowed — it is the reader's own uncommitted work"

# Directory names contain spaces, and the Working directory field is where a
# spaced path legitimately appears — its whole value is one path by definition,
# so the space is unambiguous there. In free prose it is NOT: nothing
# distinguishes a path continuing across a space from separate words, which is
# what let an unrelated earlier path vouch for a later relative one.
SPACED="$TMP_DIR/spaced.md"
sed 's|^Working directory: .*|Working directory: /Users/b/My Work/repo/.claude/worktrees/issue-44|' "$GOLDEN" >"$SPACED"
run_lint "$SPACED" >/dev/null 2>&1 \
  || fail "a spaced absolute path in the Working directory field must be allowed"

# The same spaced form in free prose is not exempt — deliberately.
assert_catches harness-path "See /tmp/build then repo/.claude/worktrees/issue-42-other."

# --- 4. No false positives on what a real handoff contains ---------------
# If any of these fire, the checker is unusable and will simply be bypassed.
BENIGN="$TMP_DIR/benign.md"
cp "$GOLDEN" "$BENIGN"
cat >>"$BENIGN" <<'EOF'
Scratch files are in /tmp and the binary is on /usr/local/bin.
The home directory is /home/ubuntu on the server.
Docs: https://github.com/auerbachb/claude-code-config/blob/main/README.md
Run `git status`, `git log --oneline -5`, and `gh pr view 903 --json state`.
Tests run with `npm test` and `pytest -q`.
The phrase "phased rollout" and the word "phases" are ordinary English.
A wrapper function named wrap_output is not a command.
EOF
run_lint "$BENIGN" >/dev/null 2>&1 || {
  run_lint "$BENIGN" >&2
  fail "the checker fired on ordinary paths, URLs, or commands — it would just get bypassed"
}

# --- 5. Structural rule: missing and empty sections ----------------------
# "Never emit an empty shell" is only real if emptiness is detectable.
MISSING="$TMP_DIR/missing.md"
grep -v '^## Decisions made this session$' "$GOLDEN" >"$MISSING"
out=$(run_lint "$MISSING" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "a document missing a required section must fail (got $rc)"
printf '%s' "$out" | grep -q 'required-sections' || fail "missing section did not report required-sections"
printf '%s' "$out" | grep -q 'is missing' || fail "missing section must be reported as missing"

EMPTY="$TMP_DIR/empty.md"
cat >"$EMPTY" <<'EOF'
# Session handoff

## Start here

## What we're working on

## Open work

## Decisions made this session

## Local state on this machine
EOF
out=$(run_lint "$EMPTY" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "an all-headings-no-content shell must fail (got $rc)"
printf '%s' "$out" | grep -q 'present but empty' \
  || fail "an empty section must be reported as empty, not merely as present"
EMPTY_HITS=$(printf '%s' "$out" | grep -c 'present but empty')
[[ "$EMPTY_HITS" -eq 5 ]] || fail "expected all 5 required sections flagged empty, got $EMPTY_HITS"

# A duplicated required heading defeats the emptiness check: content under the
# second copy vouches for an empty first one, and the reader hits the empty one
# first. Rejected outright rather than guessing which copy counts.
DUPE="$TMP_DIR/dupe.md"
{ printf '%s\n\n' "# Session handoff"
  printf '%s\n\n' "## Start here"          # deliberately empty
  printf '%s\n\n%s\n\n' "## Start here" "Actually do this."
  printf '%s\n\n%s\n\n' "## What we're working on" "x"
  printf '%s\n\n%s\n\n' "## Open work" "y"
  printf '%s\n\n%s\n\n' "## Decisions made this session" "z"
  printf '%s\n\n%s\n' "## Local state on this machine" "Working directory: /tmp/x"
} >"$DUPE"
out=$(run_lint "$DUPE" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "a duplicated required heading must fail (got $rc)"
printf '%s' "$out" | grep -q 'appears 2 times' \
  || fail "duplicate heading was not reported as a duplicate"$'\n'"got: $out"

# --- 6. The template's section list and the checker's agree --------------
# These are two files that must describe the same document. When they drift,
# every rendered handoff fails a rule nobody changed on purpose.
SECTION_COUNT=0
while IFS= read -r want; do
  [[ -n "$want" ]] || continue
  SECTION_COUNT=$((SECTION_COUNT + 1))
  grep -qF "## $want" "$TEMPLATE" \
    || fail "template is missing required section heading: $want"
done < <(sed -n '/^REQUIRED_SECTIONS=(/,/^)/p' "$LINT" | sed -n 's/^  "\(.*\)"$/\1/p')
[[ "$SECTION_COUNT" -eq 5 ]] \
  || fail "expected 5 required sections parsed from the checker, got $SECTION_COUNT"

# --- 6b. The working directory must be an absolute path ------------------
# It is the single address the reader needs in order to find the work at all.
# A relative one resolves against a checkout they are not standing in.
wd_fixture() { # replacement line for the Working directory field
  local f="$TMP_DIR/wd.md"
  sed "s|^Working directory: .*|$1|" "$GOLDEN" >"$f"
  printf '%s' "$f"
}

f=$(wd_fixture "Working directory: ../claude-code-config")
out=$(run_lint "$f" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "a relative working directory must fail (got $rc)"
printf '%s' "$out" | grep -q 'working-directory-absolute' \
  || fail "relative working directory did not report working-directory-absolute"

f=$(wd_fixture "Working directory:")
out=$(run_lint "$f" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "an empty working directory must fail (got $rc)"
printf '%s' "$out" | grep -q 'working-directory-absolute' \
  || fail "empty working directory did not report working-directory-absolute"

# A MISSING anchor must fail rather than silently disable the rule — otherwise
# rewording the template would turn the check off instead of failing loudly.
f="$TMP_DIR/wd-missing.md"
grep -v '^Working directory: ' "$GOLDEN" >"$f"
out=$(run_lint "$f" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "a missing Working directory line must fail (got $rc)"
printf '%s' "$out" | grep -q 'working-directory-absolute' \
  || fail "missing anchor must report working-directory-absolute, not pass silently"

# And the anchor the checker looks for must actually exist in the template,
# or the rule above is unreachable in practice.
grep -q 'Working directory:' "$TEMPLATE" \
  || fail "template lacks the 'Working directory:' anchor the checker requires"

# --- 7. CLI contract ------------------------------------------------------
run_lint --list-rules >/dev/null 2>&1 || fail "--list-rules should exit 0"
# Capture ONCE rather than re-running the pipeline per rule. Under `pipefail`,
# `producer | grep -q` is a race: grep exits on the first match, the producer
# takes SIGPIPE, and the pipeline reports failure even though the rule was
# found — intermittently, depending on whether the write completed first.
RULES_OUT=$(run_lint --list-rules)
RULE_COUNT=$(printf '%s\n' "$RULES_OUT" | grep -c .)
[[ "$RULE_COUNT" -eq 7 ]] || fail "expected 7 rules, got $RULE_COUNT"
for r in harness-path phase-vocabulary state-file skill-invocation \
         unrendered-placeholder required-sections working-directory-absolute; do
  printf '%s\n' "$RULES_OUT" | grep -qx "$r" || fail "--list-rules omits '$r'"
done

# `--` must hand the document through, not swallow it.
run_lint -- "$GOLDEN" >/dev/null 2>&1 || fail "'-- <doc>' should lint the document, not error"
"$LINT" -- "$GOLDEN" "$GOLDEN" >/dev/null 2>&1; [[ $? -eq 2 ]] || fail "'-- <doc> <doc>' should exit 2"

HELP_OUT=$("$LINT" --help 2>&1) || fail "--help should exit 0"
# Assert content, not just status: a truncated or broken --help is a silent
# regression if the test only looks at the exit code.
printf '%s' "$HELP_OUT" | grep -q 'EXIT STATUS' || fail "--help omits the EXIT STATUS section"
printf '%s' "$HELP_OUT" | grep -q -- '--repo-root'  || fail "--help omits the --repo-root flag"
printf '%s' "$HELP_OUT" | grep -q '4' || fail "--help does not mention exit code 4"

"$LINT" >/dev/null 2>&1; [[ $? -eq 2 ]] || fail "no document should exit 2"
"$LINT" --nope "$GOLDEN" >/dev/null 2>&1; [[ $? -eq 2 ]] || fail "unknown option should exit 2"
"$LINT" "$GOLDEN" "$GOLDEN" >/dev/null 2>&1; [[ $? -eq 2 ]] || fail "two documents should exit 2"
"$LINT" "$TMP_DIR/does-not-exist.md" >/dev/null 2>&1; [[ $? -eq 3 ]] || fail "unreadable document should exit 3"

run_lint --quiet "$GOLDEN" >"$TMP_DIR/quiet.out" 2>&1
[[ ! -s "$TMP_DIR/quiet.out" ]] || fail "--quiet should print nothing on a clean document"

# --- 8. A missing skill catalog fails closed -----------------------------
# The skill-invocation rule is catalog-driven. If the catalog cannot be found,
# the rule must fall back to a shape match — never silently check one rule
# fewer and call the document clean.
NO_CATALOG="$TMP_DIR/no-catalog"
mkdir -p "$NO_CATALOG"
SHAPED="$TMP_DIR/shaped.md"
cp "$GOLDEN" "$SHAPED"
printf '%s\n' "Then run /some-unknown-command to finish." >>"$SHAPED"
out=$("$LINT" --repo-root "$NO_CATALOG" "$SHAPED" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "with no catalog, a command-shaped token must still be caught (got $rc)"
printf '%s' "$out" | grep 'skill-invocation' | grep -q 'some-unknown-command' \
  || fail "fallback must flag the command-shaped line itself, not merely fail on something else"$'\n'"got: $out"

# An explicitly named root is authoritative — it must not be silently replaced
# by the script's own repo, or --repo-root would be decorative and the
# fail-closed path above untestable.
printf '%s' "$out" | grep -q 'harness-path' \
  && fail "unexpected harness-path violation in the no-catalog fixture"

# Short names are the most common skills (/pm, /go), so a fallback that only
# matched 3+ characters would miss exactly the ones it most needs to catch —
# defeating the fail-closed intent in the case it exists for.
for short in "/pm" "/go"; do
  SHORT_FIX="$TMP_DIR/short.md"
  cp "$GOLDEN" "$SHORT_FIX"
  printf '%s\n' "Then run $short to continue." >>"$SHORT_FIX"
  out=$("$LINT" --repo-root "$NO_CATALOG" "$SHORT_FIX" 2>&1); rc=$?
  [[ "$rc" -eq 1 ]] || fail "no-catalog fallback missed short command $short (rc=$rc)"
  printf '%s' "$out" | grep -q 'skill-invocation' \
    || fail "no-catalog fallback did not report skill-invocation for $short"
done

# --- 8b. Control characters never reach the report ------------------------
# The document quotes issue titles and review comments — text other people
# wrote. An embedded ANSI escape must not repaint the diagnostic that is
# supposed to be reporting on it.
ESC_FIX="$TMP_DIR/esc.md"
cp "$GOLDEN" "$ESC_FIX"
printf 'Then run \033[31m/wrap\033[0m to finish.\n' >>"$ESC_FIX"
out=$(run_lint "$ESC_FIX" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "an escape-laden violation line should still be caught (rc=$rc)"
printf '%s' "$out" | grep -q 'skill-invocation' || fail "escape fixture did not report the violation"
printf '%s' "$out" | LC_ALL=C grep -q '[[:cntrl:]]' \
  && fail "the report emitted raw control characters from document text"

# --- 9. Quota authority: nothing here estimates spend --------------------
# safety.md §"Anthropic Quota & Spend Authority" is deliberately unamended by
# #901; the human reads the authoritative usage view and invokes /pause. A
# silent contradiction between that rule and shipped behavior is the failure
# this block exists to prevent.
grep -q 'MUST NOT gate agent decisions' "$SAFETY_RULE" \
  || fail "safety.md quota prohibition text is missing or was altered"

BANNED='input_tokens|output_tokens|cache_read|used_percentage|tokens_remaining|budget_remaining|spend|estimate'

# Executable code only. The lint script and the recorder both *describe* the
# ban in their headers; matching that prose would fail them for saying the
# right thing.
for f in "$LINT" "$RECORDER"; do
  CODE="$TMP_DIR/code-only.sh"
  sed -e 's/[[:space:]]*#.*$//' "$f" | grep -v '^[[:space:]]*$' >"$CODE"
  if grep -nEi "$BANNED" "$CODE"; then
    fail "$(basename "$f") computes or reads token/spend accounting"
  fi
done

# The skill is Markdown, so scope the same check to what actually runs: its
# bash fenced blocks. Prose is checked positively instead, below.
SKILL_CODE="$TMP_DIR/skill-code.sh"
awk '/^```bash$/{f=1;next} /^```$/{f=0;next} f' "$SKILL" >"$SKILL_CODE"
[[ -s "$SKILL_CODE" ]] || fail "no bash blocks found in pause/SKILL.md — the code-body check would be vacuous"
if grep -nEi "$BANNED" "$SKILL_CODE"; then
  fail "pause/SKILL.md runs code that computes or reads token/spend accounting"
fi

# And positively: the skill must say out loud that the human is the sensor.
# Without this, the code check above passes on a skill that quietly tells the
# agent to judge remaining quota for itself.
grep -qi 'never estimates' "$SKILL" \
  || fail "pause/SKILL.md must state that it never estimates tokens/spend/quota"
grep -q 'Anthropic Quota & Spend Authority' "$SKILL" \
  || fail "pause/SKILL.md must cite the safety rule it is preserving"

echo "PASS: portable-handoff-lint.sh"
