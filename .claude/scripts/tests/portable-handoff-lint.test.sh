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
SKILL="$REPO_ROOT/.claude/skills/stop/SKILL.md"
TEMPLATE="$REPO_ROOT/.claude/skills/stop/references/portable-handoff-template.md"
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
  Owner: mine — nobody else is on this branch.
  Waiting on: the automated reviewer to re-run after the last push.
  Approval: nobody yet; this repository needs one approving review and green
  checks before it can merge.
  Files: portable-handoff-lint.sh and the skill that calls it — find them with
  `git ls-files '*portable-handoff*'`.
  What is left: answer whatever it raises, then merge once checks are green.
  Verify with: bash .github/scripts/run-hook-tests.sh

## Progress and verification

Completed: the handoff checker and command integration are implemented.
Remaining: answer review comments and merge the pull request.
Blockers and decisions needed: the automated review is still running.
Tests: the hook suite passes; re-run `bash .github/scripts/run-hook-tests.sh`.
Review: nobody has approved commit 0123456789abcdef0123456789abcdef01234567 yet.
Next commands: run `gh pr checks 903`, then the hook suite after any edit.

## Decisions made this session

- Reused the existing stop flag instead of adding a second one — both mean "do
  not start new work until a person says otherwise", and a second flag would
  need handling in every reader forever.

## Local state on this machine

Repository identity: auerbachb/claude-code-config
Repository root: /Users/b/Develop/claude-code-config
Working directory: /Users/b/Develop/claude-code-config/.claude/worktrees/issue-901-clean-pause
Worktree condition: linked worktree
Branch: issue-901-clean-pause
Base branch: main
HEAD commit: 0123456789abcdef0123456789abcdef01234567
Tracked changes: none
Untracked changes: none
Unpushed commits: none — run `git status` and `gh pr view 903` to confirm.

## Resume safely

Resume command: /stop-resume
For another agent: enter the working directory above and run `git status`.
Relaunch rule: inspect every recorded task outcome before replacing work; do not duplicate completed work.
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
# A Markdown link puts the destination after "](", so the leading run is link
# TEXT — stripping delimiters one at a time never reaches the path.
printf '%s\n' "Link: [working tree](/Users/b/repo/.claude/worktrees/issue-46-link)" >>"$ALLOWED"
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

## Progress and verification

## Local state on this machine

## Resume safely
EOF
# Structural-only markup is not an answer to the reader: a section holding just
# a fence pair or an HTML comment must still count as empty.
STRUCTURAL="$TMP_DIR/structural.md"
sed 's|^Adding a command that produces a handoff document any agent can act on, so a$|```|; s|^session ending on a usage limit does not lose where the work stood.$|```|' "$GOLDEN" >"$STRUCTURAL"
out=$(run_lint "$STRUCTURAL" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "a section holding only fence markers must count as empty (got $rc)"
printf '%s' "$out" | grep -q 'present but empty' \
  || fail "fence-only section was not reported as empty"$'\n'"got: $out"

# Step 6 prints the finished document inside a fence, so a render that captured
# its own fence would put every heading inside a code block. That must not
# satisfy the structural rules — the reader would see one undifferentiated code
# block with no sections at all.
FENCED="$TMP_DIR/fenced.md"
{ printf '%s\n' '```'; cat "$GOLDEN"; printf '%s\n' '```'; } >"$FENCED"
out=$(run_lint "$FENCED" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "a document whose headings are all inside a code fence must fail (got $rc)"
printf '%s' "$out" | grep -q 'is missing' \
  || fail "fenced headings should be reported as missing sections"$'\n'"got: $out"

out=$(run_lint "$EMPTY" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "an all-headings-no-content shell must fail (got $rc)"
printf '%s' "$out" | grep -q 'present but empty' \
  || fail "an empty section must be reported as empty, not merely as present"
EMPTY_HITS=$(printf '%s' "$out" | grep -c 'present but empty')
[[ "$EMPTY_HITS" -eq 7 ]] || fail "expected all 7 required sections flagged empty, got $EMPTY_HITS"

# A duplicated required heading defeats the emptiness check: content under the
# second copy vouches for an empty first one, and the reader hits the empty one
# first. Rejected outright rather than guessing which copy counts.
DUPE="$TMP_DIR/dupe.md"
{ printf '%s\n\n' "# Session handoff"
  printf '%s\n\n' "## Start here"          # deliberately empty
  printf '%s\n\n%s\n\n' "## Start here" "Actually do this."
  printf '%s\n\n%s\n\n' "## What we're working on" "x"
  printf '%s\n\n%s\n\n' "## Open work" "y"
  printf '%s\n\n%s\n\n' "## Progress and verification" "p"
  printf '%s\n\n%s\n\n' "## Decisions made this session" "z"
  printf '%s\n\n%s\n' "## Local state on this machine" "Working directory: /tmp/x"
  printf '\n%s\n\n%s\n' "## Resume safely" "Resume command: /stop-resume"
} >"$DUPE"
out=$(run_lint "$DUPE" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "a duplicated required heading must fail (got $rc)"
printf '%s' "$out" | grep -q 'appears 2 times' \
  || fail "duplicate heading was not reported as a duplicate"$'\n'"got: $out"

# --- 5b. Open-work entries: ownership, review state, verification --------
# These three rules came out of the cold read in issue #912: a document that
# passed every rule above went to an agent with the repository and nothing
# else, and it could not say who owned the half-finished work, whether anything
# was approved, or how to check that a change worked.
#
# Each fixture is a whole document rather than the golden plus a line, because
# what is under test is an ABSENCE inside one entry — and you cannot append an
# absence.
make_doc() { # $1 = path, $2 = body of the "Open work" section
  local f="$1" body="$2"
  cat >"$f" <<EOF
# Session handoff — auerbachb/claude-code-config — 2026-08-01 11:50 ET

## Start here

Read the two unresolved review comments on pull request 903 and answer them.

## What we're working on

Adding a command that produces a handoff document any agent can act on.

## Open work

$body

## Progress and verification

Completed: the checker change is implemented.
Remaining: finish review and merge.
Blockers and decisions needed: none recorded.
Tests: run bash .github/scripts/run-hook-tests.sh.
Review: re-check the linked pull request.
Next commands: run git status, then the hook suite.

## Decisions made this session

- Reused the existing stop flag rather than adding a second one — two flags
  would need handling in every later reader forever.

## Local state on this machine

Repository identity: auerbachb/claude-code-config
Repository root: /Users/b/Develop/claude-code-config
Working directory: /Users/b/Develop/claude-code-config
Worktree condition: main worktree
Branch: issue-901-clean-pause
Base branch: main
HEAD commit: 0123456789abcdef0123456789abcdef01234567
Tracked changes: none
Untracked changes: none
Unpushed commits: none

## Resume safely

Resume command: /stop-resume
For another agent: enter the working directory above and run git status.
Relaunch rule: inspect recorded task outcomes before replacing work.
EOF
}

PR_OWNER='  Owner: mine — nobody else is on this branch.'
PR_WAITING='  Waiting on: the automated reviewer to re-run after the last push.'
PR_APPROVAL='  Approval: nobody yet; one approving review and green checks are required.'
PR_VERIFY='  Verify with: bash .github/scripts/run-hook-tests.sh'
PR_HEAD='- **Pull request 903 — add the pause command**
  https://github.com/auerbachb/claude-code-config/pull/903'
PR_TAIL='  What is left: answer whatever it raises, then merge.'

assert_doc() { # description, expected-rc, body, [expected substring...]
  local desc="$1" want_rc="$2" body="$3"; shift 3
  local f="$TMP_DIR/entry.md" out rc needle
  make_doc "$f" "$body"
  out=$(run_lint "$f" 2>&1); rc=$?
  [[ "$rc" -eq "$want_rc" ]] \
    || fail "$desc: expected exit $want_rc, got $rc"$'\n'"got: $out"
  for needle in "$@"; do
    printf '%s' "$out" | grep -q -- "$needle" \
      || fail "$desc: expected output to mention '$needle'"$'\n'"got: $out"
  done
}

# A complete entry passes — the baseline these rules are measured against.
assert_doc "a fully described pull request" 0 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_TAIL"$'\n'"$PR_VERIFY"

# Ownership. The highest-cost miss in the cold read: an approved, green pull
# request belonging to another session looks maximally inviting.
assert_doc "a pull request with no owner" 1 \
  "$PR_HEAD"$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY" \
  'open-work-ownership' 'Pull request 903'

# An issue entry is an in-flight item too — ownership is not a pull-request rule.
assert_doc "an issue entry with no owner" 1 \
  '- **Issue 782 — compact output contracts**
  https://github.com/auerbachb/claude-code-config/issues/782
  Status: queued behind the statusline work.
  Verify with: bash .github/scripts/run-hook-tests.sh' \
  'open-work-ownership' 'Issue 782'

# A label with no value is the empty-shell failure at field scale.
assert_doc "an owner field with no value" 1 \
  "$PR_HEAD"$'\n''  Owner:'$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY" \
  'open-work-ownership'
assert_doc "an owner field holding only markup" 1 \
  "$PR_HEAD"$'\n''  Owner: **'$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY" \
  'open-work-ownership'

# ...but a bolded LABEL is an ordinary way to write the same answer, and
# rejecting it would train renderers to fight the checker.
assert_doc "a bolded owner label" 0 \
  "$PR_HEAD"$'\n''  **Owner:** mine'$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY"

# A field line that also contains a Markdown link must still be recognized —
# the destination-jump used for single tokens would eat the label here.
assert_doc "an owner line containing a Markdown link" 0 \
  "$PR_HEAD"$'\n''  Owner: mine, see [the note](https://example.com/n)'$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY"

# Markup that renders to NOTHING is the same empty shell as `Owner: **`, and
# leaves more behind than a character-class strip removes: both of these carry
# non-whitespace and both show the reader a blank where the answer goes.
assert_doc "an owner field holding only an empty Markdown link" 1 \
  "$PR_HEAD"$'\n''  Owner: [](/note)'$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY" \
  'open-work-ownership'
assert_doc "an owner field holding only an HTML comment" 1 \
  "$PR_HEAD"$'\n''  Owner: <!-- fill this in -->'$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY" \
  'open-work-ownership'
# The same treatment reaches the other three fields, which share the check.
assert_doc "an approval field holding only an HTML comment" 1 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n''  Approval: <!-- TODO -->'$'\n'"$PR_VERIFY" \
  'pull-request-review-state'
assert_doc "a verify field holding only an empty Markdown link" 1 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n''  Verify with: []()' \
  'verification-command'

# The negative control for all four: a link is reduced to its TEXT, not deleted,
# so a value written entirely as a link still answers the question. Without this
# the fix above would be indistinguishable from banning links in field values.
assert_doc "an owner field written entirely as a Markdown link" 0 \
  "$PR_HEAD"$'\n''  Owner: [mine](https://example.com/n)'$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY"
assert_doc "an owner field with a real answer beside a comment" 0 \
  "$PR_HEAD"$'\n''  Owner: mine <!-- confirmed at 11:50 -->'$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY"
# Reduction needs the whole `[text](dest)` shape. Brackets on their own are
# ordinary visible characters, and a checker that deleted them outright would
# reject a bracketed answer nobody would think twice about writing.
assert_doc "an owner field written in brackets" 0 \
  "$PR_HEAD"$'\n''  Owner: [unowned]'$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY"

# Review state: what is blocking it, and whether it may merge once unblocked.
assert_doc "a pull request with no approval line" 1 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n'"$PR_VERIFY" \
  'pull-request-review-state' 'Approval:'
assert_doc "a pull request with no waiting-on line" 1 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY" \
  'pull-request-review-state' 'Waiting on:'

# Those two are pull-request rules. An issue has neither a reviewer nor a merge
# button, and demanding the fields there would buy filler.
assert_doc "an owned issue needs no approval line" 0 \
  '- **Issue 782 — compact output contracts**
  https://github.com/auerbachb/claude-code-config/issues/782
  Owner: unowned — nobody has started it.
  Status: queued behind the statusline work.
  Verify with: bash .github/scripts/run-hook-tests.sh'

# Verification: in-flight work the reader cannot check is work they cannot finish.
assert_doc "in-flight work with no way to verify it" 1 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_TAIL" \
  'verification-command'

# ...and the rule is scoped to documents that HAVE in-flight work. "Nothing is
# in flight." is a complete answer; a command demanded there is invented.
assert_doc "nothing in flight needs no verify command" 0 "Nothing is in flight."

# An indented sub-bullet continues its entry rather than starting a new one, so
# a long entry does not have to repeat its own ownership line.
assert_doc "a sub-bullet does not start a new entry" 0 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n''  - it also touches the installer'$'\n'"$PR_VERIFY"

# A thematic break written with asterisks is a divider the reader sees, not an
# item anybody owns. Demanding an owner for a horizontal rule is the kind of
# false positive that gets a checker bypassed.
assert_doc "a thematic break is not an entry" 0 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY"$'\n\n''* * *'

# Fenced text is a sample, not an answer. The entry bullet, the headings and the
# working-directory field already refuse to read it; a field that still did
# would let an example vouch for the entry that contains it. The document-scoped
# verify rule is the worst of the three, because ONE fenced sample anywhere
# would answer for the whole document — including a render that captured the
# fence Step 6 prints the finished document inside.
FENCE='  ```'
assert_doc "a fenced sample cannot supply the owner" 1 \
  "$PR_HEAD"$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY"$'\n''  Other entries look like this:'$'\n'"$FENCE"$'\n''  Owner: mine'$'\n'"$FENCE" \
  'open-work-ownership'
assert_doc "a fenced sample cannot supply the approval" 1 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n'"$PR_VERIFY"$'\n'"$FENCE"$'\n''  Approval: nobody yet'$'\n'"$FENCE" \
  'pull-request-review-state'
assert_doc "a fenced command cannot satisfy the verify rule" 1 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$FENCE"$'\n'"$PR_VERIFY"$'\n'"$FENCE" \
  'verification-command'

# The negative control: gating on the fence must not make an ordinary fenced
# snippet break the entry around it. Fields OUTSIDE the fence still count, and
# the portability rules still read the fenced lines themselves.
assert_doc "a fenced snippet beside real fields is fine" 0 \
  "$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY"$'\n'"$FENCE"$'\n''  git status'$'\n'"$FENCE"

# Entries are judged one at a time: a complete first entry must not vouch for
# an incomplete second one.
TWO_ENTRIES="$PR_HEAD"$'\n'"$PR_OWNER"$'\n'"$PR_WAITING"$'\n'"$PR_APPROVAL"$'\n'"$PR_VERIFY"$'\n\n''- **Issue 782 — compact output contracts**
  https://github.com/auerbachb/claude-code-config/issues/782
  Status: queued.'
assert_doc "a second entry is judged on its own" 1 "$TWO_ENTRIES" 'open-work-ownership' 'Issue 782'
make_doc "$TMP_DIR/entry.md" "$TWO_ENTRIES"
OWNERSHIP_HITS=$(run_lint "$TMP_DIR/entry.md" 2>&1 | grep -c 'open-work-ownership')
[[ "$OWNERSHIP_HITS" -eq 1 ]] \
  || fail "expected exactly 1 ownership violation across two entries, got $OWNERSHIP_HITS"

# The last entry ends at end of file, where there is no boundary to notice.
# Section order is not enforced, so "Open work" can genuinely come last.
EOF_ENTRY="$TMP_DIR/eof-entry.md"
cat >"$EOF_ENTRY" <<'EOF'
# Session handoff — auerbachb/claude-code-config — 2026-08-01 11:50 ET

## Start here

Read the review comments on pull request 903.

## What we're working on

Adding a command that produces a handoff document any agent can act on.

## Decisions made this session

- Reused the existing stop flag rather than adding a second one.

## Progress and verification

Completed: the checker change is implemented.
Remaining: finish review.
Blockers and decisions needed: none recorded.
Tests: run `bash .github/scripts/run-hook-tests.sh`.
Review: the linked pull request still needs review.
Next commands: run `git status`.

## Local state on this machine

Repository identity: auerbachb/claude-code-config
Repository root: /Users/b/Develop/claude-code-config
Working directory: /Users/b/Develop/claude-code-config
Worktree condition: main worktree
Branch: issue-901-clean-pause
Base branch: main
HEAD commit: 0123456789abcdef0123456789abcdef01234567
Tracked changes: none
Untracked changes: none
Unpushed commits: none

## Resume safely

Resume command: /stop-resume
For another agent: enter the working directory above and run `git status`.
Relaunch rule: inspect recorded task outcomes before replacing work.

## Open work

- **Pull request 903 — add the pause command**
  https://github.com/auerbachb/claude-code-config/pull/903
  Waiting on: the automated reviewer.
  Approval: nobody yet.
  Verify with: bash .github/scripts/run-hook-tests.sh
EOF
out=$(run_lint "$EOF_ENTRY" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "an entry ending at EOF must still be judged (got $rc)"
printf '%s' "$out" | grep -q 'open-work-ownership' \
  || fail "the final entry in the file was never flushed"$'\n'"got: $out"

# --- 5c. The cold read, as a regression -----------------------------------
# The exact shape of the document issue #912 handed to a naive reader: every
# pull request says what it is waiting on, no entry says who owns it, no entry
# says whether it is approved, and nothing anywhere says how to check the work.
# The document this shape is taken from passed the seven rules that existed
# then, and was still short three answers. It must not pass these ten.
COLD_READ_SHAPE='- **Pull request 929 — align a header with what the code does**
  https://github.com/auerbachb/claude-code-config/pull/929
  Waiting on: one unresolved reviewer comment and nine unticked boxes.
  What is left: answer the comment, tick the boxes, merge.

- **Issue 779 — a status line for the terminal**
  https://github.com/auerbachb/claude-code-config/issues/779
  Status: being written right now, nothing committed yet.'
assert_doc "the pre-#912 document shape" 1 "$COLD_READ_SHAPE" \
  'open-work-ownership' 'pull-request-review-state' 'verification-command'

# --- 5d. The scan must reach the end of the document ----------------------
# A fatal expansion inside the read loop ends the loop where it stands and the
# script goes on to print a verdict about lines it never saw. The line count is
# the backstop; these two cases are where an off-by-one in it would surface as
# exit 4 on a perfectly good document.
#
# Only that direction is testable from here, and the asymmetry is worth stating
# rather than leaving a later reader to assume otherwise: the fault the guard
# exists for cannot be induced without editing the script, so deleting the
# guard leaves this suite green. What these fixtures pin is that it does not
# misfire — which is the half that would otherwise break real documents.
NO_EOL="$TMP_DIR/no-trailing-newline.md"
printf '%s' "$(cat "$GOLDEN")" >"$NO_EOL"      # command substitution strips the final newline
[[ -s "$NO_EOL" ]] || fail "the no-trailing-newline fixture is empty"
[[ "$(tail -c1 "$NO_EOL" | od -An -c | tr -d ' ')" != '\n' ]] \
  || fail "the no-trailing-newline fixture still ends in a newline"
run_lint "$NO_EOL" >/dev/null 2>&1 \
  || { run_lint "$NO_EOL" >&2; fail "a document with no trailing newline must still pass"; }

EMPTY_FILE="$TMP_DIR/zero-bytes.md"
: >"$EMPTY_FILE"
run_lint "$EMPTY_FILE" >/dev/null 2>&1; rc=$?
[[ "$rc" -eq 1 ]] || fail "an empty document should report missing sections (1), not a fault (got $rc)"

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
[[ "$SECTION_COUNT" -eq 7 ]] \
  || fail "expected 7 required sections parsed from the checker, got $SECTION_COUNT"

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

# Every takeover identity field is independently required. Removing one from
# an otherwise valid note must fail closed rather than silently narrowing the
# contract shared by the template, collector, and automatic producer.
for anchor in 'Repository identity:' 'Repository root:' 'Worktree condition:' \
              'Branch:' 'Base branch:' 'HEAD commit:' 'Tracked changes:' \
              'Untracked changes:'; do
  f="$TMP_DIR/missing-field.md"
  grep -v "^${anchor}" "$GOLDEN" >"$f"
  out=$(run_lint "$f" 2>&1); rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing '$anchor' must fail (got $rc)"
  printf '%s' "$out" | grep -q 'working-copy-fields' \
    || fail "missing '$anchor' did not report working-copy-fields"
done

EMPTY_THEN_VALID="$TMP_DIR/empty-then-valid-field.md"
awk '/^Repository identity:/ && !done { print "Repository identity:"; done=1 } { print }' \
  "$GOLDEN" >"$EMPTY_THEN_VALID"
out=$(run_lint "$EMPTY_THEN_VALID" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "an empty field followed by a populated duplicate must fail (got $rc)"
printf '%s' "$out" | grep -q 'working-copy-fields' \
  || fail "empty-then-valid duplicate did not report working-copy-fields"

# `/stop-resume` is permitted only in its dedicated field. A checkpoint that
# stopped nothing may explicitly mark the field not applicable, but every note
# still needs a relaunch rule to prevent duplicate background work.
NOT_APPLICABLE="$TMP_DIR/not-applicable.md"
sed 's|^Resume command: /stop-resume$|Resume command: not applicable — automatic checkpoint|' "$GOLDEN" >"$NOT_APPLICABLE"
run_lint "$NOT_APPLICABLE" >/dev/null 2>&1 \
  || fail "an automatic checkpoint may explicitly mark stop-resume not applicable"

BAD_RESUME="$TMP_DIR/bad-resume.md"
sed 's|^Resume command: /stop-resume$|Resume command: /pause-resume|' "$GOLDEN" >"$BAD_RESUME"
out=$(run_lint "$BAD_RESUME" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "an unrelated resume command must fail (got $rc)"
printf '%s' "$out" | grep -q 'resume-guidance' \
  || fail "bad resume entrypoint did not report resume-guidance"

PREFIX_RESUME="$TMP_DIR/prefix-resume.md"
sed 's|^Resume command: /stop-resume$|Resume command: /stop-resumeevil|' "$GOLDEN" >"$PREFIX_RESUME"
out=$(run_lint "$PREFIX_RESUME" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "a stop-resume prefix collision must fail (got $rc)"
printf '%s' "$out" | grep -q 'resume-guidance' \
  || fail "stop-resume prefix collision did not report resume-guidance"

EMPTY_RESUME="$TMP_DIR/empty-resume.md"
sed 's|^Resume command: /stop-resume$|Resume command:|' "$GOLDEN" >"$EMPTY_RESUME"
out=$(run_lint "$EMPTY_RESUME" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "an empty resume command must report a lint violation, not abort (got $rc)"
printf '%s' "$out" | grep -q 'resume-guidance' \
  || fail "empty resume command did not report resume-guidance"

CONFLICTING_RESUME="$TMP_DIR/conflicting-resume.md"
awk '/^Resume command: \/stop-resume$/ && !done { print "Resume command: /pause-resume"; done=1 } { print }' \
  "$GOLDEN" >"$CONFLICTING_RESUME"
out=$(run_lint "$CONFLICTING_RESUME" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "conflicting resume commands must fail (got $rc)"
printf '%s' "$out" | grep -q 'resume-guidance' \
  || fail "conflicting resume commands did not report resume-guidance"

NO_RELAUNCH="$TMP_DIR/no-relaunch.md"
grep -v '^Relaunch rule:' "$GOLDEN" >"$NO_RELAUNCH"
out=$(run_lint "$NO_RELAUNCH" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "missing relaunch guidance must fail (got $rc)"
printf '%s' "$out" | grep -q 'resume-guidance' \
  || fail "missing relaunch rule did not report resume-guidance"

OUTSIDE_RESUME="$TMP_DIR/outside-resume.md"
cp "$GOLDEN" "$OUTSIDE_RESUME"
printf '%s\n' 'Run /stop-resume from this unrelated line.' >>"$OUTSIDE_RESUME"
out=$(run_lint "$OUTSIDE_RESUME" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] || fail "stop-resume outside its dedicated field must fail (got $rc)"
printf '%s' "$out" | grep -q 'skill-invocation' \
  || fail "out-of-field stop-resume did not report skill-invocation"

# The per-entry fields are the same kind of contract, and the same kind of
# silent failure: reword one on either side and the rule stops firing on a
# document nobody changed. Both directions are asserted, because a rename in
# the checker alone is just as invisible as a rename in the template alone.
for anchor in 'Owner:' 'Waiting on:' 'Approval:' 'Verify with:'; do
  grep -qF "$anchor" "$TEMPLATE" \
    || fail "template lacks the '$anchor' anchor the checker requires"
  grep -qF "\"$anchor\"" "$LINT" \
    || fail "checker no longer names the '$anchor' anchor the template emits"
done

# --- 7. CLI contract ------------------------------------------------------
run_lint --list-rules >/dev/null 2>&1 || fail "--list-rules should exit 0"
# Capture ONCE rather than re-running the pipeline per rule. Under `pipefail`,
# `producer | grep -q` is a race: grep exits on the first match, the producer
# takes SIGPIPE, and the pipeline reports failure even though the rule was
# found — intermittently, depending on whether the write completed first.
RULES_OUT=$(run_lint --list-rules)
RULE_COUNT=$(printf '%s\n' "$RULES_OUT" | grep -c .)
[[ "$RULE_COUNT" -eq 12 ]] || fail "expected 12 rules, got $RULE_COUNT"
for r in harness-path phase-vocabulary state-file skill-invocation \
         unrendered-placeholder required-sections working-directory-absolute \
         open-work-ownership pull-request-review-state verification-command \
         working-copy-fields resume-guidance; do
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
# #901; the human reads the authoritative usage view and invokes /stop. A
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
